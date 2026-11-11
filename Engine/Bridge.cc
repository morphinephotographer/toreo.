#include "Bridge.h"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <future>
#include <memory>
#include <mutex>
#include <string_view>

#include "libtransmission/transmission.h"
#include "libtransmission/rpcimpl.h"
#include "libtransmission/session.h"
#include "libtransmission/torrent-metainfo.h"
#include "libtransmission/variant.h"
#include "libtransmission/utils.h"


namespace
{
void put(tr_variant::Map& map, std::string_view key, tr_variant value)
{
    map.insert_or_assign(tr_quark_new(key), std::move(value));
}

char* json(tr_variant const& value)
{
    return strdup(tr_variant_serde::json().compact().to_string(value).c_str());
}
}

void* rill_open(char const* folder, char const* options)
{
    try
    {
        tr_lib_init();

        auto defaults = tr_variant_serde::json().parse(std::string_view{options}).value_or(tr_variant::make_map());
        auto* map = defaults.get_if<tr_variant::Map>();
        if (!map)
            return nullptr;
        put(*map, "rpc_enabled", false);
        put(*map, "port_forwarding_enabled", false);
        put(*map, "queue_stalled_enabled", false);
        auto* session = tr_sessionInit(folder, true, defaults);
        if (!session || !session->mayWriteConfigDir())
        {
            if (session)
                tr_sessionClose(session);
            return nullptr;
        }
        auto ctor = std::unique_ptr<tr_ctor, decltype(&tr_ctorFree)>{tr_ctorNew(session), tr_ctorFree};
        tr_sessionLoadTorrents(session, ctor.get());
        return session;
    }
    catch (...)
    {
        return nullptr;
    }
}

void rill_close(void* handle, char const* folder)
{
    auto* session = static_cast<tr_session*>(handle);
    if (session)
    {
        try { tr_sessionSaveSettings(session, folder, tr_variant::make_map()); }
        catch (...) { /* Still shut down and flush resume records. */ }
        tr_sessionClose(session);
    }
}

char* rill_request(void* handle, char const* input)
{
    try
    {
        auto request = std::make_shared<std::string>(input);
        auto result = std::make_shared<std::promise<std::string>>();
        auto reply = result->get_future();
        auto* session = static_cast<tr_session*>(handle);
        session->run_in_session_thread([session, request, result]
        {
            try
            {
                tr_rpc_request_exec(session, std::string_view{*request}, [request, result](tr_session*, tr_variant&& response)
                {
                    try { result->set_value(tr_variant_serde::json().compact().to_string(response)); }
                    catch (...) { result->set_exception(std::current_exception()); }
                });
            }
            catch (...) { result->set_exception(std::current_exception()); }
        });
        if (reply.wait_for(std::chrono::seconds{8}) != std::future_status::ready)
            return nullptr;
        return strdup(reply.get().c_str());
    }
    catch (...)
    {
        return nullptr;
    }
}

char* rill_preview(char const* bytes, size_t length)
{
    try
    {
        auto result = tr_variant::make_map();
        auto& map = *result.get_if<tr_variant::Map>();
        tr_torrent_metainfo meta;
        tr_error error;
        if (!meta.parse_benc(std::string_view{bytes, length}, &error))
        {
            put(map, "error", std::string{error.message()});
            return json(result);
        }
        put(map, "name", std::string{meta.name()});
        auto files = tr_variant::make_vector(meta.file_count());
        auto& list = *files.get_if<tr_variant::Vector>();
        for (tr_file_index_t i = 0; i < meta.file_count(); ++i)
        {
            auto file = tr_variant::make_map();
            auto& values = *file.get_if<tr_variant::Map>();
            put(values, "name", std::string{meta.file_subpath(i)});
            put(values, "length", static_cast<int64_t>(meta.file_size(i)));
            list.push_back(std::move(file));
        }
        put(map, "files", std::move(files));
        return json(result);
    }
    catch (...)
    {
        return nullptr;
    }
}

char* rill_data_paths(void* handle, int id)
{
    try
    {
        auto* session = static_cast<tr_session*>(handle);
        auto const lock = tr_sessionLock(session);
        auto* torrent = tr_torrentFindFromId(session, id);
        if (!torrent)
            return nullptr;
        auto result = tr_variant::make_vector();
        auto& files = *result.get_if<tr_variant::Vector>();
        for (tr_file_index_t i = 0; i < tr_torrentFileCount(torrent); ++i)
        {
            auto path = tr_torrentFindFile(torrent, i);
            if (!path.empty())
                files.emplace_back(std::move(path));
        }
        return json(result);
    }
    catch (...)
    {
        return nullptr;
    }
}

void rill_free(char* value) { free(value); }
