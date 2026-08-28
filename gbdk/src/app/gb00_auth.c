#include "gb00_auth.h"
#include <stdbool.h>
#include <string.h>

/* ---- MD5 (RFC 1321), compact single-shot implementation --------------
 * Kept deliberately simple/textbook (no unrolled rounds, no lookup-
 * table cleverness) -- this runs a handful of times per test, never
 * in a hot loop, and clarity matters more than cycles here. */

static uint32_t rotl32(uint32_t x, uint8_t c)
{
    return (uint32_t)((x << c) | (x >> (32U - c)));
}

static const uint32_t kMd5K[64] = {
    0xd76aa478U,0xe8c7b756U,0x242070dbU,0xc1bdceeeU,0xf57c0fafU,0x4787c62aU,0xa8304613U,0xfd469501U,
    0x698098d8U,0x8b44f7afU,0xffff5bb1U,0x895cd7beU,0x6b901122U,0xfd987193U,0xa679438eU,0x49b40821U,
    0xf61e2562U,0xc040b340U,0x265e5a51U,0xe9b6c7aaU,0xd62f105dU,0x02441453U,0xd8a1e681U,0xe7d3fbc8U,
    0x21e1cde6U,0xc33707d6U,0xf4d50d87U,0x455a14edU,0xa9e3e905U,0xfcefa3f8U,0x676f02d9U,0x8d2a4c8aU,
    0xfffa3942U,0x8771f681U,0x6d9d6122U,0xfde5380cU,0xa4beea44U,0x4bdecfa9U,0xf6bb4b60U,0xbebfbc70U,
    0x289b7ec6U,0xeaa127faU,0xd4ef3085U,0x04881d05U,0xd9d4d039U,0xe6db99e5U,0x1fa27cf8U,0xc4ac5665U,
    0xf4292244U,0x432aff97U,0xab9423a7U,0xfc93a039U,0x655b59c3U,0x8f0ccc92U,0xffeff47dU,0x85845dd1U,
    0x6fa87e4fU,0xfe2ce6e0U,0xa3014314U,0x4e0811a1U,0xf7537e82U,0xbd3af235U,0x2ad7d2bbU,0xeb86d391U
};

static const uint8_t kMd5S[64] = {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
};

