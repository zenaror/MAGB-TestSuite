#include "sound.h"
#include <gb/gb.h>
#include <stdint.h>

void sound_init(void)
{
    NR52_REG = AUDENA_ON;
    NR51_REG = (uint8_t)(AUDTERM_1_LEFT | AUDTERM_1_RIGHT);
    NR50_REG = (uint8_t)(AUDVOL_VOL_LEFT(7) | AUDVOL_VOL_RIGHT(7));
}

static void wait_frames(uint8_t frames)
{
    uint8_t i;
    for (i = 0U; i < frames; i++) {
        vsync();
    }
}

/* `period` is the 11-bit APU period value (freq_hz = 131072 /
 * (2048 - period)); `duty` is one of the NR11 duty-cycle bit patterns
 * (0x00=12.5%, 0x40=25%, 0x80=50%, 0xC0=75%); `envelope` is a raw NR12
 * byte (bits 7-4 initial volume, bit 3 direction, bits 2-0 sweep
 * pace). Channel 1's own length timer is left disabled -- `frames`
 * (VBlanks) controls how long this plays instead, matching the
 * project's existing vsync()-loop timing style. */
static void play_tone(uint16_t period, uint8_t duty, uint8_t envelope, uint8_t frames)
{
    NR10_REG = 0x00U; /* no pitch sweep */
    NR11_REG = duty;
    NR12_REG = envelope;
    NR13_REG = (uint8_t)(period & 0xFFU);
    NR14_REG = (uint8_t)(AUDHIGH_RESTART | AUDHIGH_LENGTH_OFF | ((period >> 8) & 0x07U));
    wait_frames(frames);
}

void sound_select(void)
{
    play_tone(1884U, 0x80U, 0x81U, 3U); /* ~800 Hz, vol 8 decreasing */
}

void sound_error(void)
{
    play_tone(1393U, 0x80U, 0x84U, 10U); /* ~200 Hz, vol 8 decreasing, longer */
}

void sound_success(void)
{
    play_tone(1797U, 0x80U, 0xC2U, 4U); /* C5 */
    play_tone(1881U, 0x80U, 0xC2U, 6U); /* G5 */
}
