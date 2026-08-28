/* Mobile Adapter GB transport-level session handling.
 *
 * The request/response cycle here was derived byte-for-byte from
 * libmobile/serial.c's state machine (mobile_serial_transfer()). See
 * docs/protocol-notes.md for the full walk-through with file:line
 * citations. Summary of the wire sequence for one command:
 *
 *   GBC -> 99 66 CMD 00 LENH LENL <payload> CKH CKL   (the request)
 *   GBC -> 80 (device ack)                 <- adapter: DEVICE|0x80  (ACK1, piggybacked on the CKL transfer)
 *                                           <- adapter: CMD^0x80 or 0xF0/F1/F2  (ACK2, this transfer)
 *   GBC -> filler                          <- adapter: 0xD2 (ignored)
 *   GBC -> 0x4B (mandatory "go ahead")     <- adapter: 0xD2 (ignored)
 *   ... GBC keeps sending 0x4B, polling  ... <- adapter: 0xD2 while busy
 *   GBC -> filler (x2)                     <- adapter: 99 66 RCMD 00 LENH LENL <payload> CKH CKL (the response)
 *   GBC -> filler                          <- adapter: DEVICE|0x80  (response ACK1)
 *   GBC -> filler                          <- adapter: 0x00
 *   GBC -> 0x00 (ok) or 0xF1 (bad checksum) <- adapter: 0xD2 (retries response from the top on error)
 */
#include "magb_session.h"
#include "magb_commands.h"
#include "serial_hw.h"
#include <stddef.h>

static uint8_t xfer(magb_context_t *ctx, uint8_t tx, magb_result_t *err)
{
    uint8_t rx = 0U;
    if (serial_transfer_byte(tx, &rx) != SERIAL_HW_OK) {
        *err = MAGB_ERR_TIMEOUT;
        return 0U;
    }
    magb_trace_record(ctx, MAGB_TRACE_TX, tx);
    magb_trace_record(ctx, MAGB_TRACE_RX, rx);
    return rx;
}

void magb_context_init(magb_context_t *ctx)
{
    ctx->session_active = false;
    ctx->adapter_device = 0U;
    ctx->cancel_check = NULL;
    ctx->trace_head = 0U;
    ctx->trace_count = 0U;
    ctx->last_command_sent = 0U;
    ctx->last_command_recv = 0U;
    ctx->remote_error_command = 0U;
    ctx->remote_error_code = 0U;
}

void magb_trace_record(magb_context_t *ctx, uint8_t direction, uint8_t value)
{
    ctx->trace[ctx->trace_head].direction = direction;
    ctx->trace[ctx->trace_head].value = value;
    ctx->trace_head = (uint8_t)((ctx->trace_head + 1U) % MAGB_TRACE_LEN);
    if (ctx->trace_count < MAGB_TRACE_LEN) {
        ctx->trace_count++;
    }
}

magb_result_t magb_wake_adapter(magb_context_t *ctx)
{
    magb_result_t err = MAGB_OK;
    (void)xfer(ctx, 0x00U, &err); /* sacrificial transfer; response is garbage/0xD2, discarded either way */
    if (err != MAGB_OK) {
        return err;
    }
    serial_wait_vblanks(7U); /* ~100ms @ ~59.7Hz, see docs/protocol-notes.md */
    return MAGB_OK;
}

/* ---- Request phase: send magic+header+payload+checksum -----------
 * Returns the RX byte from the very last transfer (the checksum-low
 * byte) via *ack1_out: per libmobile's state machine, the adapter's
 * ACK1 (device id | 0x80) is piggybacked on that exact transfer,
 * there is no separate transfer for it. */
static magb_result_t send_request_frame(magb_context_t *ctx, uint8_t command,
                                         const uint8_t *payload, uint8_t payload_len,
                                         uint8_t *ack1_out)
{
    uint8_t out[MAGB_MAX_FRAME_LEN];
    uint16_t out_len = 0U;
    uint16_t i;
    magb_result_t r = magb_build_frame(out, sizeof(out), &out_len, command, 0x00U,
                                        payload, payload_len);
    magb_result_t err = MAGB_OK;
    uint8_t rx = 0U;

    if (r != MAGB_OK) {
        return r;
    }

    for (i = 0U; i < out_len; i++) {
        rx = xfer(ctx, out[i], &err);
        if (err != MAGB_OK) {
            return err;
        }
    }
    *ack1_out = rx;
    return MAGB_OK;
}

