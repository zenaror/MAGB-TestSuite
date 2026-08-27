/* Host-side unit tests for the hardware-independent Mobile Adapter GB
 * configuration parser (src/protocol/magb_config.c), validated against
 * a real 512-byte configuration file captured from libmobile-bgb
 * (config.bin at the repo root -- the first 192 bytes of that file are
 * byte-for-byte what a real Read Configuration Data (0x19) response
 * would contain; the rest is libmobile-bgb's own on-disk container
 * format, out of scope here).
 *
 * Build/run via:
 *   make test
 * (must be run from the repo root so the relative "config.bin" path
 * resolves; `make test` already does this).
 */
#include "magb_config.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;

static void check(bool cond, const char *what)
{
    if (cond) {
        printf("[PASS] %s\n", what);
    } else {
        printf("[FAIL] %s\n", what);
        g_failures++;
    }
}

static bool load_fixture(uint8_t out[MAGB_CONFIG_SIZE])
{
    FILE *f = fopen("config.bin", "rb");
    size_t n;
    if (f == NULL) {
        return false;
    }
    n = fread(out, 1U, MAGB_CONFIG_SIZE, f);
    fclose(f);
    return n == MAGB_CONFIG_SIZE;
}

/* Every field asserted here was read directly out of the real
 * config.bin with `xxd` and cross-checked against
 * docs/dandocs-magb.md's "Configuration Data" section before being
 * hardcoded -- this is a regression test against a known-good real
 * capture, not an invented vector. */
static void test_real_capture(void)
{
    uint8_t config[MAGB_CONFIG_SIZE];
    char phone[17];
    char id[MAGB_CONFIG_SLOT_ID_LEN + 1U];
    uint8_t login_len;

    if (!load_fixture(config)) {
        /* Not a failure: config.bin is a real captured account config,
         * deliberately not committed to the repo (see README.md), so
         * it's expected to be absent on a fresh checkout -- CI in
         * particular will never have one. Only a *present but wrong*
         * fixture is a real regression. */
        printf("[SKIP] config.bin fixture not found -- provide one at the repo root to run this test\n");
        return;
    }

    check(config[MAGB_CONFIG_OFF_MAGIC] == 'M' && config[MAGB_CONFIG_OFF_MAGIC + 1U] == 'A',
          "real capture: magic == \"MA\"");

    check(magb_config_checksum_ok(config),
          "real capture: stored checksum matches the additive sum of bytes 0x00-0xBD");

    /* Login ID: "g000000034", exactly the documented gXXXXXXXXX shape. */
    login_len = MAGB_CONFIG_LOGIN_ID_LEN;
    check(memcmp(&config[MAGB_CONFIG_OFF_LOGIN_ID], "g000000034", login_len) == 0,
          "real capture: login ID == \"g000000034\"");

    /* DNS servers match Dan Docs' documented Mobile System GB defaults
     * exactly (210.196.3.183 / 210.141.112.163), independent confirmation
     * that this file really is a stock Mobile Adapter GB configuration. */
    check(config[MAGB_CONFIG_OFF_DNS1] == 210U && config[MAGB_CONFIG_OFF_DNS1 + 1U] == 196U &&
          config[MAGB_CONFIG_OFF_DNS1 + 2U] == 3U && config[MAGB_CONFIG_OFF_DNS1 + 3U] == 183U,
          "real capture: primary DNS == 210.196.3.183 (Dan Docs default)");
    check(config[MAGB_CONFIG_OFF_DNS2] == 210U && config[MAGB_CONFIG_OFF_DNS2 + 1U] == 141U &&
          config[MAGB_CONFIG_OFF_DNS2 + 2U] == 112U && config[MAGB_CONFIG_OFF_DNS2 + 3U] == 163U,
          "real capture: secondary DNS == 210.141.112.163 (Dan Docs default)");

    /* Configuration Slot 1: BCD phone "#9677" + ID string "DION PDC/CDMAONE",
     * the exact documented PDC/CDMA default -- Mobile Trainer wrote this
     * slot for real when this file was captured. */
    check(magb_config_decode_phone(&config[MAGB_CONFIG_OFF_SLOT1], phone, sizeof(phone)) == 5U &&
          strcmp(phone, "#9677") == 0,
          "real capture: Slot 1 phone decodes to \"#9677\"");
    memcpy(id, &config[MAGB_CONFIG_OFF_SLOT1 + MAGB_CONFIG_SLOT_PHONE_LEN], MAGB_CONFIG_SLOT_ID_LEN);
    id[MAGB_CONFIG_SLOT_ID_LEN] = '\0';
    check(strcmp(id, "DION PDC/CDMAONE") == 0,
          "real capture: Slot 1 ID string == \"DION PDC/CDMAONE\"");

    /* Slot 2/3 are Mobile Trainer's untouched filler -- their phone
     * field is documented as unused/FF, so decoding must stop
     * immediately (0 chars) rather than emit garbage. */
    check(magb_config_decode_phone(&config[MAGB_CONFIG_OFF_SLOT2], phone, sizeof(phone)) == 0U,
          "real capture: Slot 2 (unused, all-FF phone) decodes to an empty string");
}

