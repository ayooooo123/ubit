#pragma once
#include "models.hpp"
#if !defined(__wasi__) && !defined(_WIN32)
#include <sys/xattr.h>
#endif

namespace ubit {

// MARK: - Big-Endian Binary Helpers & ISO-BMFF Box Reader/Writer

struct BinBuf {
    std::vector<uint8_t> d;
    void reserve(size_t n) { d.reserve(n); }
    size_t size() const { return d.size(); }
    void u8(uint8_t v) { d.push_back(v); }
    void u16(uint16_t v) { d.push_back((uint8_t)(v >> 8)); d.push_back((uint8_t)(v & 0xff)); }
    void u24(uint32_t v) { d.push_back((uint8_t)((v >> 16) & 0xff)); d.push_back((uint8_t)((v >> 8) & 0xff)); d.push_back((uint8_t)(v & 0xff)); }
    void u32(uint32_t v) { d.push_back((uint8_t)(v >> 24)); d.push_back((uint8_t)((v >> 16) & 0xff)); d.push_back((uint8_t)((v >> 8) & 0xff)); d.push_back((uint8_t)(v & 0xff)); }
    void i32(int32_t v) { u32((uint32_t)v); }
    void u64(uint64_t v) { u32((uint32_t)(v >> 32)); u32((uint32_t)(v & 0xffffffffu)); }
    void fourcc(const char* s) { for (int i = 0; i < 4; ++i) d.push_back(s[i] ? (uint8_t)s[i] : 0x20); }
    void raw4(uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3) { d.push_back(b0); d.push_back(b1); d.push_back(b2); d.push_back(b3); }
    void bytes(const uint8_t* p, size_t n) { d.insert(d.end(), p, p + n); }
    void bytes(const std::vector<uint8_t>& v) { d.insert(d.end(), v.begin(), v.end()); }
    void str_bytes(const std::string& s) { d.insert(d.end(), s.begin(), s.end()); }
    void zeros(size_t n) { d.insert(d.end(), n, 0); }

    template <typename F>
    void box(const char* type, F&& fn) {
        size_t start = d.size();
        u32(0);
        fourcc(type);
        fn(*this);
        uint32_t sz = (uint32_t)(d.size() - start);
        d[start] = (uint8_t)(sz >> 24); d[start+1] = (uint8_t)(sz >> 16); d[start+2] = (uint8_t)(sz >> 8); d[start+3] = (uint8_t)sz;
    }

    template <typename F>
    void box_raw4(uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3, F&& fn) {
        size_t start = d.size();
        u32(0);
        raw4(b0, b1, b2, b3);
        fn(*this);
        uint32_t sz = (uint32_t)(d.size() - start);
        d[start] = (uint8_t)(sz >> 24); d[start+1] = (uint8_t)(sz >> 16); d[start+2] = (uint8_t)(sz >> 8); d[start+3] = (uint8_t)sz;
    }

