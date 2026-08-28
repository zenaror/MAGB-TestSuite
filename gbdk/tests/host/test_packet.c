/* Host-side unit tests for the hardware-independent MAGB packet layer.
 *
 * Build/run via:
 *   make test
 * or directly:
 *   cc -Iinclude tests/host/test_packet.c src/protocol/magb_packet.c \
 *       -o build/test_packet && ./build/test_packet
 */
#include "magb_protocol.h"

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

/* Section 12: known Begin Session vector.
 *   99 66 10 00 00 08 4E 49 4E 54 45 4E 44 4F 02 77
 * Checksum must be 0x0277. ACK bytes are not part of this vector. */
static void test_begin_session_vector(void)
{
    static const uint8_t expected[] = {
        0x99, 0x66,
        0x10, 0x00, 0x00, 0x08,
        0x4E, 0x49, 0x4E, 0x54, 0x45, 0x4E, 0x44, 0x4F,
        0x02, 0x77
    };
    const uint8_t payload[8] = "NINTENDO";
    uint8_t out[MAGB_MAX_FRAME_LEN];
    uint16_t out_len = 0U;
    magb_result_t r;

    check(magb_checksum(0x10U, 0x00U, payload, 8U) == 0x0277U,
          "Begin Session checksum == 0x0277");

    r = magb_build_frame(out, sizeof(out), &out_len, 0x10U, 0x00U, payload, 8U);
    check(r == MAGB_OK, "Begin Session build_frame returns MAGB_OK");
    check(out_len == sizeof(expected), "Begin Session frame length == 16");
    check(memcmp(out, expected, sizeof(expected)) == 0,
          "Begin Session frame bytes match Section 12 vector exactly");
}

/* Zero-length payload vector: End Session (0x11). */
static void test_end_session_zero_payload(void)
{
    uint8_t out[MAGB_MAX_FRAME_LEN];
    uint16_t out_len = 0U;
    magb_result_t r;
    uint16_t checksum;

    checksum = magb_checksum(0x11U, 0x00U, NULL, 0U);
    check(checksum == 0x0011U, "End Session (zero payload) checksum == 0x0011");

    r = magb_build_frame(out, sizeof(out), &out_len, 0x11U, 0x00U, NULL, 0U);
    check(r == MAGB_OK, "End Session build_frame returns MAGB_OK");
    check(out_len == 8U, "End Session frame length == 8 (no payload bytes)");
    check(out[0] == 0x99U && out[1] == 0x66U, "End Session frame starts with magic");
    check(out[2] == 0x11U && out[3] == 0x00U && out[4] == 0x00U && out[5] == 0x00U,
          "End Session header is command=0x11 reserved=0 length=0");
    check(out[6] == 0x00U && out[7] == 0x11U,
          "End Session checksum bytes are 00 11");
}

static void test_oversized_payload_rejected(void)
{
    static uint8_t huge_payload[255];
    uint8_t out[MAGB_MAX_FRAME_LEN];
    uint16_t out_len = 0xDEADU;
    magb_result_t r;
    memset(huge_payload, 0xAA, sizeof(huge_payload));

    r = magb_build_frame(out, sizeof(out), &out_len, 0x15U, 0x00U,
                          huge_payload, 255U);
    check(r == MAGB_ERR_PAYLOAD_TOO_LARGE,
          "255-byte payload rejected as MAGB_ERR_PAYLOAD_TOO_LARGE");
    check(out_len == 0xDEADU, "out_len left untouched on rejection");
}

static void test_response_command(void)
{
    check(magb_response_command(0x10U) == 0x90U, "response(0x10) == 0x90");
    check(magb_response_command(0x15U) == 0x95U, "response(0x15) == 0x95 (not a generic success byte)");
    check(magb_is_response_command(0x90U), "0x90 is recognized as a response command");
    check(!magb_is_response_command(0x10U), "0x10 is recognized as a request command");
}

