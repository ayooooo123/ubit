#pragma once
#include <string>
#include <vector>
#include <map>
#include <functional>
#include <mutex>
#include <memory>
#include <utility>
#include <thread>
#include <chrono>
#include <atomic>
#include <stdexcept>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <cctype>
#include <algorithm>
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

namespace ubit {

// MARK: - Runtime dlopen OpenSSL (libssl.so.3 / 1.1 + libcrypto.so.3 / 1.1) & zlib (libz.so.1)
// Avoids compile-time -dev header dependencies and works across Debian, Ubuntu, Fedora, Arch, RHEL, Alpine-glibc, Distroless.

struct DynRuntime {
    // libssl
    const void* (*TLS_client_method_fn)() = nullptr;
    void* (*SSL_CTX_new_fn)(const void*) = nullptr;
    void (*SSL_CTX_free_fn)(void*) = nullptr;
    void* (*SSL_new_fn)(void*) = nullptr;
    void (*SSL_free_fn)(void*) = nullptr;
    int (*SSL_set_fd_fn)(void*, int) = nullptr;
    long (*SSL_ctrl_fn)(void*, int, long, void*) = nullptr;
    int (*SSL_connect_fn)(void*) = nullptr;
    int (*SSL_read_fn)(void*, void*, int) = nullptr;
    int (*SSL_write_fn)(void*, const void*, int) = nullptr;
    int (*SSL_shutdown_fn)(void*) = nullptr;

    // libcrypto EVP
    const void* (*EVP_sha256_fn)() = nullptr;
    const void* (*EVP_sha1_fn)() = nullptr;
    int (*EVP_Digest_fn)(const void*, size_t, unsigned char*, unsigned int*, const void*, void*) = nullptr;
    void* (*EVP_CIPHER_CTX_new_fn)() = nullptr;
    void (*EVP_CIPHER_CTX_free_fn)(void*) = nullptr;
    const void* (*EVP_aes_128_cbc_fn)() = nullptr;
    int (*EVP_DecryptInit_ex_fn)(void*, const void*, void*, const unsigned char*, const unsigned char*) = nullptr;
    int (*EVP_DecryptUpdate_fn)(void*, unsigned char*, int*, const unsigned char*, int) = nullptr;
    int (*EVP_DecryptFinal_ex_fn)(void*, unsigned char*, int*) = nullptr;

    // libz
    struct ZStream {
        const unsigned char* next_in;
        unsigned int avail_in;
        unsigned long total_in;
        unsigned char* next_out;
        unsigned int avail_out;
        unsigned long total_out;
        const char* msg;
        void* state;
        void* zalloc;
        void* zfree;
        void* opaque;
        int data_type;
        unsigned long adler;
        unsigned long reserved;
    };
    int (*inflateInit2_fn)(ZStream*, int, const char*, int) = nullptr;
    int (*inflate_fn)(ZStream*, int) = nullptr;
    int (*inflateEnd_fn)(ZStream*) = nullptr;

    void* ssl_ctx = nullptr;

    static DynRuntime& get() {
        static DynRuntime inst;
        return inst;
    }

    static void* dlopen_any(std::initializer_list<const char*> names, int flags) {
        std::vector<std::string> prefixes = {""};
        if (const char* pfx = std::getenv("PREFIX"); pfx && *pfx) {
            prefixes.push_back(std::string(pfx) + "/lib/");
        }
        prefixes.push_back("/data/data/com.termux/files/usr/lib/");
        prefixes.push_back("/system/lib64/");
        for (const auto& pre : prefixes) {
            for (const char* n : names) {
                std::string full = pre + n;
                if (void* h = dlopen(full.c_str(), flags)) return h;
            }
        }
        return nullptr;
    }

