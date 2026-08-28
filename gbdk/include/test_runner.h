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

/** Test 2: Begin Session, Read Configuration (login ID + Slot 1 dial
 * string, falling back to TEST_ISP_LOGIN/TEST_ISP_PHONE if blank),
 * Telephone Status, Dial ISP, ISP Login (with `password`), DNS, TCP
 * Open, HTTP GET against `host`:`port``path`, TCP Close, ISP Logout,
 * Hang Up, End Session. `host`/`path` are not copied -- they must
 * remain valid for the duration of the call (string literals or
 * static storage, as in `include/test_config.h`, are fine). `password`
 * is not copied either; see main.c's ISP PASSWORD menu entry
 * (ui_edit_text()) for where it comes from. */
void test_isp_http(magb_context_t *ctx, test_result_t *out, const char *password,
                    const char *host, uint16_t port, const char *path);

/** Like test_isp_http(), but performs REON's GB00 challenge/response
 * HTTP authentication first if the server answers with 401 and a
 * WWW-Authenticate: GB00 header (see docs/protocol-notes.md, "GB00
 * HTTP authentication"). The GB00 login is the same live-config login
 * ID test_isp_http() uses; `password` is the same account password. */
void test_isp_http_gb00(magb_context_t *ctx, test_result_t *out, const char *password,
                         const char *host, uint16_t port, const char *path);

/** The "NEWS ARTICLE" test: like test_isp_http_gb00(), but performs
 * the real game's full two-request flow in one ISP session -- fetches
 * TEST_HTTP_NEWS_CONFIG_PATH (news size/SRAM-address/ranking-layout
 * metadata) first, then TEST_HTTP_NEWS_PATH (the actual news content),
 * each with its own GB00 challenge/response, sharing a single DNS
 * Query for TEST_HTTP_HOST. */
void test_isp_news_article(magb_context_t *ctx, test_result_t *out, const char *password);

/** Test 2b: Begin Session, Read Configuration to find the adapter's
 * own configured login ID, dial string, email address and SMTP server,
 * Dial ISP, ISP Login (with `password`), DNS, TCP Open (port 25), a
 * minimal SMTP dialogue (HELO/MAIL FROM/RCPT TO/DATA) sending a short
 * message to that same address, TCP Close, ISP Logout, Hang Up, End
 * Session. */
void test_isp_email_send(magb_context_t *ctx, test_result_t *out, const char *password);

/** Test 2c: like test_isp_email_send(), but against the configured
 * POP3 server: USER (the local part of the configured email address)
 * / PASS (`password`) / STAT, reporting the mailbox message count. */
void test_isp_email_recv(magb_context_t *ctx, test_result_t *out, const char *password);

/** Test 2d ("RAW TCP"): Begin Session, Read Config (login/dial string
 * only), Dial ISP, ISP Login (no password needed -- libmobile doesn't
 * validate it, and there is no fixed auth step here), TCP Open to
 * `ip_digits` (a 12-digit dotted-quad string, same convention as the
 * P2P phone/IP field) : `port`, then a live, open-ended view: incoming
 * bytes are printed to the screen as they arrive until the remote
 * closes the connection or the user cancels with B. Point `ip_digits`
 * at a machine running `nc -l <port>` to see whatever gets typed there
 * appear on the Game Boy screen.
 *
 * Unlike every other test in this file, this one does NOT report
 * through a test_result_t -- there is no fixed correct response to
 * validate, so it draws its own screen directly instead (see the
 * function's own comment in test_runner.c for why). Callers should not
 * call ui_show_result() after this returns; it already shows its own
 * "press A/B" prompt before returning. */
void test_isp_raw_tcp(magb_context_t *ctx, const char *ip_digits, uint16_t port);

/** Test 3 (Caller role): Begin Session, Dial `number`, exchange the
 * MATS test frames, Hang Up, End Session. */
void test_p2p_caller(magb_context_t *ctx, test_result_t *out, const char *number);

/** Test 3 (Listener role): Begin Session, Wait For Call, exchange the
 * MATS test frames (responder side), Hang Up, End Session. */
void test_p2p_listener(magb_context_t *ctx, test_result_t *out);

/** Read Configuration Data (0x19), both halves, into `config_out`. */
void test_read_config(magb_context_t *ctx, uint8_t config_out[MAGB_CONFIG_SIZE], test_result_t *out);

#endif /* TEST_RUNNER_H */