static void md5_process_block(uint32_t state[4], const uint8_t block[64])
{
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t m[16];
    uint8_t i;

    for (i = 0U; i < 16U; i++) {
        m[i] = (uint32_t)block[i * 4U]
             | ((uint32_t)block[i * 4U + 1U] << 8)
             | ((uint32_t)block[i * 4U + 2U] << 16)
             | ((uint32_t)block[i * 4U + 3U] << 24);
    }

    for (i = 0U; i < 64U; i++) {
        uint32_t f;
        uint8_t g;
        if (i < 16U) {
            f = (b & c) | (~b & d);
            g = i;
        } else if (i < 32U) {
            f = (d & b) | (~d & c);
            g = (uint8_t)((5U * i + 1U) % 16U);
        } else if (i < 48U) {
            f = b ^ c ^ d;
            g = (uint8_t)((3U * i + 5U) % 16U);
        } else {
            f = c ^ (b | ~d);
            g = (uint8_t)((7U * i) % 16U);
        }
        f = f + a + kMd5K[i] + m[g];
        a = d;
        d = c;
        c = b;
        b = b + rotl32(f, kMd5S[i]);
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
}

void md5(const uint8_t *msg, uint16_t len, uint8_t digest[16])
{
    /* Every call site in this TestSuite hashes a base64 challenge
     * (48 bytes) plus a short password -- comfortably under two
     * 64-byte MD5 blocks. 128 bytes covers that with room to spare. */
    static uint8_t block[128];
    uint32_t state[4] = { 0x67452301U, 0xefcdab89U, 0x98badcfeU, 0x10325476U };
    uint64_t bit_len = (uint64_t)len * 8U;
    uint16_t padded_len;
    uint16_t i;

    memcpy(block, msg, len);
    block[len] = 0x80U;
    padded_len = (uint16_t)(len + 1U);
    while ((padded_len % 64U) != 56U) {
        block[padded_len++] = 0x00U;
    }
    for (i = 0U; i < 8U; i++) {
        block[padded_len + i] = (uint8_t)(bit_len >> (8U * i));
    }
    padded_len = (uint16_t)(padded_len + 8U);

    for (i = 0U; i < padded_len; i += 64U) {
        md5_process_block(state, &block[i]);
    }

    for (i = 0U; i < 4U; i++) {
        digest[i * 4U]      = (uint8_t)(state[i]);
        digest[i * 4U + 1U] = (uint8_t)(state[i] >> 8);
        digest[i * 4U + 2U] = (uint8_t)(state[i] >> 16);
        digest[i * 4U + 3U] = (uint8_t)(state[i] >> 24);
    }
}

/* ---- base64 (RFC 4648) ------------------------------------------------ */

static const char kB64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

uint16_t base64_encode(const uint8_t *data, uint16_t len, char *out)
{
    uint16_t i = 0U;
    uint16_t o = 0U;

    while (i + 3U <= len) {
        uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1U] << 8) | data[i + 2U];
        out[o++] = kB64Alphabet[(v >> 18) & 0x3FU];
        out[o++] = kB64Alphabet[(v >> 12) & 0x3FU];
        out[o++] = kB64Alphabet[(v >> 6) & 0x3FU];
        out[o++] = kB64Alphabet[v & 0x3FU];
        i += 3U;
    }

    if (len - i == 1U) {
        uint32_t v = (uint32_t)data[i] << 16;
        out[o++] = kB64Alphabet[(v >> 18) & 0x3FU];
        out[o++] = kB64Alphabet[(v >> 12) & 0x3FU];
        out[o++] = '=';
        out[o++] = '=';
    } else if (len - i == 2U) {
        uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1U] << 8);
        out[o++] = kB64Alphabet[(v >> 18) & 0x3FU];
        out[o++] = kB64Alphabet[(v >> 12) & 0x3FU];
        out[o++] = kB64Alphabet[(v >> 6) & 0x3FU];
        out[o++] = '=';
    }

    out[o] = '\0';
    return o;
}

