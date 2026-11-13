#pragma once
#include "extractors.hpp"

namespace ubit {

struct DownloadOpts {
    std::string output_dir;
    bool audio_only = false;
    std::string target_format;
    std::string max_quality = "best";
    std::string format_selector;
    bool prefer_compatible = true;
    bool download_subs = false;
    std::string sub_langs = "en";
    bool external_subs = false;
    SectionRange section;
    std::string sponsor_mode = "keep";
    std::string sponsor_cats = "default";
    std::string custom_title;
    std::string filename_tpl;
    std::string rate_limit;
    int connections = 8;
    std::string cookie_source = "builtin";
    std::string proxy;
    std::string referer;
    std::string user_agent;
    std::map<std::string, std::string> extra_headers;
    std::string playlist_title;

    static DownloadOpts from_settings(const Settings& s) {
        DownloadOpts o;
        o.output_dir = s.folder;
        o.audio_only = (s.mode == "audio");
        o.max_quality = s.quality;
        o.prefer_compatible = s.compatible;
        o.download_subs = s.subtitles;
        o.sub_langs = s.subtitle_langs;
        o.external_subs = !s.embed_subtitles;
        o.sponsor_mode = s.sponsors;
        o.filename_tpl = s.tpl;
        o.rate_limit = s.rate_limit;
        o.connections = s.connections;
        o.cookie_source = s.cookies;
        o.proxy = s.proxy;
        return o;
    }
};

struct SelectedPair {
    const MediaFormat* video = nullptr;
    const MediaFormat* audio = nullptr;
    const MediaFormat* primary() const { return video ? video : audio; }
    std::string display_quality() const { return video ? video->display_quality() : (audio ? audio->display_quality() : "Audio"); }
};

inline const MediaFormat* pick_best_audio(const std::vector<MediaFormat>& fmts, bool prefer_aac, bool prefer_webm = false) {
    std::vector<const MediaFormat*> cands;
    for (const auto& f : fmts) if (f.has_audio() && !f.has_video()) cands.push_back(&f);
    if (cands.empty()) return nullptr;
    std::sort(cands.begin(), cands.end(), [&](const MediaFormat* a, const MediaFormat* b) {
        if (prefer_webm) {
            bool aw = strutil::to_lower(a->ext) == "webm";
            bool bw = strutil::to_lower(b->ext) == "webm";
            if (aw != bw) return aw;
        } else if (prefer_aac && a->is_aac() != b->is_aac()) {
            return a->is_aac();
        }
        int64_t ba = a->bitrate ? a->bitrate : a->filesize;
        int64_t bb = b->bitrate ? b->bitrate : b->filesize;
        return ba > bb;
    });
    return cands[0];
}

inline SelectedPair select_formats(const std::vector<MediaFormat>& fmts, const DownloadOpts& opts) {
    if (fmts.empty()) throw std::runtime_error("No playable streams found");
    if (!opts.format_selector.empty()) {
        auto plus = opts.format_selector.find('+');
        if (plus != std::string::npos) {
            std::string vid = opts.format_selector.substr(0, plus), aid = opts.format_selector.substr(plus + 1);
            const MediaFormat *vf = nullptr, *af = nullptr;
            for (const auto& f : fmts) { if (f.id == vid) vf = &f; if (f.id == aid) af = &f; }
            if (!vf || !af) throw std::runtime_error("Format IDs not found: " + opts.format_selector);
            return {vf, af};
        }
        for (const auto& f : fmts) {
            if (f.id == opts.format_selector) {
                if (f.has_video() && !f.has_audio()) return {&f, pick_best_audio(fmts, opts.prefer_compatible && f.ext != "webm", f.ext == "webm")};
                return f.has_video() ? SelectedPair{&f, nullptr} : SelectedPair{nullptr, &f};
            }
        }
        throw std::runtime_error("Format ID not found: " + opts.format_selector);
    }

    if (opts.audio_only) {
        if (auto* a = pick_best_audio(fmts, opts.prefer_compatible)) return {nullptr, a};
        return {nullptr, &fmts[0]};
    }

    int max_h = (opts.max_quality == "best" || opts.max_quality.empty()) ? 0 : std::atoi(opts.max_quality.c_str());
    std::vector<const MediaFormat*> vcands;
    for (const auto& f : fmts) if (f.has_video()) vcands.push_back(&f);
    if (vcands.empty()) return {nullptr, pick_best_audio(fmts, opts.prefer_compatible) ? pick_best_audio(fmts, opts.prefer_compatible) : &fmts[0]};

    std::vector<const MediaFormat*> pool;
    for (auto* f : vcands) if (max_h <= 0 || f->height <= 0 || f->height <= max_h) pool.push_back(f);
    if (pool.empty()) pool = vcands;

    std::sort(pool.begin(), pool.end(), [&](const MediaFormat* l, const MediaFormat* r) {
        if (l->height != r->height) return l->height > r->height;
        int lf = (int)std::round(l->fps > 0 ? l->fps : 30.0), rf = (int)std::round(r->fps > 0 ? r->fps : 30.0);
        if (lf != rf) return lf > rf;
        if (opts.prefer_compatible && l->is_native_mp4() != r->is_native_mp4()) return l->is_native_mp4();
        if (opts.prefer_compatible && l->is_h264() != r->is_h264()) return l->is_h264();
        int64_t lb = l->bitrate ? l->bitrate : l->filesize;
        int64_t rb = r->bitrate ? r->bitrate : r->filesize;
        return lb > rb;
    });

    const MediaFormat* cv = pool[0];
    if (cv->has_audio()) return {cv, nullptr};
    bool cv_webm = strutil::to_lower(cv->ext) == "webm";
    return {cv, pick_best_audio(fmts, (opts.prefer_compatible || cv->ext == "mp4") && !cv_webm, cv_webm)};
}

inline HTTPClient make_http_client(
    const Settings& s,
    const DownloadOpts& o,
    const fs::path& config_dir = {}
#ifdef UBIT_SDK
    , const ubit_net_vtable* net = nullptr,
    void* net_ctx = nullptr
#endif
) {
    HTTPClient c;
#ifdef UBIT_SDK
    c.net = net;
    c.net_ctx = net_ctx;
#endif
    c.proxy_url = !o.proxy.empty() ? o.proxy : s.proxy;
    if (!o.user_agent.empty()) c.user_agent = o.user_agent;
    c.extra_headers = o.extra_headers;
    if (!o.referer.empty()) c.extra_headers["Referer"] = o.referer;
    int64_t bps = parse_rate_limit(!o.rate_limit.empty() ? o.rate_limit : s.rate_limit);
    c.limiter = std::make_shared<RateLimiter>(bps);

    std::string cs = o.cookie_source;
    if (cs == "builtin") {
        fs::path cf = config_dir.empty() ? AppPaths::cookies_file() : (config_dir / "cookies.txt");
        if (fs::exists(cf)) c.cookies = CookieVault::load_netscape(cf.string());
    } else if (cs != "none" && !cs.empty() && fs::exists(expand_tilde(cs))) {
        c.cookies = CookieVault::load_netscape(expand_tilde(cs));
    }
    return c;
}

struct EventCallbacks {
    std::function<void(const std::string&)> on_start;
    std::function<void(const MediaInfo&, const std::string&, const std::string&, const fs::path&)> on_info;
    std::function<void(double, int64_t, int64_t, int64_t, int, double)> on_progress;
    std::function<void(const std::string&)> on_stage;
    std::function<void(const fs::path&, int64_t, double)> on_done;
};

inline fs::path download_single_item(
    const std::string& url,
    const MediaInfo* pre_extracted,
    const Settings& settings,
    const DownloadOpts& opts,
    const EventCallbacks& cb,
    std::atomic<bool>& cancel_flag,
    const fs::path& config_dir = {}
#ifdef UBIT_SDK
    , const ubit_net_vtable* net = nullptr,
    void* net_ctx = nullptr
#endif
) {
    auto t0 = std::chrono::steady_clock::now();
    fs::path cfg_root = config_dir.empty() ? AppPaths::config_dir() : config_dir;
    AppPaths::ensure_dir(cfg_root);
    if (cb.on_start) cb.on_start(url);

#ifdef UBIT_SDK
    HTTPClient client = make_http_client(settings, opts, cfg_root, net, net_ctx);
#else
    HTTPClient client = make_http_client(settings, opts, cfg_root);
#endif
    if (cancel_flag.load()) throw InterruptedException();
    MediaInfo info = (pre_extracted && !pre_extracted->formats.empty()) ? *pre_extracted : ExtractorRegistry::extract(url, client);
    if (cancel_flag.load()) throw InterruptedException();
    if (info.is_drm && info.formats.empty()) throw std::runtime_error("This media is protected by DRM and can't be downloaded.");
    if (!opts.custom_title.empty()) info.title = opts.custom_title;

    SelectedPair sel = select_formats(info.formats, opts);
    bool is_audio_out = opts.audio_only || (sel.video == nullptr);

    std::string target_ext;
    if (!opts.target_format.empty()) {
        target_ext = strutil::to_lower(opts.target_format);
    } else if (is_audio_out) {
        std::string ae = sel.audio ? strutil::to_lower(sel.audio->ext) : "";
        if (SponsorAndSubs::find_ffmpeg().empty() &&
            (ae == "mp3" || ae == "opus" || ae == "ogg" || ae == "flac" || ae == "wav" || ae == "webm" || ae == "aac")) {
            target_ext = ae;
        } else {
            target_ext = settings.audio_format;
        }
    } else {
        bool v_webm = sel.video && strutil::to_lower(sel.video->ext) == "webm";
        bool a_webm = sel.audio && strutil::to_lower(sel.audio->ext) == "webm";
        if (v_webm || a_webm) {
            bool pure_webm = (!sel.video || v_webm) && (!sel.audio || a_webm);
            target_ext = pure_webm ? "webm" : "mkv";
        } else {
            target_ext = settings.video_format;
        }
    }

    fs::path base_dir = expand_tilde(opts.output_dir.empty() ? settings.folder : opts.output_dir);
    if (settings.site_folders && !info.site.empty()) base_dir /= sanitize_filename(info.site);
    if (settings.playlist_folders && !opts.playlist_title.empty()) base_dir /= sanitize_filename(opts.playlist_title);
    std::error_code ec;
    fs::create_directories(base_dir, ec);

    std::string rel_name = render_template(opts.filename_tpl.empty() ? settings.tpl : opts.filename_tpl, info, sel.display_quality(), target_ext);
    fs::path final_path = base_dir / rel_name;
    if (fs::exists(final_path)) {
        std::string stem = final_path.stem().string(), ex = final_path.extension().string();
        for (int n = 2; n < 1000; ++n) {
            fs::path cand = final_path.parent_path() / (stem + " (" + std::to_string(n) + ")" + ex);
            if (!fs::exists(cand)) { final_path = cand; break; }
        }
    }

    if (cb.on_info) cb.on_info(info, sel.display_quality(), target_ext, final_path);

    int64_t combined_est = (sel.video ? sel.video->filesize : 0) + (sel.audio ? sel.audio->filesize : 0);
    std::mutex meter_mu;
    std::vector<std::pair<double, int64_t>> samples;
    double last_emit = 0.0;

    auto report_prog = [&](int64_t done, int64_t tot, double frac_override, double live_sec) {
        if (!cb.on_progress) return;
        double now = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        int64_t spd = 0;
        int eta = -1;
        {
            std::lock_guard<std::mutex> lk(meter_mu);
            samples.push_back({now, done});
            while (!samples.empty() && now - samples.front().first > 3.0) samples.erase(samples.begin());
            if (now - last_emit < 0.12) return;
            last_emit = now;
            if (samples.size() >= 2 && now - samples.front().first > 0.08 && done >= samples.front().second) {
                spd = (int64_t)((done - samples.front().second) / (now - samples.front().first));
            }
            if (spd > 0 && tot > done) eta = (int)((tot - done) / spd);
        }
        double fr = frac_override >= 0.0 ? frac_override : (tot > 0 ? std::min(1.0, (double)done / tot) : 0.0);
        cb.on_progress(fr, done, tot, spd, eta, live_sec);
    };

    auto try_sidx_section = [&](const MediaFormat& fmt, const fs::path& dest, double& base_sec) -> bool {
        if (!opts.section.active() || (fmt.ext != "mp4" && fmt.ext != "m4a")) return false;
        int64_t pend = fmt.index_range.end > 0 ? std::max<int64_t>(32767, fmt.index_range.end) : 65535;
        try {
            auto head = client.fetch_range(fmt.url, 0, pend, fmt.headers);
            int64_t init_end = 0;
            std::vector<SidxSegment> segs;
            if (!MP4Muxer::parse_sidx(head, init_end, segs)) return false;
            double rs = opts.section.start >= 0 ? opts.section.start : 0.0;
            double re = opts.section.end >= 0 ? opts.section.end : 1e12;
            int first_i = -1, last_i = -1;
            for (int i = 0; i < (int)segs.size(); ++i) {
                if ((segs[i].start_sec + segs[i].dur_sec) > rs && segs[i].start_sec < re) {
                    if (first_i < 0) first_i = i;
                    last_i = i;
                }
            }
            if (first_i < 0) return false;
            auto body = client.fetch_range(fmt.url, segs[first_i].range.start, segs[last_i].range.end, fmt.headers);
            std::vector<uint8_t> out(head.begin(), head.begin() + init_end + 1);
            out.insert(out.end(), body.begin(), body.end());
            write_file_atomic(dest, out.data(), out.size());
            base_sec = segs[first_i].start_sec;
            return true;
        } catch (...) {
            return false;
        }
    };

    auto fetch_role = [&](MediaFormat fmt, const fs::path& dest, int64_t prior_bytes, bool is_video_role, double& base_sec, bool& is_ts) {
        std::set<std::string> blocked_ids;
        for (int att = 0; att < 3; ++att) {
            if (cancel_flag.load()) throw InterruptedException();
            try {
                auto hdrs = fmt.headers;
                if (!opts.referer.empty() && !hdrs.count("Referer")) hdrs["Referer"] = opts.referer;
                if (fmt.proto == "hls") {
                    bool fmp4 = HLSEngine::download_stream(client, fmt.url, dest, hdrs, opts.section, opts.connections, cancel_flag,
                        [&](int64_t d, int64_t est, double fr, double rsec) {
                            report_prog(prior_bytes + d, std::max(combined_est, prior_bytes + est), fmt.is_live ? 0.0 : fr, fmt.is_live ? rsec : -1.0);
                        });
                    is_ts = !fmp4 && fmt.ext != "mp3";
                    return;
                }
                if (try_sidx_section(fmt, dest, base_sec)) return;
                WorkStealingDownloader::download(client, fmt.url, dest, hdrs, fmt.filesize, opts.connections, cancel_flag,
                    [&](int64_t d, int64_t stot) {
                        int64_t gtot = combined_est > 0 ? combined_est : (prior_bytes + stot);
                        report_prog(prior_bytes + d, gtot, -1.0, -1.0);
                    });
                return;
            } catch (const StaleLinkException&) {
                if (att == 2) throw;
                if (att == 1) {
                    blocked_ids.insert(fmt.id);
                    fs::remove(dest.string() + ".part", ec);
                    fs::remove(dest.string() + ".part.json", ec);
                }
                info = ExtractorRegistry::extract(url, client);
                std::vector<MediaFormat> pool;
                for (const auto& f : info.formats) if (!blocked_ids.count(f.id)) pool.push_back(f);
                if (pool.empty()) pool = info.formats;
                auto fresh = select_formats(pool, opts);
                const MediaFormat* upd = is_video_role ? fresh.video : (fresh.audio ? fresh.audio : fresh.video);
                if (!upd) throw;
                fmt = *upd;
            }
        }
    };

    fs::path job_dir = (cfg_root / "work") / ("job_" + sha256_hex(url + "|" + sel.display_quality() + "|" + base_dir.string()).substr(0, 14));
    fs::create_directories(job_dir, ec);
    struct JobDirGuard {
        fs::path dir;
        bool keep_for_resume = false;
        ~JobDirGuard() {
            if (!keep_for_resume) {
                std::error_code e;
                fs::remove_all(dir, e);
            }
        }
    } job_guard{job_dir, false};

    fs::path v_tmp = job_dir / ("video." + (sel.video ? sel.video->ext : "mp4"));
    fs::path a_tmp = job_dir / ("audio." + (sel.audio ? sel.audio->ext : "m4a"));
    double v_base = 0.0, a_base = 0.0;
    bool v_ts = false, a_ts = false;
    int64_t v_bytes = 0;

    try {
        if (sel.video) {
            fetch_role(*sel.video, v_tmp, 0, true, v_base, v_ts);
            v_bytes = (int64_t)fs::file_size(v_tmp, ec);
            if (!sel.audio && !sel.video->audio_track_url.empty()) {
                MediaFormat ha; ha.id = "hls-audio"; ha.url = sel.video->audio_track_url; ha.ext = "m4a"; ha.proto = "hls"; ha.vcodec = "none"; ha.acodec = "mp4a"; ha.headers = sel.video->headers;
                fetch_role(ha, a_tmp, v_bytes, false, a_base, a_ts);
            }
        }
        if (sel.audio) {
            fetch_role(*sel.audio, a_tmp, v_bytes, false, a_base, a_ts);
        }
    } catch (const InterruptedException&) {
        job_guard.keep_for_resume = true;
        throw;
    }
    if (cancel_flag.load()) {
        job_guard.keep_for_resume = true;
        throw InterruptedException();
    }

    std::vector<uint8_t> cover_bytes;
    if ((settings.embed_metadata || settings.save_thumbnail) && !info.thumbnail.empty()) {
        auto ir = client.fetch(info.thumbnail, "GET", {}, "", false, 1);
        if (ir.status == 200 && ir.body.size() >= 4 && ((ir.body[0] == 0xff && ir.body[1] == 0xd8) || (ir.body[0] == 0x89 && ir.body[1] == 0x50))) {
            cover_bytes = std::move(ir.body);
        }
    }

    std::vector<std::pair<std::string, std::vector<Chapter>>> dl_subs;
    if (opts.download_subs && !info.subtitles.empty()) {
        for (const auto& st : info.subtitles) {
            if (opts.sub_langs != "all" && opts.sub_langs.find(st.lang) == std::string::npos) continue;
            auto sr = client.fetch(st.url);
            if (sr.status == 200) {
                auto cues = SponsorAndSubs::parse_vtt_cues(sr.text());
                if (!cues.empty()) dl_subs.push_back({st.lang, std::move(cues)});
            }
        }
    }

    std::vector<Chapter> chapters = info.chapters;
    std::vector<std::pair<double, double>> sponsor_cuts;
    if (opts.sponsor_mode != "keep" && info.site == "YouTube") {
        if (opts.sponsor_mode == "remove") {
            sponsor_cuts = SponsorAndSubs::fetch_sponsors(client, info.id, opts.sponsor_cats, nullptr);
            if (!sponsor_cuts.empty() && cb.on_stage) cb.on_stage("Removing sponsors");
        } else if (opts.sponsor_mode == "mark") {
            SponsorAndSubs::fetch_sponsors(client, info.id, opts.sponsor_cats, &chapters);
            std::sort(chapters.begin(), chapters.end(), [](const Chapter& a, const Chapter& b) { return a.start_time < b.start_time; });
        }
    }

    if (cb.on_stage) cb.on_stage("Merging");
    auto magic_kind = [](const fs::path& p) -> std::string {
        FILE* f = std::fopen(p.c_str(), "rb");
        if (!f) return "";
        uint8_t b[380]{};
        size_t n = std::fread(b, 1, sizeof(b), f);
        std::fclose(f);
        if (n >= 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) return "ebml";
        if (n >= 8 && (std::memcmp(&b[4], "ftyp", 4) == 0 || std::memcmp(&b[4], "styp", 4) == 0 || std::memcmp(&b[4], "moov", 4) == 0)) return "mp4";
        if (n >= 189 && b[0] == 0x47 && b[188] == 0x47) return "ts";
        if (n >= 1 && b[0] == 0x47) return "ts";
        return "raw";
    };

    bool has_v = fs::exists(v_tmp), has_a = fs::exists(a_tmp);
    std::string vk = has_v ? magic_kind(v_tmp) : "";
    std::string ak = has_a ? magic_kind(a_tmp) : "";
    std::string a_src_ext = sel.audio ? strutil::to_lower(sel.audio->ext) : "";
    bool raw_non_mp4_audio = !has_v && has_a && ak == "raw" &&
        (a_src_ext == "mp3" || a_src_ext == "opus" || a_src_ext == "ogg" || a_src_ext == "flac" || a_src_ext == "wav" || a_src_ext == "aac");
    bool ebml_involved = (vk == "ebml" || ak == "ebml" || target_ext == "webm" || target_ext == "mkv");

    // If an audio-only HLS stream actually delivered fMP4 despite a non-m4a format tag, adjust final_path cleanly to .m4a.
    if (!has_v && has_a && ak == "mp4" && opts.target_format.empty() && target_ext != "m4a" && target_ext != "mp4") {
        target_ext = "m4a";
        final_path.replace_extension(".m4a");
    }

    fs::path staged_final = job_dir / ("output." + target_ext);
    if (raw_non_mp4_audio) {
        if (a_src_ext == target_ext) staged_final = a_tmp;
        else SponsorAndSubs::run_ffmpeg_convert(a_tmp, staged_final, target_ext);
    } else if (!ebml_involved) {
        fs::path mux_out = (target_ext == "mp4" || target_ext == "m4a")
            ? staged_final
            : (job_dir / ("muxed." + std::string(is_audio_out ? "m4a" : "mp4")));

        std::vector<MP4Track> all_tracks;
        std::vector<fs::path> src_files;
        if (has_v) {
            int si = (int)src_files.size(); src_files.push_back(v_tmp);
            auto vt = (vk == "ts" || v_ts) ? TSDemuxer::demux(v_tmp) : MP4Muxer::read_tracks(v_tmp, si);
            MP4Muxer::trim_tracks(vt, opts.section, v_base);
            MP4Muxer::remove_intervals(vt, sponsor_cuts);
            for (auto& t : vt) if (!(has_a && t.kind == "soun")) all_tracks.push_back(std::move(t));
        }
        if (has_a) {
            int si = (int)src_files.size(); src_files.push_back(a_tmp);
            auto at = (ak == "ts" || a_ts) ? TSDemuxer::demux(a_tmp) : MP4Muxer::read_tracks(a_tmp, si);
            MP4Muxer::trim_tracks(at, opts.section, a_base);
            MP4Muxer::remove_intervals(at, sponsor_cuts);
            for (auto& t : at) if (t.kind == "soun") all_tracks.push_back(std::move(t));
        }
        double tot_dur = info.duration;
        for (const auto& t : all_tracks) tot_dur = std::max(tot_dur, t.duration_sec());
        if (!opts.external_subs && !is_audio_out) {
            for (const auto& [lg, cues] : dl_subs)
                all_tracks.push_back(MP4Muxer::make_timed_text_track(cues, "eng", false, tot_dur));
        }
        MP4Metadata meta;
        if (settings.embed_metadata) {
            meta = {info.title, info.author, info.upload_date, info.webpage_url, info.description, cover_bytes, chapters};
        }
        MP4Muxer::write_mp4(std::move(all_tracks), src_files, mux_out, is_audio_out, meta);
        if (mux_out != staged_final) {
            if (cb.on_stage) cb.on_stage("Converting to " + target_ext);
            SponsorAndSubs::run_ffmpeg_convert(mux_out, staged_final, target_ext);
            fs::remove(mux_out, ec);
        }
    } else if (!has_a && has_v && vk == "ebml" && !opts.section.active() && sponsor_cuts.empty() && target_ext == "webm") {
        staged_final = v_tmp;
    } else if (!has_v && has_a && ak == "ebml" && !opts.section.active() && sponsor_cuts.empty() && target_ext == "webm") {
        staged_final = a_tmp;
    } else {
        std::vector<EBMLTrack> ebml_tracks;
        std::vector<fs::path> src_files;
        auto append_ebml_src = [&](const fs::path& p, const std::string& kind, double base_s, bool keep_video, bool keep_audio) {
            int si = (int)src_files.size();
            src_files.push_back(p);
            std::vector<EBMLTrack> trs;
            if (kind == "ebml") {
                trs = EBMLMuxer::read_tracks(p, si);
            } else {
                auto mt = (kind == "ts") ? TSDemuxer::demux(p) : MP4Muxer::read_tracks(p, si);
                trs = EBMLMuxer::from_mp4_tracks(mt);
            }
            EBMLMuxer::trim_tracks(trs, opts.section, base_s);
            EBMLMuxer::remove_intervals(trs, sponsor_cuts);
            for (auto& t : trs) {
                if ((t.track_type == 1 && keep_video) || (t.track_type == 2 && keep_audio))
                    ebml_tracks.push_back(std::move(t));
            }
        };
        if (has_v) append_ebml_src(v_tmp, vk, v_base, true, !has_a);
        if (has_a) append_ebml_src(a_tmp, ak, a_base, false, true);

        bool can_webm = (target_ext != "mkv");
        for (const auto& t : ebml_tracks) {
            if (t.track_type == 1 && t.codec_id != "V_VP8" && t.codec_id != "V_VP9" && t.codec_id != "V_AV1") can_webm = false;
            if (t.track_type == 2 && t.codec_id != "A_OPUS" && t.codec_id != "A_VORBIS") can_webm = false;
        }
        if (opts.target_format.empty()) {
            std::string want_ext = can_webm ? "webm" : "mkv";
            if (target_ext != want_ext) {
                target_ext = want_ext;
                final_path.replace_extension("." + want_ext);
                staged_final = job_dir / ("output." + want_ext);
            }
        } else if (!can_webm && target_ext == "webm") {
            can_webm = false;
        }
        EBMLMuxer::write_ebml(std::move(ebml_tracks), src_files, staged_final, can_webm, info.title);
    }

    int64_t final_sz = commit_file_verified(staged_final, final_path);
    SponsorAndSubs::set_origin_xattr(final_path, info.webpage_url);

    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (cb.on_done) cb.on_done(final_path, final_sz, secs);
    return final_path;
}

} // namespace ubit
