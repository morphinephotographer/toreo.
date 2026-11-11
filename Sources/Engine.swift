import Foundation
import CryptoKit

struct Transfer: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let name, hashString, downloadDir, errorString: String
    let status, error, eta, queuePosition: Int
    let percentDone, metadataPercentComplete, uploadRatio, recheckProgress: Double
    let sizeWhenDone, leftUntilDone, rateDownload, rateUpload, uploadedEver: Int64
    let isFinished: Bool

    var active: Bool { status == 4 || status == 6 || status == 2 }
    var downloading: Bool { status == 4 && metadataPercentComplete >= 1 && sizeWhenDone > 0 && leftUntilDone > 0 }
    var complete: Bool { metadataPercentComplete >= 1 && percentDone >= 1 }
    var paused: Bool { status == 0 }
    var progress: Double { status == 2 ? recheckProgress : percentDone }
    var state: String {
        if error == 3 { return tr("Ошибка") }
        switch status {
        case 0: return complete ? tr("Завершено") : tr("Пауза")
        case 1: return tr("Ожидает проверки")
        case 2: return tr("Проверка")
        case 3, 5: return tr("В очереди")
        case 4: return metadataPercentComplete < 1 ? tr("Получаем список файлов") : tr("Скачивание")
        case 6: return tr("Раздача")
        default: return tr("Ожидание")
        }
    }
}

struct TorrentFile: Codable, Sendable {
    let name: String
    let length: Int64
    var bytesCompleted: Int64?
}

struct FileState: Identifiable, Sendable {
    let id: Int
    let file: TorrentFile
    var wanted: Bool
}

struct Preferences: Decodable, Sendable {
    var downloadDir: String
    static var initial: Self {
        .init(downloadDir: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads").path)
    }
}

struct RillError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct PreviewResult: Decodable, Sendable {
    let name: String?
    let files: [TorrentFile]?
    let error: String?
}

struct ImportDraft: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let bytes: Data?
    let magnet: String?
    let files: [TorrentFile]
    var excluded: Set<Int> = []
    var folder: String
    var start = true
}

