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


/** The "SMALL BUFFER" test: the small half of the synthetic pair that
 * replaced the Pokemon-data "NEWS ARTICLE" test. One GB00-authenticated
 * download of TEST_SMALLBUFFER_SIZE bytes -- small enough to arrive in
 * a single Transfer Data response, so it covers the no-streaming,
 * no-chunking regime BIG BUFFER never touches -- followed by a POST of
 * the same pattern back to the SAME URL, reusing the GET's
 * Authorization with no second challenge.
 *
 * That reuse is the point: this path goes through REON's doAuth(2)
 * ("utility" auth), whose 15-minute session cache exists precisely so
 * the official client can POST after authenticating once. Nothing else
 * in this TestSuite exercises it. See test_runner.c for the full
 * comparison against BIG BUFFER's doAuth(1)/type-0 route. */
void test_isp_small_buffer(magb_context_t *ctx, test_result_t *out, const char *password);

/** The "BIG BUFFER" test: the large half of the pair, and the other
 * half of REON's auth -- where SMALL BUFFER goes through doAuth(2)'s
 * cached-Authorization route, this one takes doAuth(1) for the
 * download and the three-request type-0 route for the upload (that
 * handler exits after issuing a Gb-Auth-ID, so the second request's
 * body is discarded by design). Downloads TEST_BIGBUFFER_SIZE bytes
 * (TEST_HTTP_BIGBUFFER_DOWNLOAD_PATH), verifying it via a running
 * 16-bit additive checksum streamed against the response's
 * `X-Test-Checksum` header (never buffering more than one Transfer
 * Data chunk of the body at a time), then uploads the same
 * deterministic pattern back (TEST_HTTP_BIGBUFFER_UPLOAD_PATH,
 * generated on the fly rather than stored) and checks the server's
 * own pass/fail response byte. Each leg gets its own GB00 challenge/
 * response, one ISP session for both. */
void test_isp_big_buffer(magb_context_t *ctx, test_result_t *out, const char *password);

/** Test 2b: Begin Session, Read Configuration to find the adapter's
 * own configured login ID, dial string, email address and SMTP server,
 * Dial ISP, ISP Login (with `password`), DNS, TCP Open (port 25), a
 * minimal SMTP dialogue (HELO/MAIL FROM/RCPT TO/DATA) sending a short
 * message to that same address, TCP Close, ISP Logout, Hang Up, End
 * Session. */
void test_isp_email_send(magb_context_t *ctx, test_result_t *out, const char *password);

/** Test 2c: like test_isp_email_send(), but against the configured
 * POP3 server: USER (the local part of the configured email address)
 * / PASS (`password`) / STAT, reporting the mailbox message count,
 * then TOP n 0 over the listing to find this TestSuite's own messages
 * and DELE them.
 *
 * It deletes ONLY messages whose subject starts with kTestEmailSubject
 * -- deliberately unlike the real Mobile Trainer, which RETRs what it
 * downloads and deletes all of it. This runs against a real mailbox;
 * a test that removed everything it found would delete real mail.
 * DELE only marks: the QUIT is what commits, so a failure partway
 * through leaves the mailbox untouched. */
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


/* ---- Server conformance -----------------------------------------------
 *
 * Deliberately a separate section, reached from its own main-menu entry
 * rather than from the ISP/HTTP submenu. Everything above tests the
 * ADAPTER: it passes when the Mobile Adapter, libmobile and the link
 * behave. What follows tests the SERVER, and can fail while every
 * adapter test passes. Mixing the two would make a red result
 * ambiguous about which side is broken, which is the one thing this
 * ROM exists to avoid.
 *
 * (One test today. When a second arrives, this becomes a submenu the
 * way ISP/HTTP is; a submenu of one would be ceremony.)
 */

/** Sends an Authorization whose first GB00_AUTH_PREFIX_LEN characters
 * are correct and whose remaining characters are not, and requires the
 * server to REJECT it.
 *
 * Those first 44 characters are an echo of the challenge the server
 * itself just published in its 401. Anyone who can read that 401 can
 * reproduce them without knowing any credential, so a server that
 * validates only the prefix authenticates nobody. REON did exactly
 * that in its utility-auth cache -- found from this ROM's side, by
 * accident, when a buffer overflow truncated a real Authorization and
 * the server accepted it anyway (docs/protocol-notes.md).
 *
 * PASS means 401 carrying `Gb-Status: 201` -- the server's verdict on
 * the credential. The three outcomes are deliberately distinguished,
 * because they are three different facts:
 *
 *   200                     the bypass is open: this server lacks the
 *                           fix, and its auth can be replayed by
 *                           anyone who can read a challenge.
 *   401 + Gb-Status: 201    PASS. Full validation ran and rejected it.
 *   401, no Gb-Status       inconclusive, not a pass -- the challenge
 *                           expired, so nothing judged the credential.
 *
 * Needs the same ISP password as the other authenticating tests: the
 * VALID Authorization has to be built first, and then damaged, or the
 * request would be rejected for a reason that has nothing to do with
 * the prefix. */
void test_srv_auth_prefix(magb_context_t *ctx, test_result_t *out, const char *password);


/** Read Configuration Data (0x19), both halves, into `config_out`. */
void test_read_config(magb_context_t *ctx, uint8_t config_out[MAGB_CONFIG_SIZE], test_result_t *out);

#endif /* TEST_RUNNER_H */