/* Synthetic vectors for edge cases the real capture doesn't happen to
 * exercise (a '*' digit, a mid-field terminator, an all-zero blank
 * field). */
static void test_phone_decode_synthetic(void)
{
    char out[17];
    uint8_t n;

    {
        /* "*123" then end: B1 23 Fx ... */
        const uint8_t phone[MAGB_CONFIG_SLOT_PHONE_LEN] = { 0xB1, 0x23, 0xF0, 0, 0, 0, 0, 0 };
        n = magb_config_decode_phone(phone, out, sizeof(out));
        check(n == 4U && strcmp(out, "*123") == 0,
              "synthetic: '*' nibble and mid-byte terminator decode to \"*123\"");
    }
    {
        /* Terminator in the very first (high) nibble -> empty string. */
        const uint8_t phone[MAGB_CONFIG_SLOT_PHONE_LEN] = { 0xF0, 0, 0, 0, 0, 0, 0, 0 };
        n = magb_config_decode_phone(phone, out, sizeof(out));
        check(n == 0U && out[0] == '\0',
              "synthetic: immediate terminator decodes to an empty string");
    }
    {
        /* Full 16 digits, no terminator at all within the field --
         * must not overrun `out` (out_cap=17 covers exactly 16 chars + NUL). */
        const uint8_t phone[MAGB_CONFIG_SLOT_PHONE_LEN] =
            { 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56 };
        n = magb_config_decode_phone(phone, out, sizeof(out));
        check(n == 16U && strcmp(out, "1234567890123456") == 0,
              "synthetic: 16 digits with no terminator fills the buffer exactly, no overrun");
    }
}

static void test_checksum_synthetic(void)
{
    uint8_t config[MAGB_CONFIG_SIZE];
    uint16_t sum = 0U;
    uint16_t i;

    memset(config, 0x00, sizeof(config));
    for (i = 0U; i < MAGB_CONFIG_SIZE; i++) {
        config[i] = (uint8_t)(i * 7U + 3U);
    }
    for (i = 0U; i < MAGB_CONFIG_OFF_CHECKSUM; i++) {
        sum = (uint16_t)(sum + config[i]);
    }
    config[MAGB_CONFIG_OFF_CHECKSUM] = (uint8_t)(sum >> 8);
    config[MAGB_CONFIG_OFF_CHECKSUM + 1U] = (uint8_t)sum;
    check(magb_config_checksum_ok(config), "synthetic: correct checksum validates");

    config[MAGB_CONFIG_OFF_CHECKSUM] ^= 0xFFU;
    check(!magb_config_checksum_ok(config), "synthetic: corrupted checksum is rejected");
}

int main(void)
{
    test_real_capture();
    test_phone_decode_synthetic();
    test_checksum_synthetic();

    if (g_failures == 0) {
        printf("\nAll config tests passed.\n");
        return 0;
    }
    printf("\n%d config test(s) FAILED.\n", g_failures);
    return 1;
}