    DynRuntime() {
        void* h_crypto = dlopen_any({"libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so"}, RTLD_LAZY | RTLD_GLOBAL);
        void* h_ssl    = dlopen_any({"libssl.so.3", "libssl.so.1.1", "libssl.so"}, RTLD_LAZY | RTLD_GLOBAL);
        void* h_z      = dlopen_any({"libz.so.1", "libz.so"}, RTLD_LAZY | RTLD_LOCAL);
        if (h_ssl) {
            TLS_client_method_fn = (decltype(TLS_client_method_fn))dlsym(h_ssl, "TLS_client_method");
            if (!TLS_client_method_fn) TLS_client_method_fn = (decltype(TLS_client_method_fn))dlsym(h_ssl, "SSLv23_client_method");
            SSL_CTX_new_fn = (decltype(SSL_CTX_new_fn))dlsym(h_ssl, "SSL_CTX_new");
            SSL_CTX_free_fn = (decltype(SSL_CTX_free_fn))dlsym(h_ssl, "SSL_CTX_free");
            SSL_new_fn = (decltype(SSL_new_fn))dlsym(h_ssl, "SSL_new");
            SSL_free_fn = (decltype(SSL_free_fn))dlsym(h_ssl, "SSL_free");
            SSL_set_fd_fn = (decltype(SSL_set_fd_fn))dlsym(h_ssl, "SSL_set_fd");
            SSL_ctrl_fn = (decltype(SSL_ctrl_fn))dlsym(h_ssl, "SSL_ctrl");
            SSL_connect_fn = (decltype(SSL_connect_fn))dlsym(h_ssl, "SSL_connect");
            SSL_read_fn = (decltype(SSL_read_fn))dlsym(h_ssl, "SSL_read");
            SSL_write_fn = (decltype(SSL_write_fn))dlsym(h_ssl, "SSL_write");
            SSL_shutdown_fn = (decltype(SSL_shutdown_fn))dlsym(h_ssl, "SSL_shutdown");
            if (TLS_client_method_fn && SSL_CTX_new_fn) {
                ssl_ctx = SSL_CTX_new_fn(TLS_client_method_fn());
            }
        }
        if (h_crypto) {
            EVP_sha256_fn = (decltype(EVP_sha256_fn))dlsym(h_crypto, "EVP_sha256");
            EVP_sha1_fn = (decltype(EVP_sha1_fn))dlsym(h_crypto, "EVP_sha1");
            EVP_Digest_fn = (decltype(EVP_Digest_fn))dlsym(h_crypto, "EVP_Digest");
            EVP_CIPHER_CTX_new_fn = (decltype(EVP_CIPHER_CTX_new_fn))dlsym(h_crypto, "EVP_CIPHER_CTX_new");
            EVP_CIPHER_CTX_free_fn = (decltype(EVP_CIPHER_CTX_free_fn))dlsym(h_crypto, "EVP_CIPHER_CTX_free");
            EVP_aes_128_cbc_fn = (decltype(EVP_aes_128_cbc_fn))dlsym(h_crypto, "EVP_aes_128_cbc");
            EVP_DecryptInit_ex_fn = (decltype(EVP_DecryptInit_ex_fn))dlsym(h_crypto, "EVP_DecryptInit_ex");
            EVP_DecryptUpdate_fn = (decltype(EVP_DecryptUpdate_fn))dlsym(h_crypto, "EVP_DecryptUpdate");
            EVP_DecryptFinal_ex_fn = (decltype(EVP_DecryptFinal_ex_fn))dlsym(h_crypto, "EVP_DecryptFinal_ex");
        }
        if (h_z) {
            inflateInit2_fn = (decltype(inflateInit2_fn))dlsym(h_z, "inflateInit2_");
            inflate_fn = (decltype(inflate_fn))dlsym(h_z, "inflate");
            inflateEnd_fn = (decltype(inflateEnd_fn))dlsym(h_z, "inflateEnd");
        }
    }
};

inline std::string hex_encode(const unsigned char* data, size_t len) {
    static const char* lut = "0123456789abcdef";
    std::string out(len * 2, '0');
    for (size_t i = 0; i < len; ++i) {
        out[i * 2] = lut[(data[i] >> 4) & 0xf];
        out[i * 2 + 1] = lut[data[i] & 0xf];
    }
    return out;
}

inline std::string sha256_hex(const std::string& input) {
    auto& rt = DynRuntime::get();
    unsigned char md[32]{};
    unsigned int md_len = 0;
    if (rt.EVP_Digest_fn && rt.EVP_sha256_fn) {
        rt.EVP_Digest_fn(input.data(), input.size(), md, &md_len, rt.EVP_sha256_fn(), nullptr);
        return hex_encode(md, 32);
    }
    return "0000";
}

inline std::string sha1_hex(const std::string& input) {
    auto& rt = DynRuntime::get();
    unsigned char md[20]{};
    unsigned int md_len = 0;
    if (rt.EVP_Digest_fn && rt.EVP_sha1_fn) {
        rt.EVP_Digest_fn(input.data(), input.size(), md, &md_len, rt.EVP_sha1_fn(), nullptr);
        return hex_encode(md, 20);
    }
    return "";
}

inline std::vector<uint8_t> aes128_cbc_decrypt(const std::vector<uint8_t>& cipher, const std::vector<uint8_t>& key, const uint8_t iv[16]) {
    auto& rt = DynRuntime::get();
    if (key.size() != 16 || !rt.EVP_CIPHER_CTX_new_fn || !rt.EVP_aes_128_cbc_fn) return cipher;
    void* ctx = rt.EVP_CIPHER_CTX_new_fn();
    std::vector<uint8_t> out(cipher.size() + 32);
    int len1 = 0, len2 = 0;
    if (rt.EVP_DecryptInit_ex_fn(ctx, rt.EVP_aes_128_cbc_fn(), nullptr, key.data(), iv) == 1 &&
        rt.EVP_DecryptUpdate_fn(ctx, out.data(), &len1, cipher.data(), (int)cipher.size()) == 1 &&
        rt.EVP_DecryptFinal_ex_fn(ctx, out.data() + len1, &len2) == 1) {
        out.resize((size_t)(len1 + len2));
    } else {
        out = cipher;
    }
    rt.EVP_CIPHER_CTX_free_fn(ctx);
    return out;
}

inline std::vector<uint8_t> gunzip_bytes(const uint8_t* data, size_t len) {
    auto& rt = DynRuntime::get();
    if (!rt.inflateInit2_fn || len == 0) return std::vector<uint8_t>(data, data + len);
    DynRuntime::ZStream zs{};
    zs.next_in = data;
    zs.avail_in = (unsigned int)len;
    if (rt.inflateInit2_fn(&zs, 16 + 15, "1.2.11", (int)sizeof(DynRuntime::ZStream)) != 0) {
        return std::vector<uint8_t>(data, data + len);
    }
    std::vector<uint8_t> out;
    out.reserve(len * 2);
    unsigned char buf[32768];
    int ret = 0;
    do {
        zs.next_out = buf;
        zs.avail_out = sizeof(buf);
        ret = rt.inflate_fn(&zs, 0);
        size_t have = sizeof(buf) - zs.avail_out;
        if (have > 0) out.insert(out.end(), buf, buf + have);
    } while (ret == 0);
    rt.inflateEnd_fn(&zs);
    return out;
}

// MARK: - URL Parser & URL Encoding

struct ParsedURL {
    std::string scheme;
    std::string host;
    int port = 80;
    std::string path_and_query = "/";
    std::string path = "/";
    std::string query;

