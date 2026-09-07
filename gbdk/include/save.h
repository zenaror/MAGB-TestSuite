/** Battery-backed cartridge SRAM: persists the ISP password across
 * power cycles.
 *
 * This became possible only when the ROM grew a mapper. It was
 * previously ROM ONLY (cart type 0x00) with no cart RAM at all, so the
 * password lived in WRAM and was gone at power-off -- documented at the
 * time as "would only be needed if the password had to survive a power
 * cycle, which was never asked for". The move to MBC5 for code space
 * made it cheap to also ask for RAM+BATTERY (cart type 0x1B), so now it
 * is asked for.
 *
 * WHAT THIS STORES, AND WHERE IT ENDS UP: the password is written to
 * cartridge SRAM verbatim, which on an emulator means it lands in a
 * plain `.sav` file next to the ROM, and on hardware in the cart's
 * battery-backed RAM. It is not encrypted or obscured -- there is
 * nothing to encrypt it *with* on a Game Boy, and a cart's owner can
 * always read its own save RAM. Treat the .sav as containing a real
 * account credential: do not commit it, attach it to a bug report, or
 * hand it to anyone you would not hand the password to. (The repo's
 * .gitignore already excludes the whole emulator working directory,
 * which is where BGB writes it.)
 */
#ifndef SAVE_H
#define SAVE_H

#include <stdint.h>
#include <stdbool.h>

/** Reads a previously stored password into `out` (NUL-terminated),
 * writing at most `cap`-1 characters.
 *
 * Returns false, leaving `out` an empty string, whenever the SRAM does
 * not hold a record this build wrote and can still read: never written,
 * a battery that died, a different/older layout, or a corrupted one.
 * Uninitialized cart RAM is arbitrary bytes, so "looks like a password"
 * is not good enough -- a stored record carries a magic, a layout
 * version and a checksum, and all three must agree before a single byte
 * is handed back. Silently loading garbage as a password would resurrect
 * exactly the bug that made the compile-time default worth deleting: an
 * authentication failure whose real cause is invisible. */
bool save_load_password(char *out, uint8_t cap);

/** Stores `pw` (NUL-terminated) so a later save_load_password() returns
 * it. Storing an empty string clears the record, so a user who blanks
 * the password field is not silently handed the old one back on the
 * next boot. */
void save_store_password(const char *pw);

#endif /* SAVE_H */
