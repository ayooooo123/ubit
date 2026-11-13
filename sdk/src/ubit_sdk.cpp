#include "ubit.h"
#include "engine.hpp"
#include <cstdlib>
#include <cstring>

struct ubit_cancel {
    std::atomic<bool> flag{false};
};

static char* dup_cstr(const std::string& s) {
    char* p = (char*)std::malloc(s.size() + 1);
    if (!p) return nullptr;
    std::memcpy(p, s.data(), s.size());
    p[s.size()] = '\0';
    return p;
}

static bool is_drm_msg(const std::string& msg) {
    for (size_t i = 0; i + 3 <= msg.size(); ++i) {
        if ((msg[i] == 'd' || msg[i] == 'D') &&
            (msg[i + 1] == 'r' || msg[i + 1] == 'R') &&
            (msg[i + 2] == 'm' || msg[i + 2] == 'M')) {
            bool left_ok = (i == 0) || !std::isalnum((unsigned char)msg[i - 1]);
            bool right_ok = (i + 3 == msg.size()) || !std::isalnum((unsigned char)msg[i + 3]);
            if (left_ok && right_ok) return true;
        }
    }
    return false;
}

extern "C" {

ubit_cancel_t* ubit_cancel_new(void) {
    return new (std::nothrow) ubit_cancel();
}

void ubit_cancel_trip(ubit_cancel_t* cancel) {
    if (cancel) cancel->flag.store(true, std::memory_order_seq_cst);
}

int ubit_cancel_is_tripped(const ubit_cancel_t* cancel) {
    return (cancel && cancel->flag.load(std::memory_order_seq_cst)) ? 1 : 0;
}

void ubit_cancel_free(ubit_cancel_t* cancel) {
    delete cancel;
}

void ubit_sdk_free_string(char* str) {
    std::free(str);
}

int ubit_sdk_info_json(
    const char* url,
    const char* config_dir,
    const ubit_net_vtable* net,
    void* net_ctx,
    char** out_json,
    char** out_error
) {
    if (out_json) *out_json = nullptr;
    if (out_error) *out_error = nullptr;
    if (!url || !*url || !net) {
        if (out_error) *out_error = dup_cstr("Invalid uBit SDK info arguments");
        return 1;
    }
    try {
        ubit::fs::path cfg = (config_dir && *config_dir) ? ubit::fs::path(config_dir) : ubit::AppPaths::temp_root() / "ubit-sdk";
        ubit::Settings settings = ubit::Settings::load_from(cfg);
        ubit::DownloadOpts opts = ubit::DownloadOpts::from_settings(settings);
        ubit::HTTPClient client = ubit::make_http_client(settings, opts, cfg, net, net_ctx);
        ubit::MediaInfo info = ubit::ExtractorRegistry::extract(url, client);
        if (info.is_drm && info.formats.empty()) {
            if (out_error) *out_error = dup_cstr("This video is DRM-protected");
            return 451;
        }
        std::string dumped = info.to_json().dump();
        if (out_json) *out_json = dup_cstr(dumped);
        return 0;
    } catch (const std::exception& e) {
        std::string msg = e.what();
        if (out_error) *out_error = dup_cstr(msg);
        return is_drm_msg(msg) ? 451 : 1;
    } catch (...) {
        if (out_error) *out_error = dup_cstr("This page has no video ubit can read");
        return 1;
    }
}

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
) {
    if (out_path) *out_path = nullptr;
    if (out_size) *out_size = 0;
    if (out_error) *out_error = nullptr;
    if (!url || !*url || !out_dir || !*out_dir || !net) {
        if (out_error) *out_error = dup_cstr("Invalid uBit SDK download arguments");
        return 1;
    }
    std::atomic<bool> local_cancel{false};
    std::atomic<bool>& cancel_ref = cancel ? cancel->flag : local_cancel;
    if (cancel_ref.load(std::memory_order_seq_cst)) {
        if (out_error) *out_error = dup_cstr("Cancelled");
        return 130;
    }

    try {
        ubit::fs::path cfg = (config_dir && *config_dir) ? ubit::fs::path(config_dir) : ubit::AppPaths::temp_root() / "ubit-sdk";
        ubit::Settings settings = ubit::Settings::load_from(cfg);
        ubit::DownloadOpts opts = ubit::DownloadOpts::from_settings(settings);
        opts.output_dir = out_dir;
        opts.connections = connections > 0 ? std::min<int>(32, connections) : settings.connections;

        int64_t done_size = 0;
        ubit::EventCallbacks cb;
        if (on_progress) {
            cb.on_progress = [&](double fr, int64_t done, int64_t tot, int64_t spd, int eta, double) {
                on_progress(cb_ctx, fr, done, tot, spd, (int32_t)eta);
            };
        }
        if (on_stage) {
            cb.on_stage = [&](const std::string& stg) {
                on_stage(cb_ctx, stg.c_str());
            };
        }
        cb.on_done = [&](const ubit::fs::path&, int64_t sz, double) {
            done_size = sz;
        };

        ubit::HTTPClient probe_client = ubit::make_http_client(settings, opts, cfg, net, net_ctx);
        ubit::MediaInfo initial = ubit::ExtractorRegistry::extract(url, probe_client);
        if (cancel_ref.load(std::memory_order_seq_cst)) throw ubit::InterruptedException();

        ubit::fs::path saved = ubit::download_single_item(
            url, &initial, settings, opts, cb, cancel_ref, cfg, net, net_ctx
        );
        if (out_path) *out_path = dup_cstr(saved.string());
        if (out_size) *out_size = done_size;
        return 0;
    } catch (const ubit::InterruptedException&) {
        if (out_error) *out_error = dup_cstr("Cancelled");
        return 130;
    } catch (const std::exception& e) {
        if (cancel_ref.load(std::memory_order_seq_cst)) {
            if (out_error) *out_error = dup_cstr("Cancelled");
            return 130;
        }
        std::string msg = e.what();
        if (out_error) *out_error = dup_cstr(msg);
        return is_drm_msg(msg) ? 451 : 1;
    } catch (...) {
        if (out_error) *out_error = dup_cstr("ubit failed to download this page");
        return 1;
    }
}

} // extern "C"
