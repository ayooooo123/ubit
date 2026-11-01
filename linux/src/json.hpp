#pragma once
#include <string>
#include <vector>
#include <map>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace ubit {

struct Json {
    enum Type { NUL, BOOL, NUM, STR, ARR, OBJ } type = NUL;
    bool b = false;
    double n = 0.0;
    std::string s;
    std::vector<Json> a;
    std::map<std::string, Json> o;

    Json() = default;
    Json(std::nullptr_t) : type(NUL) {}
    Json(bool v) : type(BOOL), b(v) {}
    Json(int v) : type(NUM), n(v) {}
    Json(int64_t v) : type(NUM), n((double)v) {}
    Json(size_t v) : type(NUM), n((double)v) {}
    Json(double v) : type(NUM), n(v) {}
    Json(const char* v) : type(STR), s(v ? v : "") {}
    Json(std::string v) : type(STR), s(std::move(v)) {}
    Json(std::vector<Json> v) : type(ARR), a(std::move(v)) {}
    Json(std::map<std::string, Json> v) : type(OBJ), o(std::move(v)) {}

    static Json array() { Json j; j.type = ARR; return j; }
    static Json object() { Json j; j.type = OBJ; return j; }

    bool is_null() const { return type == NUL; }
    bool is_obj() const { return type == OBJ; }
    bool is_arr() const { return type == ARR; }
    bool is_str() const { return type == STR; }
    bool is_num() const { return type == NUM; }
    bool is_bool() const { return type == BOOL; }

    const Json& operator[](const std::string& k) const {
        static const Json empty;
        if (type != OBJ) return empty;
        auto it = o.find(k);
        return it == o.end() ? empty : it->second;
    }
    Json& operator[](const std::string& k) {
        if (type != OBJ) { type = OBJ; o.clear(); }
        return o[k];
    }
    const Json& at(size_t idx) const {
        static const Json empty;
        return (type == ARR && idx < a.size()) ? a[idx] : empty;
    }
    bool has(const std::string& k) const {
        return type == OBJ && o.find(k) != o.end() && !o.at(k).is_null();
    }
    std::string str(const std::string& def = "") const {
        if (type == STR) return s;
        if (type == NUM) {
            if (std::floor(n) == n && std::abs(n) < 1e15) return std::to_string((int64_t)n);
            return std::to_string(n);
        }
        if (type == BOOL) return b ? "true" : "false";
        return def;
    }
    int64_t i64(int64_t def = 0) const {
        if (type == NUM) return (int64_t)n;
        if (type == STR && !s.empty()) {
            char* end = nullptr;
            long long v = std::strtoll(s.c_str(), &end, 10);
            if (end != s.c_str()) return (int64_t)v;
        }
        return def;
    }
    double dbl(double def = 0.0) const {
        if (type == NUM) return n;
        if (type == STR && !s.empty()) {
            char* end = nullptr;
            double v = std::strtod(s.c_str(), &end);
            if (end != s.c_str()) return v;
        }
        return def;
    }
    bool boolean(bool def = false) const {
        if (type == BOOL) return b;
        if (type == STR) return s == "true" || s == "1";
        return def;
    }

