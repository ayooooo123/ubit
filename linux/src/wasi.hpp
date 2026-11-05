#pragma once
// WebAssembly (WASI) build: the host owns DNS, TCP and TLS and decides which addresses the module may reach.
// Each call returns a negative number on failure; `read` returns 0 at end of stream.
#ifdef __wasi__
#include <cstdint>

extern "C" {
__attribute__((import_module("ubit_net"), import_name("open")))
int32_t ubit_net_open(const char* host, int32_t host_len, int32_t port, int32_t tls);
__attribute__((import_module("ubit_net"), import_name("write")))
int32_t ubit_net_write(int32_t handle, const void* buf, int32_t len);
__attribute__((import_module("ubit_net"), import_name("read")))
int32_t ubit_net_read(int32_t handle, void* buf, int32_t cap);
__attribute__((import_module("ubit_net"), import_name("close")))
void ubit_net_close(int32_t handle);
}
#endif
