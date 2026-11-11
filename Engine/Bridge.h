#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RILL_API __attribute__((visibility("default")))

RILL_API void* rill_open(char const* folder, char const* options);
RILL_API void rill_close(void* handle, char const* folder);
RILL_API char* rill_request(void* handle, char const* json);
RILL_API char* rill_preview(char const* bytes, size_t length);
RILL_API char* rill_data_paths(void* handle, int id);
RILL_API void rill_free(char* value);

#ifdef __cplusplus
}
#endif
