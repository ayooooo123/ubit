#pragma once
#include "mux.hpp"

namespace ubit {

// MARK: - String / HTML / JSON Extraction Utilities (Zero Regex Library Bloat!)

namespace strutil {

inline std::string to_lower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

inline std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a])) ++a;
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

inline bool host_matches(const ParsedURL& u, std::initializer_list<const char*> domains) {
    std::string h = to_lower(u.host);
    for (const char* d : domains) {
        std::string dm(d);
        if (h == dm) return true;
        if (h.size() > dm.size() && h.compare(h.size() - dm.size() - 1, dm.size() + 1, "." + dm) == 0) return true;
    }
    return false;
}

inline std::string query_param(const std::string& query, const std::string& key) {
    size_t p = 0;
    while (p < query.size()) {
        auto amp = query.find('&', p);
        std::string kv = (amp == std::string::npos) ? query.substr(p) : query.substr(p, amp - p);
        auto eq = kv.find('=');
        if (eq != std::string::npos && kv.substr(0, eq) == key) return url_decode(kv.substr(eq + 1));
        if (amp == std::string::npos) break;
        p = amp + 1;
    }
    return "";
}

inline std::string decode_html(std::string s) {
    const std::pair<const char*, const char*> reps[] = {
        {"&amp;", "&"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""},
        {"&#39;", "'"}, {"&apos;", "'"}, {"&#x27;", "'"}, {"&nbsp;", " "}
    };
    for (auto [k, v] : reps) {
        size_t p = 0;
        size_t kl = std::strlen(k), vl = std::strlen(v);
        while ((p = s.find(k, p)) != std::string::npos) {
            s.replace(p, kl, v);
            p += vl;
        }
    }
    return s;
}

inline std::string unescape_js(const std::string& raw) {
    Json j = Json::parse("\"" + raw + "\"");
    if (j.is_str() && !j.s.empty()) return decode_html(j.s);
    std::string s = raw;
    const std::pair<const char*, const char*> reps[] = {
        {"\\/", "/"}, {"\\u0026", "&"}, {"\\u002F", "/"}, {"\\u003d", "="}, {"\\u003D", "="}, {"&amp;", "&"}
    };
    for (auto [k, v] : reps) {
        size_t p = 0;
        while ((p = s.find(k, p)) != std::string::npos) { s.replace(p, std::strlen(k), v); p += std::strlen(v); }
    }
    return s;
}

/// Extracts balanced `{...}` or `[...]` JSON after `marker`.
inline Json json_after(const std::string& marker, const std::string& text) {
    auto pos = text.find(marker);
    if (pos == std::string::npos) return Json();
    size_t i = pos + marker.size();
    while (i < text.size() && (std::isspace((unsigned char)text[i]) || text[i] == '=')) ++i;
    if (i >= text.size() || (text[i] != '{' && text[i] != '[')) return Json();
    char open_c = text[i], close_c = (open_c == '{') ? '}' : ']';
    int depth = 0;
    bool in_str = false, esc = false;
    char qch = '"';
    size_t start = i;
    for (; i < text.size(); ++i) {
        char c = text[i];
        if (in_str) {
            if (esc) esc = false;
            else if (c == '\\') esc = true;
            else if (c == qch) in_str = false;
        } else {
            if (c == '"' || c == '\'') { in_str = true; qch = c; }
            else if (c == open_c) ++depth;
            else if (c == close_c) {
                if (--depth == 0) {
                    return Json::parse(text.substr(start, i - start + 1));
                }
            }
        }
    }
    return Json();
}

/// Finds `"key":"value"` or `"key":12345` in JS/HTML text without heavy regex DFA tables.
inline std::string find_json_field(const std::string& html, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    size_t pos = 0;
    while ((pos = html.find(needle, pos)) != std::string::npos) {
        size_t i = pos + needle.size();
        while (i < html.size() && std::isspace((unsigned char)html[i])) ++i;
        if (i < html.size() && html[i] == ':') {
            ++i;
            while (i < html.size() && std::isspace((unsigned char)html[i])) ++i;
            if (i < html.size() && html[i] == '"') {
                ++i;
                std::string out;
                while (i < html.size() && html[i] != '"') {
                    if (html[i] == '\\' && i + 1 < html.size()) { out.push_back(html[i]); out.push_back(html[i+1]); i += 2; }
                    else out.push_back(html[i++]);
                }
                return unescape_js(out);
            } else if (i < html.size() && (std::isdigit((unsigned char)html[i]) || html[i] == '-')) {
                size_t st = i;
                while (i < html.size() && (std::isdigit((unsigned char)html[i]) || html[i] == '.')) ++i;
                return html.substr(st, i - st);
            }
        }
        pos += needle.size();
    }
    return "";
}

inline std::vector<std::string> find_all_json_fields(const std::string& html, const std::string& key) {
    std::vector<std::string> res;
    std::string needle = "\"" + key + "\"";
    size_t pos = 0;
    while ((pos = html.find(needle, pos)) != std::string::npos) {
        size_t i = pos + needle.size();
        while (i < html.size() && std::isspace((unsigned char)html[i])) ++i;
        if (i < html.size() && html[i] == ':') {
            ++i;
            while (i < html.size() && std::isspace((unsigned char)html[i])) ++i;
            if (i < html.size() && html[i] == '"') {
                ++i;
                std::string out;
                while (i < html.size() && html[i] != '"') {
                    if (html[i] == '\\' && i + 1 < html.size()) { out.push_back(html[i]); out.push_back(html[i+1]); i += 2; }
                    else out.push_back(html[i++]);
                }
                res.push_back(unescape_js(out));
            }
        }
        pos += needle.size();
    }
    return res;
}

inline std::string meta_content(const std::string& prop, const std::string& html) {
    std::string low = to_lower(html);
    std::string lp = to_lower(prop);
    size_t pos = 0;
    while ((pos = low.find("<meta", pos)) != std::string::npos) {
        auto gt = low.find('>', pos);
        if (gt == std::string::npos) break;
        std::string tag_low = low.substr(pos, gt - pos + 1);
        if (tag_low.find("\"" + lp + "\"") != std::string::npos || tag_low.find("'" + lp + "'") != std::string::npos) {
            auto cpos = tag_low.find("content=");
            if (cpos != std::string::npos) {
                size_t v = pos + cpos + 8;
                if (v < gt && (html[v] == '"' || html[v] == '\'')) {
                    char q = html[v++];
                    auto endq = html.find(q, v);
                    if (endq != std::string::npos && endq <= gt) return decode_html(html.substr(v, endq - v));
                }
            }
        }
        pos = gt + 1;
    }
    return "";
}