actor Engine {
    private var handle: UnsafeMutableRawPointer?
    private var folder: String?

    private var importFolder: String?
    private var importedFiles: Set<String>?
    private var examinedFiles: [URL: ImportStamp] = [:]

    private struct ImportStamp: Equatable {
        let size: Int
        let modified: Date?
    }

    func importTorrents(from source: String, to destination: String) -> (imported: Bool, error: String?) {
        guard let folder, handle != nil, !Task.isCancelled else { return (false, nil) }
        let ledger = URL(fileURLWithPath: folder, isDirectory: true).appending(path: "auto-import.json")
        var imported = false
        var failed: [String] = []
        do {
            if importedFiles == nil {
                importedFiles = FileManager.default.fileExists(atPath: ledger.path)
                    ? try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: ledger)) : []
            }
            if importFolder != source {
                importFolder = source
                examinedFiles.removeAll()
            }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let directory = URL(fileURLWithPath: source, isDirectory: true)
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            let torrents = entries.filter { $0.pathExtension.lowercased() == "torrent" }
            let present = Set(torrents)
            examinedFiles = examinedFiles.filter { present.contains($0.key) }
            for url in torrents {
                guard !Task.isCancelled else { break }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, (1...32_000_000).contains(size) else { continue }
                let stamp = ImportStamp(size: size, modified: values.contentModificationDate)
                guard examinedFiles[url] != stamp else { continue }
                do {
                    let draft = try inspect(url, folder: destination)
                    guard let data = draft.bytes else { continue }
                    let digest = Data(SHA256.hash(data: data)).base64EncodedString()
                    if importedFiles?.contains(digest) != true {
                        _ = try add(draft)
                        imported = true
                        var updated = importedFiles ?? []
                        updated.insert(digest)
                        try JSONEncoder().encode(updated).write(to: ledger, options: .atomic)
                        importedFiles = updated
                    }
                    examinedFiles[url] = stamp
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
        } catch {
            return (imported, "\(tr("Автоимпорт недоступен")): \(error.localizedDescription)")
        }
        if let first = failed.first { return (imported, "\(tr("Не удалось импортировать")) «\(first)».") }
        return (imported, nil)
    }

    func start() throws {
        guard handle == nil else { return }
        let env = ProcessInfo.processInfo.environment
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let location = env["RILL_STORE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appending(path: "Rill/Engine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        var options = "{}"
        if !FileManager.default.fileExists(atPath: location.appending(path: "settings.json").path) {
            options = #"{"peer_port_random_on_start":true}"#
        }
        guard let opened = rill_open(location.path, options) else {
            throw RillError(tr("Не удалось открыть сессию. Проверьте доступ к папке данных toreo. и закройте другие экземпляры приложения."))
        }
        handle = opened
        folder = location.path
        do {
            try run("session_set", Self.unlimitedSettings)
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let handle, let folder {
            rill_close(handle, folder)
            self.handle = nil
        }
    }

    func list() throws -> [Transfer] {
        struct Result: Decodable { let torrents: [Transfer] }
        let fields = ["id", "name", "hash_string", "download_dir", "error", "error_string", "status", "eta",
                      "queue_position", "percent_done", "metadata_percent_complete", "size_when_done", "left_until_done",
                      "rate_download", "rate_upload", "uploaded_ever", "upload_ratio", "recheck_progress", "is_finished"]
        let response: Result = try request("torrent_get", ["fields": fields])
        return response.torrents.sorted { $0.queuePosition < $1.queuePosition }
    }

    func settings() throws -> Preferences {
        try request("session_get", [:])
    }

    private static let unlimitedSettings = [
        "download_queue_enabled": false, "seed_queue_enabled": false,
        "speed_limit_down_enabled": false, "speed_limit_up_enabled": false,
        "alt_speed_enabled": false, "alt_speed_time_enabled": false,
        "seed_ratio_limited": false, "idle_seeding_limit_enabled": false
    ]

    func transferLimitsAreDisabled() throws -> Bool {
        struct Flags: Decodable {
            let downloadQueueEnabled, seedQueueEnabled, speedLimitDownEnabled, speedLimitUpEnabled: Bool
            let altSpeedEnabled, altSpeedTimeEnabled, seedRatioLimited, idleSeedingLimitEnabled: Bool
        }
        let settings: Flags = try request("session_get", [:])
        return !settings.downloadQueueEnabled && !settings.seedQueueEnabled &&
            !settings.speedLimitDownEnabled && !settings.speedLimitUpEnabled &&
            !settings.altSpeedEnabled && !settings.altSpeedTimeEnabled &&
            !settings.seedRatioLimited && !settings.idleSeedingLimitEnabled
    }

    func setDownloadFolder(_ path: String) throws {
        try run("session_set", ["download_dir": path])
    }

    func relocate(_ torrent: Transfer, to path: String) throws {
        try run("torrent_set_location", ["ids": [torrent.hashString], "location": path, "move": false])
        try change(torrent.hashString, command: "torrent_verify")
    }

    func inspect(_ url: URL, folder: String) throws -> ImportDraft {
        if url.scheme?.lowercased() == "magnet" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let hashes = components?.queryItems?.filter { $0.name == "xt" }.compactMap(\.value) ?? []
            guard hashes.contains(where: { $0.lowercased().hasPrefix("urn:btih:") }) else {
                throw RillError(tr("Нужна magnet-ссылка с идентификатором BitTorrent v1 (btih)."))
            }
            let name = components?.queryItems?.first { $0.name == "dn" }?.value
            return .init(name: name ?? tr("Magnet-ссылка"), bytes: nil, magnet: url.absoluteString, files: [], folder: folder)
        }
        guard url.isFileURL, url.pathExtension.lowercased() == "torrent" else {
            throw RillError(tr("Выберите файл .torrent или magnet-ссылку."))
        }
        let length = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...32_000_000).contains(length) else { throw RillError(tr("Размер файла .torrent должен быть меньше 32 МБ.")) }
        let bytes = try Data(contentsOf: url)
        guard !bytes.isEmpty, bytes.count <= 32_000_000 else { throw RillError(tr("Не удалось прочитать файл .torrent.")) }
        let pointer = bytes.withUnsafeBytes { rill_preview($0.bindMemory(to: CChar.self).baseAddress, $0.count) }
        guard let pointer else { throw RillError(tr("Не удалось прочитать метаданные.")) }
        defer { rill_free(pointer) }
        let result = try JSONDecoder().decode(PreviewResult.self, from: Data(String(cString: pointer).utf8))
        guard let name = result.name, let files = result.files else {
            if result.error?.contains("missing v1 metadata") == true {
                throw RillError(tr("Этот файл использует только BitTorrent v2."))
            }
            throw RillError(tr("Файл .torrent повреждён или имеет неподдерживаемый формат."))
        }
        return .init(name: name, bytes: bytes, magnet: nil, files: files, folder: folder)
    }

    func importTorrent(_ url: URL, to folder: String) throws -> String {
        try add(inspect(url, folder: folder))
    }

    func add(_ draft: ImportDraft) throws -> String {
        struct Added: Decodable { let hashString: String }
        struct Result: Decodable { let torrentAdded: Added?; let torrentDuplicate: Added? }
        var args: [String: Any] = ["download_dir": draft.folder, "paused": !draft.start]
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: draft.folder, isDirectory: &directory),
              directory.boolValue, FileManager.default.isWritableFile(atPath: draft.folder) else {
            throw RillError(tr("Выберите папку, в которую можно записывать файлы."))
        }
        if let bytes = draft.bytes { args["metainfo"] = bytes.base64EncodedString() }
        if let magnet = draft.magnet { args["filename"] = magnet }
        if !draft.excluded.isEmpty { args["files_unwanted"] = draft.excluded.sorted() }
        let result: Result = try request("torrent_add", args)
        guard let added = result.torrentAdded ?? result.torrentDuplicate else {
            throw RillError(tr("Движок не вернул добавленную передачу."))
        }
        return added.hashString
    }

    func files(_ hash: String) throws -> [FileState] {
        struct Entry: Decodable { let files: [TorrentFile]; let wanted: [Bool] }
        struct Result: Decodable { let torrents: [Entry] }
        let result: Result = try request("torrent_get", ["ids": [hash], "fields": ["files", "wanted"]])
        guard let entry = result.torrents.first else { return [] }
        return zip(entry.files, entry.wanted).enumerated().map {
            .init(id: $0.offset, file: $0.element.0, wanted: $0.element.1)
        }
    }

    func change(_ hash: String, command: String) throws {
        try change([hash], command: command)
    }

    func change(_ hashes: [String], command: String) throws {
        guard !hashes.isEmpty else { return }
        try run(command, ["ids": hashes])
    }

    func completedFiles(_ torrent: Transfer) throws -> [URL] {
        guard let current = try list().first(where: { $0.hashString == torrent.hashString }), current.complete else {
            throw RillError(tr("Передача ещё не завершена."))
        }
        let root = URL(fileURLWithPath: current.downloadDir, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let wanted = try files(current.hashString).filter(\.wanted).map {
            root.appending(path: $0.file.name).standardizedFileURL.path
        }
        let wantedPaths = Set(wanted)
        let targets = try existingPaths(current.id).compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let real = url.resolvingSymlinksInPath()
            guard real.path.hasPrefix(prefix), wantedPaths.contains(real.path),
                  try real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return real
        }
        guard !targets.isEmpty else { throw RillError(tr("Скачанные файлы не найдены.")) }
        return targets
    }

    func trashFiles(_ torrent: Transfer) throws {
        guard torrent.metadataPercentComplete >= 1,
              let current = try list().first(where: { $0.hashString == torrent.hashString }) else {
            throw RillError(tr("Список файлов этой передачи недоступен."))
        }
        guard current.paused else {
            throw RillError(tr("Сначала приостановите передачу."))
        }

        let parent = URL(fileURLWithPath: current.downloadDir, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RillError(tr("Папка загрузки недоступна."))
        }
        let realParent = parent.resolvingSymlinksInPath().path
        let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        let realPrefix = realParent.hasSuffix("/") ? realParent : realParent + "/"
        let occupied = try Set(list().filter { $0.id != current.id }.flatMap { item in
            try existingPaths(item.id).map { canonicalKey(URL(fileURLWithPath: $0)) }
        })
        let targets = try Set(existingPaths(current.id)).map { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let type = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard url.path.hasPrefix(prefix), url.path != parent.path,
                  url.resolvingSymlinksInPath().path == realPrefix + String(url.path.dropFirst(prefix.count)),
                  type.isRegularFile == true, type.isSymbolicLink != true,
                  !occupied.contains(canonicalKey(url)) else {
                throw RillError("\(tr("Файл принадлежит другой передаче или находится за пределами папки загрузки")): \(url.lastPathComponent)")
            }
            return url
        }

        var moved = 0
        for url in targets {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved += 1
            } catch {
                throw RillError("\(tr("Не удалось переместить")) «\(url.lastPathComponent)» \(tr("в Корзину. Перемещено файлов")): \(moved). \(tr("Передача на паузе."))")
            }
        }
        try change(current.hashString, command: "torrent_remove")
    }

    private func existingPaths(_ id: Int) throws -> [String] {
        guard let handle, let pointer = rill_data_paths(handle, Int32(id)) else {
            throw RillError(tr("Не удалось определить расположение файлов."))
        }
        defer { rill_free(pointer) }
        return try JSONDecoder().decode([String].self, from: Data(String(cString: pointer).utf8))
    }

    private func canonicalKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
    }

    func setWanted(_ hash: String, index: Int, wanted: Bool) throws {
        try run("torrent_set", ["ids": [hash], (wanted ? "files_wanted" : "files_unwanted"): [index]])
    }

    private struct Empty: Decodable {}
    private struct Reply<T: Decodable>: Decodable {
        struct Fault: Decodable { let message: String }
        let result: T?
        let error: Fault?
    }

    private func run(_ method: String, _ args: [String: Any]) throws {
        let _: Empty = try request(method, args)
    }

    private func request<T: Decodable>(_ method: String, _ args: [String: Any]) throws -> T {
        guard let handle else { throw RillError(tr("Сессия передач недоступна.")) }
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": args
        ])
        guard let pointer = rill_request(handle, String(decoding: request, as: UTF8.self)) else {
            throw RillError(tr("Движок не ответил вовремя."))
        }
        defer { rill_free(pointer) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reply = try decoder.decode(Reply<T>.self, from: Data(String(cString: pointer).utf8))
        if let fault = reply.error { throw RillError(fault.message) }
        guard let result = reply.result else { throw RillError(tr("Движок вернул пустой ответ.")) }
        return result
    }
}