    static ParsedURL parse(const std::string& raw) {
        ParsedURL u;
        auto pos = raw.find("://");
        size_t host_start = 0;
        if (pos != std::string::npos) {
            u.scheme = raw.substr(0, pos);
            for (char& c : u.scheme) c = (char)std::tolower((unsigned char)c);
            host_start = pos + 3;
        } else {
            u.scheme = "https";
        }
        u.port = (u.scheme == "https") ? 443 : 80;
        auto slash = raw.find('/', host_start);
        std::string authority = (slash == std::string::npos) ? raw.substr(host_start) : raw.substr(host_start, slash - host_start);
        u.path_and_query = (slash == std::string::npos) ? "/" : raw.substr(slash);
        auto hash = u.path_and_query.find('#');
        if (hash != std::string::npos) u.path_and_query.resize(hash);
        if (u.path_and_query.empty()) u.path_and_query = "/";

        auto qpos = u.path_and_query.find('?');
        if (qpos == std::string::npos) {
            u.path = u.path_and_query;
        } else {
            u.path = u.path_and_query.substr(0, qpos);
            u.query = u.path_and_query.substr(qpos + 1);
        }

        auto at = authority.rfind('@');
        if (at != std::string::npos) authority = authority.substr(at + 1);
        auto colon = authority.rfind(':');
        if (colon != std::string::npos && authority.find(']') == std::string::npos) {
            u.host = authority.substr(0, colon);
            u.port = std::atoi(authority.c_str() + colon + 1);
        } else {
            u.host = authority;
        }
        return u;
    }