inline std::string page_title(const std::string& html) {
    std::string og = meta_content("og:title", html);
    if (!og.empty()) return og;
    std::string tw = meta_content("twitter:title", html);
    if (!tw.empty()) return tw;
    std::string low = to_lower(html);
    auto t0 = low.find("<title");
    if (t0 != std::string::npos) {
        auto gt = low.find('>', t0);
        auto t1 = low.find("</title>", gt == std::string::npos ? t0 : gt);
        if (gt != std::string::npos && t1 != std::string::npos && t1 > gt + 1) {
            return trim(decode_html(html.substr(gt + 1, t1 - gt - 1)));
        }
    }
    return "";
}

inline std::vector<std::string> scan_media_urls(const std::string& html, const std::string& ext_needle) {
    std::vector<std::string> out;
    size_t pos = 0;
    while ((pos = html.find(ext_needle, pos)) != std::string::npos) {
        // Walk backward to http:// or https://
        size_t s = pos;
        while (s > 0 && html[s-1] != '"' && html[s-1] != '\'' && !std::isspace((unsigned char)html[s-1]) && html[s-1] != '<' && html[s-1] != '(') --s;
        size_t e = pos + ext_needle.size();
        while (e < html.size() && html[e] != '"' && html[e] != '\'' && !std::isspace((unsigned char)html[e]) && html[e] != '>' && html[e] != ')') ++e;
        std::string cand = unescape_js(html.substr(s, e - s));
        if (cand.rfind("http://", 0) == 0 || cand.rfind("https://", 0) == 0) out.push_back(cand);
        pos = e;
    }
    return out;
}

inline std::string unix_to_date(int64_t ts) {
    time_t t = (time_t)ts;
    struct tm g{};
    gmtime_r(&t, &g);
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%04d-%02d-%02d", g.tm_year + 1900, g.tm_mon + 1, g.tm_mday);
    return buf;
}

} // namespace strutil

// MARK: - Generic HTML5 / OpenGraph / JSON-LD / HLS / MP4 Extractor

struct GenericExtractor {
    static MediaInfo extract(const ParsedURL& u, const std::string& raw_url, const HTTPClient& client, const std::string& force_site = "") {
        auto resp = client.fetch(raw_url);
        if (resp.status < 200 || resp.status >= 300) {
            throw std::runtime_error("HTTP " + std::to_string(resp.status) + " fetching " + u.host);
        }
        ParsedURL fin = ParsedURL::parse(resp.final_url.empty() ? raw_url : resp.final_url);
        std::string ct = strutil::to_lower(resp.header("content-type"));
        if (ct.rfind("video/", 0) == 0 || ct.rfind("audio/", 0) == 0) {
            bool aud = ct.rfind("audio/", 0) == 0;
            MediaInfo info; info.id = "direct"; info.title = fin.host; info.site = force_site.empty() ? fin.host : force_site; info.webpage_url = resp.final_url;
            MediaFormat f; f.id = "direct"; f.url = resp.final_url; f.ext = aud ? "m4a" : "mp4"; f.vcodec = aud ? "none" : "avc1"; f.acodec = "mp4a";
            info.formats.push_back(f);
            return info;
        }

        std::string html = resp.text();
        MediaInfo info;
        info.id = std::to_string(std::hash<std::string>{}(resp.final_url) & 0x7fffffff);
        info.title = strutil::page_title(html);
        if (info.title.empty()) info.title = fin.host;
        info.site = force_site.empty() ? fin.host : force_site;
        info.webpage_url = resp.final_url.empty() ? raw_url : resp.final_url;
        info.thumbnail = strutil::meta_content("og:image", html);
        info.author = strutil::meta_content("author", html);
        std::map<std::string, std::string> hdrs = {{"Referer", info.webpage_url}};

        std::set<std::string> seen;
        auto add_url = [&](const std::string& cand) {
            if (cand.empty() || cand.rfind("blob:", 0) == 0) return;
            std::string abs = fin.resolve(cand);
            if (!seen.insert(abs).second) return;
            std::string low = strutil::to_lower(abs);
            if (low.find(".m3u8") != std::string::npos) {
                auto hls = HLSEngine::extract_formats(client, abs, hdrs, "hls-" + std::to_string(info.formats.size()));
                for (auto& hf : hls) info.formats.push_back(std::move(hf));
            } else {
                bool aud = low.find(".mp3") != std::string::npos || low.find(".m4a") != std::string::npos || low.find(".opus") != std::string::npos;
                MediaFormat f;
                f.id = "web-" + std::to_string(info.formats.size());
                f.url = abs;
                f.ext = low.find(".webm") != std::string::npos ? "webm" : (low.find(".mp3") != std::string::npos ? "mp3" : (aud ? "m4a" : "mp4"));
                f.vcodec = aud ? "none" : "avc1";
                f.acodec = "mp4a";
                f.headers = hdrs;
                info.formats.push_back(std::move(f));
            }
        };

        for (const char* mp : {"og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream", "og:audio"}) {
            std::string v = strutil::meta_content(mp, html);
            if (!v.empty() && (v.find(".mp4") != std::string::npos || v.find(".m3u8") != std::string::npos || v.find(".webm") != std::string::npos || v.find(".mp3") != std::string::npos))
                add_url(v);
        }
        for (const auto& u_s : strutil::find_all_json_fields(html, "contentUrl")) add_url(u_s);
        for (const auto& u_s : strutil::scan_media_urls(html, ".m3u8")) add_url(u_s);
        if (info.formats.empty()) {
            for (const auto& u_s : strutil::scan_media_urls(html, ".mp4")) add_url(u_s);
        }
        if (info.formats.empty()) throw std::runtime_error("No downloadable media found on " + fin.host);
        return info;
    }
};

// MARK: - YouTube Multi-Client Extractor (VISIONOS 1.02 + Watch VISITOR_DATA + Tail-Range Probe + Playlists/Search)

class YouTubeExtractor {
    struct Profile {
        const char* name;
        const char* version;
        const char* id_hdr;
        const char* ua;
        std::map<std::string, std::string> extra;
        bool cookies;
    };

