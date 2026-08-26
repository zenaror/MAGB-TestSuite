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
 * references/reon/web/htdocs/cgb/upload.php's header comment; this
 * implementation was derived from and round-trip-tested (on the host,
 * in Python) against REON's actual PHP decode function
 * (references/reon/web/cgb/auth.php: decodeAuthorization()) --
 * including confirming that the FF-padding for the login ID goes on
 * the LEFT (login right-aligned within its 20-byte field), which the
 * upload.php prose comment does not state correctly. See
 * docs/protocol-notes.md, "GB00 HTTP authentication" for the full
 * derivation.
 */
#ifndef GB00_AUTH_H
#define GB00_AUTH_H

#include <stdint.h>

/** Computes the MD5 digest of an arbitrary-length byte string into a
 * 16-byte digest. Single-shot (no streaming API) -- every call site
 * in this TestSuite hashes well under 128 bytes at once. */
void md5(const uint8_t *msg, uint16_t len, uint8_t digest[16]);

/** Standard base64 (RFC 4648, '+'/'/' alphabet, '=' padding).
 * base64_encode() writes exactly 4*ceil(len/3) characters plus a NUL
 * terminator to `out` (caller must size accordingly). base64_decode()
 * returns the number of decoded bytes written to `out`, or 0xFFFF on
 * a malformed input. */
uint16_t base64_encode(const uint8_t *data, uint16_t len, char *out);
uint16_t base64_decode(const char *in, uint16_t in_len, uint8_t *out);

/** GB00_CHALLENGE_LEN: the WWW-Authenticate "name" value is always
 * exactly this many base64 characters (36 raw bytes, 36 % 3 == 0, so
 * no '=' padding). GB00_AUTHORIZATION_LEN: the Authorization "name"
 * value this TestSuite must build in response (44 + 48 characters). */
#define GB00_CHALLENGE_LEN      48U
#define GB00_AUTHORIZATION_LEN  92U

/** Builds the Authorization header's "name" value (GB00_AUTHORIZATION_LEN
 * characters + NUL) for the given challenge (exactly GB00_CHALLENGE_LEN
 * base64 characters, as received verbatim in the WWW-Authenticate
 * header), login (dionId, <=19 bytes -- this TestSuite assumes it is
 * the same account as TEST_ISP_LOGIN, see docs/protocol-notes.md) and
 * password (TEST_ISP_PASSWORD). `out` must have room for
 * GB00_AUTHORIZATION_LEN+1 bytes. */
void gb00_build_authorization(const char *challenge_b64, const char *login,
                               const char *password, char *out);

#endif /* GB00_AUTH_H */