    std::string origin() const {
        bool std_port = (scheme == "https" && port == 443) || (scheme == "http" && port == 80);
        return scheme + "://" + host + (std_port ? "" : ":" + std::to_string(port));
    }

    std::string resolve(const std::string& ref) const {
        if (ref.rfind("http://", 0) == 0 || ref.rfind("https://", 0) == 0) return ref;
        if (ref.rfind("//", 0) == 0) return scheme + ":" + ref;
        if (!ref.empty() && ref[0] == '/') return origin() + ref;
        auto last_slash = path.rfind('/');
        std::string dir = (last_slash == std::string::npos) ? "/" : path.substr(0, last_slash + 1);
        return origin() + dir + ref;
    }
};

inline std::string url_encode(const std::string& s) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') out.push_back((char)c);
        else {
            out.push_back('%');
            out.push_back(hex[(c >> 4) & 0xf]);
            out.push_back(hex[c & 0xf]);
        }
    }
    return out;
}

inline std::string url_decode(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size() && std::isxdigit((unsigned char)s[i+1]) && std::isxdigit((unsigned char)s[i+2])) {
            char h[3] = {s[i+1], s[i+2], 0};
            out.push_back((char)std::strtol(h, nullptr, 16));
            i += 2;
        } else if (s[i] == '+') {
            out.push_back(' ');
        } else {
            out.push_back(s[i]);
        }
    }
    return out;
}

// MARK: - Token-Bucket Rate Limiter

class RateLimiter {
    std::mutex mu_;
    int64_t rate_bps_ = 0;
    std::chrono::steady_clock::time_point next_allowed_ = std::chrono::steady_clock::now();
public:
    explicit RateLimiter(int64_t bps = 0) : rate_bps_(bps) {}
    void consume(size_t bytes) {
        if (rate_bps_ <= 0 || bytes == 0) return;
        std::chrono::nanoseconds wait_ns(0);
        {
            std::lock_guard<std::mutex> lk(mu_);
            auto now = std::chrono::steady_clock::now();
            auto dur = std::chrono::nanoseconds((int64_t)((double)bytes * 1e9 / (double)rate_bps_));
            auto start = std::max(now, next_allowed_);
            next_allowed_ = start + dur;
            if (start > now) wait_ns = start - now;
        }
        if (wait_ns.count() > 2000000) std::this_thread::sleep_for(wait_ns);
    }
};

// MARK: - HTTP/1.1 + TLS + SOCKS5/HTTP Proxy Streaming Client

struct HTTPResponse {
    int status = 0;
    std::string final_url;
    std::map<std::string, std::string> headers; // lowercase keys
    std::vector<uint8_t> body;

    std::string text() const { return std::string(body.begin(), body.end()); }
    std::string header(const std::string& k) const {
        std::string lk = k;
        for (char& c : lk) c = (char)std::tolower((unsigned char)c);
        auto it = headers.find(lk);
        return it == headers.end() ? "" : it->second;
    }
};