/* ---- Request-ACK phase: device ack, command echo / transport error
 *
 * Both ACK1 (device id) and ACK2 (command echo/error) are validated
 * best-effort, never fatally on an unexpected-but-non-error value.
 * This was tightened twice while bringing this ROM up against a real
 * BGB + libmobile-bgb link, using its own byte-level link log
 * cross-referenced against a known-good ROM's log on the same setup:
 *
 *   1. The adapter/relay can still return MAGB_ADAPTER_WAIT (0xD2,
 *      "still processing") on the transfer that would carry ACK1 or
 *      ACK2 -- real, observed relay latency (confirmed absent when
 *      feeding the same bytes directly into libmobile's C source,
 *      off-hardware: it always answers synchronously, zero delay).
 *      0xD2 means "not ready yet" everywhere else in this protocol;
 *      it must be tolerated the same way here.
 *
 *   2. That relay latency is not occasional -- it consistently
 *      delivers each meaningful byte one transfer later than a
 *      synchronous model predicts, which means the byte landing at
 *      the "ACK2" checkpoint can legitimately be a delayed ACK1
 *      (device-id-shaped) rather than the real ACK2 (command-echo-
 *      shaped) -- confirmed by realigning two link logs (this ROM's
 *      and a known-good ROM's) by exactly one transfer and finding
 *      both decode into a perfectly valid handshake once shifted.
 *      Requiring an exact ack2 == command|0x80 match was therefore
 *      itself the bug: only the three documented transport-error
 *      codes (0xF0/0xF1/0xF2) are unambiguous regardless of this
 *      shift, so those are the only values treated as fatal here.
 *
 * The fixed handshake byte sequence (device ack, filler, mandatory
 * 0x4B) is always sent regardless of what ACK1/ACK2 looked like; the
 * response frame's own checksum (validated later, in
 * read_response_frame()) is the real, authoritative success signal
 * for the whole exchange -- not any single intermediate ACK byte. */
static magb_result_t request_ack_phase(magb_context_t *ctx, uint8_t command,
                                        uint8_t ack1, bool *retry)
{
    magb_result_t err = MAGB_OK;
    uint8_t ack2;

    (void)command;
    *retry = false;

    if (MAGB_IS_KNOWN_ADAPTER_DEVICE(ack1 & (uint8_t)~MAGB_GBC_DEVICE_ACK)) {
        ctx->adapter_device = (uint8_t)(ack1 & (uint8_t)~MAGB_GBC_DEVICE_ACK);
    }
    /* else: not a valid device-id shape (still 0xD2, or a delayed
     * byte from a different step) -- leave ctx->adapter_device as
     * whatever it was; never fatal here. */

    ack2 = xfer(ctx, MAGB_GBC_DEVICE_ACK, &err);
    if (err != MAGB_OK) {
        return err;
    }

    if (ack2 == MAGB_ACK_ERR_UNSUPPORTED) {
        *retry = true;
        return MAGB_ERR_REMOTE_UNSUPPORTED;
    }
    if (ack2 == MAGB_ACK_ERR_CHECKSUM) {
        *retry = true;
        return MAGB_ERR_REMOTE_CHECKSUM;
    }
    if (ack2 == MAGB_ACK_ERR_INTERNAL) {
        *retry = true;
        return MAGB_ERR_REMOTE_INTERNAL;
    }
    /* Anything else (0xD2, a delayed ACK1, or the real ACK2) is not
     * one of the three documented transport errors -- proceed.
     *
     * If ACK1 hadn't already arrived by the time it was checked above
     * (0xD2), it can turn up here instead, one transfer late -- catch
     * it opportunistically so a delayed device id is not simply lost
     * (e.g. magb_dial()'s validation byte depends on knowing the
     * adapter is Blue, and every ACK1/ACK2 byte range is disjoint from
     * 0xF0-0xF2, so checking this unconditionally is safe). */
    if (MAGB_IS_KNOWN_ADAPTER_DEVICE(ack2 & (uint8_t)~MAGB_GBC_DEVICE_ACK)) {
        ctx->adapter_device = (uint8_t)(ack2 & (uint8_t)~MAGB_GBC_DEVICE_ACK);
    }

    /* Filler, then the mandatory "go ahead and process" byte. */
    (void)xfer(ctx, MAGB_GBC_WAIT, &err);
    if (err != MAGB_OK) {
        return err;
    }
    (void)xfer(ctx, MAGB_GBC_WAIT, &err);
    if (err != MAGB_OK) {
        return err;
    }

    return MAGB_OK;
}