    template <typename F>
    void full_box(const char* type, uint8_t ver, uint32_t flags, F&& fn) {
        box(type, [&](BinBuf& b) {
            b.u8(ver);
            b.u24(flags);
            fn(b);
        });
    }
};

inline uint16_t rd_u16(const uint8_t* p) { return (uint16_t)((p[0] << 8) | p[1]); }
inline uint32_t rd_u32(const uint8_t* p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
inline int32_t  rd_i32(const uint8_t* p) { return (int32_t)rd_u32(p); }
inline uint64_t rd_u64(const uint8_t* p) { return ((uint64_t)rd_u32(p) << 32) | rd_u32(p + 4); }
inline std::string rd_4cc(const uint8_t* p) { return std::string((const char*)p, 4); }

struct BoxRef {
    std::string type;
    size_t hdr_off = 0;
    size_t pay_off = 0;
    size_t end_off = 0;
};

inline std::vector<BoxRef> list_boxes(const uint8_t* base, size_t start, size_t end) {
    std::vector<BoxRef> out;
    size_t pos = start;
    while (pos + 8 <= end) {
        uint32_t sz32 = rd_u32(base + pos);
        std::string tp = rd_4cc(base + pos + 4);
        size_t hlen = 8, bend = 0;
        if (sz32 == 1) {
            if (pos + 16 > end) break;
            hlen = 16;
            bend = pos + (size_t)rd_u64(base + pos + 8);
        } else if (sz32 == 0) {
            bend = end;
        } else {
            bend = pos + sz32;
        }
        if (bend < pos + hlen || bend > end) break;
        out.push_back({tp, pos, pos + hlen, bend});
        pos = bend;
    }
    return out;
}

struct MP4Sample {
    int src_idx = 0;
    uint64_t offset = 0;
    uint32_t size = 0;
    uint32_t duration = 1024;
    int32_t cts_offset = 0;
    bool is_sync = true;
    std::vector<uint8_t> inline_data;
};

struct MP4Track {
    uint32_t track_id = 1;
    std::string kind = "vide"; // "vide", "soun", "sbtl", "text"
    uint32_t timescale = 1000;
    uint16_t width = 0;
    uint16_t height = 0;
    std::string lang = "und";
    std::vector<uint8_t> stsd_payload;
    std::vector<MP4Sample> samples;

    uint64_t total_ticks() const {
        uint64_t t = 0;
        for (const auto& s : samples) t += s.duration;
        return t;
    }
    double duration_sec() const {
        return (double)total_ticks() / (double)std::max<uint32_t>(1, timescale);
    }
};

struct MP4Metadata {
    std::string title, artist, date, webpage_url, description;
    std::vector<uint8_t> cover_img;
    std::vector<Chapter> chapters;
};

struct SidxSegment {
    ByteRange range;
    double start_sec = 0.0;
    double dur_sec = 0.0;
};

class MP4Muxer {
public:
    static bool parse_sidx(const std::vector<uint8_t>& hdr, int64_t& init_end, std::vector<SidxSegment>& segs) {
        auto boxes = list_boxes(hdr.data(), 0, hdr.size());
        const BoxRef* sidx = nullptr;
        for (const auto& b : boxes) if (b.type == "sidx") { sidx = &b; break; }
        if (!sidx || sidx->pay_off + 12 > sidx->end_off) return false;
        const uint8_t* d = hdr.data();
        uint8_t ver = d[sidx->pay_off];
        uint32_t ts = rd_u32(d + sidx->pay_off + 8);
        if (ts == 0) return false;
        size_t off = sidx->pay_off + 12;
        uint64_t earliest_pts = 0, first_off = 0;
        if (ver == 0) {
            if (off + 8 > sidx->end_off) return false;
            earliest_pts = rd_u32(d + off); first_off = rd_u32(d + off + 4); off += 8;
        } else {
            if (off + 16 > sidx->end_off) return false;
            earliest_pts = rd_u64(d + off); first_off = rd_u64(d + off + 8); off += 16;
        }
        if (off + 4 > sidx->end_off) return false;
        uint16_t count = rd_u16(d + off + 2);
        off += 4;
        int64_t cur_byte = (int64_t)sidx->end_off + (int64_t)first_off;
        uint64_t cur_ticks = earliest_pts;
        for (uint16_t i = 0; i < count && off + 12 <= sidx->end_off; ++i, off += 12) {
            int64_t rsz = (int64_t)(rd_u32(d + off) & 0x7fffffffu);
            uint32_t sdur = rd_u32(d + off + 4);
            if (rsz > 0) {
                segs.push_back({{cur_byte, cur_byte + rsz - 1}, (double)cur_ticks / ts, (double)sdur / ts});
                cur_byte += rsz;
                cur_ticks += sdur;
            }
        }
        if (segs.empty()) return false;
        init_end = (int64_t)sidx->end_off - 1;
        return true;
    }

    static std::vector<MP4Track> read_tracks(const fs::path& file_path, int src_idx = 0) {
        std::ifstream in(file_path, std::ios::binary | std::ios::ate);
        if (!in) throw std::runtime_error("Cannot open " + file_path.string());
        size_t fsize = (size_t)in.tellg();
        in.seekg(0);
        std::vector<uint8_t> buf(fsize);
        if (fsize > 0) in.read((char*)buf.data(), (std::streamsize)fsize);
        const uint8_t* d = buf.data();

        auto top = list_boxes(d, 0, fsize);
        const BoxRef* moov = nullptr;
        for (const auto& b : top) if (b.type == "moov") { moov = &b; break; }
        if (!moov) throw std::runtime_error("Missing moov box in " + file_path.filename().string());

        auto mchildren = list_boxes(d, moov->pay_off, moov->end_off);
        struct Trex { uint32_t dur = 1024, sz = 0, flags = 0; };
        std::map<uint32_t, Trex> trex_map;
        for (const auto& b : mchildren) {
            if (b.type == "mvex") {
                for (const auto& tb : list_boxes(d, b.pay_off, b.end_off)) {
                    if (tb.type == "trex" && tb.pay_off + 24 <= tb.end_off) {
                        uint32_t tid = rd_u32(d + tb.pay_off + 4);
                        trex_map[tid] = {rd_u32(d + tb.pay_off + 12), rd_u32(d + tb.pay_off + 16), rd_u32(d + tb.pay_off + 20)};
                    }
                }
            }
        }

        std::map<uint32_t, MP4Track> by_id;
        std::vector<uint32_t> order;

        for (const auto& trak : mchildren) {
            if (trak.type != "trak") continue;
            MP4Track tr;
            auto tboxes = list_boxes(d, trak.pay_off, trak.end_off);
            for (const auto& tb : tboxes) {
                if (tb.type == "tkhd") {
                    uint8_t ver = d[tb.pay_off];
                    if (ver == 0 && tb.pay_off + 84 <= tb.end_off) {
                        tr.track_id = rd_u32(d + tb.pay_off + 12);
                        tr.width = (uint16_t)(rd_u32(d + tb.pay_off + 76) >> 16);
                        tr.height = (uint16_t)(rd_u32(d + tb.pay_off + 80) >> 16);
                    } else if (ver == 1 && tb.pay_off + 96 <= tb.end_off) {
                        tr.track_id = rd_u32(d + tb.pay_off + 20);
                        tr.width = (uint16_t)(rd_u32(d + tb.pay_off + 88) >> 16);
                        tr.height = (uint16_t)(rd_u32(d + tb.pay_off + 92) >> 16);
                    }
                } else if (tb.type == "mdia") {
                    for (const auto& mb : list_boxes(d, tb.pay_off, tb.end_off)) {
                        if (mb.type == "mdhd") {
                            uint8_t ver = d[mb.pay_off];
                            tr.timescale = (ver == 0 && mb.pay_off + 16 <= mb.end_off) ? rd_u32(d + mb.pay_off + 12) : rd_u32(d + mb.pay_off + 20);
                        } else if (mb.type == "hdlr" && mb.pay_off + 12 <= mb.end_off) {
                            tr.kind = rd_4cc(d + mb.pay_off + 8);
                        } else if (mb.type == "minf") {
                            for (const auto& mfb : list_boxes(d, mb.pay_off, mb.end_off)) {
                                if (mfb.type == "stbl") {
                                    parse_stbl(d, list_boxes(d, mfb.pay_off, mfb.end_off), src_idx, tr);
                                }
                            }
                        }
                    }
                }
            }
            if ((tr.kind == "vide" || tr.kind == "soun" || tr.kind == "sbtl") && !tr.stsd_payload.empty()) {
                by_id[tr.track_id] = std::move(tr);
                order.push_back(tr.track_id);
            }
        }

        // Parse fragmented moof boxes
        for (const auto& b : top) {
            if (b.type != "moof") continue;
            uint64_t moof_start = b.hdr_off;
            for (const auto& traf : list_boxes(d, b.pay_off, b.end_off)) {
                if (traf.type != "traf") continue;
                auto tboxes = list_boxes(d, traf.pay_off, traf.end_off);
                const BoxRef* tfhd = nullptr;
                for (const auto& x : tboxes) if (x.type == "tfhd") { tfhd = &x; break; }
                if (!tfhd || tfhd->pay_off + 8 > tfhd->end_off) continue;
                uint32_t tflags = rd_u32(d + tfhd->pay_off) & 0xffffffu;
                uint32_t tid = rd_u32(d + tfhd->pay_off + 4);
                auto it = by_id.find(tid);
                if (it == by_id.end()) continue;
                auto& track = it->second;
                Trex tx = trex_map.count(tid) ? trex_map[tid] : Trex{};

                size_t hoff = tfhd->pay_off + 8;
                uint64_t base_off = moof_start;
                if ((tflags & 0x01) && hoff + 8 <= tfhd->end_off) { base_off = rd_u64(d + hoff); hoff += 8; }
                if (tflags & 0x02) hoff += 4;
                uint32_t def_dur = tx.dur, def_sz = tx.sz, def_fl = tx.flags;
                if ((tflags & 0x08) && hoff + 4 <= tfhd->end_off) { def_dur = rd_u32(d + hoff); hoff += 4; }
                if ((tflags & 0x10) && hoff + 4 <= tfhd->end_off) { def_sz = rd_u32(d + hoff); hoff += 4; }
                if ((tflags & 0x20) && hoff + 4 <= tfhd->end_off) { def_fl = rd_u32(d + hoff); hoff += 4; }

                uint64_t run_off = base_off;
                for (const auto& trun : tboxes) {
                    if (trun.type != "trun" || trun.pay_off + 8 > trun.end_off) continue;
                    uint32_t rflags = rd_u32(d + trun.pay_off) & 0xffffffu;
                    uint32_t cnt = rd_u32(d + trun.pay_off + 4);
                    size_t roff = trun.pay_off + 8;
                    if ((rflags & 0x01) && roff + 4 <= trun.end_off) {
                        run_off = (uint64_t)((int64_t)base_off + rd_i32(d + roff));
                        roff += 4;
                    }
                    bool has_first_fl = false;
                    uint32_t first_fl = 0;
                    if ((rflags & 0x04) && roff + 4 <= trun.end_off) { first_fl = rd_u32(d + roff); has_first_fl = true; roff += 4; }
                    for (uint32_t i = 0; i < cnt; ++i) {
                        uint32_t sdur = def_dur, ssz = def_sz, sfl = (i == 0 && has_first_fl) ? first_fl : def_fl;
                        int32_t scts = 0;
                        if ((rflags & 0x100) && roff + 4 <= trun.end_off) { sdur = rd_u32(d + roff); roff += 4; }
                        if ((rflags & 0x200) && roff + 4 <= trun.end_off) { ssz = rd_u32(d + roff); roff += 4; }
                        if ((rflags & 0x400) && roff + 4 <= trun.end_off) { sfl = rd_u32(d + roff); roff += 4; }
                        if ((rflags & 0x800) && roff + 4 <= trun.end_off) { scts = rd_i32(d + roff); roff += 4; }
                        bool sync = (track.kind != "vide") ? true : ((sfl & 0x00010000u) == 0);
                        track.samples.push_back({src_idx, run_off, ssz, sdur, scts, sync, {}});
                        run_off += ssz;
                    }
                }
            }
        }

        std::vector<MP4Track> res;
        for (uint32_t id : order) if (!by_id[id].samples.empty()) res.push_back(std::move(by_id[id]));
        return res;
    }

    static void trim_tracks(std::vector<MP4Track>& tracks, const SectionRange& sec, double base_sec = 0.0) {
        if (!sec.active()) return;
        double t_start = std::max(0.0, (sec.start >= 0 ? sec.start : 0.0) - base_sec);
        double t_end = (sec.end >= 0) ? std::max(t_start, sec.end - base_sec) : -1.0;

        double eff_start = t_start;
        for (const auto& t : tracks) {
            if (t.kind == "vide") {
                uint64_t ticks = 0;
                double last_sync = 0.0;
                for (const auto& s : t.samples) {
                    double cur = (double)ticks / t.timescale;
                    if (s.is_sync && cur <= t_start + 0.001) last_sync = cur;
                    if (cur > t_start) break;
                    ticks += s.duration;
                }
                eff_start = last_sync;
                break;
            }
        }

        for (auto& t : tracks) {
            std::vector<MP4Sample> kept;
            uint64_t ticks = 0;
            for (auto& s : t.samples) {
                double ss = (double)ticks / t.timescale;
                ticks += s.duration;
                double se = (double)ticks / t.timescale;
                if (se <= eff_start) continue;
                if (t_end >= 0 && ss >= t_end) break;
                kept.push_back(std::move(s));
            }
            if (!kept.empty()) t.samples = std::move(kept);
        }
    }

    static void remove_intervals(std::vector<MP4Track>& tracks, const std::vector<std::pair<double, double>>& cuts) {
        if (cuts.empty()) return;
        for (auto& t : tracks) {
            std::vector<MP4Sample> kept;
            uint64_t ticks = 0;
            bool wait_sync = false;
            for (auto& s : t.samples) {
                double sec = (double)ticks / t.timescale;
                ticks += s.duration;
                bool in_cut = false;
                for (const auto& [cs, ce] : cuts) if (sec >= cs && sec < ce) { in_cut = true; break; }
                if (in_cut) {
                    if (t.kind == "vide") wait_sync = true;
                    continue;
                }
                if (wait_sync) {
                    if (s.is_sync) wait_sync = false;
                    else continue;
                }
                kept.push_back(std::move(s));
            }
            if (!kept.empty()) t.samples = std::move(kept);
        }
    }

    static MP4Track make_timed_text_track(const std::vector<Chapter>& cues, const std::string& lang3, bool is_chapter, double total_dur) {
        MP4Track tr;
        tr.kind = is_chapter ? "text" : "sbtl";
        tr.timescale = 1000;
        tr.lang = lang3;

        auto make_sample = [](const std::string& s) {
            BinBuf b;
            b.u16((uint16_t)std::min<size_t>(65535, s.size()));
            b.str_bytes(s.substr(0, 65535));
            return b.d;
        };

        uint64_t cursor = 0;
        for (const auto& c : cues) {
            uint64_t st = (uint64_t)(std::max(0.0, c.start_time) * 1000.0);
            uint64_t en = std::max(st + 100, (uint64_t)(std::max(c.start_time + 0.1, c.end_time) * 1000.0));
            if (st > cursor) {
                auto emp = make_sample("");
                tr.samples.push_back({0, 0, (uint32_t)emp.size(), (uint32_t)(st - cursor), 0, true, std::move(emp)});
                cursor = st;
            }
            uint32_t dur = (uint32_t)(en > cursor ? en - cursor : 100);
            auto pay = make_sample(c.title);
            tr.samples.push_back({0, 0, (uint32_t)pay.size(), dur, 0, true, std::move(pay)});
            cursor += dur;
        }
        uint64_t tot = (uint64_t)(std::max(0.0, total_dur) * 1000.0);
        if (tot > cursor) {
            auto emp = make_sample("");
            tr.samples.push_back({0, 0, (uint32_t)emp.size(), (uint32_t)(tot - cursor), 0, true, std::move(emp)});
        }

        BinBuf stsd;
        stsd.u8(0); stsd.u24(0); stsd.u32(1);
        stsd.box("tx3g", [](BinBuf& e) {
            e.zeros(6); e.u16(1); e.u32(0); e.u8(1); e.u8(0xff); e.u32(0x000000ff);
            e.zeros(8); e.zeros(8); e.u32(0xffffffffu);
            e.box("ftab", [](BinBuf& f) {
                f.u16(1); f.u16(1); f.u8(10); f.str_bytes("Sans-Serif");
            });
        });
        tr.stsd_payload = std::move(stsd.d);
        return tr;
    }

    static void write_mp4(
        std::vector<MP4Track> tracks,
        const std::vector<fs::path>& source_files,
        const fs::path& dest,
        bool is_m4a,
        const MP4Metadata& meta
    ) {
        if (tracks.empty()) throw std::runtime_error("No media tracks to mux");
        double max_dur = 0.0;
        for (const auto& t : tracks) max_dur = std::max(max_dur, t.duration_sec());

        uint32_t chap_tid = 0;
        if (!meta.chapters.empty()) {
            MP4Track ctr = make_timed_text_track(meta.chapters, "eng", true, max_dur);
            if (!ctr.samples.empty()) {
                tracks.push_back(std::move(ctr));
                chap_tid = (uint32_t)tracks.size();
            }
        }
        for (size_t i = 0; i < tracks.size(); ++i) tracks[i].track_id = (uint32_t)(i + 1);

        std::vector<std::vector<uint64_t>> rel_offs(tracks.size());
        uint64_t mdat_bytes = 0;
        for (size_t i = 0; i < tracks.size(); ++i) {
            rel_offs[i].reserve(tracks[i].samples.size());
            for (const auto& s : tracks[i].samples) {
                rel_offs[i].push_back(mdat_bytes);
                mdat_bytes += s.size;
            }
        }
        uint64_t mdat_hdr_len = (mdat_bytes + 8 > 0xffffffffULL) ? 16 : 8;

        BinBuf ftyp;
        ftyp.box("ftyp", [&](BinBuf& b) {
            if (is_m4a) { b.fourcc("M4A "); b.u32(0); b.fourcc("M4A "); b.fourcc("mp42"); b.fourcc("isom"); }
            else { b.fourcc("isom"); b.u32(0x200); b.fourcc("isom"); b.fourcc("iso2"); b.fourcc("avc1"); b.fourcc("mp41"); }
        });

        auto dummy_moov = build_moov(tracks, 0, rel_offs, meta, chap_tid);
        uint64_t mdat_pay_start = ftyp.size() + dummy_moov.size() + mdat_hdr_len;
        auto final_moov = build_moov(tracks, mdat_pay_start, rel_offs, meta, chap_tid);

        std::error_code ec;
        fs::create_directories(dest.parent_path(), ec);
        fs::path part = dest.string() + ".mux.part";
        FILE* out = std::fopen(part.c_str(), "wb");
        if (!out) throw std::runtime_error("Cannot open " + part.string());

        std::fwrite(ftyp.d.data(), 1, ftyp.size(), out);
        std::fwrite(final_moov.data(), 1, final_moov.size(), out);

        BinBuf mh;
        if (mdat_hdr_len == 16) { mh.u32(1); mh.fourcc("mdat"); mh.u64(mdat_bytes + 16); }
        else { mh.u32((uint32_t)(mdat_bytes + 8)); mh.fourcc("mdat"); }
        std::fwrite(mh.d.data(), 1, mh.size(), out);

        std::vector<FILE*> src_fps;
        for (const auto& sp : source_files) src_fps.push_back(std::fopen(sp.c_str(), "rb"));

        std::vector<uint8_t> copy_buf;
        for (const auto& t : tracks) {
            for (const auto& s : t.samples) {
                if (!s.inline_data.empty()) {
                    std::fwrite(s.inline_data.data(), 1, s.inline_data.size(), out);
                } else if (s.src_idx >= 0 && (size_t)s.src_idx < src_fps.size() && src_fps[s.src_idx] && s.size > 0) {
                    if (copy_buf.size() < s.size) copy_buf.resize(s.size);
                    ::fseeko(src_fps[s.src_idx], (off_t)s.offset, SEEK_SET);
                    size_t nr = std::fread(copy_buf.data(), 1, s.size, src_fps[s.src_idx]);
                    if (nr > 0) std::fwrite(copy_buf.data(), 1, nr, out);
                }
            }
        }

        for (FILE* fp : src_fps) if (fp) std::fclose(fp);
        std::fflush(out);
        ::fsync(fileno(out));
        std::fclose(out);
        commit_file_verified(part, dest);
    }

private:
    static void parse_stbl(const uint8_t* d, const std::vector<BoxRef>& boxes, int src_idx, MP4Track& tr) {
        std::vector<uint32_t> sizes;
        std::vector<uint64_t> chunk_offs;
        struct StscRun { uint32_t first_chunk, spc; };
        std::vector<StscRun> stsc_runs;
        const BoxRef* stts_b = nullptr, *ctts_b = nullptr, *stss_b = nullptr;

        for (const auto& b : boxes) {
            if (b.type == "stsd") {
                tr.stsd_payload.assign(d + b.pay_off, d + b.end_off);
            } else if (b.type == "stsz" && b.pay_off + 12 <= b.end_off) {
                uint32_t fixed = rd_u32(d + b.pay_off + 4);
                uint32_t cnt = rd_u32(d + b.pay_off + 8);
                if (fixed != 0) sizes.assign(cnt, fixed);
                else {
                    sizes.reserve(cnt);
                    for (uint32_t i = 0; i < cnt && b.pay_off + 12 + i * 4 + 4 <= b.end_off; ++i)
                        sizes.push_back(rd_u32(d + b.pay_off + 12 + i * 4));
                }
            } else if (b.type == "stco" && b.pay_off + 8 <= b.end_off) {
                uint32_t cnt = rd_u32(d + b.pay_off + 4);
                for (uint32_t i = 0; i < cnt && b.pay_off + 8 + i * 4 + 4 <= b.end_off; ++i)
                    chunk_offs.push_back(rd_u32(d + b.pay_off + 8 + i * 4));
            } else if (b.type == "co64" && b.pay_off + 8 <= b.end_off) {
                uint32_t cnt = rd_u32(d + b.pay_off + 4);
                for (uint32_t i = 0; i < cnt && b.pay_off + 8 + i * 8 + 8 <= b.end_off; ++i)
                    chunk_offs.push_back(rd_u64(d + b.pay_off + 8 + i * 8));
            } else if (b.type == "stsc" && b.pay_off + 8 <= b.end_off) {
                uint32_t cnt = rd_u32(d + b.pay_off + 4);
                for (uint32_t i = 0; i < cnt && b.pay_off + 8 + i * 12 + 12 <= b.end_off; ++i)
                    stsc_runs.push_back({std::max<uint32_t>(1, rd_u32(d + b.pay_off + 8 + i * 12)), rd_u32(d + b.pay_off + 12 + i * 12)});
            } else if (b.type == "stts") stts_b = &b;
            else if (b.type == "ctts") ctts_b = &b;
            else if (b.type == "stss") stss_b = &b;
        }
        if (sizes.empty()) return;
        size_t n = sizes.size();
        std::vector<uint64_t> offs(n, 0);
        size_t sidx = 0;
        for (size_t r = 0; r < stsc_runs.size() && !chunk_offs.empty(); ++r) {
            size_t c0 = stsc_runs[r].first_chunk - 1;
            size_t c1 = (r + 1 < stsc_runs.size()) ? std::min(chunk_offs.size(), (size_t)(stsc_runs[r+1].first_chunk - 1)) : chunk_offs.size();
            for (size_t c = c0; c < c1; ++c) {
                uint64_t cur = chunk_offs[c];
                for (uint32_t k = 0; k < stsc_runs[r].spc && sidx < n; ++k, ++sidx) {
                    offs[sidx] = cur;
                    cur += sizes[sidx];
                }
            }
        }
        std::vector<uint32_t> durs(n, 1024);
        if (stts_b && stts_b->pay_off + 8 <= stts_b->end_off) {
            uint32_t cnt = rd_u32(d + stts_b->pay_off + 4);
            size_t si = 0;
            for (uint32_t i = 0; i < cnt && stts_b->pay_off + 8 + i * 8 + 8 <= stts_b->end_off; ++i) {
                uint32_t rc = rd_u32(d + stts_b->pay_off + 8 + i * 8);
                uint32_t rd = rd_u32(d + stts_b->pay_off + 12 + i * 8);
                for (uint32_t j = 0; j < rc && si < n; ++j) durs[si++] = rd;
            }
        }
        std::vector<int32_t> cts(n, 0);
        if (ctts_b && ctts_b->pay_off + 8 <= ctts_b->end_off) {
            uint32_t cnt = rd_u32(d + ctts_b->pay_off + 4);
            size_t si = 0;
            for (uint32_t i = 0; i < cnt && ctts_b->pay_off + 8 + i * 8 + 8 <= ctts_b->end_off; ++i) {
                uint32_t rc = rd_u32(d + ctts_b->pay_off + 8 + i * 8);
                int32_t co = rd_i32(d + ctts_b->pay_off + 12 + i * 8);
                for (uint32_t j = 0; j < rc && si < n; ++j) cts[si++] = co;
            }
        }
        std::set<size_t> syncs;
        bool has_stss = false;
        if (stss_b && stss_b->pay_off + 8 <= stss_b->end_off) {
            has_stss = true;
            uint32_t cnt = rd_u32(d + stss_b->pay_off + 4);
            for (uint32_t i = 0; i < cnt && stss_b->pay_off + 8 + i * 4 + 4 <= stss_b->end_off; ++i) {
                uint32_t v = rd_u32(d + stss_b->pay_off + 8 + i * 4);
                if (v > 0) syncs.insert(v - 1);
            }
        }
        tr.samples.reserve(n);
        for (size_t i = 0; i < n; ++i) {
            bool sy = has_stss ? (syncs.count(i) > 0) : (tr.kind != "vide");
            tr.samples.push_back({src_idx, offs[i], sizes[i], durs[i], cts[i], sy, {}});
        }
    }

    static std::vector<uint8_t> build_moov(
        const std::vector<MP4Track>& tracks,
        uint64_t base_off,
        const std::vector<std::vector<uint64_t>>& rel_offs,
        const MP4Metadata& meta,
        uint32_t chap_tid
    ) {
        double max_dur = 0.0;
        for (const auto& t : tracks) max_dur = std::max(max_dur, t.duration_sec());
        uint32_t movie_ts = 1000;
        uint32_t movie_dur = (uint32_t)(max_dur * movie_ts);

        BinBuf moov;
        moov.reserve(65536);
        moov.box("moov", [&](BinBuf& m) {
            m.full_box("mvhd", 0, 0, [&](BinBuf& b) {
                b.u32(0); b.u32(0); b.u32(movie_ts); b.u32(movie_dur);
                b.u32(0x00010000); b.u16(0x0100); b.zeros(10);
                for (uint32_t v : {0x00010000u,0u,0u,0u,0x00010000u,0u,0u,0u,0x40000000u}) b.u32(v);
                b.zeros(24);
                b.u32((uint32_t)(tracks.size() + 1));
            });

            for (size_t idx = 0; idx < tracks.size(); ++idx) {
                const auto& t = tracks[idx];
                bool is_chap = (chap_tid != 0 && t.track_id == chap_tid);
                m.box("trak", [&](BinBuf& tr) {
                    tr.full_box("tkhd", 0, is_chap ? 0 : 3, [&](BinBuf& b) {
                        b.u32(0); b.u32(0); b.u32(t.track_id); b.u32(0);
                        b.u32((uint32_t)(t.duration_sec() * movie_ts));
                        b.zeros(8); b.u16(0);
                        b.u16(t.kind == "soun" ? 1 : 0);
                        b.u16(t.kind == "soun" ? 0x0100 : 0);
                        b.u16(0);
                        for (uint32_t v : {0x00010000u,0u,0u,0u,0x00010000u,0u,0u,0u,0x40000000u}) b.u32(v);
                        b.u32((uint32_t)t.width << 16);
                        b.u32((uint32_t)t.height << 16);
                    });

                    if (chap_tid != 0 && !is_chap && (t.kind == "vide" || t.kind == "soun")) {
                        tr.box("tref", [&](BinBuf& tf) { tf.box("chap", [&](BinBuf& c) { c.u32(chap_tid); }); });
                    }

                    tr.box("mdia", [&](BinBuf& md) {
                        md.full_box("mdhd", 0, 0, [&](BinBuf& b) {
                            b.u32(0); b.u32(0); b.u32(t.timescale); b.u32((uint32_t)t.total_ticks());
                            b.u16(0x55c4); b.u16(0); // 'und'
                        });
                        md.full_box("hdlr", 0, 0, [&](BinBuf& b) {
                            b.u32(0); b.fourcc(t.kind.c_str()); b.zeros(12);
                            b.str_bytes("uBit Media Handler"); b.u8(0);
                        });
                        md.box("minf", [&](BinBuf& mf) {
                            if (t.kind == "vide") mf.full_box("vmhd", 0, 1, [](BinBuf& b) { b.zeros(8); });
                            else if (t.kind == "soun") mf.full_box("smhd", 0, 0, [](BinBuf& b) { b.zeros(4); });
                            else mf.full_box("nmhd", 0, 0, [](BinBuf&) {});

                            mf.box("dinf", [](BinBuf& di) {
                                di.full_box("dref", 0, 0, [](BinBuf& dr) {
                                    dr.u32(1); dr.full_box("url ", 0, 1, [](BinBuf&) {});
                                });
                            });

                            mf.box("stbl", [&](BinBuf& sb) {
                                sb.box("stsd", [&](BinBuf& b) { b.bytes(t.stsd_payload); });

                                std::vector<std::pair<uint32_t, uint32_t>> stts;
                                bool any_cts = false, neg_cts = false;
                                std::vector<std::pair<uint32_t, int32_t>> ctts;
                                std::vector<uint32_t> syncs;

                                for (size_t si = 0; si < t.samples.size(); ++si) {
                                    const auto& s = t.samples[si];
                                    if (!stts.empty() && stts.back().second == s.duration) stts.back().first++;
                                    else stts.push_back({1, s.duration});
                                    if (s.cts_offset != 0) any_cts = true;
                                    if (s.cts_offset < 0) neg_cts = true;
                                    if (!ctts.empty() && ctts.back().second == s.cts_offset) ctts.back().first++;
                                    else ctts.push_back({1, s.cts_offset});
                                    if (t.kind == "vide" && s.is_sync) syncs.push_back((uint32_t)(si + 1));
                                }

                                sb.full_box("stts", 0, 0, [&](BinBuf& b) {
                                    b.u32((uint32_t)stts.size());
                                    for (auto [c, du] : stts) { b.u32(c); b.u32(du); }
                                });
                                if (any_cts) {
                                    sb.full_box("ctts", neg_cts ? 1 : 0, 0, [&](BinBuf& b) {
                                        b.u32((uint32_t)ctts.size());
                                        for (auto [c, co] : ctts) { b.u32(c); b.i32(co); }
                                    });
                                }
                                if (t.kind == "vide") {
                                    sb.full_box("stss", 0, 0, [&](BinBuf& b) {
                                        b.u32((uint32_t)syncs.size());
                                        for (uint32_t si : syncs) b.u32(si);
                                    });
                                }

                                const size_t csz = 64;
                                size_t nchunks = (t.samples.size() + csz - 1) / csz;
                                size_t rem = t.samples.size() % csz;
                                sb.full_box("stsc", 0, 0, [&](BinBuf& b) {
                                    if (nchunks <= 1) { b.u32(1); b.u32(1); b.u32((uint32_t)t.samples.size()); b.u32(1); }
                                    else if (rem == 0) { b.u32(1); b.u32(1); b.u32((uint32_t)csz); b.u32(1); }
                                    else {
                                        b.u32(2);
                                        b.u32(1); b.u32((uint32_t)csz); b.u32(1);
                                        b.u32((uint32_t)nchunks); b.u32((uint32_t)rem); b.u32(1);
                                    }
                                });
                                sb.full_box("stsz", 0, 0, [&](BinBuf& b) {
                                    b.u32(0); b.u32((uint32_t)t.samples.size());
                                    for (const auto& s : t.samples) b.u32(s.size);
                                });
                                sb.full_box("co64", 0, 0, [&](BinBuf& b) {
                                    b.u32((uint32_t)nchunks);
                                    for (size_t ci = 0; ci < rel_offs[idx].size(); ci += csz)
                                        b.u64(base_off + rel_offs[idx][ci]);
                                });
                            });
                        });
                    });
                });
            }

            bool has_meta = !meta.title.empty() || !meta.artist.empty() || !meta.date.empty() || !meta.webpage_url.empty() || !meta.cover_img.empty();
            if (has_meta || !meta.chapters.empty()) {
                m.box("udta", [&](BinBuf& u) {
                    if (!meta.chapters.empty()) {
                        u.full_box("chpl", 1, 0, [&](BinBuf& c) {
                            c.u8(0);
                            uint32_t cnt = (uint32_t)std::min<size_t>(255, meta.chapters.size());
                            c.u32(cnt);
                            for (uint32_t i = 0; i < cnt; ++i) {
                                c.u64((uint64_t)(std::max(0.0, meta.chapters[i].start_time) * 10000000.0));
                                std::string ct = meta.chapters[i].title.substr(0, 120);
                                c.u8((uint8_t)ct.size());
                                c.str_bytes(ct);
                            }
                        });
                    }
                    if (has_meta) {
                        u.full_box("meta", 0, 0, [&](BinBuf& mb) {
                            mb.full_box("hdlr", 0, 0, [](BinBuf& h) {
                                h.u32(0); h.fourcc("mdir"); h.fourcc("appl"); h.zeros(8); h.u8(0);
                            });
                            mb.box("ilst", [&](BinBuf& il) {
                                auto tag = [&](uint8_t a, uint8_t b, uint8_t c, uint8_t d, const std::string& v) {
                                    if (v.empty()) return;
                                    il.box_raw4(a, b, c, d, [&](BinBuf& it) {
                                        it.box("data", [&](BinBuf& dt) { dt.u32(1); dt.u32(0); dt.str_bytes(v); });
                                    });
                                };
                                tag(0xA9, 'n', 'a', 'm', meta.title);
                                tag(0xA9, 'A', 'R', 'T', meta.artist);
                                tag(0xA9, 'd', 'a', 'y', meta.date);
                                tag(0xA9, 'c', 'm', 't', meta.webpage_url);
                                tag('d', 'e', 's', 'c', meta.description.substr(0, 250));
                                if (!meta.cover_img.empty()) {
                                    bool is_png = meta.cover_img.size() >= 4 && meta.cover_img[0] == 0x89 && meta.cover_img[1] == 0x50;
                                    il.box("covr", [&](BinBuf& it) {
                                        it.box("data", [&](BinBuf& dt) { dt.u32(is_png ? 14 : 13); dt.u32(0); dt.bytes(meta.cover_img); });
                                    });
                                }
                            });
                        });
                    }
                });
            }
        });
        return moov.d;
    }
};

// MARK: - Zero-Encode EBML (WebM & Matroska) Demuxer + Stream-Copy Muxer

struct EBMLPacket {
    int src_idx = 0;
    uint64_t offset = 0;
    uint32_t size = 0;
    int64_t pts_ns = 0;
    int64_t discard_padding_ns = 0;
    bool keyframe = true;
    std::vector<uint8_t> inline_data;
};

struct EBMLTrack {
    uint32_t track_num = 1;
    uint8_t track_type = 1; // 1 = video, 2 = audio
    std::string codec_id;
    uint64_t codec_delay_ns = 0;
    uint64_t seek_preroll_ns = 0;
    std::vector<uint8_t> codec_private;
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> colour_raw; // raw 0x55B0 master element if present
    double sample_rate = 48000.0;
    uint32_t channels = 2, bit_depth = 0;
    std::vector<EBMLPacket> packets;

    double duration_sec() const {
        if (packets.empty()) return 0.0;
        int64_t hi = 0;
        for (const auto& p : packets) if (p.pts_ns > hi) hi = p.pts_ns;
        return (double)hi / 1e9;
    }
};

class EBMLMuxer {
    static bool rd_vint_id(FILE* f, uint64_t end_pos, uint32_t& id, uint64_t& hdr_pos) {
        int64_t cur = ::ftello(f);
        if (cur < 0 || (uint64_t)cur >= end_pos) return false;
        hdr_pos = (uint64_t)cur;
        int b0 = std::fgetc(f);
        if (b0 == EOF || b0 == 0) return false;
        int len = 1;
        while (len <= 4 && (b0 & (0x80 >> (len - 1))) == 0) ++len;
        if (len > 4 || hdr_pos + (uint64_t)len > end_pos) return false;
        uint32_t v = (uint32_t)b0;
        for (int i = 1; i < len; ++i) {
            int b = std::fgetc(f);
            if (b == EOF) return false;
            v = (v << 8) | (uint32_t)b;
        }
        id = v;
        return true;
    }

    static bool rd_vint_size(FILE* f, uint64_t end_pos, uint64_t& sz, bool& unknown) {
        int64_t cur = ::ftello(f);
        if (cur < 0 || (uint64_t)cur >= end_pos) return false;
        int b0 = std::fgetc(f);
        if (b0 == EOF || b0 == 0) return false;
        int len = 1;
        while (len <= 8 && (b0 & (0x80 >> (len - 1))) == 0) ++len;
        if (len > 8 || (uint64_t)cur + (uint64_t)len > end_pos) return false;
        uint64_t mask = (0x80u >> (len - 1)) - 1u;
        uint64_t v = (uint64_t)b0 & mask;
        uint64_t all_ones = mask;
        for (int i = 1; i < len; ++i) {
            int b = std::fgetc(f);
            if (b == EOF) return false;
            v = (v << 8) | (uint64_t)b;
            all_ones = (all_ones << 8) | 0xffu;
        }
        unknown = (v == all_ones);
        sz = v;
        return true;
    }

    static uint64_t rd_uint_mem(const uint8_t* p, size_t n) {
        uint64_t v = 0;
        for (size_t i = 0; i < n && i < 8; ++i) v = (v << 8) | p[i];
        return v;
    }

    static int64_t rd_sint_mem(const uint8_t* p, size_t n) {
        if (n == 0) return 0;
        int64_t v = (p[0] & 0x80) ? -1 : 0;
        for (size_t i = 0; i < n && i < 8; ++i) v = (v << 8) | p[i];
        return v;
    }

    static double rd_float_mem(const uint8_t* p, size_t n) {
        if (n == 4) {
            uint32_t u = (uint32_t)rd_uint_mem(p, 4);
            float fv = 0.0f; std::memcpy(&fv, &u, 4);
            return (double)fv;
        }
        if (n == 8) {
            uint64_t u = rd_uint_mem(p, 8);
            double dv = 0.0; std::memcpy(&dv, &u, 8);
            return dv;
        }
        return 0.0;
    }

    static size_t rd_buf_vint(const uint8_t* p, size_t end, uint64_t& val, bool mask_marker) {
        if (end == 0 || p[0] == 0) return 0;
        size_t len = 1;
        while (len <= 8 && (p[0] & (0x80u >> (len - 1))) == 0) ++len;
        if (len > 8 || len > end) return 0;
        uint64_t v = mask_marker ? (p[0] & ((0x80u >> (len - 1)) - 1u)) : p[0];
        for (size_t i = 1; i < len; ++i) v = (v << 8) | p[i];
        val = v;
        return len;
    }

    static void wr_id(std::vector<uint8_t>& out, uint32_t id) {
        if (id > 0xffffffu) out.push_back((uint8_t)(id >> 24));
        if (id > 0xffffu)   out.push_back((uint8_t)(id >> 16));
        if (id > 0xffu)     out.push_back((uint8_t)(id >> 8));
        out.push_back((uint8_t)id);
    }

    static void wr_size(std::vector<uint8_t>& out, uint64_t sz) {
        if (sz < 0x7fu) {
            out.push_back((uint8_t)(0x80u | sz));
        } else if (sz < 0x3fffu) {
            out.push_back((uint8_t)(0x40u | (sz >> 8)));
            out.push_back((uint8_t)sz);
        } else if (sz < 0x1fffffu) {
            out.push_back((uint8_t)(0x20u | (sz >> 16)));
            out.push_back((uint8_t)(sz >> 8));
            out.push_back((uint8_t)sz);
        } else if (sz < 0x0fffffffu) {
            out.push_back((uint8_t)(0x10u | (sz >> 24)));
            out.push_back((uint8_t)(sz >> 16));
            out.push_back((uint8_t)(sz >> 8));
            out.push_back((uint8_t)sz);
        } else {
            uint64_t v = 0x0100000000000000ULL | sz;
            for (int s = 56; s >= 0; s -= 8) out.push_back((uint8_t)(v >> s));
        }
    }

    static void wr_uint(std::vector<uint8_t>& out, uint32_t id, uint64_t v) {
        wr_id(out, id);
        int n = 1;
        while (n < 8 && (v >> (n * 8)) != 0) ++n;
        wr_size(out, (uint64_t)n);
        for (int i = n - 1; i >= 0; --i) out.push_back((uint8_t)(v >> (i * 8)));
    }

    static void wr_sint(std::vector<uint8_t>& out, uint32_t id, int64_t v) {
        wr_id(out, id);
        wr_size(out, 8);
        uint64_t u = (uint64_t)v;
        for (int s = 56; s >= 0; s -= 8) out.push_back((uint8_t)(u >> s));
    }

    static void wr_f64(std::vector<uint8_t>& out, uint32_t id, double dv) {
        wr_id(out, id);
        wr_size(out, 8);
        uint64_t u = 0; std::memcpy(&u, &dv, 8);
        for (int s = 56; s >= 0; s -= 8) out.push_back((uint8_t)(u >> s));
    }

    static void wr_str(std::vector<uint8_t>& out, uint32_t id, const std::string& s) {
        wr_id(out, id);
        wr_size(out, s.size());
        out.insert(out.end(), s.begin(), s.end());
    }

    static void wr_bytes(std::vector<uint8_t>& out, uint32_t id, const std::vector<uint8_t>& b) {
        wr_id(out, id);
        wr_size(out, b.size());
        out.insert(out.end(), b.begin(), b.end());
    }

    static void wr_master(std::vector<uint8_t>& out, uint32_t id, const std::function<void(std::vector<uint8_t>&)>& fn) {
        std::vector<uint8_t> body;
        fn(body);
        wr_id(out, id);
        wr_size(out, body.size());
        out.insert(out.end(), body.begin(), body.end());
    }

    static void parse_block_frames(
        FILE* f,
        int src_idx,
        uint64_t pay_pos,
        uint64_t pay_len,
        int64_t cluster_ts_ticks,
        uint64_t ts_scale,
        bool is_simple,
        bool group_has_ref,
        int64_t discard_ns,
        std::map<uint32_t, EBMLTrack>& by_num
    ) {
        if (pay_len < 4) return;
        uint8_t hdr[16]{};
        size_t rd_n = (size_t)std::min<uint64_t>(pay_len, sizeof(hdr));
        ::fseeko(f, (off_t)pay_pos, SEEK_SET);
        if (std::fread(hdr, 1, rd_n, f) != rd_n) return;
        uint64_t tnum = 0;
        size_t vlen = rd_buf_vint(hdr, rd_n, tnum, true);
        if (vlen == 0 || vlen + 3 > pay_len) return;
        auto it = by_num.find((uint32_t)tnum);
        if (it == by_num.end()) return;
        EBMLTrack& tr = it->second;

        int16_t rel_ts = (int16_t)(((uint16_t)hdr[vlen] << 8) | hdr[vlen + 1]);
        uint8_t flags = hdr[vlen + 2];
        bool kf = is_simple ? ((flags & 0x80u) != 0) : (!group_has_ref || tr.track_type == 2);
        int lacing = (flags >> 1) & 0x03;
        int64_t pts_ns = (cluster_ts_ticks + (int64_t)rel_ts) * (int64_t)ts_scale;
        uint64_t data_off = pay_pos + vlen + 3;
        uint64_t data_len = pay_len - (vlen + 3);

        if (lacing == 0) {
            tr.packets.push_back({src_idx, data_off, (uint32_t)data_len, pts_ns, discard_ns, kf, {}});
            return;
        }
        // Unlace Xiph (1), Fixed (2), or EBML (3) laced frames.
        std::vector<uint8_t> buf((size_t)data_len);
        ::fseeko(f, (off_t)data_off, SEEK_SET);
        if (data_len > 0 && std::fread(buf.data(), 1, (size_t)data_len, f) != (size_t)data_len) return;
        if (buf.empty()) return;
        size_t nframes = (size_t)buf[0] + 1;
        size_t pos = 1;
        std::vector<size_t> fsizes;
        if (lacing == 2) {
            size_t each = (buf.size() - 1) / nframes;
            fsizes.assign(nframes, each);
        } else if (lacing == 1) {
            size_t sum = 0;
            for (size_t i = 0; i + 1 < nframes; ++i) {
                size_t sz = 0;
                while (pos < buf.size()) {
                    uint8_t b = buf[pos++];
                    sz += b;
                    if (b < 255) break;
                }
                fsizes.push_back(sz);
                sum += sz;
            }
            fsizes.push_back(pos + sum <= buf.size() ? (buf.size() - pos - sum) : 0);
        } else {
            size_t sum = 0;
            int64_t prev = 0;
            for (size_t i = 0; i + 1 < nframes; ++i) {
                uint64_t uv = 0;
                size_t l = rd_buf_vint(buf.data() + pos, buf.size() - pos, uv, true);
                if (l == 0) return;
                pos += l;
                int64_t sz = (i == 0) ? (int64_t)uv : (prev + ((int64_t)uv - ((1LL << (l * 7 - 1)) - 1LL)));
                if (sz < 0) return;
                prev = sz;
                fsizes.push_back((size_t)sz);
                sum += (size_t)sz;
            }
            fsizes.push_back(pos + sum <= buf.size() ? (buf.size() - pos - sum) : 0);
        }
        for (size_t i = 0; i < fsizes.size() && pos + fsizes[i] <= buf.size(); ++i) {
            tr.packets.push_back({
                src_idx,
                data_off + pos,
                (uint32_t)fsizes[i],
                pts_ns,
                (i + 1 == fsizes.size()) ? discard_ns : 0,
                kf,
                {}
            });
            pos += fsizes[i];
        }
    }

public:
    static bool is_ebml_file(const fs::path& p) {
        FILE* f = std::fopen(p.c_str(), "rb");
        if (!f) return false;
        uint8_t b[4]{};
        size_t n = std::fread(b, 1, 4, f);
        std::fclose(f);
        return n == 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3;
    }

    static std::vector<EBMLTrack> read_tracks(const fs::path& file_path, int src_idx = 0) {
        FILE* f = std::fopen(file_path.c_str(), "rb");
        if (!f) throw std::runtime_error("Cannot open " + file_path.string());
        ::fseeko(f, 0, SEEK_END);
        uint64_t fsize = (uint64_t)::ftello(f);
        ::fseeko(f, 0, SEEK_SET);

        uint64_t ts_scale = 1000000ULL;
        std::map<uint32_t, EBMLTrack> by_num;
        std::vector<uint32_t> order;

        uint32_t id = 0; uint64_t hpos = 0, esz = 0; bool unk = false;
        uint64_t seg_start = 0, seg_end = fsize;
        while (rd_vint_id(f, fsize, id, hpos) && rd_vint_size(f, fsize, esz, unk)) {
            uint64_t pay = (uint64_t)::ftello(f);
            uint64_t end = unk ? fsize : std::min(fsize, pay + esz);
            if (id == 0x18538067u) { seg_start = pay; seg_end = end; break; }
            ::fseeko(f, (off_t)end, SEEK_SET);
        }
        if (seg_start == 0) { std::fclose(f); throw std::runtime_error("Invalid WebM/MKV segment in " + file_path.filename().string()); }

        ::fseeko(f, (off_t)seg_start, SEEK_SET);
        while (rd_vint_id(f, seg_end, id, hpos) && rd_vint_size(f, seg_end, esz, unk)) {
            uint64_t pay = (uint64_t)::ftello(f);
            uint64_t end = unk ? seg_end : std::min(seg_end, pay + esz);
            if (id == 0x1549A966u && end - pay <= (1u << 20)) {
                // Info
                while ((uint64_t)::ftello(f) < end) {
                    uint32_t cid = 0; uint64_t chp = 0, csz = 0; bool cu = false;
                    if (!rd_vint_id(f, end, cid, chp) || !rd_vint_size(f, end, csz, cu)) break;
                    uint64_t cp = (uint64_t)::ftello(f);
                    uint64_t ce = cu ? end : std::min(end, cp + csz);
                    if (cid == 0x2AD7B1u && ce - cp <= 8) {
                        uint8_t b[8]{}; size_t n = (size_t)(ce - cp);
                        if (std::fread(b, 1, n, f) == n) ts_scale = std::max<uint64_t>(1, rd_uint_mem(b, n));
                    }
                    ::fseeko(f, (off_t)ce, SEEK_SET);
                }
            } else if (id == 0x1654AE6Bu && end - pay <= (4u << 20)) {
                // Tracks
                while ((uint64_t)::ftello(f) < end) {
                    uint32_t tid = 0; uint64_t thp = 0, tsz = 0; bool tu = false;
                    if (!rd_vint_id(f, end, tid, thp) || !rd_vint_size(f, end, tsz, tu)) break;
                    uint64_t tp = (uint64_t)::ftello(f);
                    uint64_t te = tu ? end : std::min(end, tp + tsz);
                    if (tid == 0xAEu) {
                        EBMLTrack tr;
                        while ((uint64_t)::ftello(f) < te) {
                            uint32_t fid = 0; uint64_t fhp = 0, fsz = 0; bool fu = false;
                            if (!rd_vint_id(f, te, fid, fhp) || !rd_vint_size(f, te, fsz, fu)) break;
                            uint64_t fp = (uint64_t)::ftello(f);
                            uint64_t fe = fu ? te : std::min(te, fp + fsz);
                            size_t fn = (size_t)(fe - fp);
                            if (fid == 0xD7u && fn <= 8) {
                                uint8_t b[8]{}; if (std::fread(b, 1, fn, f) == fn) tr.track_num = (uint32_t)rd_uint_mem(b, fn);
                            } else if (fid == 0x83u && fn <= 8) {
                                uint8_t b[8]{}; if (std::fread(b, 1, fn, f) == fn) tr.track_type = (uint8_t)rd_uint_mem(b, fn);
                            } else if (fid == 0x86u && fn <= 256) {
                                tr.codec_id.resize(fn);
                                if (fn > 0 && std::fread(tr.codec_id.data(), 1, fn, f) == fn) {
                                    while (!tr.codec_id.empty() && tr.codec_id.back() == '\0') tr.codec_id.pop_back();
                                }
                            } else if (fid == 0x56AAu && fn <= 8) {
                                uint8_t b[8]{}; if (std::fread(b, 1, fn, f) == fn) tr.codec_delay_ns = rd_uint_mem(b, fn);
                            } else if (fid == 0x56BBu && fn <= 8) {
                                uint8_t b[8]{}; if (std::fread(b, 1, fn, f) == fn) tr.seek_preroll_ns = rd_uint_mem(b, fn);
                            } else if (fid == 0x63A2u && fn <= (1u << 20)) {
                                tr.codec_private.resize(fn);
                                if (fn > 0) (void)std::fread(tr.codec_private.data(), 1, fn, f);
                            } else if (fid == 0xE0u) {
                                while ((uint64_t)::ftello(f) < fe) {
                                    uint32_t vid = 0; uint64_t vhp = 0, vsz = 0; bool vu = false;
                                    if (!rd_vint_id(f, fe, vid, vhp) || !rd_vint_size(f, fe, vsz, vu)) break;
                                    uint64_t vp = (uint64_t)::ftello(f);
                                    uint64_t ve = vu ? fe : std::min(fe, vp + vsz);
                                    size_t vn = (size_t)(ve - vp);
                                    if (vid == 0xB0u && vn <= 8) { uint8_t b[8]{}; if (std::fread(b, 1, vn, f) == vn) tr.width = (uint32_t)rd_uint_mem(b, vn); }
                                    else if (vid == 0xBAu && vn <= 8) { uint8_t b[8]{}; if (std::fread(b, 1, vn, f) == vn) tr.height = (uint32_t)rd_uint_mem(b, vn); }
                                    else if (vid == 0x55B0u && !vu && ve - vhp <= 4096) {
                                        tr.colour_raw.resize((size_t)(ve - vhp));
                                        ::fseeko(f, (off_t)vhp, SEEK_SET);
                                        (void)std::fread(tr.colour_raw.data(), 1, tr.colour_raw.size(), f);
                                    }
                                    ::fseeko(f, (off_t)ve, SEEK_SET);
                                }
                            } else if (fid == 0xE1u) {
                                while ((uint64_t)::ftello(f) < fe) {
                                    uint32_t aid = 0; uint64_t ahp = 0, asz = 0; bool au = false;
                                    if (!rd_vint_id(f, fe, aid, ahp) || !rd_vint_size(f, fe, asz, au)) break;
                                    uint64_t ap = (uint64_t)::ftello(f);
                                    uint64_t ae = au ? fe : std::min(fe, ap + asz);
                                    size_t an = (size_t)(ae - ap);
                                    if (aid == 0xB5u && (an == 4 || an == 8)) { uint8_t b[8]{}; if (std::fread(b, 1, an, f) == an) tr.sample_rate = rd_float_mem(b, an); }
                                    else if (aid == 0x9Fu && an <= 8) { uint8_t b[8]{}; if (std::fread(b, 1, an, f) == an) tr.channels = (uint32_t)rd_uint_mem(b, an); }
                                    else if (aid == 0x6264u && an <= 8) { uint8_t b[8]{}; if (std::fread(b, 1, an, f) == an) tr.bit_depth = (uint32_t)rd_uint_mem(b, an); }
                                    ::fseeko(f, (off_t)ae, SEEK_SET);
                                }
                            }
                            ::fseeko(f, (off_t)fe, SEEK_SET);
                        }
                        if ((tr.track_type == 1 || tr.track_type == 2) && !tr.codec_id.empty()) {
                            by_num[tr.track_num] = std::move(tr);
                            order.push_back(by_num.rbegin()->first);
                        }
                    }
                    ::fseeko(f, (off_t)te, SEEK_SET);
                }
                order.clear();
                for (const auto& [tn, _] : by_num) order.push_back(tn);
            } else if (id == 0x1F43B675u) {
                // Cluster
                int64_t cluster_ts = 0;
                while ((uint64_t)::ftello(f) < end) {
                    uint32_t cid = 0; uint64_t chp = 0, csz = 0; bool cu = false;
                    if (!rd_vint_id(f, end, cid, chp) || !rd_vint_size(f, end, csz, cu)) break;
                    // In an unknown-size Cluster, a top-level Segment element starts the next section.
                    if (unk && (cid == 0x1F43B675u || cid == 0x1C53BB6Bu || cid == 0x1254C367u)) {
                        end = chp;
                        break;
                    }
                    uint64_t cp = (uint64_t)::ftello(f);
                    uint64_t ce = cu ? end : std::min(end, cp + csz);
                    if (cid == 0xE7u && ce - cp <= 8) {
                        uint8_t b[8]{}; size_t n = (size_t)(ce - cp);
                        if (std::fread(b, 1, n, f) == n) cluster_ts = (int64_t)rd_uint_mem(b, n);
                    } else if (cid == 0xA3u) {
                        parse_block_frames(f, src_idx, cp, ce - cp, cluster_ts, ts_scale, true, false, 0, by_num);
                    } else if (cid == 0xA0u) {
                        uint64_t blk_p = 0, blk_l = 0;
                        bool has_ref = false;
                        int64_t discard_ns = 0;
                        while ((uint64_t)::ftello(f) < ce) {
                            uint32_t bid = 0; uint64_t bhp = 0, bsz = 0; bool bu = false;
                            if (!rd_vint_id(f, ce, bid, bhp) || !rd_vint_size(f, ce, bsz, bu)) break;
                            uint64_t bp = (uint64_t)::ftello(f);
                            uint64_t be = bu ? ce : std::min(ce, bp + bsz);
                            if (bid == 0xA1u) { blk_p = bp; blk_l = be - bp; }
                            else if (bid == 0xFBu) has_ref = true;
                            else if (bid == 0x75A2u && be - bp <= 8) {
                                uint8_t b[8]{}; size_t n = (size_t)(be - bp);
                                if (std::fread(b, 1, n, f) == n) discard_ns = rd_sint_mem(b, n);
                            }
                            ::fseeko(f, (off_t)be, SEEK_SET);
                        }
                        if (blk_l > 0) parse_block_frames(f, src_idx, blk_p, blk_l, cluster_ts, ts_scale, false, has_ref, discard_ns, by_num);
                    }
                    ::fseeko(f, (off_t)ce, SEEK_SET);
                }
            }
            ::fseeko(f, (off_t)end, SEEK_SET);
        }
        std::fclose(f);

        std::vector<EBMLTrack> out;
        for (uint32_t tn : order) if (!by_num[tn].packets.empty()) out.push_back(std::move(by_num[tn]));
        return out;
    }

    static std::vector<EBMLTrack> from_mp4_tracks(const std::vector<MP4Track>& mp4_tracks) {
        std::vector<EBMLTrack> out;
        for (const auto& mt : mp4_tracks) {
            if (mt.kind != "vide" && mt.kind != "soun") continue;
            if (mt.stsd_payload.size() < 16) continue;
            const uint8_t* sd = mt.stsd_payload.data();
            auto entries = list_boxes(sd, 8, mt.stsd_payload.size());
            if (entries.empty()) continue;
            const BoxRef& se = entries[0];

            EBMLTrack et;
            et.track_type = (mt.kind == "vide") ? 1 : 2;
            if (mt.kind == "vide") {
                if (se.type == "avc1" || se.type == "avc3") et.codec_id = "V_MPEG4/ISO/AVC";
                else if (se.type == "hvc1" || se.type == "hev1") et.codec_id = "V_MPEGH/ISO/HEVC";
                else if (se.type == "av01") et.codec_id = "V_AV1";
                else if (se.type == "vp09") et.codec_id = "V_VP9";
                else if (se.type == "vp08") et.codec_id = "V_VP8";
                else continue;
                et.width = mt.width;
                et.height = mt.height;
                if (se.pay_off + 78 <= se.end_off) {
                    if (et.width == 0) et.width = ((uint32_t)sd[se.pay_off + 24] << 8) | sd[se.pay_off + 25];
                    if (et.height == 0) et.height = ((uint32_t)sd[se.pay_off + 26] << 8) | sd[se.pay_off + 27];
                    for (const auto& cb : list_boxes(sd, se.pay_off + 78, se.end_off)) {
                        if (cb.type == "avcC" || cb.type == "hvcC" || cb.type == "av1C" || cb.type == "vpcC") {
                            et.codec_private.assign(sd + cb.pay_off, sd + cb.end_off);
                            break;
                        }
                    }
                }
            } else {
                et.sample_rate = mt.timescale > 0 ? (double)mt.timescale : 48000.0;
                if (se.pay_off + 28 <= se.end_off) {
                    et.channels = std::max<uint32_t>(1, ((uint32_t)sd[se.pay_off + 16] << 8) | sd[se.pay_off + 17]);
                    uint32_t sr16 = rd_u32(sd + se.pay_off + 24) >> 16;
                    if (sr16 > 0) et.sample_rate = (double)sr16;
                }
                if (se.type == "mp4a" && se.pay_off + 28 <= se.end_off) {
                    et.codec_id = "A_AAC";
                    for (const auto& cb : list_boxes(sd, se.pay_off + 28, se.end_off)) {
                        if (cb.type == "esds" && cb.pay_off + 4 < cb.end_off) {
                            size_t p = cb.pay_off + 4;
                            while (p + 2 <= cb.end_off) {
                                uint8_t tag = sd[p++];
                                uint32_t dlen = 0;
                                for (int k = 0; k < 4 && p < cb.end_off; ++k) {
                                    uint8_t b = sd[p++];
                                    dlen = (dlen << 7) | (b & 0x7fu);
                                    if ((b & 0x80u) == 0) break;
                                }
                                if (tag == 0x03 && p + 3 <= cb.end_off) {
                                    uint8_t fl = sd[p + 2];
                                    p += 3 + ((fl & 0x80) ? 2 : 0) + ((fl & 0x40) ? (1 + sd[p + 3]) : 0) + ((fl & 0x20) ? 2 : 0);
                                } else if (tag == 0x04 && p + 13 <= cb.end_off) {
                                    p += 13;
                                } else if (tag == 0x05 && p + dlen <= cb.end_off) {
                                    et.codec_private.assign(sd + p, sd + p + dlen);
                                    break;
                                } else {
                                    p += dlen;
                                }
                            }
                        }
                    }
                } else if (se.type == "Opus" && se.pay_off + 28 <= se.end_off) {
                    et.codec_id = "A_OPUS";
                    et.sample_rate = 48000.0;
                    et.seek_preroll_ns = 80000000ULL;
                    for (const auto& cb : list_boxes(sd, se.pay_off + 28, se.end_off)) {
                        if (cb.type == "dOps" && cb.pay_off + 11 <= cb.end_off) {
                            const uint8_t* dp = sd + cb.pay_off;
                            uint8_t ch = dp[1];
                            uint16_t pre = ((uint16_t)dp[2] << 8) | dp[3];
                            uint32_t srate = rd_u32(dp + 4);
                            uint16_t gain = ((uint16_t)dp[8] << 8) | dp[9];
                            uint8_t mapf = dp[10];
                            et.channels = std::max<uint32_t>(1, ch);
                            et.codec_delay_ns = (uint64_t)pre * 1000000000ULL / 48000ULL;
                            std::vector<uint8_t> oh = {'O','p','u','s','H','e','a','d', 1, ch,
                                (uint8_t)(pre & 0xff), (uint8_t)(pre >> 8),
                                (uint8_t)(srate & 0xff), (uint8_t)((srate >> 8) & 0xff), (uint8_t)((srate >> 16) & 0xff), (uint8_t)(srate >> 24),
                                (uint8_t)(gain & 0xff), (uint8_t)(gain >> 8), mapf};
                            if (cb.pay_off + 11 < cb.end_off) oh.insert(oh.end(), sd + cb.pay_off + 11, sd + cb.end_off);
                            et.codec_private = std::move(oh);
                        }
                    }
                } else continue;
            }

            uint32_t ts = std::max<uint32_t>(1, mt.timescale);
            int64_t ticks = 0;
            et.packets.reserve(mt.samples.size());
            for (const auto& s : mt.samples) {
                int64_t pts_ticks = ticks + (int64_t)s.cts_offset;
                int64_t pts_ns = (pts_ticks * 1000000000LL) / (int64_t)ts;
                et.packets.push_back({s.src_idx, s.offset, s.size, std::max<int64_t>(0, pts_ns), 0, s.is_sync, s.inline_data});
                ticks += s.duration;
            }
            if (!et.packets.empty()) out.push_back(std::move(et));
        }
        return out;
    }

    static void trim_tracks(std::vector<EBMLTrack>& tracks, const SectionRange& sec, double base_sec = 0.0) {
        if (!sec.active()) return;
        int64_t s_ns = (int64_t)(std::max(0.0, (sec.start >= 0 ? sec.start : 0.0) - base_sec) * 1e9);
        int64_t e_ns = (sec.end >= 0) ? (int64_t)(std::max(0.0, sec.end - base_sec) * 1e9) : -1;
        int64_t eff_ns = s_ns;
        for (const auto& t : tracks) {
            if (t.track_type == 1) {
                int64_t last_kf = 0;
                for (const auto& p : t.packets) {
                    if (p.pts_ns > s_ns) break;
                    if (p.keyframe) last_kf = p.pts_ns;
                }
                eff_ns = last_kf;
                break;
            }
        }
        for (auto& t : tracks) {
            std::vector<EBMLPacket> kept;
            for (auto& p : t.packets) {
                if (p.pts_ns < eff_ns) continue;
                if (e_ns >= 0 && p.pts_ns > e_ns) break;
                p.pts_ns -= eff_ns;
                kept.push_back(std::move(p));
            }
            t.packets.swap(kept);
        }
    }

    static void remove_intervals(std::vector<EBMLTrack>& tracks, const std::vector<std::pair<double, double>>& cuts) {
        if (cuts.empty()) return;
        for (auto& t : tracks) {
            std::vector<EBMLPacket> kept;
            for (auto& p : t.packets) {
                double s = (double)p.pts_ns / 1e9;
                bool drop = false;
                double shift = 0.0;
                for (const auto& [c0, c1] : cuts) {
                    if (s >= c0 && s < c1) { drop = true; break; }
                    if (s >= c1) shift += (c1 - c0);
                }
                if (!drop) {
                    p.pts_ns = std::max<int64_t>(0, p.pts_ns - (int64_t)(shift * 1e9));
                    kept.push_back(std::move(p));
                }
            }
            t.packets.swap(kept);
        }
    }

    static void write_ebml(
        std::vector<EBMLTrack> tracks,
        const std::vector<fs::path>& source_files,
        const fs::path& dest,
        bool is_webm,
        const std::string& title = ""
    ) {
        if (tracks.empty()) throw std::runtime_error("No WebM/MKV tracks to mux");
        uint32_t video_tnum = 0;
        int64_t max_pts_ns = 0;
        for (size_t i = 0; i < tracks.size(); ++i) {
            tracks[i].track_num = (uint32_t)(i + 1);
            if (tracks[i].track_type == 1 && video_tnum == 0) video_tnum = tracks[i].track_num;
            for (const auto& p : tracks[i].packets) if (p.pts_ns > max_pts_ns) max_pts_ns = p.pts_ns;
        }
        double dur_ms = std::max(1.0, (double)max_pts_ns / 1e6 + 20.0);

        std::vector<FILE*> ins(source_files.size(), nullptr);
        struct InGuard {
            std::vector<FILE*>& v;
            ~InGuard() { for (FILE* f : v) if (f) std::fclose(f); }
        } in_guard{ins};
        for (size_t i = 0; i < source_files.size(); ++i) {
            ins[i] = std::fopen(source_files[i].c_str(), "rb");
            if (!ins[i]) throw std::runtime_error("Cannot open source " + source_files[i].string());
        }

        fs::path part = dest.string() + ".part";
        FILE* out = std::fopen(part.c_str(), "wb");
        if (!out) throw std::runtime_error("Cannot write " + part.string());

        // 1. EBML header + Segment 8-byte size placeholder + 128-byte SeekHead/Void slot.
        std::vector<uint8_t> ebml_hdr;
        wr_master(ebml_hdr, 0x1A45DFA3u, [&](std::vector<uint8_t>& h) {
            wr_uint(h, 0x4286u, 1);
            wr_uint(h, 0x42F7u, 1);
            wr_uint(h, 0x42F2u, 4);
            wr_uint(h, 0x42F3u, 8);
            wr_str(h, 0x4282u, is_webm ? "webm" : "matroska");
            wr_uint(h, 0x4287u, 4);
            wr_uint(h, 0x4285u, 2);
        });
        std::fwrite(ebml_hdr.data(), 1, ebml_hdr.size(), out);

        uint64_t seg_size_file_off = (uint64_t)::ftello(out) + 4;
        uint8_t seg_open[12] = {0x18, 0x53, 0x80, 0x67, 0x01, 0, 0, 0, 0, 0, 0, 0};
        std::fwrite(seg_open, 1, 12, out);
        uint64_t seg_data_off = (uint64_t)::ftello(out);

        constexpr size_t SEEK_SLOT_LEN = 128;
        std::vector<uint8_t> blank_slot(SEEK_SLOT_LEN, 0);
        blank_slot[0] = 0xEC; // EBML Void placeholder until patched
        blank_slot[1] = (uint8_t)(0x80u | (SEEK_SLOT_LEN - 2));
        std::fwrite(blank_slot.data(), 1, SEEK_SLOT_LEN, out);

        // 2. Info + Tracks
        uint64_t info_rel = (uint64_t)::ftello(out) - seg_data_off;
        std::vector<uint8_t> info_buf;
        wr_master(info_buf, 0x1549A966u, [&](std::vector<uint8_t>& ib) {
            wr_uint(ib, 0x2AD7B1u, 1000000ULL);
            wr_str(ib, 0x4D80u, "uBit");
            wr_str(ib, 0x5741u, "uBit");
            wr_f64(ib, 0x4489u, dur_ms);
            if (!is_webm && !title.empty()) wr_str(ib, 0x7BA9u, title);
        });
        std::fwrite(info_buf.data(), 1, info_buf.size(), out);

        uint64_t tracks_rel = (uint64_t)::ftello(out) - seg_data_off;
        std::vector<uint8_t> tracks_buf;
        wr_master(tracks_buf, 0x1654AE6Bu, [&](std::vector<uint8_t>& tb) {
            for (const auto& t : tracks) {
                wr_master(tb, 0xAEu, [&](std::vector<uint8_t>& te) {
                    wr_uint(te, 0xD7u, t.track_num);
                    wr_uint(te, 0x73C5u, t.track_num);
                    wr_uint(te, 0x83u, t.track_type);
                    wr_uint(te, 0x9Cu, 0);
                    wr_str(te, 0x86u, t.codec_id);
                    if (t.codec_delay_ns > 0) wr_uint(te, 0x56AAu, t.codec_delay_ns);
                    if (t.seek_preroll_ns > 0) wr_uint(te, 0x56BBu, t.seek_preroll_ns);
                    if (!t.codec_private.empty()) wr_bytes(te, 0x63A2u, t.codec_private);
                    if (t.track_type == 1) {
                        wr_master(te, 0xE0u, [&](std::vector<uint8_t>& vb) {
                            wr_uint(vb, 0xB0u, std::max<uint32_t>(1, t.width));
                            wr_uint(vb, 0xBAu, std::max<uint32_t>(1, t.height));
                            if (!t.colour_raw.empty()) vb.insert(vb.end(), t.colour_raw.begin(), t.colour_raw.end());
                        });
                    } else {
                        wr_master(te, 0xE1u, [&](std::vector<uint8_t>& ab) {
                            wr_f64(ab, 0xB5u, t.sample_rate > 0 ? t.sample_rate : 48000.0);
                            wr_uint(ab, 0x9Fu, std::max<uint32_t>(1, t.channels));
                            if (t.bit_depth > 0) wr_uint(ab, 0x6264u, t.bit_depth);
                        });
                    }
                });
            }
        });
        std::fwrite(tracks_buf.data(), 1, tracks_buf.size(), out);

        // 3. Interleave packets across tracks by millisecond timestamp (video keyframes first on ties).
        struct Ref { uint32_t t_idx; uint32_t p_idx; int64_t ms; bool v_kf; };
        size_t total_pkts = 0;
        for (const auto& t : tracks) total_pkts += t.packets.size();
        std::vector<Ref> sched;
        sched.reserve(total_pkts);
        for (size_t ti = 0; ti < tracks.size(); ++ti) {
            bool is_v = (tracks[ti].track_type == 1);
            for (size_t pi = 0; pi < tracks[ti].packets.size(); ++pi) {
                int64_t ms = (tracks[ti].packets[pi].pts_ns + 500000LL) / 1000000LL;
                sched.push_back({(uint32_t)ti, (uint32_t)pi, std::max<int64_t>(0, ms), is_v && tracks[ti].packets[pi].keyframe});
            }
        }
        std::stable_sort(sched.begin(), sched.end(), [](const Ref& a, const Ref& b) {
            if (a.ms != b.ms) return a.ms < b.ms;
            if (a.v_kf != b.v_kf) return a.v_kf;
            return a.t_idx < b.t_idx;
        });

        struct CueRec { uint64_t time_ms; uint32_t track_num; uint64_t cluster_rel; };
        std::vector<CueRec> cues;
        std::vector<uint8_t> copy_buf(65536);

        size_t idx = 0;
        while (idx < sched.size()) {
            int64_t cluster_ms = sched[idx].ms;
            size_t end_idx = idx + 1;
            while (end_idx < sched.size()) {
                int64_t rel = sched[end_idx].ms - cluster_ms;
                if (rel > 30000) break;
                if (video_tnum != 0) {
                    if (sched[end_idx].v_kf && rel >= 500) break;
                } else if (rel >= 4000) {
                    break;
                }
                ++end_idx;
            }

            // Exact pre-computed Cluster byte size -> single-pass streaming write with 0 RAM buffering of frames!
            std::vector<uint8_t> ts_el;
            wr_uint(ts_el, 0xE7u, (uint64_t)cluster_ms);
            uint64_t cluster_payload_sz = ts_el.size();

            for (size_t k = idx; k < end_idx; ++k) {
                const auto& tr = tracks[sched[k].t_idx];
                const auto& pk = tr.packets[sched[k].p_idx];
                uint32_t pay_sz = pk.inline_data.empty() ? pk.size : (uint32_t)pk.inline_data.size();
                uint64_t blk_sz = 4ULL + pay_sz;
                if (pk.discard_padding_ns == 0) {
                    std::vector<uint8_t> tmp_h;
                    wr_id(tmp_h, 0xA3u);
                    wr_size(tmp_h, blk_sz);
                    cluster_payload_sz += tmp_h.size() + blk_sz;
                } else {
                    std::vector<uint8_t> sub_h, dp_el, ref_el, grp_h;
                    wr_id(sub_h, 0xA1u); wr_size(sub_h, blk_sz);
                    wr_sint(dp_el, 0x75A2u, pk.discard_padding_ns);
                    if (!pk.keyframe) wr_uint(ref_el, 0xFBu, 0);
                    uint64_t grp_sz = sub_h.size() + blk_sz + dp_el.size() + ref_el.size();
                    wr_id(grp_h, 0xA0u); wr_size(grp_h, grp_sz);
                    cluster_payload_sz += grp_h.size() + grp_sz;
                }
            }

            uint64_t cluster_rel = (uint64_t)::ftello(out) - seg_data_off;
            uint32_t cue_track = (video_tnum != 0) ? video_tnum : tracks[0].track_num;
            cues.push_back({(uint64_t)cluster_ms, cue_track, cluster_rel});

            std::vector<uint8_t> cl_hdr;
            wr_id(cl_hdr, 0x1F43B675u);
            wr_size(cl_hdr, cluster_payload_sz);
            cl_hdr.insert(cl_hdr.end(), ts_el.begin(), ts_el.end());
            std::fwrite(cl_hdr.data(), 1, cl_hdr.size(), out);

            auto stream_pkt = [&](const EBMLPacket& pk) {
                if (!pk.inline_data.empty()) {
                    std::fwrite(pk.inline_data.data(), 1, pk.inline_data.size(), out);
                    return;
                }
                FILE* sf = ins[(size_t)pk.src_idx];
                ::fseeko(sf, (off_t)pk.offset, SEEK_SET);
                uint32_t rem = pk.size;
                while (rem > 0) {
                    size_t chunk = std::min<size_t>(rem, copy_buf.size());
                    size_t got = std::fread(copy_buf.data(), 1, chunk, sf);
                    if (got == 0) throw std::runtime_error("Unexpected EOF reading WebM/MKV packet");
                    std::fwrite(copy_buf.data(), 1, got, out);
                    rem -= (uint32_t)got;
                }
            };

            for (size_t k = idx; k < end_idx; ++k) {
                const auto& tr = tracks[sched[k].t_idx];
                const auto& pk = tr.packets[sched[k].p_idx];
                uint32_t pay_sz = pk.inline_data.empty() ? pk.size : (uint32_t)pk.inline_data.size();
                int16_t rel_ms = (int16_t)std::max<int64_t>(-32768, std::min<int64_t>(32767, sched[k].ms - cluster_ms));
                uint8_t b4[4] = {
                    (uint8_t)(0x80u | (tr.track_num & 0x7fu)),
                    (uint8_t)((uint16_t)rel_ms >> 8),
                    (uint8_t)((uint16_t)rel_ms & 0xffu),
                    (uint8_t)((pk.discard_padding_ns == 0 && pk.keyframe) ? 0x80u : 0x00u)
                };
                uint64_t blk_sz = 4ULL + pay_sz;
                if (pk.discard_padding_ns == 0) {
                    std::vector<uint8_t> bh;
                    wr_id(bh, 0xA3u); wr_size(bh, blk_sz);
                    bh.insert(bh.end(), b4, b4 + 4);
                    std::fwrite(bh.data(), 1, bh.size(), out);
                    stream_pkt(pk);
                } else {
                    std::vector<uint8_t> sub_h, dp_el, ref_el, grp_h;
                    wr_id(sub_h, 0xA1u); wr_size(sub_h, blk_sz);
                    wr_sint(dp_el, 0x75A2u, pk.discard_padding_ns);
                    if (!pk.keyframe) wr_uint(ref_el, 0xFBu, 0);
                    uint64_t grp_sz = sub_h.size() + blk_sz + dp_el.size() + ref_el.size();
                    wr_id(grp_h, 0xA0u); wr_size(grp_h, grp_sz);
                    grp_h.insert(grp_h.end(), sub_h.begin(), sub_h.end());
                    grp_h.insert(grp_h.end(), b4, b4 + 4);
                    std::fwrite(grp_h.data(), 1, grp_h.size(), out);
                    stream_pkt(pk);
                    std::fwrite(dp_el.data(), 1, dp_el.size(), out);
                    if (!ref_el.empty()) std::fwrite(ref_el.data(), 1, ref_el.size(), out);
                }
            }
            idx = end_idx;
        }

        // 4. Cues index
        uint64_t cues_rel = (uint64_t)::ftello(out) - seg_data_off;
        std::vector<uint8_t> cues_buf;
        wr_master(cues_buf, 0x1C53BB6Bu, [&](std::vector<uint8_t>& cb) {
            for (const auto& c : cues) {
                wr_master(cb, 0xBBu, [&](std::vector<uint8_t>& cp) {
                    wr_uint(cp, 0xB3u, c.time_ms);
                    wr_master(cp, 0xB7u, [&](std::vector<uint8_t>& tp) {
                        wr_uint(tp, 0xF7u, c.track_num);
                        wr_uint(tp, 0xF1u, c.cluster_rel);
                    });
                });
            }
        });
        std::fwrite(cues_buf.data(), 1, cues_buf.size(), out);

        uint64_t file_end = (uint64_t)::ftello(out);
        uint64_t seg_len = file_end - seg_data_off;

        // 5. Patch Segment 8-byte size and SeekHead + trailing Void inside the 128-byte slot.
        uint64_t seg_vint = 0x0100000000000000ULL | seg_len;
        uint8_t seg_sz8[8];
        for (int i = 0; i < 8; ++i) seg_sz8[i] = (uint8_t)(seg_vint >> ((7 - i) * 8));
        ::fseeko(out, (off_t)seg_size_file_off, SEEK_SET);
        std::fwrite(seg_sz8, 1, 8, out);

        std::vector<uint8_t> seek_head;
        auto add_seek = [&](std::vector<uint8_t>& sh, uint32_t target_id, uint64_t rel_pos) {
            wr_master(sh, 0x4DBBu, [&](std::vector<uint8_t>& sk) {
                std::vector<uint8_t> idb; wr_id(idb, target_id);
                wr_bytes(sk, 0x53ABu, idb);
                wr_uint(sk, 0x53ACu, rel_pos);
            });
        };
        wr_master(seek_head, 0x114D9B74u, [&](std::vector<uint8_t>& sh) {
            add_seek(sh, 0x1549A966u, info_rel);
            add_seek(sh, 0x1654AE6Bu, tracks_rel);
            add_seek(sh, 0x1C53BB6Bu, cues_rel);
        });
        if (seek_head.size() + 2 <= SEEK_SLOT_LEN) {
            size_t rem = SEEK_SLOT_LEN - seek_head.size() - 2;
            seek_head.push_back(0xEC);
            seek_head.push_back((uint8_t)(0x80u | rem));
            seek_head.resize(SEEK_SLOT_LEN, 0);
            ::fseeko(out, (off_t)seg_data_off, SEEK_SET);
            std::fwrite(seek_head.data(), 1, SEEK_SLOT_LEN, out);
        }

        std::fflush(out);
        ::fsync(fileno(out));
        std::fclose(out);
        commit_file_verified(part, dest);
    }
};

// MARK: - Pure C++ 188-Byte MPEG-TS (H.264 Annex-B + ADTS AAC) -> MP4Track Demuxer

class TSDemuxer {
    struct AU { int64_t pts = 0, dts = 0; std::vector<uint8_t> es; };
public:
    static std::vector<MP4Track> demux(const fs::path& ts_path) {
        std::ifstream in(ts_path, std::ios::binary | std::ios::ate);
        if (!in) return {};
        size_t sz = (size_t)in.tellg();
        in.seekg(0);
        std::vector<uint8_t> d(sz);
        if (sz > 0) in.read((char*)d.data(), (std::streamsize)sz);

        size_t pos = 0;
        while (pos + 376 < sz && !(d[pos] == 0x47 && d[pos + 188] == 0x47)) ++pos;

        uint16_t pmt_pid = 0xffff, v_pid = 0xffff, a_pid = 0xffff;
        std::vector<uint8_t> v_pes, a_pes;
        std::vector<AU> v_units;
        std::vector<std::vector<uint8_t>> a_adts;

        auto parse_pes = [](const std::vector<uint8_t>& pes, int64_t& pts, int64_t& dts, size_t& es_off) -> bool {
            if (pes.size() < 9 || pes[0] != 0 || pes[1] != 0 || pes[2] != 1) return false;
            uint8_t f2 = pes[7];
            es_off = 9 + pes[8];
            if (es_off > pes.size()) return false;
            auto rpts = [&](size_t o) -> int64_t {
                return ((int64_t)((pes[o] >> 1) & 7) << 30) | ((int64_t)pes[o+1] << 22) |
                       ((int64_t)((pes[o+2] >> 1) & 0x7f) << 15) | ((int64_t)pes[o+3] << 7) | ((pes[o+4] >> 1) & 0x7f);
            };
            if ((f2 & 0x80) && pes.size() >= 14) {
                pts = rpts(9); dts = pts;
                if ((f2 & 0x40) && pes.size() >= 19) dts = rpts(14);
            }
            return true;
        };

        auto flush_v = [&]() {
            int64_t pts = 0, dts = 0; size_t eo = 0;
            if (!v_pes.empty() && parse_pes(v_pes, pts, dts, eo))
                v_units.push_back({pts, dts, std::vector<uint8_t>(v_pes.begin() + eo, v_pes.end())});
            v_pes.clear();
        };
        auto flush_a = [&]() {
            int64_t pts = 0, dts = 0; size_t eo = 0;
            if (!a_pes.empty() && parse_pes(a_pes, pts, dts, eo)) {
                size_t p = eo;
                while (p + 7 <= a_pes.size()) {
                    if (a_pes[p] == 0xff && (a_pes[p+1] & 0xf0) == 0xf0) {
                        size_t flen = ((size_t)(a_pes[p+3] & 3) << 11) | ((size_t)a_pes[p+4] << 3) | (a_pes[p+5] >> 5);
                        if (flen > 7 && p + flen <= a_pes.size()) {
                            a_adts.emplace_back(a_pes.begin() + p, a_pes.begin() + p + flen);
                            p += flen;
                            continue;
                        }
                    }
                    ++p;
                }
            }
            a_pes.clear();
        };

        for (; pos + 188 <= sz; pos += 188) {
            if (d[pos] != 0x47) continue;
            bool pusi = (d[pos+1] & 0x40) != 0;
            uint16_t pid = ((uint16_t)(d[pos+1] & 0x1f) << 8) | d[pos+2];
            uint8_t afc = (d[pos+3] >> 4) & 3;
            if (afc == 2) continue;
            size_t poff = pos + 4 + (afc == 3 ? 1 + d[pos+4] : 0);
            if (poff >= pos + 188) continue;

            if (pid == 0) {
                size_t p = poff + (pusi ? 1 + d[poff] : 0);
                if (p + 12 <= pos + 188) {
                    size_t slen = ((d[p+1] & 0x0f) << 8) | d[p+2];
                    size_t end = std::min(pos + 188, p + 3 + slen - 4);
                    for (size_t ep = p + 8; ep + 4 <= end; ep += 4) {
                        if (rd_u16(&d[ep]) != 0) { pmt_pid = rd_u16(&d[ep+2]) & 0x1fff; break; }
                    }
                }
            } else if (pid == pmt_pid) {
                size_t p = poff + (pusi ? 1 + d[poff] : 0);
                if (p + 12 <= pos + 188) {
                    size_t slen = ((d[p+1] & 0x0f) << 8) | d[p+2];
                    size_t pil = ((d[p+10] & 0x0f) << 8) | d[p+11];
                    size_t end = std::min(pos + 188, p + 3 + slen - 4);
                    for (size_t ep = p + 12 + pil; ep + 5 <= end;) {
                        uint8_t st = d[ep];
                        uint16_t epid = rd_u16(&d[ep+1]) & 0x1fff;
                        size_t esl = rd_u16(&d[ep+3]) & 0x0fff;
                        if (st == 0x1b && v_pid == 0xffff) v_pid = epid;
                        else if (st == 0x0f && a_pid == 0xffff) a_pid = epid;
                        ep += 5 + esl;
                    }
                }
            } else if (pid == v_pid) {
                if (pusi) flush_v();
                v_pes.insert(v_pes.end(), d.begin() + poff, d.begin() + pos + 188);
            } else if (pid == a_pid) {
                if (pusi) flush_a();
                a_pes.insert(a_pes.end(), d.begin() + poff, d.begin() + pos + 188);
            }
        }
        flush_v(); flush_a();

        std::vector<MP4Track> out;
        if (!v_units.empty()) {
            std::vector<uint8_t> sps, pps;
            MP4Track vt; vt.track_id = 1; vt.kind = "vide"; vt.timescale = 90000; vt.width = 1920; vt.height = 1080;
            for (size_t idx = 0; idx < v_units.size(); ++idx) {
                const auto& u = v_units[idx].es;
                BinBuf sample;
                bool idr = false, vcl = false;
                size_t i = 0, ns = std::string::npos;
                auto emit_nal = [&](size_t a, size_t b) {
                    if (b <= a) return;
                    uint8_t nt = u[a] & 0x1f;
                    if (nt == 7) { sps.assign(u.begin() + a, u.begin() + b); return; }
                    if (nt == 8) { pps.assign(u.begin() + a, u.begin() + b); return; }
                    if (nt == 9) return;
                    if (nt == 5) { idr = true; vcl = true; }
                    else if (nt >= 1 && nt <= 4) vcl = true;
                    sample.u32((uint32_t)(b - a));
                    sample.bytes(&u[a], b - a);
                };
                while (i + 3 <= u.size()) {
                    size_t scl = 0;
                    if (u[i] == 0 && u[i+1] == 0) {
                        if (u[i+2] == 1) scl = 3;
                        else if (i + 4 <= u.size() && u[i+2] == 0 && u[i+3] == 1) scl = 4;
                    }
                    if (scl) {
                        if (ns != std::string::npos) emit_nal(ns, i);
                        ns = i + scl; i += scl;
                    } else ++i;
                }
                if (ns != std::string::npos && ns < u.size()) emit_nal(ns, u.size());
                if (vcl && sample.size() > 0) {
                    int64_t next_dts = (idx + 1 < v_units.size()) ? v_units[idx+1].dts : (v_units[idx].dts + 3000);
                    uint32_t dur = (uint32_t)std::max<int64_t>(1, next_dts - v_units[idx].dts);
                    int32_t cts = (int32_t)(v_units[idx].pts - v_units[idx].dts);
                    vt.samples.push_back({0, 0, (uint32_t)sample.size(), dur, cts, idr, std::move(sample.d)});
                }
            }
            if (sps.size() >= 4 && !pps.empty() && !vt.samples.empty()) {
                BinBuf stsd; stsd.u8(0); stsd.u24(0); stsd.u32(1);
                stsd.box("avc1", [&](BinBuf& b) {
                    b.zeros(6); b.u16(1); b.zeros(16); b.u16(vt.width); b.u16(vt.height);
                    b.u32(0x00480000); b.u32(0x00480000); b.u32(0); b.u16(1); b.zeros(32); b.u16(0x0018); b.u16(0xffff);
                    b.box("avcC", [&](BinBuf& c) {
                        c.u8(1); c.u8(sps[1]); c.u8(sps[2]); c.u8(sps[3]); c.u8(0xff); c.u8(0xe1);
                        c.u16((uint16_t)sps.size()); c.bytes(sps);
                        c.u8(1); c.u16((uint16_t)pps.size()); c.bytes(pps);
                    });
                });
                vt.stsd_payload = std::move(stsd.d);
                out.push_back(std::move(vt));
            }
        }
        if (!a_adts.empty()) {
            static const uint32_t srates[] = {96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};
            const auto& f0 = a_adts[0];
            uint8_t prof = ((f0[2] >> 6) & 3) + 1;
            uint8_t sri = (f0[2] >> 2) & 0x0f;
            uint8_t ch = ((f0[2] & 1) << 2) | ((f0[3] >> 6) & 3);
            uint32_t sr = sri < 13 ? srates[sri] : 44100;
            MP4Track at; at.track_id = 2; at.kind = "soun"; at.timescale = sr;
            for (const auto& fr : a_adts) {
                size_t hl = (fr[1] & 1) ? 7 : 9;
                if (fr.size() > hl) {
                    std::vector<uint8_t> raw(fr.begin() + hl, fr.end());
                    at.samples.push_back({0, 0, (uint32_t)raw.size(), 1024, 0, true, std::move(raw)});
                }
            }
            uint8_t asc0 = (uint8_t)((prof << 3) | ((sri >> 1) & 7));
            uint8_t asc1 = (uint8_t)(((sri & 1) << 7) | (ch << 3));
            BinBuf stsd; stsd.u8(0); stsd.u24(0); stsd.u32(1);
            stsd.box("mp4a", [&](BinBuf& b) {
                b.zeros(6); b.u16(1); b.zeros(8); b.u16(ch ? ch : 2); b.u16(16); b.u32(0); b.u32(sr << 16);
                b.full_box("esds", 0, 0, [&](BinBuf& e) {
                    e.u8(3); e.u8(25); e.u16(1); e.u8(0);
                    e.u8(4); e.u8(17); e.u8(0x40); e.u8(0x15); e.u24(0); e.u32(128000); e.u32(128000);
                    e.u8(5); e.u8(2); e.u8(asc0); e.u8(asc1);
                    e.u8(6); e.u8(1); e.u8(2);
                });
            });
            at.stsd_payload = std::move(stsd.d);
            out.push_back(std::move(at));
        }
        return out;
    }
};

// MARK: - HLS Engine (Master & Media M3U8, #EXT-X-MAP, AES-128, Parallel Pool, Live Recorder)

class HLSEngine {
public:
    static std::map<std::string, std::string> parse_attrs(const std::string& raw) {
        std::map<std::string, std::string> m;
        size_t i = 0;
        while (i < raw.size()) {
            while (i < raw.size() && (raw[i] == ',' || std::isspace((unsigned char)raw[i]))) ++i;
            auto eq = raw.find('=', i);
            if (eq == std::string::npos) break;
            std::string k = raw.substr(i, eq - i);
            size_t v = eq + 1;
            if (v < raw.size() && raw[v] == '"') {
                ++v;
                auto q2 = raw.find('"', v);
                m[k] = (q2 == std::string::npos) ? raw.substr(v) : raw.substr(v, q2 - v);
                i = (q2 == std::string::npos) ? raw.size() : q2 + 1;
            } else {
                auto cm = raw.find(',', v);
                m[k] = (cm == std::string::npos) ? raw.substr(v) : raw.substr(v, cm - v);
                i = (cm == std::string::npos) ? raw.size() : cm + 1;
            }
        }
        return m;
    }

    static std::vector<MediaFormat> extract_formats(const HTTPClient& client, const std::string& pl_url, const std::map<std::string, std::string>& hdrs = {}, const std::string& pfx = "hls") {
        auto resp = client.fetch(pl_url, "GET", hdrs);
        if (resp.status < 200 || resp.status >= 300) return {};
        std::string txt = resp.text();
        ParsedURL base = ParsedURL::parse(resp.final_url.empty() ? pl_url : resp.final_url);

        if (txt.find("#EXT-X-STREAM-INF") == std::string::npos) {
            bool live = (txt.find("#EXT-X-ENDLIST") == std::string::npos) && (txt.find("#EXTINF:") != std::string::npos);
            std::string low_txt = txt;
            for (char& c : low_txt) c = (char)std::tolower((unsigned char)c);
            std::string ext = "mp4", vc = "avc1", ac = "mp4a";
            if (low_txt.find(".opus") != std::string::npos) { ext = "opus"; vc = "none"; ac = "opus"; }
            else if (low_txt.find(".ogg") != std::string::npos) { ext = "ogg"; vc = "none"; ac = "opus"; }
            else if (low_txt.find(".mp3") != std::string::npos) { ext = "mp3"; vc = "none"; ac = "mp3"; }
            else if (low_txt.find(".webm") != std::string::npos) { ext = "webm"; vc = "vp9"; ac = "opus"; }
            MediaFormat f; f.id = pfx; f.url = base.origin() + base.path_and_query; f.ext = ext; f.proto = "hls";
            f.vcodec = vc; f.acodec = ac; f.headers = hdrs; f.is_live = live;
            return {f};
        }

        std::map<std::string, std::string> audio_groups;
        std::vector<std::string> lines;
        std::istringstream ss(txt);
        std::string ln;
        while (std::getline(ss, ln)) {
            while (!ln.empty() && (ln.back() == '\r' || ln.back() == '\n' || ln.back() == ' ')) ln.pop_back();
            lines.push_back(ln);
        }
        for (const auto& l : lines) {
            if (l.rfind("#EXT-X-MEDIA:", 0) == 0) {
                auto a = parse_attrs(l.substr(13));
                if (a["TYPE"] == "AUDIO" && !a["GROUP-ID"].empty() && !a["URI"].empty()) {
                    if (audio_groups.find(a["GROUP-ID"]) == audio_groups.end() || a["DEFAULT"] == "YES")
                        audio_groups[a["GROUP-ID"]] = base.resolve(a["URI"]);
                }
            }
        }

        std::vector<MediaFormat> fmts;
        for (size_t i = 0; i < lines.size(); ++i) {
            if (lines[i].rfind("#EXT-X-STREAM-INF:", 0) != 0) continue;
            auto a = parse_attrs(lines[i].substr(18));
            size_t j = i + 1;
            while (j < lines.size() && (lines[j].empty() || lines[j][0] == '#')) ++j;
            if (j >= lines.size()) break;
            MediaFormat f;
            f.url = base.resolve(lines[j]);
            f.ext = "mp4"; f.proto = "hls"; f.headers = hdrs;
            f.bitrate = std::atoll((a.count("AVERAGE-BANDWIDTH") ? a["AVERAGE-BANDWIDTH"] : a["BANDWIDTH"]).c_str());
            if (a.count("RESOLUTION")) {
                auto x = a["RESOLUTION"].find('x');
                if (x == std::string::npos) x = a["RESOLUTION"].find('X');
                if (x != std::string::npos) {
                    f.width = std::atoi(a["RESOLUTION"].substr(0, x).c_str());
                    f.height = std::atoi(a["RESOLUTION"].substr(x + 1).c_str());
                }
            }
            if (a.count("FRAME-RATE")) f.fps = std::atof(a["FRAME-RATE"].c_str());
            f.vcodec = "avc1"; f.acodec = "mp4a";
            if (a.count("AUDIO") && audio_groups.count(a["AUDIO"])) f.audio_track_url = audio_groups[a["AUDIO"]];
            f.id = f.height > 0 ? (pfx + "-" + std::to_string(f.height) + "p") : (pfx + "-" + std::to_string(fmts.size()));
            fmts.push_back(std::move(f));
            i = j;
        }
        return fmts;
    }

    /// Downloads HLS media playlist into `dest`. Returns `true` if fMP4, `false` if MPEG-TS / raw audio.
    static bool download_stream(
        const HTTPClient& client,
        const std::string& pl_url,
        const fs::path& dest,
        const std::map<std::string, std::string>& hdrs,
        const SectionRange& sec,
        int connections,
        std::atomic<bool>& cancel_or_stop_live,
        std::function<void(int64_t, int64_t, double, double)> on_progress
    ) {
        auto resp = client.fetch(pl_url, "GET", hdrs);
        if (resp.status < 200 || resp.status >= 300) throw std::runtime_error("HLS playlist HTTP " + std::to_string(resp.status));
        ParsedURL base = ParsedURL::parse(resp.final_url.empty() ? pl_url : resp.final_url);

        struct Seg { std::string url; double dur = 0; ByteRange br{0, -1}; std::string key_url; uint8_t iv[16]{}; bool has_iv = false; uint64_t seq = 0; };
        auto parse_pl = [&](const std::string& txt, const ParsedURL& b, std::string& init_u, bool& is_live, double& target_dur) {
            std::vector<Seg> segs;
            is_live = (txt.find("#EXT-X-ENDLIST") == std::string::npos);
            target_dur = 4.0;
            uint64_t mseq = 0;
            double cdur = 0;
            ByteRange cbr{0, -1};
            int64_t prev_end = 0;
            std::string ckey;
            uint8_t civ[16]{};
            bool chas_iv = false;

            std::istringstream ss(txt);
            std::string l;
            while (std::getline(ss, l)) {
                while (!l.empty() && (l.back() == '\r' || l.back() == '\n' || l.back() == ' ')) l.pop_back();
                if (l.empty()) continue;
                if (l.rfind("#EXT-X-TARGETDURATION:", 0) == 0) target_dur = std::atof(l.c_str() + 22);
                else if (l.rfind("#EXT-X-MEDIA-SEQUENCE:", 0) == 0) mseq = std::strtoull(l.c_str() + 22, nullptr, 10);
                else if (l.rfind("#EXT-X-MAP:", 0) == 0) {
                    auto a = parse_attrs(l.substr(11));
                    if (!a["URI"].empty()) init_u = b.resolve(a["URI"]);
                } else if (l.rfind("#EXT-X-KEY:", 0) == 0) {
                    auto a = parse_attrs(l.substr(11));
                    if (a["METHOD"] == "AES-128" && !a["URI"].empty()) {
                        ckey = b.resolve(a["URI"]);
                        chas_iv = false;
                        std::string ivs = a["IV"];
                        if (ivs.rfind("0x", 0) == 0 || ivs.rfind("0X", 0) == 0) ivs = ivs.substr(2);
                        if (ivs.size() == 32) {
                            for (int k = 0; k < 16; ++k) {
                                char hh[3] = {ivs[k*2], ivs[k*2+1], 0};
                                civ[k] = (uint8_t)std::strtoul(hh, nullptr, 16);
                            }
                            chas_iv = true;
                        }
                    } else if (a["METHOD"] == "NONE") { ckey.clear(); chas_iv = false; }
                } else if (l.rfind("#EXT-X-BYTERANGE:", 0) == 0) {
                    std::string bs = l.substr(17);
                    auto at = bs.find('@');
                    int64_t len = std::atoll(bs.c_str());
                    int64_t st = (at == std::string::npos) ? prev_end : std::atoll(bs.c_str() + at + 1);
                    prev_end = st + len;
                    cbr = {st, st + len - 1};
                } else if (l.rfind("#EXTINF:", 0) == 0) {
                    cdur = std::atof(l.c_str() + 8);
                } else if (l[0] != '#') {
                    Seg sg; sg.url = b.resolve(l); sg.dur = cdur; sg.br = cbr; sg.key_url = ckey; sg.has_iv = chas_iv;
                    std::memcpy(sg.iv, civ, 16); sg.seq = mseq + segs.size();
                    segs.push_back(std::move(sg));
                    cdur = 0; cbr = {0, -1};
                }
            }
            return segs;
        };

        std::string init_url;
        bool is_live = false;
        double target_dur = 4.0;
        auto segs = parse_pl(resp.text(), base, init_url, is_live, target_dur);

        if (is_live && !sec.active()) {
            // Live HLS recording loop until cancel_or_stop_live
            fs::path part = dest.string() + ".part";
            FILE* out = std::fopen(part.c_str(), "wb");
            if (!out) throw std::runtime_error("Cannot open " + part.string());
            bool wrote_init = false, fmp4 = false;
            std::set<uint64_t> seen;
            int64_t rec_bytes = 0;
            double rec_sec = 0.0;
            bool first = true;
            while (!cancel_or_stop_live.load()) {
                if (!first) {
                    auto r2 = client.fetch(pl_url, "GET", hdrs);
                    if (r2.status >= 200 && r2.status < 300) segs = parse_pl(r2.text(), ParsedURL::parse(r2.final_url.empty() ? pl_url : r2.final_url), init_url, is_live, target_dur);
                }
                first = false;
                if (!wrote_init && !init_url.empty()) {
                    auto ir = client.fetch(init_url, "GET", hdrs);
                    std::fwrite(ir.body.data(), 1, ir.body.size(), out);
                    rec_bytes += (int64_t)ir.body.size();
                    wrote_init = true; fmp4 = true;
                }
                size_t start_i = seen.empty() && segs.size() > 3 ? segs.size() - 3 : 0;
                for (size_t i = start_i; i < segs.size() && !cancel_or_stop_live.load(); ++i) {
                    if (!seen.insert(segs[i].seq).second) continue;
                    auto sr = client.fetch(segs[i].url, "GET", hdrs);
                    if (!sr.body.empty()) {
                        if (!wrote_init && rec_bytes == 0 && sr.body[0] != 0x47) fmp4 = true;
                        std::fwrite(sr.body.data(), 1, sr.body.size(), out);
                        rec_bytes += (int64_t)sr.body.size();
                        rec_sec += segs[i].dur;
                        if (on_progress) on_progress(rec_bytes, 0, 0.0, rec_sec);
                    }
                }
                if (!is_live) break;
                for (int k = 0; k < 10 && !cancel_or_stop_live.load(); ++k)
                    std::this_thread::sleep_for(std::chrono::milliseconds((int)(std::max(1.0, target_dur * 0.5) * 100)));
            }
            std::fflush(out);
            ::fsync(fileno(out));
            std::fclose(out);
            commit_file_verified(part, dest);
            return fmp4;
        }

        if (sec.active()) {
            std::vector<Seg> filt;
            double acc = 0.0;
            for (const auto& sg : segs) {
                double s0 = acc, s1 = acc + sg.dur; acc = s1;
                if (sec.start >= 0 && s1 < sec.start) continue;
                if (sec.end >= 0 && s0 > sec.end) break;
                filt.push_back(sg);
            }
            if (!filt.empty()) segs.swap(filt);
        }

        std::vector<uint8_t> init_bytes;
        if (!init_url.empty()) init_bytes = client.fetch(init_url, "GET", hdrs).body;

        fs::path seg_dir = dest.parent_path() / (dest.filename().string() + "_segs");
        std::error_code ec;
        fs::create_directories(seg_dir, ec);
        struct SegDirGuard {
            fs::path dir;
            bool keep = false;
            ~SegDirGuard() { if (!keep) { std::error_code e; fs::remove_all(dir, e); } }
        } seg_guard{seg_dir, false};
        std::mutex mu;
        std::map<std::string, std::vector<uint8_t>> key_cache;
        std::atomic<size_t> next_idx{0};
        std::atomic<size_t> done_cnt{0};
        std::atomic<int64_t> total_bytes{0};
        std::atomic<bool> failed{false};

        int nworkers = std::max(1, std::min(16, connections));
        std::vector<WorkerThread> pool;
        for (int w = 0; w < nworkers; ++w) {
            pool.emplace_back([&]() {
                while (!cancel_or_stop_live.load() && !failed.load()) {
                    size_t i = next_idx.fetch_add(1);
                    if (i >= segs.size()) break;
                    char name[32]; std::snprintf(name, sizeof(name), "%06zu.seg", i);
                    fs::path sf = seg_dir / name;
                    if (fs::exists(sf) && fs::file_size(sf, ec) > 0) {
                        int64_t b = total_bytes.fetch_add((int64_t)fs::file_size(sf, ec)) + (int64_t)fs::file_size(sf, ec);
                        size_t dc = ++done_cnt;
                        double fr = (double)dc / std::max<size_t>(1, segs.size());
                        if (on_progress) on_progress(b, fr > 0.01 ? (int64_t)(b / fr) : 0, fr, 0);
                        continue;
                    }
                    std::vector<uint8_t> data;
                    try {
                        if (segs[i].br.end >= segs[i].br.start && segs[i].br.length() > 0) {
                            data = client.fetch_range(segs[i].url, segs[i].br.start, segs[i].br.end, hdrs);
                        } else {
                            auto r = client.fetch(segs[i].url, "GET", hdrs);
                            if (r.status < 200 || r.status >= 300) { failed.store(true); break; }
                            data = std::move(r.body);
                        }
                        if (!segs[i].key_url.empty()) {
                            std::vector<uint8_t> key;
                            {
                                std::lock_guard<std::mutex> lk(mu);
                                if (key_cache.count(segs[i].key_url)) key = key_cache[segs[i].key_url];
                            }
                            if (key.empty()) {
                                key = client.fetch(segs[i].key_url, "GET", hdrs).body;
                                std::lock_guard<std::mutex> lk(mu);
                                key_cache[segs[i].key_url] = key;
                            }
                            uint8_t iv[16]{};
                            if (segs[i].has_iv) std::memcpy(iv, segs[i].iv, 16);
                            else {
                                uint64_t sq = segs[i].seq;
                                for (int k = 0; k < 8; ++k) iv[15 - k] = (uint8_t)((sq >> (k * 8)) & 0xff);
                            }
                            data = aes128_cbc_decrypt(data, key, iv);
                        }
                        write_file_atomic(sf, data.data(), data.size());
                        int64_t b = total_bytes.fetch_add((int64_t)data.size()) + (int64_t)data.size();
                        size_t dc = ++done_cnt;
                        double fr = (double)dc / std::max<size_t>(1, segs.size());
                        if (on_progress) on_progress(b, fr > 0.01 ? (int64_t)(b / fr) : 0, fr, 0);
                    } catch (...) {
                        failed.store(true);
                        break;
                    }
                }
            });
        }
        for (auto& t : pool) t.join();
        if (cancel_or_stop_live.load()) { seg_guard.keep = true; throw InterruptedException(); }
        if (failed.load()) throw std::runtime_error("HLS segment download failed");

        fs::path part = dest.string() + ".part";
        FILE* out = std::fopen(part.c_str(), "wb");
        if (!out) throw std::runtime_error("Cannot write " + part.string());
        std::vector<uint8_t> head16;
        if (!init_bytes.empty()) {
            std::fwrite(init_bytes.data(), 1, init_bytes.size(), out);
            head16.assign(init_bytes.begin(), init_bytes.begin() + std::min<size_t>(16, init_bytes.size()));
        }
        auto ogg_crc32 = [](const uint8_t* data, size_t len) -> uint32_t {
            uint32_t crc = 0;
            for (size_t k = 0; k < len; ++k) {
                crc ^= (uint32_t)data[k] << 24;
                for (int b = 0; b < 8; ++b) crc = (crc & 0x80000000u) ? ((crc << 1) ^ 0x04C11DB7u) : (crc << 1);
            }
            return crc;
        };
        bool unchain_ogg = false;
        uint32_t ogg_serial = 0x55424954u;
        uint32_t ogg_seq = 0;
        int64_t ogg_max_gran = 0;
        for (size_t i = 0; i < segs.size(); ++i) {
            char name[32]; std::snprintf(name, sizeof(name), "%06zu.seg", i);
            std::ifstream sf(seg_dir / name, std::ios::binary);
            std::vector<uint8_t> sb((std::istreambuf_iterator<char>(sf)), std::istreambuf_iterator<char>());
            if (head16.empty() && !sb.empty()) {
                head16.assign(sb.begin(), sb.begin() + std::min<size_t>(16, sb.size()));
                unchain_ogg = init_bytes.empty() && segs.size() > 1 && sb.size() >= 27 && std::memcmp(sb.data(), "OggS", 4) == 0;
            }
            if (!unchain_ogg) {
                if (!sb.empty()) std::fwrite(sb.data(), 1, sb.size(), out);
                continue;
            }
            // Seamless Ogg HLS unchaining: strip duplicate BOS/tags headers on segments i > 0 and maintain continuous granules + CRC.
            size_t p = 0;
            int hdr_pages_skipped = 0;
            int64_t seg_gran_base = -1;
            while (p + 27 <= sb.size() && std::memcmp(&sb[p], "OggS", 4) == 0) {
                uint8_t nsegs = sb[p + 26];
                if (p + 27 + nsegs > sb.size()) break;
                size_t body_len = 0;
                for (uint8_t s = 0; s < nsegs; ++s) body_len += sb[p + 27 + s];
                size_t page_len = 27 + nsegs + body_len;
                if (p + page_len > sb.size()) break;

                uint8_t htype = sb[p + 5];
                uint64_t graw = 0;
                for (int k = 7; k >= 0; --k) graw = (graw << 8) | sb[p + 6 + k];
                int64_t gran = (int64_t)graw;

                if (i == 0 && ogg_seq == 0) {
                    ogg_serial = (uint32_t)sb[p + 14] | ((uint32_t)sb[p + 15] << 8) | ((uint32_t)sb[p + 16] << 16) | ((uint32_t)sb[p + 17] << 24);
                }
                if (i > 0 && ((htype & 0x02u) != 0 || (gran == 0 && hdr_pages_skipped < 2))) {
                    ++hdr_pages_skipped;
                    p += page_len;
                    continue;
                }
                if (gran > 0) {
                    if (seg_gran_base < 0) seg_gran_base = (i > 0 && gran <= ogg_max_gran) ? ogg_max_gran : 0;
                    gran += seg_gran_base;
                    if (gran > ogg_max_gran) ogg_max_gran = gran;
                }
                bool is_final_page = (i + 1 == segs.size()) && (p + page_len >= sb.size());
                uint8_t new_htype = (uint8_t)((htype & ~0x04u) | (is_final_page ? 0x04u : 0x00u));
                if (i > 0) new_htype &= ~0x02u;
                sb[p + 5] = new_htype;
                uint64_t ug = (uint64_t)gran;
                for (int k = 0; k < 8; ++k) sb[p + 6 + k] = (uint8_t)((ug >> (k * 8)) & 0xffu);
                for (int k = 0; k < 4; ++k) sb[p + 14 + k] = (uint8_t)((ogg_serial >> (k * 8)) & 0xffu);
                for (int k = 0; k < 4; ++k) sb[p + 18 + k] = (uint8_t)((ogg_seq >> (k * 8)) & 0xffu);
                ++ogg_seq;
                sb[p + 22] = sb[p + 23] = sb[p + 24] = sb[p + 25] = 0;
                uint32_t crc = ogg_crc32(&sb[p], page_len);
                for (int k = 0; k < 4; ++k) sb[p + 22 + k] = (uint8_t)((crc >> (k * 8)) & 0xffu);
                std::fwrite(&sb[p], 1, page_len, out);
                p += page_len;
            }
        }
        std::fflush(out);
        ::fsync(fileno(out));
        std::fclose(out);
        commit_file_verified(part, dest);
        bool is_fmp4 = !init_bytes.empty() || (head16.size() >= 8 && std::memcmp(&head16[4], "ftyp", 4) == 0);
        return is_fmp4;
    }
};

// MARK: - SponsorBlock, Chapter Parser, Subtitles & Linux xattr + FFmpeg Converter

struct SponsorAndSubs {
    static std::vector<std::pair<double, double>> fetch_sponsors(const HTTPClient& client, const std::string& video_id, const std::string& cat_spec, std::vector<Chapter>* mark_into = nullptr) {
        if (video_id.empty()) return {};
        std::string cats_json = "[\"sponsor\",\"selfpromo\",\"interaction\"]";
        if (cat_spec == "all") cats_json = "[\"sponsor\",\"selfpromo\",\"interaction\",\"intro\",\"outro\",\"preview\",\"music_offtopic\",\"filler\"]";
        else if (!cat_spec.empty() && cat_spec != "default") {
            Json arr = Json::array();
            size_t p = 0;
            while (p < cat_spec.size()) {
                auto cm = cat_spec.find(',', p);
                arr.a.push_back(cm == std::string::npos ? cat_spec.substr(p) : cat_spec.substr(p, cm - p));
                if (cm == std::string::npos) break;
                p = cm + 1;
            }
            cats_json = arr.dump();
        }
        std::string prefix = sha256_hex(video_id).substr(0, 4);
        std::string url = "https://sponsor.ajay.app/api/skipSegments/" + prefix + "?categories=" + url_encode(cats_json);
        auto r = client.fetch(url, "GET", {}, "", false, 1);
        if (r.status != 200) return {};
        Json root = Json::parse(r.text());
        std::vector<std::pair<double, double>> out;
        if (!root.is_arr()) return out;
        for (const auto& entry : root.a) {
            if (entry["videoID"].str() != video_id || !entry["segments"].is_arr()) continue;
            for (const auto& s : entry["segments"].a) {
                if (s["segment"].is_arr() && s["segment"].a.size() == 2) {
                    double a = s["segment"].at(0).dbl(), b = s["segment"].at(1).dbl();
                    if (b > a) {
                        out.push_back({a, b});
                        if (mark_into) mark_into->push_back({"[Sponsor: " + s["category"].str("sponsor") + "]", a, b});
                    }
                }
            }
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    static std::vector<Chapter> chapters_from_description(const std::string& desc, double total_dur) {
        if (desc.empty()) return {};
        std::vector<std::pair<double, std::string>> pts;
        std::istringstream ss(desc);
        std::string ln;
        while (std::getline(ss, ln)) {
            size_t i = 0;
            while (i < ln.size() && !std::isdigit((unsigned char)ln[i])) ++i;
            size_t ts_start = i;
            bool saw_colon = false;
            while (i < ln.size() && (std::isdigit((unsigned char)ln[i]) || ln[i] == ':')) {
                if (ln[i] == ':') saw_colon = true;
                ++i;
            }
            if (!saw_colon || i <= ts_start || i >= ln.size()) continue;
            double sec = SectionRange::parse_ts(ln.substr(ts_start, i - ts_start));
            if (sec < 0) continue;
            while (i < ln.size() && (std::isspace((unsigned char)ln[i]) || ln[i] == '-' || ln[i] == '|' || ln[i] == ')' || ln[i] == ']')) ++i;
            std::string title = ln.substr(i);
            while (!title.empty() && (title.back() == '\r' || title.back() == ' ')) title.pop_back();
            if (!title.empty()) pts.push_back({sec, title});
        }
        if (pts.size() < 2) return {};
        std::sort(pts.begin(), pts.end());
        std::vector<Chapter> chs;
        for (size_t i = 0; i < pts.size(); ++i) {
            double end = (i + 1 < pts.size()) ? pts[i+1].first : (total_dur > pts[i].first ? total_dur : pts[i].first + 60.0);
            if (end > pts[i].first) chs.push_back({pts[i].second, pts[i].first, end});
        }
        return chs;
    }

    static std::vector<Chapter> parse_vtt_cues(const std::string& vtt) {
        std::vector<Chapter> cues;
        std::istringstream ss(vtt);
        std::string ln;
        while (std::getline(ss, ln)) {
            auto arr = ln.find("-->");
            if (arr == std::string::npos) continue;
            std::string lhs = ln.substr(0, arr);
            std::string rhs = ln.substr(arr + 3);
            for (char& c : lhs) if (c == ',') c = '.';
            for (char& c : rhs) if (c == ',') c = '.';
            auto sp = rhs.find_first_not_of(" \t");
            if (sp != std::string::npos) rhs = rhs.substr(sp);
            auto sp2 = rhs.find_first_of(" \t\r\n");
            if (sp2 != std::string::npos) rhs.resize(sp2);
            double s = SectionRange::parse_ts(lhs), e = SectionRange::parse_ts(rhs);
            if (s < 0 || e <= s) continue;
            std::string body, tl;
            while (std::getline(ss, tl)) {
                while (!tl.empty() && tl.back() == '\r') tl.pop_back();
                if (tl.empty()) break;
                // strip simple <...> tags
                std::string clean;
                bool in_tag = false;
                for (char ch : tl) {
                    if (ch == '<') in_tag = true;
                    else if (ch == '>') in_tag = false;
                    else if (!in_tag) clean.push_back(ch);
                }
                if (!clean.empty()) {
                    if (!body.empty()) body.push_back('\n');
                    body += clean;
                }
            }
            if (!body.empty()) cues.push_back({body, s, e});
        }
        return cues;
    }

    static void set_origin_xattr(const fs::path& file, const std::string& url) {
        if (!url.empty()) {
#ifdef __linux__
            (void)::setxattr(file.c_str(), "user.xdg.origin.url", url.data(), url.size(), 0);
#elif defined(__APPLE__)
            (void)::setxattr(file.c_str(), "user.xdg.origin.url", url.data(), url.size(), 0, 0);
#endif
        }
    }

    static std::string find_ffmpeg() {
#if defined(__wasi__) || defined(UBIT_SDK)
        return "";
#else
        if (const char* env = std::getenv("UBIT_FFMPEG"); env && *env && ::access(env, X_OK) == 0) return env;
        const char* path_env = std::getenv("PATH");
        if (!path_env) return "";
        std::string pe(path_env);
        size_t p = 0;
        while (p <= pe.size()) {
            auto col = pe.find(':', p);
            std::string dir = (col == std::string::npos) ? pe.substr(p) : pe.substr(p, col - p);
            std::string cand = dir + "/ffmpeg";
            if (!dir.empty() && ::access(cand.c_str(), X_OK) == 0) return cand;
            if (col == std::string::npos) break;
            p = col + 1;
        }
        return "";
#endif
    }

    static void run_ffmpeg_convert(const fs::path& in_file, const fs::path& out_file, const std::string& fmt, const fs::path* second_input = nullptr) {
#if defined(__wasi__) || defined(UBIT_SDK)
        (void)in_file; (void)out_file; (void)second_input;
        throw std::runtime_error("Converting/muxing to ." + fmt + " needs ffmpeg, which this sandboxed uBit build does not run (MP4 and M4A mux natively).");
#else
        std::string ff = find_ffmpeg();
        if (ff.empty()) {
            throw std::runtime_error("Converting/muxing to ." + fmt + " on Linux requires ffmpeg on PATH (MP4 and M4A mux natively with zero dependencies).");
        }
        std::string cmd = "\"" + ff + "\" -y -loglevel error -i \"" + in_file.string() + "\"";
        if (second_input) cmd += " -i \"" + second_input->string() + "\"";
        if (second_input) cmd += " -c copy";
        else if (fmt == "mp3") cmd += " -vn -c:a libmp3lame -q:a 2";
        else if (fmt == "opus") cmd += " -vn -c:a libopus -b:a 160k";
        else if (fmt == "flac") cmd += " -vn -c:a flac";
        else if (fmt == "wav") cmd += " -vn -c:a pcm_s16le";
        else cmd += " -c copy";
        cmd += " \"" + out_file.string() + "\"";
        if (std::system(cmd.c_str()) != 0) throw std::runtime_error("ffmpeg conversion failed for ." + fmt);
#endif
    }
};

} // namespace ubit
