/** Layer 2 -- pure, hardware-independent parsing of the 192-byte
 * Mobile Adapter GB configuration blob (as returned by Read
 * Configuration Data, 0x19; see magb_network.h for the basic field
 * offsets already used for login ID/email/SMTP/POP).
 *
 * This header adds the parts of the layout that need actual decoding
 * logic rather than a plain ASCII-field copy: the configuration-slot
 * BCD phone number, the trailing checksum, and the registration-state
 * byte's two documented values -- see docs/protocol-notes.md's
 * "Read Configuration Data" section and docs/dandocs-magb.md's
 * "Configuration Data" section for the citations.
 *
 * Deliberately kept free of any GBDK/hardware dependency (no
 * magb_context_t, no serial calls) so it can be unit-tested on the
 * host against a real captured configuration blob -- see
 * tests/host/test_config.c.
 */
#ifndef MAGB_CONFIG_H
#define MAGB_CONFIG_H

#include "magb_network.h"
#include <stdint.h>
#include <stdbool.h>

/* Configuration Slot layout (3 slots, 24 bytes each): an 8-byte BCD
 * telephone number followed by a 16-byte ASCII ID string. Mobile
 * Trainer only ever configures Slot 1; Slots 2/3 are left as
 * FF/00 filler on a stock configuration. */
#define MAGB_CONFIG_OFF_SLOT1      118U
#define MAGB_CONFIG_OFF_SLOT2      142U
#define MAGB_CONFIG_OFF_SLOT3      166U
#define MAGB_CONFIG_SLOT_LEN       24U
#define MAGB_CONFIG_SLOT_PHONE_LEN 8U
#define MAGB_CONFIG_SLOT_ID_LEN    16U

#define MAGB_CONFIG_OFF_CHECKSUM 190U

/* Registration state byte (offset MAGB_CONFIG_OFF_REG_STATE): the two
 * documented values. Note both have bit 0 set, so a bit-0-only check
 * (this TestSuite's original implementation) cannot tell them apart --
 * the distinguishing bit is bit 7. Any other value is "never
 * registered" (e.g. an EEPROM libmobile hasn't run Mobile Trainer
 * against yet). */
#define MAGB_REG_STATE_COMPLETE 0x81U /* Mobile Trainer registration finished */
#define MAGB_REG_STATE_PENDING  0x01U /* registration in progress */

/* BCD phone number nibble codes (Configuration Slot's first 8 bytes,
 * two digits/symbols per byte, high nibble first). */
#define MAGB_CONFIG_PHONE_NIBBLE_HASH 0xAU
#define MAGB_CONFIG_PHONE_NIBBLE_STAR 0xBU
#define MAGB_CONFIG_PHONE_NIBBLE_END  0xFU

/** True if bytes MAGB_CONFIG_OFF_CHECKSUM..+1 equal the 16-bit
 * unsigned additive sum of bytes 0..MAGB_CONFIG_OFF_CHECKSUM-1,
 * stored big-endian (high byte first) -- confirmed against a real
 * config blob captured from libmobile-bgb (see tests/host/test_config.c). */
bool magb_config_checksum_ok(const uint8_t config[MAGB_CONFIG_SIZE]);

/** Decodes an 8-byte BCD-packed configuration-slot phone number into a
 * NUL-terminated ASCII string in `out` (capacity `out_cap`; 17 bytes
 * -- 16 possible digits/symbols plus NUL -- covers the worst case).
 * Reads nibbles high-then-low, byte by byte; 0xA -> '#', 0xB -> '*',
 * 0xF -> stop immediately (the documented end-of-number marker; bytes
 * past it, and their remaining nibble if 0xF fell in a high nibble,
 * are unused filler). Any other nibble value (0-9) is copied as the
 * matching ASCII digit. Returns the number of characters written
 * (excluding the NUL), 0 if the field's first nibble is already the
 * end marker (empty/unset slot). */
uint8_t magb_config_decode_phone(const uint8_t phone[MAGB_CONFIG_SLOT_PHONE_LEN],
                                  char *out, uint8_t out_cap);

#endif /* MAGB_CONFIG_H */
