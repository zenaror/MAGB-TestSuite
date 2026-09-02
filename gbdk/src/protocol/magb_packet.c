#include "magb_protocol.h"

uint16_t magb_checksum(uint8_t command, uint8_t reserved,
                        const uint8_t *payload, uint8_t payload_len)
{
    uint16_t sum = (uint16_t)command + (uint16_t)reserved;
    uint8_t i;

    /* length_high is always 0x00 for the <=254 byte payloads this
     * TestSuite ever sends, but add it explicitly so the formula
     * matches docs/protocol-notes.md byte-for-byte. */
    sum += 0x00U;
    sum += (uint16_t)payload_len;

    for (i = 0U; i < payload_len; i++) {
        sum += (uint16_t)payload[i];
    }

    return sum;
}

magb_result_t magb_build_frame(uint8_t *out, uint16_t out_cap, uint16_t *out_len,
                                uint8_t command, uint8_t reserved,
                                const uint8_t *payload, uint8_t payload_len)
{
    uint16_t checksum;
    uint16_t len;
    uint8_t i;

    if (payload_len > MAGB_MAX_PAYLOAD) {
        return MAGB_ERR_PAYLOAD_TOO_LARGE;
    }

    len = 2U + MAGB_HEADER_LEN + (uint16_t)payload_len + MAGB_CHECKSUM_LEN;
    if (out_cap < len) {
        return MAGB_ERR_PAYLOAD_TOO_LARGE;
    }

    checksum = magb_checksum(command, reserved, payload, payload_len);

    out[0] = MAGB_MAGIC_1;
    out[1] = MAGB_MAGIC_2;
    out[2] = command;
    out[3] = reserved;
    out[4] = 0x00U; /* length_high: payload never exceeds 254 bytes */
    out[5] = payload_len;

    for (i = 0U; i < payload_len; i++) {
        out[6 + i] = payload[i];
    }

    out[6U + payload_len]     = (uint8_t)(checksum >> 8);
    out[6U + payload_len + 1] = (uint8_t)(checksum & 0xFFU);

    *out_len = len;
    return MAGB_OK;
}

uint8_t magb_response_command(uint8_t command)
{
    return (uint8_t)(command | MAGB_RESPONSE_BIT);
}

bool magb_is_response_command(uint8_t command)
{
    return (command & MAGB_RESPONSE_BIT) != 0U;
}

void magb_parser_reset(magb_parser_t *p)
{
    p->state = MAGB_RX_MAGIC_1;
    p->packet.command = 0U;
    p->packet.reserved = 0U;
    p->packet.payload_len = 0U;
    p->expected_len = 0U;
    p->payload_index = 0U;
    p->checksum_calc = 0U;
    p->checksum_recv = 0U;
    p->error = MAGB_OK;
}

magb_rx_state_t magb_parser_feed(magb_parser_t *p, uint8_t byte)
{
    switch (p->state) {
    case MAGB_RX_MAGIC_1:
        if (byte == MAGB_MAGIC_1) {
            p->state = MAGB_RX_MAGIC_2;
        }
        /* else: stay put, resynchronize on the next 0x99. */
        break;

    case MAGB_RX_MAGIC_2:
        if (byte == MAGB_MAGIC_2) {
            p->state = MAGB_RX_COMMAND;
        } else {
            p->error = MAGB_ERR_BAD_MAGIC;
            p->state = MAGB_RX_ERROR;
        }
        break;

    case MAGB_RX_COMMAND:
        p->packet.command = byte;
        p->checksum_calc = (uint16_t)byte;
        p->state = MAGB_RX_RESERVED;
        break;

    case MAGB_RX_RESERVED:
        p->packet.reserved = byte;
        p->checksum_calc += (uint16_t)byte;
        p->state = MAGB_RX_LENGTH_HIGH;
        break;

    case MAGB_RX_LENGTH_HIGH:
        p->checksum_calc += (uint16_t)byte;
        if (byte != 0x00U) {
            /* This TestSuite never expects a >254 byte payload; a
             * non-zero high byte is treated as a framing error
             * rather than silently accepted. */
            p->error = MAGB_ERR_BAD_LENGTH;
            p->state = MAGB_RX_ERROR;
        } else {
            p->state = MAGB_RX_LENGTH_LOW;
        }
        break;

    case MAGB_RX_LENGTH_LOW:
        p->checksum_calc += (uint16_t)byte;
        /* No upper-bound check here: byte is already an 8-bit value
         * (0..255), and MAGB_MAX_RX_PAYLOAD (255, magb_protocol.h) --
         * the real adapter's own documented receive limit, per Dan
         * Docs -- is exactly that type's maximum, so every possible
         * value is already legal and packet.payload[] (sized for
         * MAGB_MAX_RX_PAYLOAD) already has room for it. This state
         * used to accept the byte at face value but size payload[] for
         * the smaller, send-only MAGB_MAX_PAYLOAD (254) instead,
         * silently overrunning it by one byte -- and corrupting
         * payload_len itself, stored right after payload[] -- against
         * a real 255-byte Transfer Data response (a WWW-Authenticate
         * challenge that a raw capture confirmed arrived intact but
         * failed to parse downstream). Fixed by sizing payload[] for
         * MAGB_MAX_RX_PAYLOAD instead of rejecting the byte -- matches
         * rgbds's own ReadResponseFrame, which hit and fixed this
         * identical case first (see protocol.inc's
         * PROTO_MAX_RX_PAYLOAD_LEN comment). */
        p->expected_len = (uint16_t)byte;
        p->packet.payload_len = byte;
        p->payload_index = 0U;
        p->state = (p->expected_len == 0U) ? MAGB_RX_CHECKSUM_HIGH : MAGB_RX_PAYLOAD;
        break;

    case MAGB_RX_PAYLOAD:
        p->packet.payload[p->payload_index] = byte;
        p->checksum_calc += (uint16_t)byte;
        p->payload_index++;
        if ((uint16_t)p->payload_index >= p->expected_len) {
            p->state = MAGB_RX_CHECKSUM_HIGH;
        }
        break;

    case MAGB_RX_CHECKSUM_HIGH:
        p->checksum_recv = (uint16_t)byte << 8;
        p->state = MAGB_RX_CHECKSUM_LOW;
        break;

    case MAGB_RX_CHECKSUM_LOW:
        p->checksum_recv |= (uint16_t)byte;
        if (p->checksum_recv != p->checksum_calc) {
            p->error = MAGB_ERR_BAD_CHECKSUM;
            p->state = MAGB_RX_ERROR;
        } else {
            p->state = MAGB_RX_DONE;
        }
        break;

    case MAGB_RX_DONE:
    case MAGB_RX_ERROR:
    default:
        /* Caller must magb_parser_reset() before feeding more bytes. */
        break;
    }

    return p->state;
}