/* ---- Wait for the adapter to finish processing and start replying - */
static magb_result_t wait_for_response_start(magb_context_t *ctx, uint16_t timeout_frames)
{
    magb_result_t err = MAGB_OK;
    uint16_t start = serial_now();
    uint8_t rx;

    for (;;) {
        rx = xfer(ctx, MAGB_GBC_WAIT, &err);
        if (err != MAGB_OK) {
            return err;
        }
        if (rx != MAGB_ADAPTER_WAIT) {
            /* rx is the response's first magic byte (0x99). */
            if (rx != MAGB_MAGIC_1) {
                return MAGB_ERR_BAD_MAGIC;
            }
            return MAGB_OK;
        }
        if (ctx->cancel_check != NULL && ctx->cancel_check()) {
            return MAGB_ERR_CANCELLED;
        }
        if (serial_elapsed_frames(start) > timeout_frames) {
            return MAGB_ERR_TIMEOUT;
        }
    }
}

/* ---- Receive magic(2nd)+header+payload+checksum into `response` -- */
static magb_result_t read_response_frame(magb_context_t *ctx, magb_packet_t *response,
                                          bool *checksum_ok)
{
    magb_parser_t p;
    magb_result_t err = MAGB_OK;
    magb_rx_state_t state;
    uint8_t rx;

    magb_parser_reset(&p);
    /* Feed the already-consumed first magic byte manually. */
    state = magb_parser_feed(&p, MAGB_MAGIC_1);

    for (;;) {
        rx = xfer(ctx, MAGB_GBC_WAIT, &err);
        if (err != MAGB_OK) {
            return err;
        }
        state = magb_parser_feed(&p, rx);
        if (state == MAGB_RX_DONE || state == MAGB_RX_ERROR) {
            break;
        }
    }

    *response = p.packet;
    *checksum_ok = (state == MAGB_RX_DONE);
    if (!*checksum_ok) {
        return p.error;
    }
    return MAGB_OK;
}

/* ---- Response-ACK phase: GBC acknowledges (or NACKs) the response - */
static magb_result_t response_ack_phase(magb_context_t *ctx, bool checksum_ok)
{
    magb_result_t err = MAGB_OK;
    uint8_t response_ack1;

    response_ack1 = xfer(ctx, MAGB_GBC_WAIT, &err); /* adapter device id, opportunistic */
    if (err != MAGB_OK) {
        return err;
    }
    if (MAGB_IS_KNOWN_ADAPTER_DEVICE(response_ack1 & (uint8_t)~MAGB_GBC_DEVICE_ACK)) {
        ctx->adapter_device = (uint8_t)(response_ack1 & (uint8_t)~MAGB_GBC_DEVICE_ACK);
    }
    (void)xfer(ctx, MAGB_GBC_WAIT, &err); /* always 0x00 from the adapter, don't-care */
    if (err != MAGB_OK) {
        return err;
    }

    (void)xfer(ctx, checksum_ok ? 0x00U : MAGB_ACK_ERR_CHECKSUM, &err);
    if (err != MAGB_OK) {
        return err;
    }

    return checksum_ok ? MAGB_OK : MAGB_ERR_BAD_CHECKSUM;
}