struct CookieEntry {
    std::string domain;
    bool subdomains = true;
    std::string path = "/";
    bool secure = false;
    int64_t expires = 0;
    std::string name;
    std::string value;
};

class CookieVault {
    std::vector<CookieEntry> entries_;
public:
    void add(CookieEntry e) { entries_.push_back(std::move(e)); }

    static CookieVault load_netscape(const std::string& file_path) {
        CookieVault v;
        FILE* f = std::fopen(file_path.c_str(), "rb");
        if (!f) return v;
        char line[8192];
        while (std::fgets(line, sizeof(line), f)) {
            std::string s(line);
            while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
            if (s.rfind("#HttpOnly_", 0) == 0) s = s.substr(10);
            else if (s.empty() || s[0] == '#') continue;
            std::vector<std::string> cols;
            size_t start = 0;
            while (true) {
                auto tab = s.find('\t', start);
                if (tab == std::string::npos) { cols.push_back(s.substr(start)); break; }
                cols.push_back(s.substr(start, tab - start));
                start = tab + 1;
            }
            if (cols.size() >= 7) {
                v.add(CookieEntry{
                    cols[0],
                    cols[1] == "TRUE" || (!cols[0].empty() && cols[0][0] == '.'),
                    cols[2],
                    cols[3] == "TRUE",
                    std::atoll(cols[4].c_str()),
                    cols[5],
                    cols[6]
                });
            }
        }
        std::fclose(f);
        return v;
    }

    std::string header_for(const ParsedURL& u) const {
        std::string host = u.host;
        for (char& c : host) c = (char)std::tolower((unsigned char)c);
        int64_t now = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        std::string out;
        for (const auto& c : entries_) {
            std::string dom = c.domain;
            while (!dom.empty() && dom[0] == '.') dom.erase(dom.begin());
            for (char& ch : dom) ch = (char)std::tolower((unsigned char)ch);
            bool match = (host == dom) || (c.subdomains && host.size() > dom.size() && host.compare(host.size() - dom.size() - 1, dom.size() + 1, "." + dom) == 0);
            if (!match) continue;
            if (c.secure && u.scheme != "https") continue;
            if (u.path.rfind(c.path, 0) != 0) continue;
            if (c.expires > 0 && c.expires < now) continue;
            if (!out.empty()) out += "; ";
            out += c.name + "=" + c.value;
        }
        return out;
    }

    std::string value_named(const std::string& name, const std::string& dom_sub) const {
        for (const auto& c : entries_) {
            if (c.name == name && c.domain.find(dom_sub) != std::string::npos) return c.value;
        }
        return "";
    }
};

class HTTPClient {
public:
    static constexpr const char* DEFAULT_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

    CookieVault cookies;
    std::string proxy_url;
    std::string user_agent = DEFAULT_UA;
    std::map<std::string, std::string> extra_headers;
    std::shared_ptr<RateLimiter> limiter = std::make_shared<RateLimiter>(0);

private:
    struct SocketConn {
        int fd = -1;
        void* ssl = nullptr;

        ~SocketConn() { close_conn(); }
        void close_conn() {
            auto& rt = DynRuntime::get();
            if (ssl) {
                if (rt.SSL_shutdown_fn) rt.SSL_shutdown_fn(ssl);
                if (rt.SSL_free_fn) rt.SSL_free_fn(ssl);
                ssl = nullptr;
            }
            if (fd >= 0) { ::close(fd); fd = -1; }
        }
        ssize_t write_all(const void* buf, size_t len) {
            auto& rt = DynRuntime::get();
            const uint8_t* p = (const uint8_t*)buf;
            size_t sent = 0;
            while (sent < len) {
                int n = ssl ? rt.SSL_write_fn(ssl, p + sent, (int)(len - sent))
                            : (int)::send(fd, p + sent, len - sent, MSG_NOSIGNAL);
                if (n <= 0) return -1;
                sent += (size_t)n;
            }
            return (ssize_t)sent;
        }
        ssize_t read_some(void* buf, size_t cap) {
            auto& rt = DynRuntime::get();
            return ssl ? rt.SSL_read_fn(ssl, buf, (int)cap)
                       : ::recv(fd, buf, cap, 0);
        }
    };

