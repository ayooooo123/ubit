#include "engine.hpp"
#include <iostream>
#ifndef __wasi__
#include <csignal>
#include <sys/un.h>
#endif

namespace ubit {

static std::atomic<int> g_sigint_count{0};
static std::atomic<bool> g_cancel_flag{false};

extern "C" void on_sigint(int) {
    int c = ++g_sigint_count;
    g_cancel_flag.store(true);
    if (c >= 2) {
        const char* msg = "\nDiscarded.\n";
        (void)::write(STDERR_FILENO, msg, std::strlen(msg));
        std::_Exit(130);
    }
}

inline void upsert_library_item(const Json& item) {
    AppPaths::ensure();
    Json arr = Json::parse(read_file_text(AppPaths::library_file()));
    if (!arr.is_arr()) arr = Json::array();
    std::string id = item["id"].str();
    bool replaced = false;
    for (auto& el : arr.a) {
        if (el["id"].str() == id) { el = item; replaced = true; break; }
    }
    if (!replaced) arr.a.insert(arr.a.begin(), item);
    std::string s = arr.dump(2);
    write_file_atomic(AppPaths::library_file(), s.data(), s.size());
}

#ifndef __wasi__
// MARK: - Native Linux Desktop App Loopback UI (GTK WebKit / Chromeless --app= Window)

inline int run_linux_desktop_gui() {
    AppPaths::ensure();
    int sfd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (sfd < 0) return 1;
    int one = 1;
    ::setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (::bind(sfd, (sockaddr*)&addr, sizeof(addr)) != 0 || ::listen(sfd, 16) != 0) {
        ::close(sfd);
        return 1;
    }
    socklen_t alen = sizeof(addr);
    ::getsockname(sfd, (sockaddr*)&addr, &alen);
    int port = ntohs(addr.sin_port);
    std::string app_url = "http://127.0.0.1:" + std::to_string(port) + "/";

    static const char* UI_HTML = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>uBit</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,"Inter","Segoe UI",sans-serif}
body{background:#0f0f12;color:#f4f4f6;height:100vh;display:flex;flex-direction:column;overflow:hidden}
.top{display:flex;gap:10px;padding:14px 16px;align-items:center;border-bottom:1px solid #222228}
.omni{flex:1;display:flex;align-items:center;background:#1a1a20;border:1px solid #2c2c35;border-radius:9px;padding:8px 12px;gap:8px}
.omni input{flex:1;background:none;border:none;color:#fff;font-size:13.5px;outline:none}
.btn{background:#2563eb;color:#fff;border:none;border-radius:8px;padding:8px 14px;font-size:12.5px;font-weight:600;cursor:pointer}
.btn:hover{background:#1d4ed8}
.subbar{display:flex;gap:8px;padding:10px 16px;font-size:12px;color:#9ca3af;align-items:center}
.pill{padding:4px 10px;border-radius:99px;cursor:pointer}
.pill.on{background:rgba(37,99,235,.22);color:#60a5fa;font-weight:600}
.list{flex:1;overflow-y:auto;padding:12px 16px;display:flex;flex-direction:column;gap:8px}
.card{display:flex;gap:12px;padding:10px 12px;background:#17171c;border:1px solid #23232b;border-radius:10px;align-items:center}
.thumb{width:92px;height:52px;border-radius:7px;background:#252530 center/cover;flex-shrink:0}
.meta{flex:1;min-width:0}
.title{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub{font-size:11px;color:#9ca3af;margin-top:3px}
.foot{padding:8px 16px;border-top:1px solid #222228;font-size:11px;color:#71717a;display:flex;justify-content:space-between}
</style></head><body>
<div class="top">
  <form class="omni" onsubmit="addLink(event)">
    <input id="u" placeholder="Paste a link to download, or search YouTube…" autofocus>
    <select id="m" style="background:#26262f;color:#ddd;border:none;border-radius:5px;padding:3px 6px;font-size:11px">
      <option value="video">Video (MP4)</option><option value="audio">Audio (M4A)</option>
    </select>
  </form>
  <button class="btn" onclick="addLink(event)">Download</button>
</div>
<div class="subbar"><b style="color:#eee">Library</b><span class="pill on">All</span></div>
<div class="list" id="list"></div>
<div class="foot"><span id="folder">~/Downloads</span><span>uBit 0.3.1 · Zero-Paywall Native Engine</span></div>
<script>
async function refresh(){
  const r=await fetch('/api/list');const d=await r.json();
  document.getElementById('folder').textContent=d.folder;
  const el=document.getElementById('list');
  el.innerHTML=(d.items||[]).map(i=>`<div class="card">
    <div class="thumb" style="background-image:url('${i.thumbnail||''}')"></div>
    <div class="meta"><div class="title">${i.title||i.url}</div>
    <div class="sub">${i.site||''} · ${i.state} ${i.progress?('· '+Math.round(i.progress*100)+'%'):''} ${i.path?('· '+i.path):''}</div></div>
  </div>`).join('')||'<div style="margin:auto;color:#666;font-size:13px">Paste any video or audio link above and press Enter</div>';
}
async function addLink(e){e.preventDefault();const inp=document.getElementById('u');const v=inp.value.trim();if(!v)return;
  inp.value='';await fetch('/api/add',{method:'POST',body:JSON.stringify({url:v,mode:document.getElementById('m').value})});refresh();}
setInterval(refresh,800);refresh();
</script></body></html>)HTML";

    // Launch native desktop window (chromeless --app= or xdg-open)
    std::thread([app_url]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        if (std::system("command -v termux-open-url >/dev/null 2>&1") == 0) {
            std::string cmd = "termux-open-url \"" + app_url + "\" >/dev/null 2>&1 &";
            (void)std::system(cmd.c_str());
            return;
        }
        const char* browsers[] = {"chromium", "chromium-browser", "google-chrome", "brave-browser", "microsoft-edge"};
        for (const char* b : browsers) {
            std::string check = "command -v " + std::string(b) + " >/dev/null 2>&1";
            if (std::system(check.c_str()) == 0) {
                std::string cmd = std::string(b) + " --app=\"" + app_url + "\" --window-size=740,540 >/dev/null 2>&1 &";
                (void)std::system(cmd.c_str());
                return;
            }
        }
        std::string xdg = "xdg-open \"" + app_url + "\" >/dev/null 2>&1 &";
        (void)std::system(xdg.c_str());
    }).detach();

    fprintf(stderr, "uBit UI running at %s (Ctrl-C to quit)\n", app_url.c_str());

    std::mutex jobs_mu;
    Json live_jobs = Json::parse(read_file_text(AppPaths::library_file()));
    if (!live_jobs.is_arr()) live_jobs = Json::array();

    while (!g_cancel_flag.load()) {
        int cfd = ::accept(sfd, nullptr, nullptr);
        if (cfd < 0) continue;
        char buf[8192];
        ssize_t n = ::recv(cfd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) { ::close(cfd); continue; }
        buf[n] = 0;
        std::string req(buf, (size_t)n);

        auto send_resp = [&](const char* ct, const std::string& body) {
            std::string h = "HTTP/1.1 200 OK\r\nContent-Type: " + std::string(ct) + "\r\nContent-Length: " + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
            (void)::send(cfd, h.data(), h.size(), MSG_NOSIGNAL);
            ::close(cfd);
        };

        if (req.rfind("GET /api/list", 0) == 0) {
            Settings s = Settings::load();
            Json out = Json::object();
            out["folder"] = s.folder;
            {
                std::lock_guard<std::mutex> lk(jobs_mu);
                out["items"] = live_jobs;
            }
            send_resp("application/json", out.dump());
        } else if (req.rfind("POST /api/add", 0) == 0) {
            auto bpos = req.find("\r\n\r\n");
            Json payload = (bpos != std::string::npos) ? Json::parse(req.substr(bpos + 4)) : Json();
            std::string u = payload["url"].str();
            bool aud = payload["mode"].str() == "audio";
            if (!u.empty()) {
                std::string jid = std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
                {
                    std::lock_guard<std::mutex> lk(jobs_mu);
                    Json item = Json::object();
                    item["id"] = jid; item["url"] = u; item["title"] = u; item["state"] = "downloading"; item["progress"] = 0.0;
                    live_jobs.a.insert(live_jobs.a.begin(), item);
                }
                std::thread([&, jid, u, aud]() {
                    Settings s = Settings::load();
                    DownloadOpts opts = DownloadOpts::from_settings(s);
                    opts.audio_only = aud;
                    EventCallbacks cb;
                    cb.on_info = [&](const MediaInfo& inf, const std::string&, const std::string&, const fs::path& p) {
                        std::lock_guard<std::mutex> lk(jobs_mu);
                        for (auto& it : live_jobs.a) if (it["id"].str() == jid) {
                            it["title"] = inf.title; it["site"] = inf.site; it["thumbnail"] = inf.thumbnail; it["path"] = p.string();
                        }
                    };
                    cb.on_progress = [&](double fr, int64_t, int64_t, int64_t, int, double) {
                        std::lock_guard<std::mutex> lk(jobs_mu);
                        for (auto& it : live_jobs.a) if (it["id"].str() == jid) it["progress"] = fr;
                    };
                    cb.on_done = [&](const fs::path& p, int64_t sz, double) {
                        std::lock_guard<std::mutex> lk(jobs_mu);
                        for (auto& it : live_jobs.a) if (it["id"].str() == jid) {
                            it["state"] = "done"; it["progress"] = 1.0; it["path"] = p.string(); it["totalBytes"] = sz;
                            upsert_library_item(it);
                        }
                    };
                    try { download_single_item(u, nullptr, s, opts, cb, g_cancel_flag); }
                    catch (const std::exception& ex) {
                        std::lock_guard<std::mutex> lk(jobs_mu);
                        for (auto& it : live_jobs.a) if (it["id"].str() == jid) { it["state"] = "failed"; it["error"] = ex.what(); }
                    }
                }).detach();
            }
            send_resp("application/json", "{\"ok\":true}");
        } else {
            send_resp("text/html; charset=utf-8", UI_HTML);
        }
    }
    ::close(sfd);
    return 0;
}
#endif

// MARK: - CLI Runner

inline void emit_ndjson(const Json& j) {
    std::string s = j.dump() + "\n";
    (void)::write(STDOUT_FILENO, s.data(), s.size());
}

inline std::string pad_col(const std::string& s, size_t w) {
    return s.size() >= w ? s : (s + std::string(w - s.size(), ' '));
}

inline void print_llm_manifest() {
    std::printf(
        "# uBit (%s) — Agent CLI Contract\n\n"
        "Binary: `ubit` (Linux x86_64 / arm64 & macOS arm64). Zero external dependencies required for MP4 and M4A.\n\n"
        "## Commands\n"
        "- `ubit get <url>... [flags]` — Download video/audio. Prefer `--json` (NDJSON events on stdout) or `--quiet` (prints only final saved file path(s)).\n"
        "- `ubit info <url> --json` — Probe metadata (`id`, `title`, `site`, `author`, `duration`, `isLive`, `isDRM`, `formats`, `subtitles`, `chapters`, `entries`).\n"
        "- `ubit formats <url> --json` — Return JSON array of `MediaFormat` objects.\n"
        "- `ubit list --json` — Return JSON array of library items.\n"
        "- `ubit subs [list|add <url>|remove <n>|check] [--json] [--quiet]` — Manage channel/playlist subscriptions.\n"
        "- `ubit settings [key [value]] [--json]` — Read or mutate persistent settings (`%s`).\n"
        "- `ubit sites --json` — Return JSON array of 35 built-in site extractors.\n\n"
        "## High-Leverage Flags for Agents (`ubit get`)\n"
        "- `--json` — Emit NDJSON events: `start`, `info`, `progress`, `process`, `done`, `error`, `stopped`.\n"
        "- `--quiet` — Print ONLY saved absolute file paths to stdout.\n"
        "- `--no-library` — Omit ephemeral agent scratch downloads from user library.\n"
        "- `--section START-END` — Keyframe-accurate `sidx` HTTP byte-range clip trim (e.g. `0:30-1:00`).\n"
        "- `-q <best|2160|1440|1080|720|480|360>` / `-f <vid+aid>` / `-a` (audio only).\n"
        "- `UBIT_CONFIG_DIR=/tmp/agent-ubit` — Isolate state per agent sandbox.\n\n"
        "## Exit Codes\n"
        "- `0` = done, `1` = download/extractor error, `2` = bad usage, `130` = interrupted (resumable on re-run).\n",
        UBIT_VERSION, AppPaths::settings_file().c_str()
    );
}

inline void print_main_help() {
    std::printf(
        "ubit %s — ultra-small native media downloader & agent CLI (zero Pro paywalls).\n\n"
        "Usage\n"
        "  ubit                          Open the desktop UI\n"
        "  ubit <url>...                 Download, as `ubit get`\n"
        "  ubit get <url>... [flags]     Download media (see `ubit get --help`)\n"
        "  ubit info <url> [--json]      Title, formats, subtitles, playlist items\n"
        "  ubit formats <url> [--json]   List all stream formats for `-f`\n"
        "  ubit list [--json]            Downloads across the app and CLI\n"
        "  ubit subs [add|remove|check]  Subscribe to channels and playlists\n"
        "  ubit settings [name [value]]  View or modify shared settings\n"
        "  ubit sites [--json]           List all 35 built-in site extractors\n"
        "  ubit version\n"
        "  ubit --llms                   Print machine-readable contract for AI agents\n\n"
        "Exit codes: 0 done, 1 failed, 2 bad usage, 130 stopped with Ctrl-C (run again to resume).\n",
        UBIT_VERSION
    );
}

inline void print_get_help() {
    std::puts(
        "Usage: ubit get <url>... [flags]\n\n"
        "  -o, --output DIR              Folder to save into\n"
        "  -a, --audio                   Audio only (M4A)\n"
        "      --to FORMAT               mp4, m4a (native zero-FFmpeg), or mkv, mov, webm, mp3, opus, flac, wav\n"
        "      --mp3                     Audio as MP3\n"
        "  -q, --quality Q               best, 2160, 1440, 1080, 720, 480, 360\n"
        "  -f, --format IDS              Exact format ID(s), e.g. 399+140\n"
        "      --compatible / --best-codec\n"
        "      --subs / --sub-langs L / --sub-files\n"
        "  -i, --input FILE              Read URLs one per line (- reads stdin)\n"
        "      --playlist / --no-playlist / --items 1,3,5-7\n"
        "      --section 1:00-2:30       Keyframe-accurate sidx byte-range clip trim\n"
        "      --sponsors-remove CATS / --sponsors-mark CATS / --keep-sponsors\n"
        "      --title TEXT / --name TEMPLATE\n"
        "      --rate 2M / --connections N (1-32, default 8)\n"
        "      --cookies FILE / --no-cookies / --proxy URL / --referer URL / --user-agent UA / --header 'K: V'\n"
        "      --json / --quiet / --no-library"
    );
}

inline int run_get(const std::vector<std::string>& args) {
    for (const auto& a : args) if (a == "-h" || a == "--help") { print_get_help(); return 0; }
    Settings settings = Settings::load();
    DownloadOpts opts = DownloadOpts::from_settings(settings);
    std::vector<std::string> urls;
    std::string input_file, items_spec;
    bool json_mode = false, quiet_mode = false, no_lib = false, no_pl = false, force_pl = false;

    for (size_t i = 0; i < args.size(); ++i) {
        const std::string& a = args[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= args.size()) throw std::invalid_argument("missing value for " + a);
            return args[++i];
        };
        try {
            if (a == "-o" || a == "--output") opts.output_dir = expand_tilde(next());
            else if (a == "-a" || a == "--audio") opts.audio_only = true;
            else if (a == "--mp3") { opts.audio_only = true; opts.target_format = "mp3"; }
            else if (a == "--to") {
                opts.target_format = strutil::to_lower(next());
                if (opts.target_format == "m4a" || opts.target_format == "mp3" || opts.target_format == "opus" || opts.target_format == "flac" || opts.target_format == "wav")
                    opts.audio_only = true;
            } else if (a == "-q" || a == "--quality") {
                opts.max_quality = next();
                if (!opts.max_quality.empty() && opts.max_quality.back() == 'p') opts.max_quality.pop_back();
            } else if (a == "-f" || a == "--format") opts.format_selector = next();
            else if (a == "--compatible") opts.prefer_compatible = true;
            else if (a == "--best-codec") opts.prefer_compatible = false;
            else if (a == "--subs") opts.download_subs = true;
            else if (a == "--sub-langs") { opts.download_subs = true; opts.sub_langs = next(); }
            else if (a == "--sub-files") opts.external_subs = true;
            else if (a == "-i" || a == "--input") input_file = next();
            else if (a == "--playlist") force_pl = true;
            else if (a == "--no-playlist") no_pl = true;
            else if (a == "--items") items_spec = next();
            else if (a == "--section") { if (!SectionRange::parse(next(), opts.section)) { std::fprintf(stderr, "invalid --section\n"); return 2; } }
            else if (a == "--sponsors-remove") { opts.sponsor_mode = "remove"; opts.sponsor_cats = next(); }
            else if (a == "--sponsors-mark") { opts.sponsor_mode = "mark"; opts.sponsor_cats = next(); }
            else if (a == "--keep-sponsors") opts.sponsor_mode = "keep";
            else if (a == "--title") opts.custom_title = next();
            else if (a == "--name") opts.filename_tpl = next();
            else if (a == "--rate") opts.rate_limit = next();
            else if (a == "--connections") opts.connections = std::max(1, std::min(32, std::atoi(next().c_str())));
            else if (a == "--cookies" || a == "--cookies-from-browser") opts.cookie_source = next();
            else if (a == "--no-cookies") opts.cookie_source = "none";
            else if (a == "--proxy") opts.proxy = next();
            else if (a == "--referer") opts.referer = next();
            else if (a == "--user-agent") opts.user_agent = next();
            else if (a == "--header") {
                std::string hv = next();
                auto col = hv.find(':');
                if (col == std::string::npos) return 2;
                opts.extra_headers[strutil::trim(hv.substr(0, col))] = strutil::trim(hv.substr(col + 1));
            } else if (a == "--json") json_mode = true;
            else if (a == "--quiet" || a == "-s") quiet_mode = true;
            else if (a == "--no-library") no_lib = true;
            else if (!a.empty() && a[0] == '-') { std::fprintf(stderr, "ubit get: unknown flag %s\n", a.c_str()); return 2; }
            else urls.push_back(a);
        } catch (const std::invalid_argument& e) {
            std::fprintf(stderr, "ubit get: %s\n", e.what());
            return 2;
        }
    }

    if (!input_file.empty()) {
        std::istream* in = &std::cin;
        std::ifstream fin;
        if (input_file != "-") { fin.open(expand_tilde(input_file)); if (!fin) return 1; in = &fin; }
        std::string ln;
        while (std::getline(*in, ln)) {
            ln = strutil::trim(ln);
            if (!ln.empty() && ln[0] != '#') urls.push_back(ln);
        }
    }
    if (urls.empty()) { print_get_help(); return 2; }

    bool is_tty = ::isatty(STDERR_FILENO) != 0;
    bool any_failed = false;
    (void)no_pl; (void)force_pl; (void)items_spec;

    for (const auto& u : urls) {
        Json lib_item = Json::object();
        lib_item["id"] = std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
        lib_item["url"] = u;
        lib_item["state"] = "downloading";

        EventCallbacks cb;
        cb.on_start = [&](const std::string& su) {
            if (json_mode) { Json e = Json::object(); e["event"] = "start"; e["url"] = su; emit_ndjson(e); }
        };
        cb.on_info = [&](const MediaInfo& inf, const std::string& qual, const std::string& ex, const fs::path& p) {
            lib_item["title"] = inf.title; lib_item["site"] = inf.site; lib_item["quality"] = qual; lib_item["ext"] = ex; lib_item["path"] = p.string();
            if (!no_lib) upsert_library_item(lib_item);
            if (json_mode) {
                Json e = Json::object();
                e["event"] = "info"; e["title"] = inf.title; e["site"] = inf.site; e["quality"] = qual; e["ext"] = ex; e["path"] = p.string(); e["live"] = inf.is_live;
                emit_ndjson(e);
            } else if (!quiet_mode) {
                std::fprintf(stderr, "▸ %s [%s · %s]\n", inf.title.c_str(), inf.site.c_str(), qual.c_str());
            }
        };
        cb.on_progress = [&](double fr, int64_t done, int64_t tot, int64_t spd, int eta, double lsec) {
            if (json_mode) {
                Json e = Json::object();
                e["event"] = "progress";
                e["fraction"] = std::round(fr * 1000.0) / 1000.0;
                e["downloaded"] = done; e["total"] = tot; e["speed"] = spd;
                if (eta >= 0) e["eta"] = eta;
                if (lsec >= 0) { e["live"] = true; e["seconds"] = lsec; }
                emit_ndjson(e);
            } else if (!quiet_mode && is_tty) {
                int pct = (int)std::round(fr * 100.0);
                std::fprintf(stderr, "\r\033[K  %3d%%  %s / %s  %s/s", pct, format_bytes(done).c_str(), format_bytes(tot).c_str(), format_bytes(spd).c_str());
                std::fflush(stderr);
            }
        };
        cb.on_stage = [&](const std::string& stg) {
            if (json_mode) { Json e = Json::object(); e["event"] = "process"; e["stage"] = stg; emit_ndjson(e); }
            else if (!quiet_mode && is_tty) { std::fprintf(stderr, "\r\033[K  ⚙ %s…", stg.c_str()); std::fflush(stderr); }
        };
        cb.on_done = [&](const fs::path& p, int64_t sz, double secs) {
            lib_item["state"] = "done"; lib_item["totalBytes"] = sz; lib_item["downloadedBytes"] = sz;
            if (!no_lib) upsert_library_item(lib_item);
            if (json_mode) {
                Json e = Json::object();
                e["event"] = "done"; e["path"] = p.string(); e["size"] = sz; e["seconds"] = std::round(secs * 100.0) / 100.0;
                emit_ndjson(e);
            } else if (quiet_mode) {
                std::printf("%s\n", p.c_str());
            } else {
                if (is_tty) std::fprintf(stderr, "\r\033[K");
                std::fprintf(stderr, "✓ Saved %s (%s in %.1fs)\n", p.c_str(), format_bytes(sz).c_str(), secs);
            }
        };

        try {
            HTTPClient probe_client = make_http_client(settings, opts);
            MediaInfo initial = ExtractorRegistry::extract(u, probe_client);
            if (!initial.entries.empty() && initial.formats.empty()) {
                DownloadOpts pl_opts = opts;
                pl_opts.playlist_title = initial.title;
                for (const auto& entry : initial.entries) {
                    download_single_item(entry.url, nullptr, settings, pl_opts, cb, g_cancel_flag);
                }
            } else {
                download_single_item(u, &initial, settings, opts, cb, g_cancel_flag);
            }
        } catch (const InterruptedException&) {
            lib_item["state"] = "paused";
            if (!no_lib) upsert_library_item(lib_item);
            if (json_mode) { Json e = Json::object(); e["event"] = "stopped"; e["url"] = u; emit_ndjson(e); }
            return 130;
        } catch (const std::exception& ex) {
            if (g_cancel_flag.load()) return 130;
            any_failed = true;
            lib_item["state"] = "failed"; lib_item["error"] = ex.what();
            if (!no_lib) upsert_library_item(lib_item);
            if (json_mode) { Json e = Json::object(); e["event"] = "error"; e["url"] = u; e["error"] = ex.what(); emit_ndjson(e); }
            else { if (is_tty) std::fprintf(stderr, "\r\033[K"); std::fprintf(stderr, "error: %s\n", ex.what()); }
        }
    }
    return any_failed ? 1 : 0;
}

inline int run_info(const std::vector<std::string>& args, bool fmts_only) {
    bool json_mode = false;
    std::string url;
    Settings settings = Settings::load();
    DownloadOpts opts = DownloadOpts::from_settings(settings);
    for (size_t i = 0; i < args.size(); ++i) {
        if (args[i] == "--json") json_mode = true;
        else if (args[i] == "--cookies" && i + 1 < args.size()) opts.cookie_source = args[++i];
        else if (args[i] == "--no-cookies") opts.cookie_source = "none";
        else if (!args[i].empty() && args[i][0] != '-' && url.empty()) url = args[i];
    }
    if (url.empty()) { std::fprintf(stderr, "Usage: ubit %s <url> [--json]\n", fmts_only ? "formats" : "info"); return 2; }

    try {
        HTTPClient client = make_http_client(settings, opts);
        MediaInfo info = ExtractorRegistry::extract(url, client);
        if (info.is_drm && info.formats.empty()) { std::fprintf(stderr, "error: this media is protected by DRM and can't be downloaded\n"); return 1; }
        if (json_mode) {
            if (fmts_only) {
                Json fa = Json::array(); for (const auto& f : info.formats) fa.a.push_back(f.to_json());
                std::puts(fa.dump(2).c_str());
            } else {
                std::puts(info.to_json().dump(2).c_str());
            }
            return 0;
        }
        if (!fmts_only) {
            std::printf("Title:    %s\nSite:     %s\n", info.title.c_str(), info.site.c_str());
            if (!info.author.empty()) std::printf("Author:   %s\n", info.author.c_str());
            if (info.duration > 0) std::printf("Duration: %s\n", format_duration(info.duration).c_str());
            if (!info.entries.empty()) {
                std::printf("\nItems (%zu):\n", info.entries.size());
                for (size_t i = 0; i < info.entries.size(); ++i)
                    std::printf("  %3zu. %s  %s\n", i + 1, info.entries[i].title.c_str(), info.entries[i].url.c_str());
                return 0;
            }
            std::puts("");
        }
        std::printf("%s %s %s %s %s PROTO\n", pad_col("ID",14).c_str(), pad_col("EXT",6).c_str(), pad_col("QUALITY",12).c_str(), pad_col("CODECS",14).c_str(), pad_col("SIZE",12).c_str());
        for (const auto& f : info.formats) {
            std::string sz = f.filesize > 0 ? format_bytes(f.filesize) : (f.bitrate > 0 ? std::to_string(f.bitrate / 1000) + " kbps" : "—");
            std::printf("%s %s %s %s %s %s\n",
                pad_col(f.id,14).c_str(), pad_col(f.ext,6).c_str(), pad_col(f.display_quality(),12).c_str(),
                pad_col(f.short_codec(),14).c_str(), pad_col(sz,12).c_str(), f.proto.c_str());
        }
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }
}

} // namespace ubit

int main(int argc, char** argv) {
    using namespace ubit;
#ifdef __wasi__
    // No signals or desktop window in WebAssembly: the host stops the module by ending its process.
    if (argc <= 1) { print_main_help(); return 2; }
#else
    std::signal(SIGINT, on_sigint);
    std::signal(SIGPIPE, SIG_IGN);

    if (argc <= 1) {
        return run_linux_desktop_gui();
    }
#endif

    std::string cmd = argv[1];
    std::vector<std::string> rest;
    for (int i = 2; i < argc; ++i) rest.emplace_back(argv[i]);

    if (cmd == "-h" || cmd == "--help" || cmd == "help") { print_main_help(); return 0; }
    if (cmd == "-v" || cmd == "--version" || cmd == "version") { std::printf("ubit %s\n", UBIT_VERSION); return 0; }
    if (cmd == "--llms" || cmd == "llms") { print_llm_manifest(); return 0; }
    if (cmd == "get") return run_get(rest);
    if (cmd == "info") return run_info(rest, false);
    if (cmd == "formats") return run_info(rest, true);
    if (cmd == "sites") {
        bool jm = !rest.empty() && rest[0] == "--json";
        auto names = ExtractorRegistry::site_names();
        if (jm) {
            Json a = Json::array(); for (const auto& n : names) a.a.push_back(n);
            std::puts(a.dump().c_str());
        } else {
            std::printf("Sites with dedicated native extractors (%zu):\n", names.size());
            for (const auto& n : names) std::printf("  %s\n", n.c_str());
        }
        return 0;
    }
    if (cmd == "list") {
        Json arr = Json::parse(read_file_text(AppPaths::library_file()));
        if (!arr.is_arr()) arr = Json::array();
        if (!rest.empty() && rest[0] == "--json") { std::puts(arr.dump(2).c_str()); return 0; }
        if (arr.a.empty()) { std::puts("No downloads yet."); return 0; }
        for (const auto& it : arr.a)
            std::printf("[%-11s] %s  %s\n", it["state"].str().c_str(), it["title"].str().c_str(), it["path"].str(it["url"].str()).c_str());
        return 0;
    }
    if (cmd == "settings") {
        Settings s = Settings::load();
        if (rest.empty()) { std::puts(s.to_json().dump(2).c_str()); return 0; }
        if (rest[0] == "--json") { std::puts(s.to_json().dump().c_str()); return 0; }
        if (rest.size() == 1) { std::puts(s.to_json()[rest[0]].str().c_str()); return 0; }
        if (!s.set_key(rest[0], rest[1])) { std::fprintf(stderr, "error: invalid setting\n"); return 2; }
        s.save();
        std::printf("%s = %s\n", rest[0].c_str(), rest[1].c_str());
        return 0;
    }

    // Shorthand `ubit <url>...` or `ubit -a <url>`
    std::vector<std::string> all_args;
    for (int i = 1; i < argc; ++i) all_args.emplace_back(argv[i]);
    return run_get(all_args);
}
