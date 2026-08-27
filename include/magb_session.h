/** Layer 2 -- Mobile Adapter GB session: transport-level command
 * exchange (magic/header/payload/checksum + the full ACK/idle-byte
 * handshake), Begin/End Session, and the diagnostic trace buffer.
 *
 * The full command/response cycle implemented here was derived by
 * reading libmobile's serial-layer state machine byte-for-byte (see
 * docs/protocol-notes.md, section "ACK/idle-byte handshake, exactly").
 * It is intentionally more detailed than the commonly-quoted "2 ACK
 * bytes" summary: there are two distinct ACK phases (one right after
 * the request's checksum, one right after the response's checksum),
 * each involving a device-id byte, a command-echo/error byte, and
 * 0x4B/0xD2 idle-byte bookkeeping.
 */
#ifndef MAGB_SESSION_H
#define MAGB_SESSION_H

#include "magb_protocol.h"
#include <stdint.h>
#include <stdbool.h>

#define MAGB_TRACE_LEN 128U

#define MAGB_TRACE_TX 0U
#define MAGB_TRACE_RX 1U

typedef struct {
    uint8_t direction; /* MAGB_TRACE_TX or MAGB_TRACE_RX */
    uint8_t value;
} magb_trace_entry_t;

/* Real-time budgets for the RESPONSE_WAITING poll (in ~59.7 Hz VBlank
 * frames via sys_time). These bound how long the Game Boy will keep
 * clocking 0x4B while the adapter is off doing (possibly networked)
 * work; they are independent of the byte-level hardware timeout in
 * serial_hw.c. See docs/protocol-notes.md for the reasoning. */
#define MAGB_TIMEOUT_FRAMES_SHORT 180U  /* ~3s: session control commands */
#define MAGB_TIMEOUT_FRAMES_LONG  900U  /* ~15s: dial/ISP login/DNS/TCP open */

/** Polled by the protocol layer during any long wait (RESPONSE_WAITING,
 * incoming-call wait, ...) so the application layer can let the user
 * abort with B without the protocol layer knowing about joypad/UI
 * hardware. Returning true aborts the current command with
 * MAGB_ERR_CANCELLED. May be NULL (no cancellation available). */
typedef bool (*magb_cancel_fn_t)(void);

typedef struct {
    bool session_active;
    uint8_t adapter_device;      /* raw id (e.g. MAGB_DEVICE_ADAPTER_BLUE), captured on Begin Session */

    magb_cancel_fn_t cancel_check;

    magb_trace_entry_t trace[MAGB_TRACE_LEN];
    uint8_t trace_head;   /* next write index */
    uint8_t trace_count;  /* number of valid entries, saturates at MAGB_TRACE_LEN */

    /* Last exchange, for the UI's diagnostic screen. */
    uint8_t last_command_sent;
    uint8_t last_command_recv;

    /* Populated by magb_execute() when the adapter reports an Error
     * Status (0x6E) response: which command it says failed, and its
     * command-specific error code (Dan Docs' "6E - Error Status"
     * table). Stale/meaningless unless the most recent magb_result_t
     * was MAGB_ERR_REMOTE_STATUS. */
    uint8_t remote_error_command;
    uint8_t remote_error_code;
} magb_context_t;

void magb_context_init(magb_context_t *ctx);

/** Records one traced byte. Overwrites the oldest entry once the ring
 * buffer is full; never allocates, never grows. */
void magb_trace_record(magb_context_t *ctx, uint8_t direction, uint8_t value);

/** Section 8: sacrificial wake-up transfer + ~7 VBlank settle delay.
 * Always succeeds (the sacrificial response byte is discarded); the
 * only failure mode is a hardware timeout on the single byte transfer,
 * which means no adapter is physically present at all. */
magb_result_t magb_wake_adapter(magb_context_t *ctx);

/** Runs the full command/response cycle for `command`:
 *   - transmits magic+header+payload+checksum
 *   - performs the request-ACK phase (device id + command echo / error),
 *     retransmitting the whole request up to MAGB_MAX_RETRANSMIT times
 *     if the adapter reports 0xF0/0xF1/0xF2 in the echo byte
 *   - sends the 0x4B "go ahead" byte
 *   - polls (bounded by `timeout_frames`) while the adapter is busy
 *   - receives and validates the response frame
 *   - performs the response-ACK phase, asking the adapter to resend
 *     the response (bounded by MAGB_MAX_RETRANSMIT) if our own
 *     checksum validation of it failed
 *
 * On MAGB_OK, `response` holds the decoded response packet and
 * ctx->adapter_device / ctx->last_command_* are updated. This function
 * does NOT itself judge whether response->command is the "right"
 * command for the request -- 0x15 (Transfer Data) can legitimately
 * come back as 0x1F|0x80 instead of 0x15|0x80 to signal a remote
 * disconnect, so that judgment belongs to the network-layer command
 * wrapper that knows which responses are valid for it.
 *
 * The one exception: an Error Status (0x6E) response is never a valid
 * success shape for *any* command, so it's recognized here, once, for
 * every caller instead of duplicating the check in every wrapper
 * (confirmed on real BGB: a P2P Transfer Data poll came back as
 * 0x6E|0x80 with payload [0x15, 0x00], "Transfer Data: invalid
 * connection", after the far end's connection dropped -- every wrapper
 * that only checked for its own expected response command was
 * misreporting this as MAGB_ERR_UNEXPECTED_COMMAND). On that response,
 * this records the failed command/error code in
 * ctx->remote_error_command/_code (Dan Docs' "6E - Error Status"
 * table) and returns MAGB_ERR_REMOTE_STATUS instead of MAGB_OK.
 */
magb_result_t magb_execute(magb_context_t *ctx, uint8_t command,
                            const uint8_t *payload, uint8_t payload_len,
                            magb_packet_t *response, uint16_t timeout_frames);

/** Section 21: Begin Session (0x10) with the literal 8-byte "NINTENDO"
 * payload, validating the echoed payload and capturing the adapter
 * device id. Marks ctx->session_active only once every check passes. */
magb_result_t magb_begin_session(magb_context_t *ctx);

/** End Session (0x11), zero-length payload both ways. */
magb_result_t magb_end_session(magb_context_t *ctx);

#endif /* MAGB_SESSION_H */
