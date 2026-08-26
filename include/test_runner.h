/** Layer 3 -- TestSuite test groups. Sequences real magb_network.h /
 * magb_session.h calls and reports a generic, diagnostic-rich result.
 * No SB_REG/SC_REG access happens here -- only Layer 2 calls.
 */
#ifndef TEST_RUNNER_H
#define TEST_RUNNER_H

#include "magb_protocol.h"
#include "magb_session.h"
#include "magb_network.h"
#include <stdint.h>
#include <stdbool.h>

/** Generic per-test outcome (Section 37). `detail` holds up to two
 * screen-width diagnostic lines the UI prints verbatim. */
typedef struct {
    bool passed;
    magb_result_t result;

    uint8_t command;
    uint8_t expected;
    uint8_t actual;

    uint16_t tx_bytes;
    uint16_t rx_bytes;

    char detail[2][21];

    /** Official Mobile Adapter GB error code ("NN-NNN", e.g.
     * "24-000"), as displayed by real Nintendo software, when this
     * failure maps onto one of the documented codes. Empty if not
     * applicable (e.g. this TestSuite's own low-level framing errors
     * have no official code). See docs/protocol-notes.md, "Official
     * Mobile Adapter GB error codes". */
    char official_code[8];
} test_result_t;

/** Test 1: wake, Begin Session, identify the adapter, End Session. */
void test_adapter_session(magb_context_t *ctx, test_result_t *out);

/** Test 2: Begin Session, Telephone Status, Dial ISP, ISP Login, DNS,
 * TCP Open, HTTP GET against `host`:`port``path`, TCP Close, ISP
 * Logout, Hang Up, End Session. `host`/`path` are not copied -- they
 * must remain valid for the duration of the call (string literals or
 * static storage, as in `include/test_config.h`, are fine). */
void test_isp_http(magb_context_t *ctx, test_result_t *out,
                    const char *host, uint16_t port, const char *path);

/** Like test_isp_http(), but performs REON's GB00 challenge/response
 * HTTP authentication first if the server answers with 401 and a
 * WWW-Authenticate: GB00 header (see docs/protocol-notes.md, "GB00
 * HTTP authentication"). Uses TEST_ISP_LOGIN/TEST_ISP_PASSWORD as the
 * account credentials. */
void test_isp_http_gb00(magb_context_t *ctx, test_result_t *out,
                         const char *host, uint16_t port, const char *path);

/** Test 2b: Begin Session, Dial ISP, ISP Login, Read Configuration to
 * find the adapter's own configured email address + SMTP server, DNS,
 * TCP Open (port 25), a minimal SMTP dialogue (HELO/MAIL FROM/RCPT
 * TO/DATA) sending a short message to that same address, TCP Close,
 * ISP Logout, Hang Up, End Session. */
void test_isp_email_send(magb_context_t *ctx, test_result_t *out);

/** Test 2c: like test_isp_email_send(), but against the configured
 * POP3 server: USER (the local part of the configured email address)
 * / PASS (TEST_ISP_PASSWORD) / STAT, reporting the mailbox message
 * count. */
void test_isp_email_recv(magb_context_t *ctx, test_result_t *out);

/** Test 3 (Caller role): Begin Session, Dial `number`, exchange the
 * MATS test frames, Hang Up, End Session. */
void test_p2p_caller(magb_context_t *ctx, test_result_t *out, const char *number);

/** Test 3 (Listener role): Begin Session, Wait For Call, exchange the
 * MATS test frames (responder side), Hang Up, End Session. */
void test_p2p_listener(magb_context_t *ctx, test_result_t *out);

/** Read Configuration Data (0x19), both halves, into `config_out`. */
void test_read_config(magb_context_t *ctx, uint8_t config_out[MAGB_CONFIG_SIZE], test_result_t *out);

#endif /* TEST_RUNNER_H */