    static std::string extract_vid(const ParsedURL& u) {
        if (strutil::host_matches(u, {"youtu.be"})) {
            std::string p = u.path;
            if (!p.empty() && p[0] == '/') p.erase(p.begin());
            auto sl = p.find('/');
            std::string id = sl == std::string::npos ? p : p.substr(0, sl);
            if (id.size() == 11) return id;
        }
        std::string v = strutil::query_param(u.query, "v");
        if (v.size() == 11) return v;
        for (const char* pfx : {"/shorts/", "/embed/", "/live/", "/v/"}) {
            if (u.path.rfind(pfx, 0) == 0) {
                std::string rest = u.path.substr(std::strlen(pfx));
                auto sl = rest.find('/');
                std::string id = sl == std::string::npos ? rest : rest.substr(0, sl);
                if (id.size() == 11) return id;
            }
        }
        return "";
    }

    static bool verify_tail_playable(const HTTPClient& client, const std::string& url, int64_t clen, const std::string& ua) {
        int64_t s = clen > 131072 ? (clen - 4096) : 0;
        int64_t e = clen > 131072 ? (clen - 1) : 2047;
        try {
            auto chunk = client.fetch_range(url, s, e, {{"User-Agent", ua}});
            return !chunk.empty();
        } catch (...) {
            return false;
        }
    }

    static Json call_player(const HTTPClient& client, const std::string& vid, const Profile& prof, const std::string& visitor_data) {
        Json c = Json::object();
        c["clientName"] = prof.name;
        c["clientVersion"] = prof.version;
        c["hl"] = "en";
        c["gl"] = "US";
        c["userAgent"] = prof.ua;
        if (!visitor_data.empty()) c["visitorData"] = visitor_data;
        for (const auto& [k, v] : prof.extra) c[k] = v;

        Json ctx = Json::object(); ctx["client"] = c;
        Json body = Json::object();
        body["videoId"] = vid;
        body["context"] = ctx;
        body["contentCheckOk"] = true;
        body["racyCheckOk"] = true;

        std::map<std::string, std::string> hdrs = {
            {"Content-Type", "application/json"},
            {"User-Agent", prof.ua},
            {"X-YouTube-Client-Name", prof.id_hdr},
            {"X-YouTube-Client-Version", prof.version},
            {"Origin", "https://www.youtube.com"}
        };
        if (!visitor_data.empty()) hdrs["X-Goog-Visitor-Id"] = visitor_data;

        if (prof.cookies) {
            std::string sap = client.cookies.value_named("SAPISID", "youtube.com");
            if (sap.empty()) sap = client.cookies.value_named("__Secure-3PAPISID", "youtube.com");
            if (!sap.empty()) {
                int64_t ts = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
                std::string sig = sha1_hex(std::to_string(ts) + " " + sap + " https://www.youtube.com");
                hdrs["Authorization"] = "SAPISIDHASH " + std::to_string(ts) + "_" + sig;
                hdrs["X-Origin"] = "https://www.youtube.com";
            }
        }

        auto resp = client.fetch("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", "POST", hdrs, body.dump(), prof.cookies);
        return resp.status == 200 ? Json::parse(resp.text()) : Json();
    }

    static void collect_items(const Json& node, std::vector<PlaylistEntry>& entries, std::string& cont) {
        if (node.is_obj()) {
            const Json* vr = nullptr;
            if (node.has("playlistVideoRenderer")) vr = &node["playlistVideoRenderer"];
            else if (node.has("videoRenderer")) vr = &node["videoRenderer"];
            else if (node.has("reelItemRenderer")) vr = &node["reelItemRenderer"];
            if (vr && vr->is_obj()) {
                std::string vid = (*vr)["videoId"].str();
                if (!vid.empty()) {
                    bool dup = false;
                    for (const auto& e : entries) if (e.id == vid) { dup = true; break; }
                    if (!dup) {
                        std::string t = (*vr)["title"]["simpleText"].str();
                        if (t.empty() && (*vr)["title"]["runs"].is_arr() && !(*vr)["title"]["runs"].a.empty())
                            t = (*vr)["title"]["runs"].at(0)["text"].str();
                        double dur = SectionRange::parse_ts((*vr)["lengthSeconds"].str());
                        if (dur < 0) dur = SectionRange::parse_ts((*vr)["lengthText"]["simpleText"].str());
                        entries.push_back({vid, t.empty() ? vid : t, "https://www.youtube.com/watch?v=" + vid, std::max(0.0, dur), "https://i.ytimg.com/vi/" + vid + "/mqdefault.jpg", ""});
                    }
                }
                return;
            }
            if (cont.empty() && node.has("continuationEndpoint")) {
                cont = node["continuationEndpoint"]["continuationCommand"]["token"].str();
            }
            for (const auto& [_, v] : node.o) collect_items(v, entries, cont);
        } else if (node.is_arr()) {
            for (const auto& x : node.a) collect_items(x, entries, cont);
        }
    }

public:
    static MediaInfo search(const std::string& query, const HTTPClient& client) {
        Json body = Json::object();
        Json c = Json::object(); c["clientName"] = "WEB"; c["clientVersion"] = "2.20261029.11.00"; c["hl"] = "en"; c["gl"] = "US";
        Json ctx = Json::object(); ctx["client"] = c;
        body["context"] = ctx; body["query"] = query;
        auto r = client.fetch("https://www.youtube.com/youtubei/v1/search?prettyPrint=false", "POST", {{"Content-Type", "application/json"}}, body.dump());
        Json root = Json::parse(r.text());
        MediaInfo info; info.id = "search"; info.title = "Search: " + query; info.site = "YouTube";
        info.webpage_url = "https://www.youtube.com/results?search_query=" + url_encode(query);
        std::string cont;
        collect_items(root, info.entries, cont);
        if (info.entries.empty()) throw std::runtime_error("No YouTube results for '" + query + "'");
        return info;
    }