    int dial_tcp(const std::string& host, int port) const {
        struct addrinfo hints{}, *res = nullptr;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        std::string port_s = std::to_string(port);
        if (::getaddrinfo(host.c_str(), port_s.c_str(), &hints, &res) != 0 || !res) return -1;
        int fd = -1;
        for (auto* p = res; p; p = p->ai_next) {
            fd = ::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
            if (fd < 0) continue;
            struct timeval tv{25, 0};
            ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
            int one = 1;
            ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            if (::connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
            ::close(fd);
            fd = -1;
        }
        ::freeaddrinfo(res);
        return fd;
    }

    bool open_connection(SocketConn& conn, const ParsedURL& target) const {
        if (!proxy_url.empty()) {
            ParsedURL px = ParsedURL::parse(proxy_url);
            int fd = dial_tcp(px.host, px.port);
            if (fd < 0) return false;
            conn.fd = fd;
            if (px.scheme.rfind("socks", 0) == 0) {
                // SOCKS5 domain handshake
                uint8_t greet[3] = {0x05, 0x01, 0x00};
                uint8_t gresp[2]{};
                if (::send(fd, greet, 3, MSG_NOSIGNAL) != 3 || ::recv(fd, gresp, 2, 0) != 2 || gresp[1] != 0x00) return false;
                std::vector<uint8_t> req = {0x05, 0x01, 0x00, 0x03, (uint8_t)target.host.size()};
                req.insert(req.end(), target.host.begin(), target.host.end());
                req.push_back((uint8_t)((target.port >> 8) & 0xff));
                req.push_back((uint8_t)(target.port & 0xff));
                uint8_t sresp[10]{};
                if (::send(fd, req.data(), req.size(), MSG_NOSIGNAL) != (ssize_t)req.size() || ::recv(fd, sresp, 10, 0) < 4 || sresp[1] != 0x00) return false;
            } else if (target.scheme == "https") {
                std::string connect_req = "CONNECT " + target.host + ":" + std::to_string(target.port) + " HTTP/1.1\r\nHost: " + target.host + "\r\n\r\n";
                if (::send(fd, connect_req.data(), connect_req.size(), MSG_NOSIGNAL) <= 0) return false;
                std::string hdr;
                char ch;
                while (hdr.find("\r\n\r\n") == std::string::npos && ::recv(fd, &ch, 1, 0) == 1) hdr.push_back(ch);
                if (hdr.find(" 200") == std::string::npos) return false;
            }
        } else {
            conn.fd = dial_tcp(target.host, target.port);
            if (conn.fd < 0) return false;
        }

        if (target.scheme == "https") {
            auto& rt = DynRuntime::get();
            if (!rt.ssl_ctx || !rt.SSL_new_fn) return false;
            conn.ssl = rt.SSL_new_fn(rt.ssl_ctx);
            rt.SSL_set_fd_fn(conn.ssl, conn.fd);
            // SSL_CTRL_SET_TLSEXT_HOSTNAME = 55
            if (rt.SSL_ctrl_fn) rt.SSL_ctrl_fn(conn.ssl, 55, 0, (void*)target.host.c_str());
            if (rt.SSL_connect_fn(conn.ssl) != 1) return false;
        }
        return true;
    }

public:
    /// Streams response body chunks via `on_chunk(ptr, len) -> bool` (returning false aborts early cleanly).
    HTTPResponse stream_request(
        const std::string& raw_url,
        const std::string& method = "GET",
        const std::map<std::string, std::string>& req_headers = {},
        const std::string& req_body = "",
        bool include_cookies = true,
        std::function<bool(const uint8_t*, size_t)> on_chunk = nullptr,
        int max_redirects = 6
    ) const {
        std::string cur_url = raw_url;
        std::string cur_method = method;
        std::string cur_body = req_body;

        for (int redir = 0; redir <= max_redirects; ++redir) {
            ParsedURL u = ParsedURL::parse(cur_url);
            SocketConn conn;
            if (!open_connection(conn, u)) {
                HTTPResponse err;
                err.status = -1;
                err.final_url = cur_url;
                return err;
            }

            std::map<std::string, std::string> merged;
            merged["Host"] = u.host;
            merged["User-Agent"] = user_agent;
            merged["Accept"] = "*/*";
            merged["Accept-Language"] = "en-US,en;q=0.9";
            if (!on_chunk) merged["Accept-Encoding"] = "gzip";
            merged["Connection"] = "close";

            for (const auto& [k, v] : extra_headers) merged[k] = v;
            for (const auto& [k, v] : req_headers) merged[k] = v;
            if (include_cookies && merged.find("Cookie") == merged.end()) {
                std::string ck = cookies.header_for(u);
                if (!ck.empty()) merged["Cookie"] = ck;
            }
            if (!cur_body.empty()) {
                merged["Content-Length"] = std::to_string(cur_body.size());
            }

            std::string wire = cur_method + " " + u.path_and_query + " HTTP/1.1\r\n";
            for (const auto& [k, v] : merged) wire += k + ": " + v + "\r\n";
            wire += "\r\n";
            if (conn.write_all(wire.data(), wire.size()) < 0) return HTTPResponse{-1, cur_url, {}, {}};
            if (!cur_body.empty() && conn.write_all(cur_body.data(), cur_body.size()) < 0) return HTTPResponse{-1, cur_url, {}, {}};

            // Read HTTP response headers
            std::string raw_buf;
            raw_buf.reserve(8192);
            uint8_t tmp[16384];
            size_t hdr_end = std::string::npos;
            while ((hdr_end = raw_buf.find("\r\n\r\n")) == std::string::npos) {
                ssize_t n = conn.read_some(tmp, sizeof(tmp));
                if (n <= 0) break;
                raw_buf.append((const char*)tmp, (size_t)n);
                if (raw_buf.size() > 131072) break;
            }
            if (hdr_end == std::string::npos) return HTTPResponse{-1, cur_url, {}, {}};

            HTTPResponse resp;
            resp.final_url = cur_url;
            std::string hdr_block = raw_buf.substr(0, hdr_end);
            size_t line_pos = 0;
            bool first_line = true;
            while (line_pos < hdr_block.size()) {
                auto eol = hdr_block.find("\r\n", line_pos);
                std::string ln = (eol == std::string::npos) ? hdr_block.substr(line_pos) : hdr_block.substr(line_pos, eol - line_pos);
                line_pos = (eol == std::string::npos) ? hdr_block.size() : eol + 2;
                if (first_line) {
                    first_line = false;
                    auto sp = ln.find(' ');
                    if (sp != std::string::npos) resp.status = std::atoi(ln.c_str() + sp + 1);
                } else {
                    auto col = ln.find(':');
                    if (col != std::string::npos) {
                        std::string hk = ln.substr(0, col);
                        for (char& c : hk) c = (char)std::tolower((unsigned char)c);
                        std::string hv = ln.substr(col + 1);
                        while (!hv.empty() && (hv.front() == ' ' || hv.front() == '\t')) hv.erase(hv.begin());
                        resp.headers[hk] = hv;
                    }
                }
            }

            if ((resp.status == 301 || resp.status == 302 || resp.status == 303 || resp.status == 307 || resp.status == 308) && !resp.header("location").empty()) {
                cur_url = u.resolve(resp.header("location"));
                if (resp.status == 303) { cur_method = "GET"; cur_body.clear(); }
                continue;
            }

            if (cur_method == "HEAD") return resp;

            const uint8_t* leftover_ptr = (const uint8_t*)raw_buf.data() + hdr_end + 4;
            size_t leftover_len = raw_buf.size() - (hdr_end + 4);
            bool is_chunked = resp.header("transfer-encoding").find("chunked") != std::string::npos;
            bool is_gzip = resp.header("content-encoding").find("gzip") != std::string::npos;
            int64_t content_len = resp.header("content-length").empty() ? -1 : std::atoll(resp.header("content-length").c_str());

            auto deliver = [&](const uint8_t* p, size_t n) -> bool {
                if (n == 0) return true;
                limiter->consume(n);
                if (on_chunk && !is_gzip) return on_chunk(p, n);
                resp.body.insert(resp.body.end(), p, p + n);
                return true;
            };

            if (is_chunked) {
                std::string cbuf((const char*)leftover_ptr, leftover_len);
                size_t cp = 0;
                while (true) {
                    while (cbuf.find("\r\n", cp) == std::string::npos) {
                        ssize_t n = conn.read_some(tmp, sizeof(tmp));
                        if (n <= 0) goto done_body;
                        cbuf.append((const char*)tmp, (size_t)n);
                    }
                    auto crlf = cbuf.find("\r\n", cp);
                    size_t chunk_sz = std::strtoull(cbuf.c_str() + cp, nullptr, 16);
                    cp = crlf + 2;
                    if (chunk_sz == 0) break;
                    while (cbuf.size() - cp < chunk_sz + 2) {
                        ssize_t n = conn.read_some(tmp, sizeof(tmp));
                        if (n <= 0) break;
                        cbuf.append((const char*)tmp, (size_t)n);
                    }
                    size_t avail = std::min(chunk_sz, cbuf.size() - cp);
                    if (!deliver((const uint8_t*)cbuf.data() + cp, avail)) goto done_body;
                    cp += avail + 2;
                    if (cp > 65536) { cbuf.erase(0, cp); cp = 0; }
                }
            } else {
                int64_t received = 0;
                if (leftover_len > 0) {
                    size_t take = (content_len >= 0) ? std::min<size_t>(leftover_len, (size_t)content_len) : leftover_len;
                    if (!deliver(leftover_ptr, take)) goto done_body;
                    received += (int64_t)take;
                }
                while (content_len < 0 || received < content_len) {
                    size_t want = sizeof(tmp);
                    if (content_len >= 0 && content_len - received < (int64_t)want) want = (size_t)(content_len - received);
                    ssize_t n = conn.read_some(tmp, want);
                    if (n <= 0) break;
                    if (!deliver(tmp, (size_t)n)) break;
                    received += n;
                }
            }

        done_body:
            if (is_gzip && !resp.body.empty()) {
                resp.body = gunzip_bytes(resp.body.data(), resp.body.size());
                if (on_chunk && !resp.body.empty()) {
                    on_chunk(resp.body.data(), resp.body.size());
                    resp.body.clear();
                }
            }
            return resp;
        }
        return HTTPResponse{-1, cur_url, {}, {}};
    }

    HTTPResponse fetch(
        const std::string& url,
        const std::string& method = "GET",
        const std::map<std::string, std::string>& headers = {},
        const std::string& body = "",
        bool include_cookies = true,
        int retries = 3
    ) const {
        HTTPResponse last;
        for (int i = 0; i < std::max(1, retries); ++i) {
            last = stream_request(url, method, headers, body, include_cookies, nullptr);
            if (last.status >= 200 && last.status < 300) return last;
            if (last.status == 403 || last.status == 404 || last.status == 410) return last;
            if (i + 1 < retries) std::this_thread::sleep_for(std::chrono::milliseconds(350 * (1 << i)));
        }
        return last;
    }

    std::vector<uint8_t> fetch_range(const std::string& url, int64_t start, int64_t end, std::map<std::string, std::string> headers = {}) const {
        headers["Range"] = "bytes=" + std::to_string(start) + "-" + std::to_string(end);
        auto r = fetch(url, "GET", headers);
        if (r.status != 206 && r.status != 200) throw std::runtime_error("HTTP " + std::to_string(r.status));
        return r.body;
    }
};

} // namespace ubit
