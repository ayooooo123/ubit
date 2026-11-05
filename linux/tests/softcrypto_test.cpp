// Known-answer checks for softcrypto.hpp: FIPS 180 hashes, FIPS 197 C.1, RFC 3602 case #2, and an openssl-made padded message.
// c++ -std=c++20 linux/tests/softcrypto_test.cpp -o /tmp/softcrypto_test && /tmp/softcrypto_test
#include "../src/softcrypto.hpp"
#include <cassert>
#include <cstdio>
#include <string>

static std::string hex(const uint8_t* p, size_t n) {
    static const char* d = "0123456789abcdef";
    std::string s;
    for (size_t i = 0; i < n; ++i) { s += d[p[i] >> 4]; s += d[p[i] & 15]; }
    return s;
}

static std::vector<uint8_t> unhex(const std::string& s) {
    std::vector<uint8_t> out;
    for (size_t i = 0; i + 1 < s.size(); i += 2) out.push_back((uint8_t)std::stoul(s.substr(i, 2), nullptr, 16));
    return out;
}

int main() {
    using namespace ubit::soft;
    const std::string abc = "abc";
    const std::string two = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"; // 448 bits: the length spills into a second block
    uint8_t md[32];
    sha256((const uint8_t*)abc.data(), abc.size(), md);
    assert(hex(md, 32) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    sha256((const uint8_t*)two.data(), two.size(), md);
    assert(hex(md, 32) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    sha256(nullptr, 0, md);
    assert(hex(md, 32) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    sha1((const uint8_t*)abc.data(), abc.size(), md);
    assert(hex(md, 20) == "a9993e364706816aba3e25717850c26c9cd0d89d");
    sha1((const uint8_t*)two.data(), two.size(), md);
    assert(hex(md, 20) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1");

    // FIPS 197 C.1: one block back to its plaintext.
    auto key = unhex("000102030405060708090a0b0c0d0e0f");
    uint8_t out[16];
    Aes128Decrypt(key.data()).block(unhex("69c4e0d86a7b0430d8cdb78070b4c55a").data(), out);
    assert(hex(out, 16) == "00112233445566778899aabbccddeeff");

    // RFC 3602 case #2: two blocks with no padding, so the padding check must refuse them.
    auto k2 = unhex("c286696d887c9aa0611bbb3e2025a45a");
    auto iv = unhex("562e17996d093d28ddb3ba695a2e6f58");
    auto ct = unhex("d296cd94c2cccf8a3a863028b5e1dc0a7586602d253cfff91b8266bea6d61ab1");
    std::vector<uint8_t> pt;
    assert(!aes128_cbc_decrypt(ct, k2.data(), iv.data(), pt));
    Aes128Decrypt d2(k2.data());
    std::vector<uint8_t> raw;
    uint8_t prev[16];
    for (int i = 0; i < 16; ++i) prev[i] = iv[i];
    for (size_t off = 0; off < ct.size(); off += 16) {
        uint8_t b[16];
        d2.block(&ct[off], b);
        for (int i = 0; i < 16; ++i) { raw.push_back(b[i] ^ prev[i]); prev[i] = ct[off + i]; }
    }
    assert(hex(raw.data(), raw.size()) == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    assert(!aes128_cbc_decrypt(std::vector<uint8_t>(15, 0), k2.data(), iv.data(), pt)); // not a whole block

    // `openssl enc -aes-128-cbc` (PKCS#7) of a 34-byte message under the same key and IV.
    auto padded = unhex("bd05e1f3e409098c3d88bd3da1933808abf9dbc2669858015174f5c0fd70c55aa029dacc192757845fa294efff3d835e");
    assert(aes128_cbc_decrypt(padded, k2.data(), iv.data(), pt));
    assert(std::string(pt.begin(), pt.end()) == "an HLS segment, padded to 48 bytes");

    std::puts("softcrypto: all known-answer tests pass");
    return 0;
}