static int8_t b64_value(char c)
{
    if (c >= 'A' && c <= 'Z') return (int8_t)(c - 'A');
    if (c >= 'a' && c <= 'z') return (int8_t)(c - 'a' + 26);
    if (c >= '0' && c <= '9') return (int8_t)(c - '0' + 52);
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

uint16_t base64_decode(const char *in, uint16_t in_len, uint8_t *out)
{
    uint16_t i = 0U;
    uint16_t o = 0U;

    if (in_len % 4U != 0U) {
        return 0xFFFFU;
    }

    while (i < in_len) {
        int8_t v0 = b64_value(in[i]);
        int8_t v1 = b64_value(in[i + 1U]);
        bool pad2 = (in[i + 2U] == '=');
        bool pad3 = (in[i + 3U] == '=');
        int8_t v2 = pad2 ? 0 : b64_value(in[i + 2U]);
        int8_t v3 = pad3 ? 0 : b64_value(in[i + 3U]);
        uint32_t v;

        if (v0 < 0 || v1 < 0 || (!pad2 && v2 < 0) || (!pad3 && v3 < 0)) {
            return 0xFFFFU;
        }

        v = ((uint32_t)v0 << 18) | ((uint32_t)v1 << 12) | ((uint32_t)v2 << 6) | (uint32_t)v3;
        out[o++] = (uint8_t)(v >> 16);
        if (!pad2) {
            out[o++] = (uint8_t)(v >> 8);
        }
        if (!pad3) {
            out[o++] = (uint8_t)v;
        }
        i += 4U;
    }

    return o;
}

/* ---- GB00 challenge/response ------------------------------------------
 * See include/gb00_auth.h and docs/protocol-notes.md for the full
 * derivation. Byte-for-byte confirmed via a host-side Python
 * round-trip against REON's actual PHP decode function before this
 * C port was written. */

static uint8_t get_bit(uint8_t byte, uint8_t n)
{
    return (uint8_t)((byte >> n) & 1U);
}

/* Rebuilds the same 36-byte "bitsSorted" value REON's server derives
 * from the challenge: bytes 0-17 pack the even-numbered bits of each
 * challenge byte pair, bytes 18-35 pack the odd-numbered bits of the
 * same pairs. */
static void gb00_bits_sorted(const uint8_t challenge_raw[36], uint8_t out[36])
{
    uint8_t i;
    for (i = 0U; i < 18U; i++) {
        uint8_t b1 = challenge_raw[i * 2U];
        uint8_t b2 = challenge_raw[i * 2U + 1U];
        out[i] = (uint8_t)((get_bit(b1,6)<<7)|(get_bit(b1,4)<<6)|(get_bit(b1,2)<<5)|(get_bit(b1,0)<<4)
                          |(get_bit(b2,6)<<3)|(get_bit(b2,4)<<2)|(get_bit(b2,2)<<1)|(get_bit(b2,0)<<0));
    }
    for (i = 18U; i < 36U; i++) {
        uint8_t j = (uint8_t)(i - 18U);
        uint8_t b1 = challenge_raw[j * 2U];
        uint8_t b2 = challenge_raw[j * 2U + 1U];
        out[i] = (uint8_t)((get_bit(b1,7)<<7)|(get_bit(b1,5)<<6)|(get_bit(b1,3)<<5)|(get_bit(b1,1)<<4)
                          |(get_bit(b2,7)<<3)|(get_bit(b2,5)<<2)|(get_bit(b2,3)<<1)|(get_bit(b2,1)<<0));
    }
}

/* Client-side bit rotation: bit0->bit3, bit3->bit6, bit6->bit0 (the
 * exact inverse of the server's un-rotate step). */
static uint8_t gb00_rotate_encode(uint8_t x)
{
    uint8_t v = (uint8_t)(x & 0xB6U); /* 0b10110110: bits 7,5,4,2,1 unchanged */
    v = (uint8_t)(v | (get_bit(x, 0) << 3) | (get_bit(x, 3) << 6) | (get_bit(x, 6) << 0));
    return v;
}

void gb00_build_authorization(const char *challenge_b64, const char *login,
                               const char *password, char *out)
{
    uint8_t challenge_raw[36];
    uint8_t bits_sorted[36];
    uint8_t md5_input[GB00_CHALLENGE_LEN + 32U]; /* challenge text + password, generous bound */
    uint8_t password_len;
    uint8_t login_len;
    uint16_t md5_input_len;
    uint8_t pw_hash[16];
    uint8_t plaintext[36];
    uint8_t scrambled[36];
    uint8_t i;

    (void)base64_decode(challenge_b64, GB00_CHALLENGE_LEN, challenge_raw);
    gb00_bits_sorted(challenge_raw, bits_sorted);

    memcpy(md5_input, challenge_b64, GB00_CHALLENGE_LEN);
    password_len = (uint8_t)strlen(password);
    memcpy(&md5_input[GB00_CHALLENGE_LEN], password, password_len);
    md5_input_len = (uint16_t)(GB00_CHALLENGE_LEN + password_len);
    md5(md5_input, md5_input_len, pw_hash);

    memcpy(plaintext, pw_hash, 16U);
    login_len = (uint8_t)strlen(login);
    /* Login ID is right-aligned in its 20-byte field, left-padded with
     * 0xFF -- confirmed necessary (not what the public prose writeup
     * describes) by round-tripping against REON's real decode logic;
     * see docs/protocol-notes.md. */
    for (i = 0U; i < (uint8_t)(20U - login_len); i++) {
        plaintext[16U + i] = 0xFFU;
    }
    memcpy(&plaintext[36U - login_len], login, login_len);

    for (i = 0U; i < 36U; i++) {
        scrambled[i] = gb00_rotate_encode((uint8_t)(plaintext[i] ^ bits_sorted[i]));
    }

    /* First component: a fresh, independently-padded base64 encoding
     * of the challenge's first 32 raw bytes -- NOT a slice of the
     * original 48-character challenge text (36 bytes has no base64
     * padding, so a naive slice at character 44 does not correspond
     * to a clean 32-byte prefix; confirmed by round-trip test). */
    (void)base64_encode(challenge_raw, 32U, out);
    (void)base64_encode(scrambled, 36U, &out[44]);
}
