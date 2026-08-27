#include "magb_config.h"

bool magb_config_checksum_ok(const uint8_t config[MAGB_CONFIG_SIZE])
{
    uint16_t sum = 0U;
    uint16_t i;
    uint16_t stored;

    for (i = 0U; i < MAGB_CONFIG_OFF_CHECKSUM; i++) {
        sum = (uint16_t)(sum + config[i]);
    }
    stored = (uint16_t)(((uint16_t)config[MAGB_CONFIG_OFF_CHECKSUM] << 8)
                         | config[MAGB_CONFIG_OFF_CHECKSUM + 1U]);
    return sum == stored;
}

uint8_t magb_config_decode_phone(const uint8_t phone[MAGB_CONFIG_SLOT_PHONE_LEN],
                                  char *out, uint8_t out_cap)
{
    uint8_t i;
    uint8_t n = 0U;

    for (i = 0U; i < (uint8_t)(MAGB_CONFIG_SLOT_PHONE_LEN * 2U) && n < (uint8_t)(out_cap - 1U); i++) {
        uint8_t byte = phone[i / 2U];
        uint8_t nibble = (i % 2U == 0U) ? (uint8_t)(byte >> 4) : (uint8_t)(byte & 0x0FU);

        if (nibble == MAGB_CONFIG_PHONE_NIBBLE_END) {
            break;
        }
        if (nibble == MAGB_CONFIG_PHONE_NIBBLE_HASH) {
            out[n++] = '#';
        } else if (nibble == MAGB_CONFIG_PHONE_NIBBLE_STAR) {
            out[n++] = '*';
        } else if (nibble <= 9U) {
            out[n++] = (char)('0' + nibble);
        }
        /* Other nibble values (0xC-0xE) are undocumented; skip them
         * rather than emitting garbage into the dial string. */
    }
    out[n] = '\0';
    return n;
}
