#ifndef UBIT_H
#define UBIT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Host-supplied TCP/TLS transport vtable: every outbound connection passes through the host's DNS/SSRF policy and TLS stack.
typedef struct ubit_net_vtable {
    int32_t (*open)(void* ctx, const char* host, int32_t host_len, int32_t port, int32_t tls);
    int32_t (*write)(void* ctx, int32_t handle, const void* buf, int32_t len);
    int32_t (*read)(void* ctx, int32_t handle, void* buf, int32_t cap);
    void (*close)(void* ctx, int32_t handle);
} ubit_net_vtable;

typedef struct ubit_cancel ubit_cancel_t;

typedef void (*ubit_progress_fn)(
    void* ctx,
    double fraction,
    int64_t downloaded,
    int64_t total,
    int64_t speed,
    int32_t eta_secs
);

typedef void (*ubit_stage_fn)(void* ctx, const char* stage);

ubit_cancel_t* ubit_cancel_new(void);
void ubit_cancel_trip(ubit_cancel_t* cancel);
int ubit_cancel_is_tripped(const ubit_cancel_t* cancel);
void ubit_cancel_free(ubit_cancel_t* cancel);

// Status codes: 0 = ok, 1 = error, 130 = cancelled, 451 = DRM-protected.
int ubit_sdk_info_json(
    const char* url,
    const char* config_dir,
    const ubit_net_vtable* net,
    void* net_ctx,
    char** out_json,
    char** out_error
);

int ubit_sdk_download(
    const char* url,
    const char* out_dir,
    const char* config_dir,
    int32_t connections,
    const ubit_net_vtable* net,
    void* net_ctx,
    ubit_progress_fn on_progress,
    ubit_stage_fn on_stage,
    void* cb_ctx,
    ubit_cancel_t* cancel,
    char** out_path,
    int64_t* out_size,
    char** out_error
);

void ubit_sdk_free_string(char* str);

#ifdef __cplusplus
}
#endif

#endif