/* Feed a known-good frame byte by byte and confirm the parser reaches
 * MAGB_RX_DONE with the exact decoded payload. */
static void test_parser_accepts_valid_frame(void)
{
    static const uint8_t frame[] = {
        0x99, 0x66,
        0x10, 0x00, 0x00, 0x08,
        0x4E, 0x49, 0x4E, 0x54, 0x45, 0x4E, 0x44, 0x4F,
        0x02, 0x77
    };
    magb_parser_t p;
    magb_rx_state_t s = MAGB_RX_MAGIC_1;
    size_t i;

    magb_parser_reset(&p);
    for (i = 0; i < sizeof(frame); i++) {
        s = magb_parser_feed(&p, frame[i]);
    }

    check(s == MAGB_RX_DONE, "parser reaches MAGB_RX_DONE on a valid frame");
    check(p.packet.command == 0x10U, "parser decodes command == 0x10");
    check(p.packet.payload_len == 8U, "parser decodes payload_len == 8");
    check(memcmp(p.packet.payload, "NINTENDO", 8) == 0,
          "parser decodes payload bytes exactly as NINTENDO");
}

/* Corrupt the checksum's low byte and confirm the parser rejects it. */
static void test_parser_rejects_bad_checksum(void)
{
    static const uint8_t frame[] = {
        0x99, 0x66,
        0x10, 0x00, 0x00, 0x08,
        0x4E, 0x49, 0x4E, 0x54, 0x45, 0x4E, 0x44, 0x4F,
        0x02, 0x78 /* corrupted: should be 0x77 */
    };
    magb_parser_t p;
    magb_rx_state_t s = MAGB_RX_MAGIC_1;
    size_t i;

    magb_parser_reset(&p);
    for (i = 0; i < sizeof(frame); i++) {
        s = magb_parser_feed(&p, frame[i]);
    }

    check(s == MAGB_RX_ERROR, "parser reaches MAGB_RX_ERROR on a corrupted checksum");
    check(p.error == MAGB_ERR_BAD_CHECKSUM, "parser reports MAGB_ERR_BAD_CHECKSUM");
}

/* A bad second magic byte is a hard framing error (not silently resynced). */
static void test_parser_rejects_bad_magic(void)
{
    magb_parser_t p;
    magb_rx_state_t s;

    magb_parser_reset(&p);
    s = magb_parser_feed(&p, 0x99U);
    check(s == MAGB_RX_MAGIC_2, "parser advances past a correct first magic byte");
    s = magb_parser_feed(&p, 0x00U); /* should have been 0x66 */
    check(s == MAGB_RX_ERROR, "parser reaches MAGB_RX_ERROR on a bad second magic byte");
    check(p.error == MAGB_ERR_BAD_MAGIC, "parser reports MAGB_ERR_BAD_MAGIC");
}

/* Garbage before the magic must be skipped (resync on 0x99). */
static void test_parser_resyncs_on_garbage_prefix(void)
{
    magb_parser_t p;
    magb_rx_state_t s;

    magb_parser_reset(&p);
    s = magb_parser_feed(&p, 0xD2U); /* adapter wait byte, not magic */
    check(s == MAGB_RX_MAGIC_1, "parser ignores a stray 0xD2 before magic");
    s = magb_parser_feed(&p, 0x99U);
    check(s == MAGB_RX_MAGIC_2, "parser locks on once 0x99 arrives");
}

int main(void)
{
    test_begin_session_vector();
    test_end_session_zero_payload();
    test_oversized_payload_rejected();
    test_response_command();
    test_parser_accepts_valid_frame();
    test_parser_rejects_bad_checksum();
    test_parser_rejects_bad_magic();
    test_parser_resyncs_on_garbage_prefix();

    if (g_failures == 0) {
        printf("\nAll tests passed.\n");
        return 0;
    }
    printf("\n%d test(s) FAILED.\n", g_failures);
    return 1;
}