    static MediaInfo extract_playlist(const std::string& list_id, const std::string& raw_url, const HTTPClient& client) {
        std::string bid = list_id.rfind("VL", 0) == 0 ? list_id : ("VL" + list_id);
        auto call_browse = [&](const std::string& field, const std::string& val) {
            Json body = Json::object();
            Json c = Json::object(); c["clientName"] = "WEB"; c["clientVersion"] = "2.20261029.11.00"; c["hl"] = "en"; c["gl"] = "US";
            Json ctx = Json::object(); ctx["client"] = c;
            body["context"] = ctx; body[field] = val;
            auto r = client.fetch("https://www.youtube.com/youtubei/v1/browse?prettyPrint=false", "POST", {{"Content-Type", "application/json"}}, body.dump());
            return Json::parse(r.text());
        };
        Json root = call_browse("browseId", bid);
        MediaInfo info; info.id = list_id; info.site = "YouTube"; info.webpage_url = raw_url;
        info.title = root["metadata"]["playlistMetadataRenderer"]["title"].str("Playlist " + list_id);
        std::string cont;
        collect_items(root, info.entries, cont);
        for (int p = 0; p < 20 && !cont.empty(); ++p) {
            std::string tok = cont; cont.clear();
            collect_items(call_browse("continuation", tok), info.entries, cont);
        }
        if (info.entries.empty()) throw std::runtime_error("Playlist is empty or private");
        return info;
    }

    static MediaInfo extract(const ParsedURL& u, const std::string& raw_url, const HTTPClient& client) {
        std::string vid = extract_vid(u);
        std::string list_id = strutil::query_param(u.query, "list");
        if (!list_id.empty() && (vid.empty() || u.path.rfind("/playlist", 0) == 0)) {
            return extract_playlist(list_id, raw_url, client);
        }
        if (u.path.rfind("/results", 0) == 0) {
            return search(strutil::query_param(u.query, "search_query"), client);
        }
        if (vid.empty() && (u.path.rfind("/@", 0) == 0 || u.path.rfind("/channel/", 0) == 0 || u.path.rfind("/c/", 0) == 0)) {
            auto r = client.fetch(raw_url);
            std::string html = r.text();
            std::string cid = strutil::find_json_field(html, "externalId");
            if (cid.size() == 24 && cid.rfind("UC", 0) == 0) {
                auto pl = extract_playlist("UU" + cid.substr(2), raw_url, client);
                std::string pt = strutil::page_title(html);
                if (!pt.empty()) pl.title = pt;
                return pl;
            }
        }
        if (vid.empty()) throw std::runtime_error("Could not extract YouTube video ID");

        // Fetch Watch Context (VISITOR_DATA + ytInitialPlayerResponse)
        std::string visitor_data;
        Json watch_ipr;
        auto wr = client.fetch("https://www.youtube.com/watch?v=" + vid + "&bpctr=9999999999&has_verified=1");
        if (wr.status == 200) {
            std::string whtml = wr.text();
            visitor_data = strutil::find_json_field(whtml, "VISITOR_DATA");
            watch_ipr = strutil::json_after("var ytInitialPlayerResponse =", whtml);
        }
        if (visitor_data.empty()) {
            auto sw = client.fetch("https://www.youtube.com/sw.js_data", "GET", {}, "", false);
            auto pos = sw.text().find("\"Cgt");
            if (pos != std::string::npos) {
                auto q2 = sw.text().find('"', pos + 1);
                if (q2 != std::string::npos) visitor_data = sw.text().substr(pos + 1, q2 - pos - 1);
            }
        }

        const Profile profiles[] = {
            {"VISIONOS", "1.02", "101", "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
             {{"deviceMake","Apple"},{"deviceModel","RealityDevice17,1"},{"osName","visionOS"},{"osVersion","26.5.23O471"}}, false},
            {"IOS", "21.26.4", "5", "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
             {{"deviceMake","Apple"},{"deviceModel","iPhone16,2"},{"osName","iPhone"},{"osVersion","18.3.2.22D82"}}, false},
            {"TVHTML5", "5.20260707", "7", "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
             {{"deviceMake","Samsung"},{"deviceModel","UKS9800"},{"osName","Tizen"},{"osVersion","2.4.0"}}, true},
        };

        Json chosen_resp;
        std::vector<MediaFormat> chosen_fmts;
        std::string hls_manifest, hls_ua, last_reason;

        for (const auto& prof : profiles) {
            Json resp = call_player(client, vid, prof, visitor_data);
            if (!resp.is_obj()) continue;
            std::string st = resp["playabilityStatus"]["status"].str();
            if (st != "OK" && !resp.has("streamingData")) {
                std::string r = resp["playabilityStatus"]["reason"].str();
                if (!r.empty()) last_reason = r;
                continue;
            }
            const Json& sd = resp["streamingData"];
            if (hls_manifest.empty() && sd.has("hlsManifestUrl")) {
                hls_manifest = sd["hlsManifestUrl"].str();
                hls_ua = prof.ua;
            }

            std::vector<Json> raw_fmts;
            if (sd["formats"].is_arr()) for (const auto& x : sd["formats"].a) raw_fmts.push_back(x);
            if (sd["adaptiveFormats"].is_arr()) for (const auto& x : sd["adaptiveFormats"].a) raw_fmts.push_back(x);

            std::vector<MediaFormat> parsed;
            for (const auto& f : raw_fmts) {
                std::string furl = f["url"].str();
                if (furl.empty()) continue;
                MediaFormat mf;
                mf.id = std::to_string(f["itag"].i64());
                mf.url = furl;
                mf.proto = "http";
                std::string mime = f["mimeType"].str("video/mp4");
                bool is_aud = mime.rfind("audio/", 0) == 0;
                bool is_webm = mime.find("webm") != std::string::npos;
                mf.ext = is_webm ? "webm" : (is_aud ? "m4a" : "mp4");
                auto cq1 = mime.find("codecs=\"");
                std::string cstr = (cq1 != std::string::npos) ? mime.substr(cq1 + 8, mime.find('"', cq1 + 8) - (cq1 + 8)) : "";
                auto comma = cstr.find(',');
                if (is_aud) { mf.vcodec = "none"; mf.acodec = cstr.empty() ? "mp4a.40.2" : cstr; }
                else if (comma != std::string::npos) { mf.vcodec = cstr.substr(0, comma); mf.acodec = strutil::trim(cstr.substr(comma + 1)); }
                else { mf.vcodec = cstr.empty() ? "avc1" : cstr; mf.acodec = "none"; }

                mf.width = (int)f["width"].i64();
                mf.height = (int)f["height"].i64();
                mf.fps = f["fps"].dbl();
                mf.bitrate = f.has("averageBitrate") ? f["averageBitrate"].i64() : f["bitrate"].i64();
                mf.filesize = f["contentLength"].i64();
                mf.quality_label = f["qualityLabel"].str();
                mf.headers["User-Agent"] = prof.ua;
                if (f["indexRange"].is_obj()) {
                    mf.index_range = {f["indexRange"]["start"].i64(), f["indexRange"]["end"].i64()};
                }
                parsed.push_back(std::move(mf));
            }

            if (!parsed.empty()) {
                const MediaFormat* probe = &parsed[0];
                for (const auto& pf : parsed) if (pf.filesize > 2000000) { probe = &pf; break; }
                if (verify_tail_playable(client, probe->url, probe->filesize, prof.ua)) {
                    chosen_resp = resp;
                    chosen_fmts = std::move(parsed);
                    break;
                }
            } else if (!hls_manifest.empty()) {
                chosen_resp = resp;
                break;
            }
        }

        const Json& meta_r = chosen_resp.is_obj() ? chosen_resp : watch_ipr;
        if (!meta_r.is_obj()) throw std::runtime_error("YouTube player request failed");

        const Json& vd = meta_r.has("videoDetails") ? meta_r["videoDetails"] : watch_ipr["videoDetails"];
        const Json& mf_r = watch_ipr.has("microformat") ? watch_ipr["microformat"]["playerMicroformatRenderer"] : meta_r["microformat"]["playerMicroformatRenderer"];

        MediaInfo info;
        info.id = vid;
        info.title = vd["title"].str(vid);
        info.site = "YouTube";
        info.webpage_url = "https://www.youtube.com/watch?v=" + vid;
        info.author = vd["author"].str();
        info.description = vd["shortDescription"].str();
        info.duration = vd["lengthSeconds"].dbl();
        info.is_live = vd["isLiveContent"].boolean() && (vd["isLive"].boolean() || info.duration == 0.0);
        info.upload_date = mf_r["publishDate"].str().substr(0, 10);
        info.thumbnail = "https://i.ytimg.com/vi/" + vid + "/maxresdefault.jpg";
        info.formats = std::move(chosen_fmts);

        if ((info.is_live || info.formats.empty()) && !hls_manifest.empty()) {
            auto hfmts = HLSEngine::extract_formats(client, hls_manifest, {{"User-Agent", hls_ua}}, "hls");
            for (auto& hf : hfmts) { hf.is_live = info.is_live; info.formats.push_back(std::move(hf)); }
        }
        if (info.formats.empty()) throw std::runtime_error("YouTube: " + (last_reason.empty() ? "No playable non-DRM streams" : last_reason));

        const Json& caps = watch_ipr.has("captions") ? watch_ipr["captions"] : meta_r["captions"];
        const Json& tlist = caps["playerCaptionsTracklistRenderer"]["captionTracks"];
        if (tlist.is_arr()) {
            for (const auto& ct : tlist.a) {
                std::string burl = ct["baseUrl"].str();
                std::string lang = ct["languageCode"].str();
                if (burl.empty() || lang.empty()) continue;
                if (burl.find("fmt=") == std::string::npos) burl += "&fmt=vtt";
                info.subtitles.push_back({lang, ct["name"]["simpleText"].str(lang), burl, "vtt", ct["kind"].str() == "asr"});
            }
        }
        info.chapters = SponsorAndSubs::chapters_from_description(info.description, info.duration);
        return info;
    }
};

