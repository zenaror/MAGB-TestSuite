#include "save.h"
#include "test_config.h"

#include <gbdk/platform.h>

/* Cartridge SRAM window. MBC5 maps the selected RAM bank here once RAM
 * is enabled; bank 0 is the only one this ROM uses (the header declares
 * a single 8 KiB bank, and a password needs a few dozen bytes). */
static uint8_t *const kSram = (uint8_t *)0xA000;

/* Record layout, serialized explicitly rather than as a struct -- same
 * reasoning as the protocol layer (repo-root CLAUDE.md, "Do not rely on
 * packed C structs"), and here it also pins the on-cart format so a
 * compiler or padding change can't silently invalidate everyone's save.
 *
 *   0   'M'
 *   1   'A'
 *   2   layout version
 *   3   password length (0..SAVE_MAX_LEN)
 *   4.. password bytes, not NUL-terminated
 *   4+n additive checksum of bytes 0..4+n-1
 */
#define SAVE_OFF_MAGIC0  0U
#define SAVE_OFF_MAGIC1  1U
#define SAVE_OFF_VERSION 2U
#define SAVE_OFF_LEN     3U
#define SAVE_OFF_DATA    4U

#define SAVE_MAGIC0  0x4DU /* 'M' */
#define SAVE_MAGIC1  0x41U /* 'A' */
#define SAVE_VERSION 1U

/* Bumping SAVE_VERSION is how to change the layout: an old record then
 * fails validation and is treated as absent, rather than being read
 * back through the wrong field offsets. */
#define SAVE_MAX_LEN TEST_ISP_PASSWORD_MAX_LEN

static uint8_t save_checksum(uint8_t len)
{
    uint8_t sum = 0U;
    uint8_t i;

    for (i = 0U; i < (uint8_t)(SAVE_OFF_DATA + len); i++) {
        sum = (uint8_t)(sum + kSram[i]);
    }
    return sum;
}

bool save_load_password(char *out, uint8_t cap)
{
    uint8_t len;
    uint8_t i;
    bool ok = false;

    out[0] = '\0';

    ENABLE_RAM;
    SWITCH_RAM(0);

    if (kSram[SAVE_OFF_MAGIC0] == SAVE_MAGIC0
        && kSram[SAVE_OFF_MAGIC1] == SAVE_MAGIC1
        && kSram[SAVE_OFF_VERSION] == SAVE_VERSION) {
        len = kSram[SAVE_OFF_LEN];
        /* Length is validated against BOTH the format's own cap and the
         * caller's buffer before it is used to index anything -- it
         * comes from battery-backed RAM, which is as untrusted as any
         * other external input. */
        if (len <= SAVE_MAX_LEN && len < cap
            && kSram[SAVE_OFF_DATA + len] == save_checksum(len)) {
            for (i = 0U; i < len; i++) {
                out[i] = (char)kSram[SAVE_OFF_DATA + i];
            }
            out[len] = '\0';
            ok = len > 0U;
        }
    }

    DISABLE_RAM;
    return ok;
}

void save_store_password(const char *pw)
{
    uint8_t len = 0U;
    uint8_t i;

    while (pw[len] != '\0' && len < SAVE_MAX_LEN) {
        len++;
    }

    ENABLE_RAM;
    SWITCH_RAM(0);

    kSram[SAVE_OFF_MAGIC0] = SAVE_MAGIC0;
    kSram[SAVE_OFF_MAGIC1] = SAVE_MAGIC1;
    kSram[SAVE_OFF_VERSION] = SAVE_VERSION;
    kSram[SAVE_OFF_LEN] = len;
    for (i = 0U; i < len; i++) {
        kSram[SAVE_OFF_DATA + i] = (uint8_t)pw[i];
    }
    kSram[SAVE_OFF_DATA + len] = save_checksum(len);

    /* Leaving cart RAM enabled across a power-off is the classic way to
     * corrupt a save: the write-enable latch is what protects the RAM
     * while the supply collapses. Disable it as soon as the write is
     * done, every time. */
    DISABLE_RAM;
}