magb_result_t magb_execute(magb_context_t *ctx, uint8_t command,
                            const uint8_t *payload, uint8_t payload_len,
                            magb_packet_t *response, uint16_t timeout_frames)
{
    magb_result_t r;
    uint8_t attempt;
    bool retry;
    bool checksum_ok;
    uint8_t ack1;

    ctx->last_command_sent = command;

    for (attempt = 0U; attempt < MAGB_MAX_RETRANSMIT; attempt++) {
        r = send_request_frame(ctx, command, payload, payload_len, &ack1);
        if (r != MAGB_OK) {
            return r;
        }

        r = request_ack_phase(ctx, command, ack1, &retry);
        if (r == MAGB_OK) {
            break;
        }
        if (!retry) {
            return r;
        }
        /* Transport-level NACK (0xF0/F1/F2): resend the whole request. */
    }
    if (attempt >= MAGB_MAX_RETRANSMIT) {
        return r;
    }

    r = wait_for_response_start(ctx, timeout_frames);
    if (r != MAGB_OK) {
        return r;
    }

    for (attempt = 0U; attempt < MAGB_MAX_RETRANSMIT; attempt++) {
        r = read_response_frame(ctx, response, &checksum_ok);
        if (r != MAGB_OK && r != MAGB_ERR_BAD_CHECKSUM) {
            /* Desync (bad magic/length) rather than a corrupted-in-
             * transit checksum: there is nothing a resend-request can
             * fix here, since we can no longer trust our own byte
             * count. Give up immediately instead of retrying. */
            return r;
        }

        r = response_ack_phase(ctx, checksum_ok);
        if (r == MAGB_ERR_TIMEOUT) {
            return r;
        }
        if (checksum_ok) {
            break;
        }
        /* checksum_ok was false: adapter will resend the same response. */
    }
    if (!checksum_ok) {
        return MAGB_ERR_BAD_CHECKSUM;
    }

    ctx->last_command_recv = response->command;

    if (response->command == magb_response_command(MAGB_CMD_ERROR_STATUS)) {
        if (response->payload_len >= 2U) {
            ctx->remote_error_command = response->payload[0];
            ctx->remote_error_code = response->payload[1];
        }
        return MAGB_ERR_REMOTE_STATUS;
    }
    return MAGB_OK;
}

magb_result_t magb_begin_session(magb_context_t *ctx)
{
    static const uint8_t nintendo[MAGB_NINTENDO_MAGIC_LEN] =
        { 'N', 'I', 'N', 'T', 'E', 'N', 'D', 'O' };
    magb_packet_t response;
    magb_result_t r;

    ctx->session_active = false;

    r = magb_wake_adapter(ctx);
    if (r != MAGB_OK) {
        return r;
    }

    /* magb_execute() already captures+validates the adapter device id
     * (via request_ack_phase()) for every command, Begin Session
     * included -- see ctx->adapter_device afterwards. */
    r = magb_execute(ctx, MAGB_CMD_BEGIN_SESSION, nintendo, MAGB_NINTENDO_MAGIC_LEN,
                      &response, MAGB_TIMEOUT_FRAMES_SHORT);
    if (r != MAGB_OK) {
        return r;
    }

    if (response.command != magb_response_command(MAGB_CMD_BEGIN_SESSION)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    if (response.payload_len != MAGB_NINTENDO_MAGIC_LEN) {
        return MAGB_ERR_BAD_LENGTH;
    }
    {
        uint8_t i;
        for (i = 0U; i < MAGB_NINTENDO_MAGIC_LEN; i++) {
            if (response.payload[i] != nintendo[i]) {
                return MAGB_ERR_SESSION;
            }
        }
    }

    ctx->session_active = true;
    return MAGB_OK;
}

magb_result_t magb_end_session(magb_context_t *ctx)
{
    magb_packet_t response;
    magb_result_t r = magb_execute(ctx, MAGB_CMD_END_SESSION, NULL, 0U, &response,
                                    MAGB_TIMEOUT_FRAMES_SHORT);
    ctx->session_active = false;
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_END_SESSION)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    return MAGB_OK;
}
