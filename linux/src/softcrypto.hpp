#pragma once
// Portable SHA-1, SHA-256 and AES-128-CBC decryption for builds without OpenSSL (the WebAssembly build).
#include <cstddef>
#include <cstdint>
#include <vector>

namespace ubit::soft {

inline uint32_t rotl32(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }
inline uint32_t rotr32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

// Pads a message into 64-byte blocks with its bit length, big-endian, as SHA-1 and SHA-256 both do.
inline std::vector<uint8_t> md_pad(const uint8_t* data, size_t len) {
    std::vector<uint8_t> m(data, data + len);
    m.push_back(0x80);
    while (m.size() % 64 != 56) m.push_back(0);
    uint64_t bits = (uint64_t)len * 8;
    for (int i = 7; i >= 0; --i) m.push_back((uint8_t)(bits >> (i * 8)));
    return m;
}

inline uint32_t be32(const uint8_t* p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

inline void sha256(const uint8_t* data, size_t len, uint8_t out[32]) {
    static const uint32_t K[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    auto m = md_pad(data, len);
    for (size_t off = 0; off < m.size(); off += 64) {
        uint32_t w[64];
        for (int i = 0; i < 16; ++i) w[i] = be32(&m[off + 4 * i]);
        for (int i = 16; i < 64; ++i) {
            uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
        for (int i = 0; i < 64; ++i) {
            uint32_t t1 = k + (rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
            uint32_t t2 = (rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
            k = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += k;
    }
    for (int i = 0; i < 8; ++i) for (int j = 0; j < 4; ++j) out[4 * i + j] = (uint8_t)(h[i] >> (24 - 8 * j));
}

inline void sha1(const uint8_t* data, size_t len, uint8_t out[20]) {
    uint32_t h[5] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0};
    auto m = md_pad(data, len);
    for (size_t off = 0; off < m.size(); off += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; ++i) w[i] = be32(&m[off + 4 * i]);
        for (int i = 16; i < 80; ++i) w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        for (int i = 0; i < 80; ++i) {
            uint32_t f, k;
            if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
            else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
            else { f = b ^ c ^ d; k = 0xca62c1d6; }
            uint32_t t = rotl32(a, 5) + f + e + k + w[i];
            e = d; d = c; c = rotl32(b, 30); b = a; a = t;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
    }
    for (int i = 0; i < 5; ++i) for (int j = 0; j < 4; ++j) out[4 * i + j] = (uint8_t)(h[i] >> (24 - 8 * j));
}

class Aes128Decrypt {
    uint8_t sbox_[256], inv_[256], rk_[176];

    static uint8_t xtime(uint8_t a) { return (uint8_t)((a << 1) ^ ((a & 0x80) ? 0x1b : 0)); }
    static uint8_t mul(uint8_t a, uint8_t b) {
        uint8_t p = 0;
        while (b) { if (b & 1) p ^= a; a = xtime(a); b >>= 1; }
        return p;
    }
    static uint8_t rotl8(uint8_t x, int n) { return (uint8_t)((x << n) | (x >> (8 - n))); }

public:
    explicit Aes128Decrypt(const uint8_t key[16]) {
        // The S-box from its definition (multiplicative inverse in GF(2^8), then the affine map).
        uint8_t p = 1, q = 1;
        do {
            p = (uint8_t)(p ^ xtime(p));
            q ^= (uint8_t)(q << 1); q ^= (uint8_t)(q << 2); q ^= (uint8_t)(q << 4);
            if (q & 0x80) q ^= 0x09;
            sbox_[p] = (uint8_t)(q ^ rotl8(q, 1) ^ rotl8(q, 2) ^ rotl8(q, 3) ^ rotl8(q, 4) ^ 0x63);
        } while (p != 1);
        sbox_[0] = 0x63;
        for (int i = 0; i < 256; ++i) inv_[sbox_[i]] = (uint8_t)i;

        for (int i = 0; i < 16; ++i) rk_[i] = key[i];
        uint8_t rcon = 1;
        for (int i = 16; i < 176; i += 4) {
            uint8_t t[4] = {rk_[i - 4], rk_[i - 3], rk_[i - 2], rk_[i - 1]};
            if (i % 16 == 0) {
                uint8_t t0 = t[0];
                t[0] = (uint8_t)(sbox_[t[1]] ^ rcon); t[1] = sbox_[t[2]]; t[2] = sbox_[t[3]]; t[3] = sbox_[t0];
                rcon = xtime(rcon);
            }
            for (int j = 0; j < 4; ++j) rk_[i + j] = (uint8_t)(rk_[i - 16 + j] ^ t[j]);
        }
    }

    void block(const uint8_t in[16], uint8_t out[16]) const {
        uint8_t s[16];
        for (int i = 0; i < 16; ++i) s[i] = (uint8_t)(in[i] ^ rk_[160 + i]);
        for (int round = 9; round >= 0; --round) {
            uint8_t t[16];
            // InvShiftRows + InvSubBytes; byte i sits at row i % 4, column i / 4.
            for (int c = 0; c < 4; ++c) for (int r = 0; r < 4; ++r) t[r + 4 * c] = inv_[s[r + 4 * ((c - r + 4) % 4)]];
            for (int i = 0; i < 16; ++i) s[i] = (uint8_t)(t[i] ^ rk_[16 * round + i]);
            if (round == 0) break;
            for (int c = 0; c < 4; ++c) {
                uint8_t a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
                s[4 * c]     = (uint8_t)(mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9));
                s[4 * c + 1] = (uint8_t)(mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13));
                s[4 * c + 2] = (uint8_t)(mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11));
                s[4 * c + 3] = (uint8_t)(mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14));
            }
        }
        for (int i = 0; i < 16; ++i) out[i] = s[i];
    }
};

// CBC with PKCS#7 padding; returns false (like a failed EVP_DecryptFinal_ex) on bad length or padding.
inline bool aes128_cbc_decrypt(const std::vector<uint8_t>& cipher, const uint8_t key[16], const uint8_t iv[16], std::vector<uint8_t>& out) {
    if (cipher.empty() || cipher.size() % 16 != 0) return false;
    Aes128Decrypt aes(key);
    out.resize(cipher.size());
    uint8_t prev[16];
    for (int i = 0; i < 16; ++i) prev[i] = iv[i];
    for (size_t off = 0; off < cipher.size(); off += 16) {
        aes.block(&cipher[off], &out[off]);
        for (int i = 0; i < 16; ++i) { out[off + i] ^= prev[i]; prev[i] = cipher[off + i]; }
    }
    uint8_t pad = out.back();
    if (pad == 0 || pad > 16) return false;
    for (size_t i = out.size() - pad; i < out.size(); ++i) if (out[i] != pad) return false;
    out.resize(out.size() - pad);
    return true;
}

} // namespace ubit::soft
