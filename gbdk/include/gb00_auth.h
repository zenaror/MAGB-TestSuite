/** GB00 authentication -- REON's custom HTTP challenge/response scheme
 * for Pokémon-Crystal-era Mobile Adapter GB downloads/uploads.
 *
 * This is an APPLICATION-layer (HTTP-level) scheme, not part of the
 * Mobile Adapter protocol itself -- it rides inside ordinary HTTP
 * request/response bodies sent over a ordinary MAGB TCP connection,
 * exactly like the rest of this TestSuite's HTTP test does. It
 * belongs in the app layer, not magb_network.c.
 *
 * The algorithm was reverse-engineered by SimonTime (credited in
 * REONTeam/reon's own source) and is documented in prose in
 * REON's web/htdocs/cgb/upload.php header comment; this
 * implementation was derived from and round-trip-tested (on the host,
 * in Python) against REON's actual PHP decode function
 * (web/cgb/auth.php: decodeAuthorization()) --
 * including confirming that the FF-padding for the login ID goes on
 * the LEFT (login right-aligned within its 20-byte field), which the
 * upload.php prose comment does not state correctly. See
 * docs/protocol-notes.md, "GB00 HTTP authentication" for the full
 * derivation.
 */
#ifndef GB00_AUTH_H
#define GB00_AUTH_H

#include <stdint.h>

/* This translation unit lives in its own auto-assigned ROM bank (see
 * gb00_auth.c's `#pragma bank 255` and the Makefile's MBC5/-autobank
 * flags), so every function below is called across a bank boundary and
 * must carry GBDK's BANKED marker on BOTH the prototype and the
 * definition -- a mismatch compiles cleanly and then jumps into the
 * wrong bank at runtime, which is exactly how the previous, much wider
 * banking attempt failed (see the Makefile's own note).
 *
 * Nothing else in this ROM is banked, but do NOT read that as "calls
 * out of gb00_auth are automatically safe". The rest of the ROM does
 * not fit in bank 0, so its non-banked code is laid out flat across
 * banks 0 AND 1 -- and everything of it above 0x3FFF is displaced for
 * exactly as long as this module is mapped in. gb00_auth.c therefore
 * calls nothing outside itself at all (it carries local copies of
 * memcpy/strlen rather than <string.h>'s, which landed at 0x6DF2 and
 * 0x7732), and the Makefile pins the bank trampoline into bank 0.
 * `make check-banking` enforces both.
 *
 * The host-side unit tests (tests/host/, built with the native
 * compiler) never compile this module, but keep the fallback anyway so
 * including this header from a host build can't break on an unknown
 * keyword. */
#ifdef MAGB_HOST_TEST
#define GB00_BANKED
#else
#include <gbdk/platform.h>
#define GB00_BANKED BANKED
#endif

/** Computes the MD5 digest of an arbitrary-length byte string into a
 * 16-byte digest. Single-shot (no streaming API) -- every call site
 * in this TestSuite hashes well under 128 bytes at once. */
void md5(const uint8_t *msg, uint16_t len, uint8_t digest[16]) GB00_BANKED;

/** Standard base64 (RFC 4648, '+'/'/' alphabet, '=' padding).
 * base64_encode() writes exactly 4*ceil(len/3) characters plus a NUL
 * terminator to `out` (caller must size accordingly). base64_decode()
 * returns the number of decoded bytes written to `out`, or 0xFFFF on
 * a malformed input. */
uint16_t base64_encode(const uint8_t *data, uint16_t len, char *out) GB00_BANKED;
uint16_t base64_decode(const char *in, uint16_t in_len, uint8_t *out) GB00_BANKED;

/** GB00_CHALLENGE_LEN: the WWW-Authenticate "name" value is always
 * exactly this many base64 characters (36 raw bytes, 36 % 3 == 0, so
 * no '=' padding). GB00_AUTHORIZATION_LEN: the Authorization "name"
 * value this TestSuite must build in response (44 + 48 characters). */
#define GB00_CHALLENGE_LEN      48U
#define GB00_AUTHORIZATION_LEN  92U

/** How much of an Authorization is an echo of the server's own
 * published challenge, and therefore proves nothing about the client.
 *
 * The first GB00_AUTH_PREFIX_LEN characters are derived from the
 * challenge alone; only the remaining
 * GB00_AUTHORIZATION_LEN - GB00_AUTH_PREFIX_LEN carry the credential.
 * A server that validates only the prefix accepts anyone who can read
 * the 401 it just sent -- which is exactly the bypass this project
 * found in REON's utility-auth cache (docs/protocol-notes.md, "An
 * authentication bypass in REON's utility-auth cache"). Used by the
 * server-conformance test that checks the fix is in place. */
#define GB00_AUTH_PREFIX_LEN    44U

/** Builds the Authorization header's "name" value (GB00_AUTHORIZATION_LEN
 * characters + NUL) for the given challenge (exactly GB00_CHALLENGE_LEN
 * base64 characters, as received verbatim in the WWW-Authenticate
 * header), login (dionId, <=19 bytes -- read live from the adapter's
 * own config, see docs/protocol-notes.md) and password (entered by the
 * user via the "ISP PASSWORD" menu -- see main.c). `out` must have
 * room for GB00_AUTHORIZATION_LEN+1 bytes. */
void gb00_build_authorization(const char *challenge_b64, const char *login,
                               const char *password, char *out) GB00_BANKED;

#endif /* GB00_AUTH_H */
