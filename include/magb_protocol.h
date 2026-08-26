/** Layer 2 -- Mobile Adapter GB wire protocol: packet format.
 *
 * This header is intentionally hardware-free: no gb/gb.h, no SB_REG,
 * no timing. That is what lets tests/host/test_packet.c build and run
 * with the host's native compiler (see the Makefile `test` target).
 *
 * Wire format (see docs/protocol-notes.md for the full derivation and
 * source citations):
 *
 *   byte 0-1   magic            0x99 0x66
 *   byte 2     command
 *   byte 3     reserved/peer-id (0x00 from the GBC; see magb_commands.h
 *              for the device-id/response-bit convention on replies)
 *   byte 4     payload length, high byte (always 0x00, payload <= 254)
 *   byte 5     payload length, low byte
 *   byte 6..   payload (0..254 bytes)
 *   next 2     checksum, big-endian (high byte first)
 *
 * The checksum is the 16-bit unsigned sum of command + reserved +
 * length_high + length_low + every payload byte. The 0x99 0x66 magic
 * is NOT part of the checksum.
 *
 * IMPORTANT: 0x02/0x03 (STX/ETX) are NOT Mobile Adapter GB packet
 * delimiters. That framing belongs to unrelated Game Boy Printer-link
 * accessories documented elsewhere on Dan Docs. Do not introduce them
 * here.
 */
#ifndef MAGB_PROTOCOL_H
#define MAGB_PROTOCOL_H

#include <stdint.h>
#include <stdbool.h>

#define MAGB_MAGIC_1 ((uint8_t)0x99)
#define MAGB_MAGIC_2 ((uint8_t)0x66)

#define MAGB_HEADER_LEN 4U  /* command, reserved, length_high, length_low */
#define MAGB_CHECKSUM_LEN 2U
#define MAGB_MAX_PAYLOAD 254U

/* magic(2) + header(4) + payload(<=254) + checksum(2) */
#define MAGB_MAX_FRAME_LEN (2U + MAGB_HEADER_LEN + MAGB_MAX_PAYLOAD + MAGB_CHECKSUM_LEN)

/* Response command bit: response_command = request_command | 0x80.
 * NOTE: 0x95 is simply 0x15|0x80 (the Transfer Data response). It is
 * NOT a generic "handshake succeeded" byte -- do not special-case it. */
#define MAGB_RESPONSE_BIT ((uint8_t)0x80)

/* Flow-control bytes (see docs/protocol-notes.md, section on wait bytes). */
#define MAGB_ADAPTER_WAIT ((uint8_t)0xD2) /* adapter -> GBC: "still processing" */
#define MAGB_GBC_WAIT     ((uint8_t)0x4B) /* GBC -> adapter: clock-filler while reading a response */

/* Documented ACK-phase error bytes returned by the adapter. */
#define MAGB_ACK_ERR_UNSUPPORTED ((uint8_t)0xF0)
#define MAGB_ACK_ERR_CHECKSUM    ((uint8_t)0xF1)
#define MAGB_ACK_ERR_INTERNAL    ((uint8_t)0xF2)

/* Bounded retransmission on a checksum NACK. */
#define MAGB_MAX_RETRANSMIT 4U

typedef enum {
    MAGB_OK = 0,

    MAGB_ERR_TIMEOUT,
    MAGB_ERR_NOT_CGB,
    MAGB_ERR_ADAPTER_NOT_FOUND,

    MAGB_ERR_BAD_MAGIC,
    MAGB_ERR_BAD_LENGTH,
    MAGB_ERR_PAYLOAD_TOO_LARGE,
    MAGB_ERR_BAD_CHECKSUM,
    MAGB_ERR_BAD_ACK,
    MAGB_ERR_BAD_DEVICE_ID,
    MAGB_ERR_UNEXPECTED_COMMAND,

    MAGB_ERR_REMOTE_UNSUPPORTED,
    MAGB_ERR_REMOTE_CHECKSUM,
    MAGB_ERR_REMOTE_INTERNAL,

    MAGB_ERR_SESSION,
    MAGB_ERR_PHONE,
    MAGB_ERR_ISP,
    MAGB_ERR_DNS,
    MAGB_ERR_TCP,
    MAGB_ERR_P2P,

    MAGB_ERR_CANCELLED
} magb_result_t;

/** A logical, already-decoded MAGB packet (no magic/checksum bytes). */
typedef struct {
    uint8_t command;
    uint8_t reserved;
    uint8_t payload[MAGB_MAX_PAYLOAD];
    uint8_t payload_len;
} magb_packet_t;

/** 16-bit unsigned sum of command + reserved + length_high + length_low
 * + every payload byte. Does NOT include the 0x99 0x66 magic. */
uint16_t magb_checksum(uint8_t command, uint8_t reserved,
                        const uint8_t *payload, uint8_t payload_len);

/** Serializes magic + header + payload + checksum into `out`.
 *
 * `out_cap` must be at least MAGB_MAX_FRAME_LEN for arbitrary input;
 * the actual encoded length (which depends on payload_len) is written
 * to *out_len on success.
 *
 * Returns MAGB_ERR_PAYLOAD_TOO_LARGE (without touching `out`) if
 * payload_len exceeds MAGB_MAX_PAYLOAD. Never truncates.
 */
magb_result_t magb_build_frame(uint8_t *out, uint16_t out_cap, uint16_t *out_len,
                                uint8_t command, uint8_t reserved,
                                const uint8_t *payload, uint8_t payload_len);

/** Computes the response command id for a given request command id. */
uint8_t magb_response_command(uint8_t command);

/** True if `command` already has the response bit (0x80) set. */
bool magb_is_response_command(uint8_t command);

/* ---- Streaming frame parser -------------------------------------- */

typedef enum {
    MAGB_RX_MAGIC_1 = 0,
    MAGB_RX_MAGIC_2,
    MAGB_RX_COMMAND,
    MAGB_RX_RESERVED,
    MAGB_RX_LENGTH_HIGH,
    MAGB_RX_LENGTH_LOW,
    MAGB_RX_PAYLOAD,
    MAGB_RX_CHECKSUM_HIGH,
    MAGB_RX_CHECKSUM_LOW,
    MAGB_RX_DONE,
    MAGB_RX_ERROR
} magb_rx_state_t;

typedef struct {
    magb_rx_state_t state;
    magb_packet_t packet;
    uint16_t expected_len;   /* payload length announced by the header */
    uint8_t payload_index;
    uint16_t checksum_calc;  /* running sum as bytes arrive */
    uint16_t checksum_recv;  /* checksum bytes as received */
    magb_result_t error;     /* valid once state == MAGB_RX_ERROR */
} magb_parser_t;

/** Resets the parser to start looking for a new frame at MAGB_RX_MAGIC_1. */
void magb_parser_reset(magb_parser_t *p);

/** Feeds one received byte into the parser and returns the new state.
 *
 * On a magic mismatch at MAGB_RX_MAGIC_1 the parser stays at
 * MAGB_RX_MAGIC_1 (silently resynchronizing on the next 0x99), which
 * is safe because 0x99 never legitimately appears as the first byte
 * of anything else in this protocol's framing. A magic mismatch at
 * MAGB_RX_MAGIC_2 (byte 1 not 0x66) is treated as a hard framing
 * error (MAGB_RX_ERROR / MAGB_ERR_BAD_MAGIC) rather than silently
 * resynchronized, since re-scanning mid-stream for 0x99 0x66 risks
 * matching accidental payload data.
 */
magb_rx_state_t magb_parser_feed(magb_parser_t *p, uint8_t byte);

#endif /* MAGB_PROTOCOL_H */