    static void append_utf8(std::string& out, uint32_t cp) {
        if (cp <= 0x7f) out.push_back((char)cp);
        else if (cp <= 0x7ff) {
            out.push_back((char)(0xc0 | (cp >> 6)));
            out.push_back((char)(0x80 | (cp & 0x3f)));
        } else if (cp <= 0xffff) {
            out.push_back((char)(0xe0 | (cp >> 12)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3f)));
            out.push_back((char)(0x80 | (cp & 0x3f)));
        } else {
            out.push_back((char)(0xf0 | (cp >> 18)));
            out.push_back((char)(0x80 | ((cp >> 12) & 0x3f)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3f)));
            out.push_back((char)(0x80 | (cp & 0x3f)));
        }
    }

    struct Parser {
        const std::string& src;
        size_t p = 0;

        void ws() {
            while (p < src.size() && (unsigned char)src[p] <= 0x20) ++p;
        }
        uint32_t hex4() {
            uint32_t v = 0;
            for (int i = 0; i < 4 && p < src.size(); ++i, ++p) {
                char c = src[p];
                v <<= 4;
                if (c >= '0' && c <= '9') v |= (c - '0');
                else if (c >= 'a' && c <= 'f') v |= (c - 'a' + 10);
                else if (c >= 'A' && c <= 'F') v |= (c - 'A' + 10);
            }
            return v;
        }
        std::string parse_str() {
            char quote = src[p++];
            std::string out;
            while (p < src.size()) {
                char c = src[p++];
                if (c == quote) return out;
                if (c == '\\' && p < src.size()) {
                    char e = src[p++];
                    switch (e) {
                        case '"': out.push_back('"'); break;
                        case '\'': out.push_back('\''); break;
                        case '\\': out.push_back('\\'); break;
                        case '/': out.push_back('/'); break;
                        case 'b': out.push_back('\b'); break;
                        case 'f': out.push_back('\f'); break;
                        case 'n': out.push_back('\n'); break;
                        case 'r': out.push_back('\r'); break;
                        case 't': out.push_back('\t'); break;
                        case 'u': {
                            uint32_t u1 = hex4();
                            if (u1 >= 0xd800 && u1 <= 0xdbff && p + 1 < src.size() && src[p] == '\\' && src[p+1] == 'u') {
                                p += 2;
                                uint32_t u2 = hex4();
                                if (u2 >= 0xdc00 && u2 <= 0xdfff) {
                                    u1 = 0x10000 + (((u1 - 0xd800) << 10) | (u2 - 0xdc00));
                                }
                            }
                            append_utf8(out, u1);
                            break;
                        }
                        default: out.push_back(e); break;
                    }
                } else {
                    out.push_back(c);
                }
            }
            return out;
        }
        Json val() {
            ws();
            if (p >= src.size()) return Json();
            char c = src[p];
            if (c == '"' || c == '\'') return Json(parse_str());
            if (c == '{') {
                ++p;
                Json j = Json::object();
                ws();
                if (p < src.size() && src[p] == '}') { ++p; return j; }
                while (p < src.size()) {
                    ws();
                    if (p < src.size() && src[p] == '}') { ++p; break; }
                    std::string k = (src[p] == '"' || src[p] == '\'') ? parse_str() : "";
                    ws();
                    if (p < src.size() && src[p] == ':') ++p;
                    j.o[std::move(k)] = val();
                    ws();
                    if (p < src.size() && src[p] == ',') ++p;
                    else if (p < src.size() && src[p] == '}') { ++p; break; }
                    else break;
                }
                return j;
            }
            if (c == '[') {
                ++p;
                Json j = Json::array();
                ws();
                if (p < src.size() && src[p] == ']') { ++p; return j; }
                while (p < src.size()) {
                    ws();
                    if (p < src.size() && src[p] == ']') { ++p; break; }
                    j.a.push_back(val());
                    ws();
                    if (p < src.size() && src[p] == ',') ++p;
                    else if (p < src.size() && src[p] == ']') { ++p; break; }
                    else break;
                }
                return j;
            }
            if (src.compare(p, 4, "true") == 0) { p += 4; return Json(true); }
            if (src.compare(p, 5, "false") == 0) { p += 5; return Json(false); }
            if (src.compare(p, 4, "null") == 0) { p += 4; return Json(); }
            if (src.compare(p, 9, "undefined") == 0) { p += 9; return Json(); }
            char* end = nullptr;
            double num = std::strtod(src.c_str() + p, &end);
            if (end && end > src.c_str() + p) {
                p = (size_t)(end - src.c_str());
                return Json(num);
            }
            ++p;
            return Json();
        }
    };

    static Json parse(const std::string& text) {
        Parser pr{text, 0};
        return pr.val();
    }

    static void escape_into(std::string& out, const std::string& s) {
        out.push_back('"');
        for (unsigned char c : s) {
            switch (c) {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\b': out += "\\b"; break;
                case '\f': out += "\\f"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default:
                    if (c < 0x20) {
                        char buf[8];
                        std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                        out += buf;
                    } else {
                        out.push_back((char)c);
                    }
            }
        }
        out.push_back('"');
    }

    void dump_into(std::string& out, int indent = -1, int depth = 0) const {
        auto pad = [&](int d) {
            if (indent > 0) out.append((size_t)(d * indent), ' ');
        };
        switch (type) {
            case NUL: out += "null"; break;
            case BOOL: out += (b ? "true" : "false"); break;
            case NUM: {
                if (!std::isfinite(n)) { out += "0"; break; }
                if (std::floor(n) == n && std::abs(n) < 9e15) {
                    out += std::to_string((int64_t)n);
                } else {
                    char buf[64];
                    std::snprintf(buf, sizeof(buf), "%.6g", n);
                    out += buf;
                }
                break;
            }
            case STR: escape_into(out, s); break;
            case ARR: {
                if (a.empty()) { out += "[]"; break; }
                out.push_back('[');
                for (size_t i = 0; i < a.size(); ++i) {
                    if (i) out.push_back(',');
                    if (indent > 0) { out.push_back('\n'); pad(depth + 1); }
                    a[i].dump_into(out, indent, depth + 1);
                }
                if (indent > 0) { out.push_back('\n'); pad(depth); }
                out.push_back(']');
                break;
            }
            case OBJ: {
                if (o.empty()) { out += "{}"; break; }
                out.push_back('{');
                bool first = true;
                for (const auto& [k, v] : o) {
                    if (!first) out.push_back(',');
                    first = false;
                    if (indent > 0) { out.push_back('\n'); pad(depth + 1); }
                    escape_into(out, k);
                    out.push_back(':');
                    if (indent > 0) out.push_back(' ');
                    v.dump_into(out, indent, depth + 1);
                }
                if (indent > 0) { out.push_back('\n'); pad(depth); }
                out.push_back('}');
                break;
            }
        }
    }

    std::string dump(int indent = -1) const {
        std::string out;
        dump_into(out, indent, 0);
        return out;
    }
};

} // namespace ubit
