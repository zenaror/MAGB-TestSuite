/** Explicit number formatting for wire-format strings.
 *
 * These exist because SDCC's sprintf() silently produced the wrong
 * thing. The SMALL BUFFER upload built its POST header with
 * "Content-Length: %u ... X-Test-Checksum: %hx%hx" and went out on the
 * wire seven bytes short -- exactly the width of the three digits of
 * "128" and the four of "1fc0". The server therefore saw an empty
 * Content-Length, forwarded no body to PHP, and answered "checksum of
 * nothing", which looked like a rejected upload rather than a malformed
 * request. Nothing warned; the ROM built clean.
 *
 * The lesson is not "find the printf quirk". It is that a TestSuite
 * whose whole job is putting exact bytes on a wire should not be
 * deriving those bytes from a formatter it cannot test. These are
 * plain C, they take an explicit width, and tests/host/test_fmt.c
 * checks them on the host -- including the leading-zero cases that a
 * "%x" would get wrong and that only show up for one checksum value in
 * sixteen.
 *
 * Every one of these appends at `out` and returns the new write cursor,
 * so a header is built by chaining them. None writes a NUL; the caller
 * terminates once at the end.
 */
#ifndef MAGB_FMT_H
#define MAGB_FMT_H

#include <stdint.h>

/** Appends `s` (NUL-terminated, terminator not copied). */
char *magb_fmt_str(char *out, const char *s);

/** Appends `v` in decimal, no leading zeros ("0" for zero). Used for
 * Content-Length, where a leading zero would be legal but a missing
 * digit would not. */
char *magb_fmt_u16(char *out, uint16_t v);

/** Appends `v` as exactly four UPPERCASE hex digits, zero-padded.
 *
 * The width is not cosmetic: REON compares the client's
 * X-Test-Checksum against its own `sprintf('%04X')`, so a checksum of
 * 0x0F00 has to be "0F00" and never "F00". Uppercase so both ROMs put
 * identical bytes on the wire -- the RGBDS side has always used an
 * uppercase table, and while REON normalises case, two implementations
 * of the same TestSuite disagreeing on their own wire format is a bug
 * waiting for a server that does not. */
char *magb_fmt_hex16(char *out, uint16_t v);

/** Appends `v` as exactly two UPPERCASE hex digits, zero-padded. */
char *magb_fmt_hex8(char *out, uint8_t v);

#endif /* MAGB_FMT_H */