// MARK: - Unified 35-Site Extractor Registry

class ExtractorRegistry {
public:
    static std::vector<std::string> site_names() {
        return {
            "9GAG", "Bandcamp", "Bilibili", "Bluesky", "Coub", "Dailymotion", "Douyin",
            "Facebook", "GitHub", "Imgur", "Instagram", "Internet Archive", "Kick",
            "Kuaishou", "Loom", "Mastodon", "Mixcloud", "Odysee", "PeerTube", "Pinterest",
            "Reddit", "Rumble", "SoundCloud", "Streamable", "TED", "Threads", "TikTok",
            "Tumblr", "Twitch", "VK", "Vimeo", "Weibo", "X", "Xiaohongshu", "YouTube"
        };
    }

    static MediaInfo extract(const std::string& raw_input, const HTTPClient& client) {
        std::string in = strutil::trim(raw_input);
        if (in.rfind("ytsearch:", 0) == 0) return YouTubeExtractor::search(in.substr(9), client);
        if (in.find("://") == std::string::npos) {
            if (in.find('.') != std::string::npos && in.find(' ') == std::string::npos) in = "https://" + in;
            else return YouTubeExtractor::search(in, client);
        }
        ParsedURL u = ParsedURL::parse(in);

        // Direct file / HLS / DASH check
        auto dot = u.path.rfind('.');
        std::string pext = (dot != std::string::npos) ? strutil::to_lower(u.path.substr(dot + 1)) : "";
        if (pext == "m3u8") {
            MediaInfo info; info.id = "hls"; info.title = "HLS Stream"; info.site = u.host; info.webpage_url = in;
            info.formats = HLSEngine::extract_formats(client, in);
            for (const auto& f : info.formats) if (f.is_live) info.is_live = true;
            return info;
        }
        if (pext == "mp4" || pext == "m4a" || pext == "webm" || pext == "mp3" || pext == "wav" || pext == "flac") {
            bool aud = (pext == "m4a" || pext == "mp3" || pext == "wav" || pext == "flac");
            auto sl = u.path.rfind('/');
            std::string stem = (sl == std::string::npos) ? u.path : u.path.substr(sl + 1);
            if (auto d2 = stem.rfind('.'); d2 != std::string::npos) stem.resize(d2);
            MediaInfo info; info.id = stem.empty() ? "direct" : stem; info.title = url_decode(info.id); info.site = u.host; info.webpage_url = in;
            MediaFormat f; f.id = "direct-" + pext; f.url = in; f.ext = pext; f.vcodec = aud ? "none" : "avc1"; f.acodec = pext == "mp3" ? "mp3" : "mp4a";
            info.formats.push_back(f);
            return info;
        }

        // 1. YouTube
        if (strutil::host_matches(u, {"youtube.com", "youtu.be", "youtube-nocookie.com"})) {
            return YouTubeExtractor::extract(u, in, client);
        }

        // 2. SoundCloud
        if (strutil::host_matches(u, {"soundcloud.com", "on.soundcloud.com"})) {
            auto pr = client.fetch(in);
            std::string html = pr.text();
            std::string fin_u = pr.final_url.empty() ? in : pr.final_url;
            std::string cid = strutil::find_json_field(html, "client_id");
            if (cid.size() != 32) {
                for (const auto& js_u : strutil::scan_media_urls(html, ".js")) {
                    if (js_u.find("sndcdn.com/assets/") == std::string::npos) continue;
                    auto jr = client.fetch(js_u, "GET", {}, "", false);
                    auto p = jr.text().find("client_id:\"");
                    if (p != std::string::npos && p + 43 <= jr.text().size()) {
                        cid = jr.text().substr(p + 11, 32);
                        break;
                    }
                }
            }
            if (cid.empty()) throw std::runtime_error("Could not find SoundCloud client_id");
            auto rr = client.fetch("https://api-v2.soundcloud.com/resolve?url=" + url_encode(fin_u) + "&client_id=" + cid);
            Json res = Json::parse(rr.text());
            MediaInfo info;
            info.id = std::to_string(res["id"].i64());
            info.title = res["title"].str("SoundCloud");
            info.site = "SoundCloud";
            info.webpage_url = fin_u;
            info.author = res["user"]["username"].str();
            info.duration = res["duration"].dbl() / 1000.0;
            info.upload_date = res["created_at"].str().substr(0, 10);
            info.thumbnail = res["artwork_url"].str();
            for (size_t p = 0; (p = info.thumbnail.find("-large.", p)) != std::string::npos;) info.thumbnail.replace(p, 7, "-t500x500.");

            if (res["kind"].str() == "playlist" && res["tracks"].is_arr()) {
                for (const auto& t : res["tracks"].a) {
                    if (!t["permalink_url"].str().empty())
                        info.entries.push_back({std::to_string(t["id"].i64()), t["title"].str("Track"), t["permalink_url"].str(), t["duration"].dbl() / 1000.0, "", ""});
                }
                return info;
            }
            std::string tauth = res["track_authorization"].str();
            if (res["media"]["transcodings"].is_arr()) {
                for (const auto& tc : res["media"]["transcodings"].a) {
                    std::string pr_s = tc["format"]["protocol"].str();
                    if (pr_s.find("encrypted") != std::string::npos) continue;
                    std::string lu = tc["url"].str() + "?client_id=" + cid + (tauth.empty() ? "" : "&track_authorization=" + tauth);
                    Json lj = Json::parse(client.fetch(lu).text());
                    std::string au = lj["url"].str();
                    if (au.empty()) continue;
                    bool opus = tc["format"]["mime_type"].str().find("opus") != std::string::npos;
                    MediaFormat mf;
                    mf.id = pr_s + "-" + (opus ? "opus" : "mp3");
                    mf.url = au;
                    mf.ext = opus ? "opus" : "mp3";
                    mf.proto = (pr_s.find("hls") != std::string::npos || au.find(".m3u8") != std::string::npos) ? "hls" : "http";
                    mf.vcodec = "none";
                    mf.acodec = opus ? "opus" : "mp3";
                    mf.bitrate = opus ? 160000 : 128000;
                    mf.quality_label = opus ? "Audio (OPUS)" : "Audio (MP3)";
                    info.formats.push_back(std::move(mf));
                }
            }
            if (info.formats.empty()) throw std::runtime_error("No downloadable SoundCloud streams");
            return info;
        }

        // 3. Vimeo
        if (strutil::host_matches(u, {"vimeo.com"})) {
            std::string vid;
            for (size_t i = 0; i < u.path.size(); ++i) {
                if (std::isdigit((unsigned char)u.path[i])) {
                    size_t j = i;
                    while (j < u.path.size() && std::isdigit((unsigned char)u.path[j])) ++j;
                    if (j - i >= 6) { vid = u.path.substr(i, j - i); break; }
                    i = j;
                }
            }
            if (vid.empty()) throw std::runtime_error("Not a Vimeo video URL");
            auto cr = client.fetch("https://player.vimeo.com/video/" + vid + "/config", "GET", {{"Referer", "https://vimeo.com/"}});
            Json cfg = Json::parse(cr.text());
            MediaInfo info; info.id = vid; info.title = cfg["video"]["title"].str("Vimeo " + vid); info.site = "Vimeo"; info.webpage_url = in;
            info.author = cfg["video"]["owner"]["name"].str(); info.duration = cfg["video"]["duration"].dbl();
            info.thumbnail = cfg["video"]["thumbs"]["base"].str();
            bool saw_drm = false;
            const Json& files = cfg["request"]["files"];
            if (files["progressive"].is_arr()) {
                for (const auto& p : files["progressive"].a) {
                    MediaFormat f; f.id = "http-" + p["quality"].str(); f.url = p["url"].str(); f.ext = "mp4";
                    f.vcodec = "avc1"; f.acodec = "mp4a"; f.width = (int)p["width"].i64(); f.height = (int)p["height"].i64();
                    f.headers["Referer"] = "https://vimeo.com/";
                    if (!f.url.empty()) info.formats.push_back(std::move(f));
                }
            }
            if (files["hls"]["cdns"].is_obj()) {
                for (const auto& [_, cv] : files["hls"]["cdns"].o) {
                    std::string m3u8 = cv["url"].str(cv["avc_url"].str());
                    if (m3u8.find("/drm/") != std::string::npos) { saw_drm = true; continue; }
                    if (!m3u8.empty()) {
                        auto hf = HLSEngine::extract_formats(client, m3u8, {{"Referer", "https://vimeo.com/"}});
                        for (auto& x : hf) info.formats.push_back(std::move(x));
                        break;
                    }
                }
            }
            if (info.formats.empty() && saw_drm) info.is_drm = true;
            return info;
        }

        // 4. X / Twitter
        if (strutil::host_matches(u, {"x.com", "twitter.com", "vxtwitter.com", "fxtwitter.com", "fixupx.com"})) {
            auto st = u.path.find("/status/");
            if (st != std::string::npos) {
                size_t a = st + 8, b = a;
                while (b < u.path.size() && std::isdigit((unsigned char)u.path[b])) ++b;
                std::string tid = u.path.substr(a, b - a);
                auto vxr = client.fetch("https://api.vxtwitter.com/Twitter/status/" + tid, "GET", {}, "", false);
                Json vx = Json::parse(vxr.text());
                if (vx["media_extended"].is_arr()) {
                    MediaInfo info; info.id = tid; info.title = vx["text"].str("X " + tid).substr(0, 100); info.site = "X";
                    info.webpage_url = "https://x.com/i/status/" + tid; info.author = vx["user_screen_name"].str();
                    for (size_t i = 0; i < vx["media_extended"].a.size(); ++i) {
                        const auto& m = vx["media_extended"].at(i);
                        if (m["type"].str() == "video" || m["type"].str() == "gif") {
                            MediaFormat f; f.id = "mp4-" + std::to_string(i); f.url = m["url"].str(); f.ext = "mp4";
                            f.vcodec = "avc1"; f.acodec = "mp4a"; f.width = (int)m["size"]["width"].i64(); f.height = (int)m["size"]["height"].i64();
                            if (info.thumbnail.empty()) info.thumbnail = m["thumbnail_url"].str();
                            if (!f.url.empty()) info.formats.push_back(std::move(f));
                        }
                    }
                    if (!info.formats.empty()) return info;
                }
            }
        }

        // 5. Reddit
        if (strutil::host_matches(u, {"reddit.com", "redd.it"})) {
            auto pr = client.fetch(in);
            ParsedURL fin = ParsedURL::parse(pr.final_url.empty() ? in : pr.final_url);
            std::string p = fin.path;
            while (!p.empty() && p.back() == '/') p.pop_back();
            auto jr = client.fetch("https://www.reddit.com" + p + ".json?raw_json=1", "GET", {{"Accept", "application/json"}});
            Json root = Json::parse(jr.text());
            if (root.is_arr() && !root.a.empty()) {
                Json post = root.at(0)["data"]["children"].at(0)["data"];
                if (post["crosspost_parent_list"].is_arr() && !post["crosspost_parent_list"].a.empty())
                    post = post["crosspost_parent_list"].at(0);
                Json rv = post["secure_media"]["reddit_video"];
                if (!rv.is_obj()) rv = post["preview"]["reddit_video_preview"];
                if (rv.is_obj()) {
                    MediaInfo info; info.id = post["id"].str("reddit"); info.title = post["title"].str("Reddit Video");
                    info.site = "Reddit"; info.webpage_url = pr.final_url; info.author = post["author"].str(); info.duration = rv["duration"].dbl();
                    if (!rv["hls_url"].str().empty()) info.formats = HLSEngine::extract_formats(client, rv["hls_url"].str());
                    if (!rv["fallback_url"].str().empty()) {
                        MediaFormat fb; fb.id = "fallback"; fb.url = rv["fallback_url"].str(); fb.ext = "mp4"; fb.vcodec = "avc1"; fb.acodec = "none"; fb.height = (int)rv["height"].i64();
                        info.formats.push_back(fb);
                    }
                    if (!info.formats.empty()) return info;
                }
            }
        }

        // 6. Bluesky
        if (strutil::host_matches(u, {"bsky.app"})) {
            auto pp = u.path.find("/profile/");
            auto po = u.path.find("/post/");
            if (pp != std::string::npos && po != std::string::npos) {
                std::string handle = u.path.substr(pp + 9, po - (pp + 9));
                std::string rkey = u.path.substr(po + 6);
                std::string at_uri = url_encode("at://" + handle + "/app.bsky.feed.post/" + rkey);
                Json root = Json::parse(client.fetch("https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?depth=0&parentHeight=0&uri=" + at_uri, "GET", {}, "", false).text());
                Json post = root["thread"]["post"];
                Json media = post["embed"].has("media") ? post["embed"]["media"] : post["embed"];
                std::string pl = media["playlist"].str();
                if (!pl.empty()) {
                    MediaInfo info; info.id = rkey; info.title = post["record"]["text"].str("Bluesky " + rkey).substr(0, 100);
                    info.site = "Bluesky"; info.webpage_url = in; info.author = handle; info.thumbnail = media["thumbnail"].str();
                    info.formats = HLSEngine::extract_formats(client, pl);
                    return info;
                }
            }
        }

        // 7. Bilibili
        if (strutil::host_matches(u, {"bilibili.com", "b23.tv"})) {
            auto pr = client.fetch(in);
            ParsedURL fin = ParsedURL::parse(pr.final_url.empty() ? in : pr.final_url);
            auto bv = fin.path.find("BV");
            if (bv != std::string::npos && bv + 12 <= fin.path.size()) {
                std::string bvid = fin.path.substr(bv, 12);
                std::map<std::string, std::string> bh = {{"Referer", "https://www.bilibili.com/"}};
                Json v = Json::parse(client.fetch("https://api.bilibili.com/x/web-interface/view?bvid=" + bvid, "GET", bh).text())["data"];
                int64_t cid = v["cid"].i64();
                Json pd = Json::parse(client.fetch("https://api.bilibili.com/x/player/playurl?bvid=" + bvid + "&cid=" + std::to_string(cid) + "&qn=120&fnval=4048&fourk=1", "GET", bh).text())["data"];
                MediaInfo info; info.id = bvid; info.title = v["title"].str(bvid); info.site = "Bilibili"; info.webpage_url = fin.origin() + fin.path_and_query;
                info.author = v["owner"]["name"].str(); info.duration = v["duration"].dbl(); info.thumbnail = v["pic"].str();
                for (const auto& vf : pd["dash"]["video"].a) {
                    MediaFormat f; f.id = "v-" + std::to_string(vf["id"].i64()); f.url = vf["baseUrl"].str(vf["base_url"].str()); f.ext = "mp4";
                    f.vcodec = vf["codecs"].str("avc1"); f.acodec = "none"; f.width = (int)vf["width"].i64(); f.height = (int)vf["height"].i64(); f.bitrate = vf["bandwidth"].i64(); f.headers = bh;
                    if (!f.url.empty()) info.formats.push_back(std::move(f));
                }
                for (const auto& af : pd["dash"]["audio"].a) {
                    MediaFormat f; f.id = "a-" + std::to_string(af["id"].i64()); f.url = af["baseUrl"].str(af["base_url"].str()); f.ext = "m4a";
                    f.vcodec = "none"; f.acodec = "mp4a.40.2"; f.bitrate = af["bandwidth"].i64(); f.headers = bh;
                    if (!f.url.empty()) info.formats.push_back(std::move(f));
                }
                if (!info.formats.empty()) return info;
            }
        }

        // 8. Twitch & Kick & Streamable & Dailymotion & Internet Archive
        if (strutil::host_matches(u, {"streamable.com"})) {
            std::string code = u.path.substr(u.path.rfind('/') + 1);
            Json obj = Json::parse(client.fetch("https://api.streamable.com/videos/" + code).text());
            if (obj["files"].is_obj()) {
                MediaInfo info; info.id = code; info.title = obj["title"].str("Streamable " + code); info.site = "Streamable"; info.webpage_url = in; info.duration = obj["duration"].dbl();
                for (const auto& [k, fv] : obj["files"].o) {
                    std::string fu = fv["url"].str();
                    if (fu.rfind("//", 0) == 0) fu = "https:" + fu;
                    if (!fu.empty()) {
                        MediaFormat f; f.id = k; f.url = fu; f.ext = "mp4"; f.vcodec = "avc1"; f.acodec = "mp4a"; f.height = (int)fv["height"].i64(); f.filesize = fv["size"].i64();
                        info.formats.push_back(f);
                    }
                }
                if (!info.formats.empty()) return info;
            }
        }
        if (strutil::host_matches(u, {"dailymotion.com", "dai.ly"})) {
            std::string vid = (u.host == "dai.ly") ? u.path.substr(1) : (u.path.find("/video/") != std::string::npos ? u.path.substr(u.path.find("/video/") + 7) : "");
            if (auto sl = vid.find('/'); sl != std::string::npos) vid.resize(sl);
            if (!vid.empty()) {
                Json md = Json::parse(client.fetch("https://www.dailymotion.com/player/metadata/video/" + vid).text());
                std::string m3u8 = md["qualities"]["auto"].at(0)["url"].str();
                if (!m3u8.empty()) {
                    MediaInfo info; info.id = vid; info.title = md["title"].str(vid); info.site = "Dailymotion"; info.webpage_url = in; info.duration = md["duration"].dbl();
                    info.formats = HLSEngine::extract_formats(client, m3u8);
                    return info;
                }
            }
        }
        if (strutil::host_matches(u, {"archive.org"})) {
            for (const char* pfx : {"/details/", "/download/", "/embed/"}) {
                if (u.path.rfind(pfx, 0) == 0) {
                    std::string iid = u.path.substr(std::strlen(pfx));
                    if (auto sl = iid.find('/'); sl != std::string::npos) iid.resize(sl);
                    Json mr = Json::parse(client.fetch("https://archive.org/metadata/" + iid).text());
                    if (mr["files"].is_arr()) {
                        MediaInfo info; info.id = iid; info.title = mr["metadata"]["title"].str(iid); info.site = "Internet Archive"; info.webpage_url = in;
                        for (const auto& f : mr["files"].a) {
                            std::string fn = f["name"].str();
                            auto d = fn.rfind('.');
                            std::string e = d != std::string::npos ? strutil::to_lower(fn.substr(d + 1)) : "";
                            if (e == "mp4" || e == "m4a" || e == "mp3" || e == "webm" || e == "flac") {
                                MediaFormat mf; mf.id = fn; mf.url = "https://archive.org/download/" + iid + "/" + url_encode(fn);
                                mf.ext = e; mf.vcodec = (e == "mp4" || e == "webm") ? "avc1" : "none"; mf.acodec = e == "mp3" ? "mp3" : "mp4a";
                                mf.filesize = f["size"].i64();
                                info.formats.push_back(std::move(mf));
                            }
                        }
                        if (!info.formats.empty()) return info;
                    }
                }
            }
        }
        if (strutil::host_matches(u, {"bandcamp.com"})) {
            auto r = client.fetch(in);
            std::string html = r.text();
            auto dt = html.find("data-tralbum=\"");
            if (dt != std::string::npos) {
                auto eq = html.find('"', dt + 14);
                Json tr = Json::parse(strutil::decode_html(html.substr(dt + 14, eq - (dt + 14))));
                if (tr["trackinfo"].is_arr() && !tr["trackinfo"].a.empty()) {
                    const auto& t0 = tr["trackinfo"].at(0);
                    std::string mp3 = t0["file"]["mp3-128"].str();
                    if (!mp3.empty()) {
                        if (mp3.rfind("//", 0) == 0) mp3 = "https:" + mp3;
                        MediaInfo info; info.id = std::to_string(t0["id"].i64()); info.title = t0["title"].str("Bandcamp"); info.site = "Bandcamp";
                        info.webpage_url = in; info.author = tr["artist"].str(); info.duration = t0["duration"].dbl();
                        MediaFormat f; f.id = "mp3-128"; f.url = mp3; f.ext = "mp3"; f.vcodec = "none"; f.acodec = "mp3"; f.bitrate = 128000;
                        info.formats.push_back(f);
                        return info;
                    }
                }
            }
        }

        // All remaining named sites route through specialized headers + GenericExtractor
        std::string site_label;
        const std::pair<const char*, const char*> domain_map[] = {
            {"tiktok.com","TikTok"}, {"instagram.com","Instagram"}, {"facebook.com","Facebook"}, {"fb.watch","Facebook"},
            {"threads.net","Threads"}, {"threads.com","Threads"}, {"mixcloud.com","Mixcloud"}, {"rumble.com","Rumble"},
            {"odysee.com","Odysee"}, {"imgur.com","Imgur"}, {"tumblr.com","Tumblr"}, {"pinterest.com","Pinterest"},
            {"loom.com","Loom"}, {"ted.com","TED"}, {"vk.com","VK"}, {"vkvideo.ru","VK"}, {"douyin.com","Douyin"},
            {"kuaishou.com","Kuaishou"}, {"weibo.com","Weibo"}, {"xiaohongshu.com","Xiaohongshu"}, {"xhslink.com","Xiaohongshu"},
            {"github.com","GitHub"}, {"coub.com","Coub"}, {"9gag.com","9GAG"}, {"twitch.tv","Twitch"}, {"kick.com","Kick"}
        };
        for (auto [dom, lbl] : domain_map) {
            if (strutil::host_matches(u, {dom})) { site_label = lbl; break; }
        }
        return GenericExtractor::extract(u, in, client, site_label);
    }
};

} // namespace ubit
