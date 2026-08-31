#include "test_runner.h"
#include "magb_network.h"
#include "magb_config.h"
#include "magb_commands.h"
#include "test_config.h"
#include "gb00_auth.h"

#include <gb/gb.h> /* vsync(), joypad(); also used for the P2P receive poll spacing below */
#include <gbdk/console.h> /* cls()/gotoxy(), for test_isp_raw_tcp()'s live view only --
                            * every other test here reports through test_result_t and
                            * never touches the screen directly */
#include <string.h>
#include <stdio.h>

/* Diagnostic strings repeated across many of this file's tests (each
 * ISP test hits the same "BEGIN SESSION FAILED"/kMsgDialIspFailed/...
 * failure points independently) -- shared constants instead of a
 * separate string literal per call site, since SDCC doesn't pool
 * identical literals itself and this ROM has no mapper (32 KiB, see
 * the Makefile's LCCFLAGS comment): with 8, 6, 6, 5, 5, 5, 4 and 3
 * call sites respectively, this was worth well over a hundred bytes,
 * the difference between fitting the on-screen keyboard and not. */
/* "FAIL" rather than "FAILED" throughout this block -- purely a ROM
 * budget trim (this ROM has no mapper, 32 KiB fixed; see the
 * Makefile's LCCFLAGS comment) freed up when the Email Send test's
 * message grew real MIME headers (see that test's own comment). Kept
 * uniform across every constant in this group rather than shortening
 * only as many as strictly needed, so no two of these disagree on
 * which word for "didn't work" they use. */
static const char kMsgBeginSessionFailed[] = "BEGIN SESSION FAIL";
static const char kMsgReadConfigFailed[]   = "READ CONFIG FAIL";
static const char kMsgTransferTimeout[]    = "TRANSFER TIMEOUT";
static const char kMsgDialIspFailed[]      = "DIAL ISP FAIL";
static const char kMsgIspLoginFailed[]     = "ISP LOGIN FAIL";
static const char kMsgDnsQueryFailed[]     = "DNS QUERY FAIL";
static const char kMsgTcpOpenFailed[]      = "TCP OPEN FAIL";
static const char kMsgPhoneStatusFailed[]  = "PHONE STATUS FAIL";
static const char kMsgEchoSendFailed[]     = "ECHO SEND FAIL";
static const char kMsgHelloWorldOk[]       = "HELLO WORLD OK";
static const char kMsgNoCall[]             = "NO CALL";
static const char kMsgBadTestFrame[]       = "BAD TEST FRAME";
static const char kHelloWorld[]            = "HELLO WORLD";

/* Official Nintendo Mobile Adapter error codes (docs/protocol-notes.md)
 * repeated across the many ISP/HTTP/DNS/POP3 test variants -- same
 * dedup rationale as the kMsg* block above. */
static const char kCode15000[] = "15-000";
static const char kCode20000[] = "20-000";
static const char kCode24000[] = "24-000";
static const char kCode25000[] = "25-000";
static const char kCode31002[] = "31-002";
static const char kCode32000[] = "32-000";
static const char kCode32401[] = "32-401";

/* Shared between test_isp_email_send() (which writes this exact header
 * line into the test message) and delete_matching_test_emails() (which
 * scans POP3 headers for it) -- the two must never drift apart, since
 * the delete only removes messages carrying this ROM's own test
 * subject line, never anything else in the mailbox. */
#define kTestEmailSubjectLine "Subject: MAGB TestSuite"

/* ---- MATS: TestSuite-only P2P payload framing (Section 33) --------
 * This is carried *inside* MAGB Transfer Data (0x15) payloads. It is
 * not part of the Mobile Adapter protocol itself. */
#define MATS_HEADER_LEN 7U /* magic(4) + version(1) + sequence(1) + length(1) */
#define MATS_MAX_PAYLOAD 16U /* covers the "HELLO WORLD" (11 bytes) exchange below */
#define MATS_VERSION 1U

static uint8_t mats_build(uint8_t *out, uint8_t sequence,
                           const uint8_t *payload, uint8_t payload_len)
{
    out[0] = 'M'; out[1] = 'A'; out[2] = 'T'; out[3] = 'S';
    out[4] = MATS_VERSION;
    out[5] = sequence;
    out[6] = payload_len;
    memcpy(&out[MATS_HEADER_LEN], payload, payload_len);
    return (uint8_t)(MATS_HEADER_LEN + payload_len);
}

static bool mats_parse(const uint8_t *in, uint8_t in_len, uint8_t *sequence,
                        uint8_t *payload, uint8_t *payload_len)
{
    if (in_len < MATS_HEADER_LEN) {
        return false;
    }
    if (in[0] != 'M' || in[1] != 'A' || in[2] != 'T' || in[3] != 'S') {
        return false;
    }
    if (in[4] != MATS_VERSION) {
        return false;
    }
    if (in[6] > MATS_MAX_PAYLOAD || (uint8_t)(in_len - MATS_HEADER_LEN) < in[6]) {
        return false;
    }
    *sequence = in[5];
    *payload_len = in[6];
    memcpy(payload, &in[MATS_HEADER_LEN], in[6]);
    return true;
}

static void result_init(test_result_t *out, uint8_t command)
{
    memset(out, 0, sizeof(*out));
    out->command = command;
    out->expected = magb_response_command(command);
}

/* Official Mobile Adapter GB error codes, as displayed by real
 * Nintendo software (not a TestSuite invention -- see
 * docs/protocol-notes.md, "Official Mobile Adapter GB error codes").
 * Only the codes with an unambiguous mapping onto this TestSuite's own
 * magb_result_t are covered; anything else is left uncoded (empty
 * string) rather than guessed. */
static const char *default_official_code(magb_result_t r)
{
    switch (r) {
    case MAGB_ERR_TIMEOUT:
    case MAGB_ERR_ADAPTER_NOT_FOUND:
        return "10-000"; /* Adapter is not connected */
    case MAGB_ERR_BAD_MAGIC:
    case MAGB_ERR_BAD_LENGTH:
    case MAGB_ERR_PAYLOAD_TOO_LARGE:
    case MAGB_ERR_BAD_CHECKSUM:
    case MAGB_ERR_BAD_ACK:
    case MAGB_ERR_BAD_DEVICE_ID:
    case MAGB_ERR_UNEXPECTED_COMMAND:
    case MAGB_ERR_REMOTE_UNSUPPORTED:
    case MAGB_ERR_REMOTE_CHECKSUM:
    case MAGB_ERR_REMOTE_INTERNAL:
    case MAGB_ERR_SESSION:
        return "21-000"; /* Communication error */
    default:
        return ""; /* no official mapping for this one */
    }
}

static void result_fail(test_result_t *out, magb_result_t r, const char *line0)
{
    out->passed = false;
    out->result = r;
    strncpy(out->detail[0], line0, sizeof(out->detail[0]) - 1U);
    strncpy(out->official_code, default_official_code(r), sizeof(out->official_code) - 1U);
}

/* Like result_fail(), but with a more specific official code than the
 * generic per-magb_result_t default -- used where the *command* that
 * failed (dial, DNS, TCP open, ...) narrows it down further than the
 * transport-level result alone can. */
static void result_fail_code(test_result_t *out, magb_result_t r, const char *line0,
                              const char *code)
{
    result_fail(out, r, line0);
    strncpy(out->official_code, code, sizeof(out->official_code) - 1U);
}

/* ---- Test 1: Adapter / Session -------------------------------------- */
void test_adapter_session(magb_context_t *ctx, test_result_t *out)
{
    magb_result_t r;

    result_init(out, MAGB_CMD_BEGIN_SESSION);

    r = magb_begin_session(ctx);
    out->result = r;
    out->actual = ctx->last_command_recv;

    if (r != MAGB_OK) {
        result_fail(out, r, kMsgBeginSessionFailed);
        sprintf(out->detail[1], "EXP %hx GOT %hx", (unsigned char)out->expected,
                (unsigned char)out->actual);
        return;
    }

    out->passed = true;
    sprintf(out->detail[0], "ADAPTER ID: %hx", (unsigned char)ctx->adapter_device);
    sprintf(out->detail[1], "NINTENDO ECHO OK");

    (void)magb_end_session(ctx);
}

/* ---- Read Configuration Data ----------------------------------------- */
void test_read_config(magb_context_t *ctx, uint8_t config_out[MAGB_CONFIG_SIZE], test_result_t *out)
{
    magb_result_t r;

    result_init(out, MAGB_CMD_READ_CONFIG);

    if (!ctx->session_active) {
        r = magb_begin_session(ctx);
        if (r != MAGB_OK) {
            result_fail(out, r, "NO SESSION");
            return;
        }
    }

    r = magb_read_config(ctx, config_out);
    out->result = r;
    out->actual = ctx->last_command_recv;

    if (r != MAGB_OK) {
        result_fail(out, r, kMsgReadConfigFailed);
    } else {
        out->passed = true;
        sprintf(out->detail[0], "192 BYTES READ");
        sprintf(out->detail[1], "SEE CONFIG SCREEN");
    }

    (void)magb_end_session(ctx);
}

/* ---- Test 2: ISP / HTTP ------------------------------------------------ */
/* Kept <=255 (not 256) so "bytes remaining" always fits in the
 * uint8_t out_cap magb_transfer_data() expects without wrapping. */
#define HTTP_RESP_BUF_SIZE 240U
#define HTTP_MAX_TOTAL_BYTES 8192U
#define HTTP_MAX_EMPTY_POLLS 5U

static uint8_t s_http_resp[HTTP_RESP_BUF_SIZE];

static void isp_http_cleanup(magb_context_t *ctx, uint8_t conn_id, bool have_conn, bool logged_in)
{
    if (have_conn) {
        (void)magb_tcp_close(ctx, conn_id);
    }
    if (logged_in) {
        (void)magb_isp_logout(ctx);
    }
    (void)magb_hangup(ctx);
    (void)magb_end_session(ctx);
}

/* Copies printable bytes from a config field until a 0x00 byte or
 * `max_len`, NUL-terminating. Config fields observed 0x00-padded past
 * their actual content. */
static void config_field_to_cstr(const uint8_t *field, uint8_t max_len,
                                  char *out, uint8_t out_cap)
{
    uint8_t i;
    uint8_t n = 0U;
    for (i = 0U; i < max_len && n < (uint8_t)(out_cap - 1U); i++) {
        if (field[i] == 0x00U) {
            break;
        }
        out[n++] = (char)field[i];
    }
    out[n] = '\0';
}

/* Everything every ISP-touching test needs to read live from the
 * adapter's own Read Configuration Data (0x19) response, rather than
 * from compile-time TEST_* constants -- per the project owner's own
 * request: "se algo exigir autenticacao, voce tem que ler todas as
 * infos necessarias da config do adaptador". Only the password isn't
 * here: it is never stored anywhere in the documented 192-byte
 * configuration layout (see docs/dandocs-magb.md), so it has to come
 * from the user (ui_edit_text(), the "ISP PASSWORD" menu entry --
 * see main.c). There is no compile-time fallback for it -- an empty
 * password is a hard failure for the tests that need one, via
 * require_password() below, rather than a guessed value.
 *
 * Every field EXCEPT the password falls back to its TEST_*
 * compile-time default if the config field is blank (an adapter that
 * never ran Mobile Trainer registration), so this keeps working
 * against libmobile's default unregistered config exactly like before
 * this change. */
typedef struct {
    char login[MAGB_CONFIG_LOGIN_ID_LEN + 1U];
    char phone[17]; /* worst case: 16 BCD digits/symbols + NUL */
    char email[MAGB_CONFIG_EMAIL_LEN + 1U];
    char smtp[MAGB_CONFIG_SMTP_LEN + 1U];
    char pop[MAGB_CONFIG_POP_LEN + 1U];
} magb_isp_identity_t;

static magb_result_t read_isp_identity(magb_context_t *ctx, magb_isp_identity_t *out)
{
    uint8_t config[MAGB_CONFIG_SIZE];
    magb_result_t r = magb_read_config(ctx, config);
    if (r != MAGB_OK) {
        return r;
    }

    config_field_to_cstr(&config[MAGB_CONFIG_OFF_LOGIN_ID], MAGB_CONFIG_LOGIN_ID_LEN,
                          out->login, sizeof(out->login));
    if (out->login[0] == '\0') {
        strncpy(out->login, TEST_ISP_LOGIN, sizeof(out->login) - 1U);
        out->login[sizeof(out->login) - 1U] = '\0';
    }

    if (magb_config_decode_phone(&config[MAGB_CONFIG_OFF_SLOT1], out->phone, sizeof(out->phone)) == 0U) {
        strncpy(out->phone, TEST_ISP_PHONE, sizeof(out->phone) - 1U);
        out->phone[sizeof(out->phone) - 1U] = '\0';
    }

    config_field_to_cstr(&config[MAGB_CONFIG_OFF_EMAIL], MAGB_CONFIG_EMAIL_LEN,
                          out->email, sizeof(out->email));
    config_field_to_cstr(&config[MAGB_CONFIG_OFF_SMTP], MAGB_CONFIG_SMTP_LEN,
                          out->smtp, sizeof(out->smtp));
    config_field_to_cstr(&config[MAGB_CONFIG_OFF_POP], MAGB_CONFIG_POP_LEN,
                          out->pop, sizeof(out->pop));
    return MAGB_OK;
}

/* Used only by tests that actually authenticate against a real
 * account (GB00 HTTP, POP3) -- unlike Dial/ISP Login itself (which
 * libmobile accepts with any password) or SMTP (which REON's own
 * source accepts unauthenticated), these fail with a real 401/-ERR if
 * the password is wrong, so this TestSuite must never guess one.
 * isp_password[] in main.c starts empty (no compile-time "test"
 * default -- see docs/protocol-notes.md for why one was removed) and
 * is only ever set by the user via the ISP PASSWORD screen; this is
 * the single check that turns "still empty" into an explicit,
 * immediate failure instead of silently sending an empty password to
 * the server and reporting whatever generic error comes back. Called
 * before result_init() -- callers must not call result_init()
 * themselves until after this returns true. */
static bool require_password(test_result_t *out, const char *password)
{
    if (password[0] != '\0') {
        return true;
    }
    result_init(out, MAGB_CMD_TRANSFER);
    result_fail(out, MAGB_ERR_ISP, "SET ISP PASSWORD");
    return false;
}

void test_isp_http(magb_context_t *ctx, test_result_t *out, const char *password,
                    const char *host, uint16_t port, const char *path)
{
    static char s_request[224];
    magb_result_t r;
    magb_phone_status_t phone;
    magb_isp_login_result_t isp;
    magb_isp_identity_t id;
    uint8_t dns1[4] = { TEST_DNS_PRIMARY_A, TEST_DNS_PRIMARY_B, TEST_DNS_PRIMARY_C, TEST_DNS_PRIMARY_D };
    uint8_t dns2[4] = { TEST_DNS_SECONDARY_A, TEST_DNS_SECONDARY_B, TEST_DNS_SECONDARY_C, TEST_DNS_SECONDARY_D };
    uint8_t host_ip[4];
    uint8_t conn_id = 0U;
    uint16_t request_len;
    uint16_t resp_len = 0U;
    uint16_t total_received = 0U;
    bool remote_closed = false;
    uint8_t empty_polls = 0U;
    uint8_t got_len;

    result_init(out, MAGB_CMD_TRANSFER);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, kMsgBeginSessionFailed); return; }

    r = read_isp_identity(ctx, &id);
    if (r != MAGB_OK) { result_fail(out, r, kMsgReadConfigFailed); (void)magb_end_session(ctx); return; }

    r = magb_telephone_status(ctx, &phone);
    if (r != MAGB_OK) {
        result_fail(out, r, kMsgPhoneStatusFailed);
        (void)magb_end_session(ctx);
        return;
    }

    r = magb_dial(ctx, id.phone, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgDialIspFailed, kCode20000);
        (void)magb_end_session(ctx);
        return;
    }

    r = magb_isp_login(ctx, id.login, password, dns1, dns2, &isp);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgIspLoginFailed, kCode25000);
        isp_http_cleanup(ctx, 0U, false, false);
        return;
    }

    r = magb_dns_query(ctx, host, host_ip);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgDnsQueryFailed, kCode15000);
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }
    sprintf(out->detail[0], "DNS %u.%u.%u.%u",
            host_ip[0], host_ip[1], host_ip[2], host_ip[3]);

    r = magb_tcp_open(ctx, host_ip, port, &conn_id);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgTcpOpenFailed, kCode24000);
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

    sprintf(s_request,
        "GET %s HTTP/1.0\r\n"
        "Host: %s\r\n"
        "User-Agent: MAGB-TestSuite/1.0\r\n"
        "Connection: close\r\n\r\n",
        path, host);
    request_len = (uint16_t)strlen(s_request);

    /* resp_len is always 0 here (this is the first receive), so the
     * full buffer is available -- no need for the same "how much
     * space is left" clamp the polling loop below needs. */
    r = magb_transfer_data(ctx, conn_id, (const uint8_t *)s_request, (uint8_t)request_len,
                            &s_http_resp[resp_len], (uint8_t)HTTP_RESP_BUF_SIZE,
                            &got_len, &remote_closed, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "HTTP SEND FAILED", kCode32000);
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }
    resp_len = (uint16_t)(resp_len + got_len);
    total_received = (uint16_t)(total_received + got_len);

    while (!remote_closed && total_received < HTTP_MAX_TOTAL_BYTES &&
           empty_polls < HTTP_MAX_EMPTY_POLLS) {
        uint8_t cap = (resp_len < HTTP_RESP_BUF_SIZE) ? (uint8_t)(HTTP_RESP_BUF_SIZE - resp_len) : 0U;

        r = magb_transfer_data(ctx, conn_id, NULL, 0U,
                                &s_http_resp[resp_len], cap,
                                &got_len, &remote_closed, MAGB_TIMEOUT_FRAMES_LONG);
        if (r != MAGB_OK) {
            result_fail_code(out, r, "HTTP RECV FAILED", kCode32000);
            isp_http_cleanup(ctx, conn_id, true, true);
            return;
        }

        if (got_len == 0U && !remote_closed) {
            empty_polls++;
        } else {
            empty_polls = 0U;
        }

        if (cap > 0U) {
            resp_len = (uint16_t)(resp_len + got_len);
        }
        total_received = (uint16_t)(total_received + got_len);
    }

    isp_http_cleanup(ctx, conn_id, true, true);

    out->tx_bytes = request_len;
    out->rx_bytes = total_received;

    if (resp_len >= 5U && memcmp(s_http_resp, "HTTP/", 5U) == 0) {
        out->passed = true;
        out->result = MAGB_OK;
        if (resp_len >= 12U) {
            char status[4];
            memcpy(status, &s_http_resp[9], 3U);
            status[3] = '\0';
            sprintf(out->detail[0], "HTTP STATUS %s", status);
            /* "32-XXX" is the official code for this exact situation
             * (HTTP error XXX) -- even a "success" 2xx status is worth
             * showing this way for consistency/comparison purposes. */
            sprintf(out->official_code, "32-%s", status);
        } else {
            sprintf(out->detail[0], "HTTP/ (SHORT)");
            strcpy(out->official_code, kCode32000);
        }
        sprintf(out->detail[1], "RX TOTAL %u B", total_received);
    } else {
        out->passed = false;
        out->result = MAGB_OK; /* transport worked; this is an application-layer mismatch */
        sprintf(out->detail[0], "TRANSPORT OK");
        sprintf(out->detail[1], "NO HTTP/ PREFIX");
        strcpy(out->official_code, kCode15000);
    }
}

/* ---- Test 2a: ISP HTTP with REON's GB00 challenge/response auth -------
 * Confirmed necessary by reading REON's own source (not assumed):
 * web/cgb/pokemon/news.php's get_news_file()/get_news_parameters_bin()
 * both call bxt_pokemon_news_require_authenticated_user_id(), which
 * unconditionally calls doAuth(2) -- "Pokémon news + ranking endpoints
 * require auth even if free". See docs/protocol-notes.md, "GB00 HTTP
 * authentication" for the full derivation (round-trip tested against
 * REON's actual PHP decode function before this was written).
 *
 * The GB00 login (dionId) and the Dial phone number are both read
 * live from the adapter's own Read Configuration Data (0x19) response
 * via read_isp_identity() (login: offset MAGB_CONFIG_OFF_LOGIN_ID, the
 * real "gXXXXXXXXX"-style registered ID; phone: Configuration Slot 1,
 * BCD-decoded -- see Dan Docs' Mobile Adapter GB configuration
 * layout), the same way the email tests read the email/SMTP/POP
 * fields -- not TEST_ISP_LOGIN/TEST_ISP_PHONE. A real REON account is
 * provisioned against that registered ID, not an arbitrary string, so
 * hardcoding "test" here would 401 against any real deployment even
 * with perfectly correct crypto. The password is passed in from the
 * caller (interactively entered via ui_edit_text(), see main.c) since
 * no password is ever stored anywhere in the adapter's configuration
 * memory (see CLAUDE.md's Test Configuration section). */
/* 200 was measured to be too small against a real server: a real
 * nginx 401 challenge response (Server/Date/Content-Type/Connection
 * headers *plus* the ~81-byte WWW-Authenticate line) is 227 bytes on
 * its own, confirmed from a real BGB link-log capture -- the
 * WWW-Authenticate header landed past byte 200 and got silently
 * truncated, so gb00_find_challenge() could never find a complete
 * challenge and every News test failed before ever attempting the
 * authenticated retry (independent of login/password, which the log
 * showed were already correct). 360 covers that with margin, plus
 * room for a real (larger, no WWW-Authenticate line but a binary body)
 * 200 OK from get_news_parameters_bin()/get_news_file(). */
#define GB00_RESP_BUF_SIZE 360U
static uint8_t s_gb00_resp[GB00_RESP_BUF_SIZE];

/* Sends one HTTP/1.0 GET (optionally with an extra header line, e.g.
 * "Authorization: ...\r\n", or NULL for none) over `conn_id` and
 * accumulates the response into s_gb00_resp. Mirrors test_isp_http()'s
 * receive loop, kept separate because this flow needs to do it twice
 * (once to provoke the 401, once with the computed Authorization).
 * GB00_RESP_BUF_SIZE exceeds 255, unlike HTTP_RESP_BUF_SIZE, so every
 * per-call capacity passed to magb_transfer_data() (a uint8_t) is
 * explicitly clamped to 255 rather than just cast, which would
 * otherwise silently wrap for a "remaining space" value above 255. */
static magb_result_t gb00_http_get(magb_context_t *ctx, uint8_t conn_id,
                                    const char *host, const char *path,
                                    const char *extra_header,
                                    uint16_t *out_resp_len, bool *remote_closed)
{
    static char s_gb00_req[256];
    magb_result_t r;
    uint16_t resp_len = 0U;
    uint8_t empty_polls = 0U;
    uint8_t got_len;
    uint16_t req_len;
    uint8_t cap0;

    sprintf(s_gb00_req, "GET %s HTTP/1.0\r\nHost: %s\r\n%s\r\n",
            path, host, (extra_header != NULL) ? extra_header : "");
    req_len = (uint16_t)strlen(s_gb00_req);

    cap0 = (GB00_RESP_BUF_SIZE > 255U) ? 255U : (uint8_t)GB00_RESP_BUF_SIZE;
    r = magb_transfer_data(ctx, conn_id, (const uint8_t *)s_gb00_req, (uint8_t)req_len,
                            &s_gb00_resp[0], cap0,
                            &got_len, remote_closed, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        return r;
    }
    resp_len = got_len;

    while (!*remote_closed && resp_len < GB00_RESP_BUF_SIZE && empty_polls < HTTP_MAX_EMPTY_POLLS) {
        uint16_t remaining = (uint16_t)(GB00_RESP_BUF_SIZE - resp_len);
        uint8_t cap = (remaining > 255U) ? 255U : (uint8_t)remaining;
        r = magb_transfer_data(ctx, conn_id, NULL, 0U,
                                &s_gb00_resp[resp_len], cap,
                                &got_len, remote_closed, MAGB_TIMEOUT_FRAMES_LONG);
        if (r != MAGB_OK) {
            return r;
        }
        empty_polls = (got_len == 0U && !*remote_closed) ? (uint8_t)(empty_polls + 1U) : 0U;
        resp_len = (uint16_t)(resp_len + got_len);
    }

    *out_resp_len = resp_len;
    return MAGB_OK;
}

/* Finds "WWW-Authenticate:" in the accumulated response and copies the
 * GB00_CHALLENGE_LEN-character quoted challenge that follows the next
 * '"' into `out` (NUL-terminated). No strstr() in GBDK's string.h. */
static bool gb00_find_challenge(const uint8_t *resp, uint16_t resp_len, char *out)
{
    static const char kNeedle[] = "WWW-Authenticate:";
    uint8_t needle_len = (uint8_t)(sizeof(kNeedle) - 1U);
    uint16_t i;

    for (i = 0U; (uint16_t)(i + needle_len) < resp_len; i++) {
        if (memcmp(&resp[i], kNeedle, needle_len) == 0) {
            uint16_t j = (uint16_t)(i + needle_len);
            while (j < resp_len && resp[j] != '"') {
                j++;
            }
            j++; /* skip the opening quote itself */
            if ((uint16_t)(j + GB00_CHALLENGE_LEN) > resp_len) {
                return false;
            }
            memcpy(out, &resp[j], GB00_CHALLENGE_LEN);
            out[GB00_CHALLENGE_LEN] = '\0';
            return true;
        }
    }
    return false;
}

static bool gb00_status_code(const uint8_t *resp, uint16_t resp_len, char status[4])
{
    if (resp_len < 12U || memcmp(resp, "HTTP/", 5U) != 0) {
        return false;
    }
    memcpy(status, &resp[9], 3U);
    status[3] = '\0';
    return true;
}

/* Fetches one URL with REON's GB00 challenge/response auth: GET with
 * no Authorization; if the response isn't a 401, done (no auth was
 * required for this path). Otherwise finds the WWW-Authenticate
 * challenge, computes the Authorization value, and re-sends the GET
 * with it. Manages its own TCP connection (opens fresh, always closes
 * before returning -- the caller only owns Begin Session/Dial/ISP
 * Login/DNS around one or more calls to this). On MAGB_OK, `status`
 * holds the final 3-digit HTTP status and `*resp_len` the final
 * response's byte count (both from the auth retry if one happened,
 * from the first GET otherwise); `*did_auth` records which. On
 * failure, `*fail_stage` is a short human-readable label for
 * `out->detail[]` (e.g. "NO WWW-AUTH HDR") and the return value is the
 * `magb_result_t` to report (MAGB_ERR_ISP for an application-level
 * parse failure that isn't itself a magb_result_t). */
static magb_result_t gb00_fetch(magb_context_t *ctx, const uint8_t host_ip[4], uint16_t port,
                                 const char *host, const char *path,
                                 const char *login, const char *password,
                                 char status[4], uint16_t *resp_len, bool *did_auth,
                                 const char **fail_stage)
{
    uint8_t conn_id;
    magb_result_t r;
    bool remote_closed;
    char challenge[GB00_CHALLENGE_LEN + 1U];
    static char auth_header[16U + GB00_AUTHORIZATION_LEN + 4U];

    *did_auth = false;

    r = magb_tcp_open(ctx, host_ip, port, &conn_id);
    if (r != MAGB_OK) { *fail_stage = kMsgTcpOpenFailed; return r; }

    r = gb00_http_get(ctx, conn_id, host, path, NULL, resp_len, &remote_closed);
    if (r != MAGB_OK) {
        (void)magb_tcp_close(ctx, conn_id);
        *fail_stage = "HTTP SEND FAILED";
        return r;
    }

    if (!gb00_status_code(s_gb00_resp, *resp_len, status)) {
        (void)magb_tcp_close(ctx, conn_id);
        *fail_stage = "NO HTTP/ PREFIX";
        return MAGB_ERR_ISP;
    }

    if (strncmp(status, "401", 3) != 0) {
        /* No auth needed after all (or something else entirely) --
         * report the status directly, same shape as test_isp_http(). */
        (void)magb_tcp_close(ctx, conn_id);
        return MAGB_OK;
    }

    if (!gb00_find_challenge(s_gb00_resp, *resp_len, challenge)) {
        (void)magb_tcp_close(ctx, conn_id);
        *fail_stage = "NO WWW-AUTH HDR";
        return MAGB_ERR_ISP;
    }

    /* REON's PHP closes the connection after the 401 (Connection: close
     * is implied by HTTP/1.0); re-open before the authenticated retry. */
    (void)magb_tcp_close(ctx, conn_id);
    r = magb_tcp_open(ctx, host_ip, port, &conn_id);
    if (r != MAGB_OK) { *fail_stage = "TCP REOPEN FAILED"; return r; }

    {
        char auth_value[GB00_AUTHORIZATION_LEN + 1U];
        gb00_build_authorization(challenge, login, password, auth_value);
        sprintf(auth_header, "Authorization: GB00 name=\"%s\"\r\n", auth_value);
    }

    r = gb00_http_get(ctx, conn_id, host, path, auth_header, resp_len, &remote_closed);
    (void)magb_tcp_close(ctx, conn_id);
    if (r != MAGB_OK) { *fail_stage = "AUTH SEND FAILED"; return r; }

    if (!gb00_status_code(s_gb00_resp, *resp_len, status)) {
        *fail_stage = "NO HTTP/ AFTER AUTH";
        return MAGB_ERR_ISP;
    }

    *did_auth = true;
    return MAGB_OK;
}

void test_isp_http_gb00(magb_context_t *ctx, test_result_t *out, const char *password,
                         const char *host, uint16_t port, const char *path)
{
    magb_result_t r;
    magb_phone_status_t phone;
    magb_isp_login_result_t isp;
    magb_isp_identity_t id;
    uint8_t dns1[4] = { TEST_DNS_PRIMARY_A, TEST_DNS_PRIMARY_B, TEST_DNS_PRIMARY_C, TEST_DNS_PRIMARY_D };
    uint8_t dns2[4] = { TEST_DNS_SECONDARY_A, TEST_DNS_SECONDARY_B, TEST_DNS_SECONDARY_C, TEST_DNS_SECONDARY_D };
    uint8_t host_ip[4];
    uint16_t resp_len;
    bool did_auth;
    char status[4];
    const char *fail_stage;

    if (!require_password(out, password)) { return; }
    result_init(out, MAGB_CMD_TRANSFER);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, kMsgBeginSessionFailed); return; }

    r = read_isp_identity(ctx, &id);
    if (r != MAGB_OK) { result_fail(out, r, kMsgReadConfigFailed); (void)magb_end_session(ctx); return; }
    /* detail[1] is only otherwise touched right below, at the very end
     * of this function -- result_fail() only ever overwrites detail[0],
     * so this survives to the result screen on every exit path, success
     * or failure, which matters here specifically because a wrong
     * login is the single most likely cause of a 401-after-retry. */
    sprintf(out->detail[1], "LOGIN %s", id.login);

    r = magb_telephone_status(ctx, &phone);
    if (r != MAGB_OK) { result_fail(out, r, kMsgPhoneStatusFailed); (void)magb_end_session(ctx); return; }

    r = magb_dial(ctx, id.phone, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) { result_fail_code(out, r, kMsgDialIspFailed, kCode20000); (void)magb_end_session(ctx); return; }

    r = magb_isp_login(ctx, id.login, password, dns1, dns2, &isp);
    if (r != MAGB_OK) { result_fail_code(out, r, kMsgIspLoginFailed, kCode25000); isp_http_cleanup(ctx, 0U, false, false); return; }

    /* Every hostname this test touches gets its own DNS Query (0x28)
     * first -- there is exactly one here (`host`), queried once. */
    r = magb_dns_query(ctx, host, host_ip);
    if (r != MAGB_OK) { result_fail_code(out, r, kMsgDnsQueryFailed, kCode15000); isp_http_cleanup(ctx, 0U, false, true); return; }

    r = gb00_fetch(ctx, host_ip, port, host, path, id.login, password, status, &resp_len, &did_auth, &fail_stage);
    if (r != MAGB_OK) {
        result_fail_code(out, r, fail_stage, kCode32401);
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

    isp_http_cleanup(ctx, 0U, false, true);
    out->rx_bytes = resp_len;
    out->passed = true;
    out->result = MAGB_OK;
    sprintf(out->detail[0], did_auth ? "AUTH -> HTTP %s" : "HTTP %s (NO AUTH)", status);
    /* detail[1] is left as the "LOGIN <id>" line set above. */
    sprintf(out->official_code, "32-%s", status);
}

/* Like test_isp_http_gb00(), but for the "NEWS ARTICLE" menu entry:
 * mirrors what a real game actually does for the Goldenrod
 * Communication Center news feature -- fetch the news *config* first
 * (size, SRAM address, ranking layout; see news.php's
 * get_news_parameters_bin()), then the news *article* itself
 * (get_news_file()), in the same ISP session, one DNS query for the
 * shared host. Both legitimately need their own GB00 challenge/
 * response (this TestSuite does not rely on REON's optional 15-minute
 * utility-auth session cache across separate connections -- see
 * doAuth()'s $_SESSION['utility_authed_*'] path in auth.php -- since
 * that isn't guaranteed by the documented protocol, just observed as
 * an optimization the real client may use). */
void test_isp_news_article(magb_context_t *ctx, test_result_t *out, const char *password)
{
    magb_result_t r;
    magb_phone_status_t phone;
    magb_isp_login_result_t isp;
    magb_isp_identity_t id;
    uint8_t dns1[4] = { TEST_DNS_PRIMARY_A, TEST_DNS_PRIMARY_B, TEST_DNS_PRIMARY_C, TEST_DNS_PRIMARY_D };
    uint8_t dns2[4] = { TEST_DNS_SECONDARY_A, TEST_DNS_SECONDARY_B, TEST_DNS_SECONDARY_C, TEST_DNS_SECONDARY_D };
    uint8_t host_ip[4];
    uint16_t resp_len;
    bool did_auth;
    char cfg_status[4];
    char art_status[4];
    const char *fail_stage;

    if (!require_password(out, password)) { return; }
    result_init(out, MAGB_CMD_TRANSFER);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, kMsgBeginSessionFailed); return; }

    r = read_isp_identity(ctx, &id);
    if (r != MAGB_OK) { result_fail(out, r, kMsgReadConfigFailed); (void)magb_end_session(ctx); return; }
    sprintf(out->detail[1], "LOGIN %s", id.login);

    r = magb_telephone_status(ctx, &phone);
    if (r != MAGB_OK) { result_fail(out, r, kMsgPhoneStatusFailed); (void)magb_end_session(ctx); return; }

    r = magb_dial(ctx, id.phone, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) { result_fail_code(out, r, kMsgDialIspFailed, kCode20000); (void)magb_end_session(ctx); return; }

    r = magb_isp_login(ctx, id.login, password, dns1, dns2, &isp);
    if (r != MAGB_OK) { result_fail_code(out, r, kMsgIspLoginFailed, kCode25000); isp_http_cleanup(ctx, 0U, false, false); return; }

    /* One DNS Query (0x28) for TEST_HTTP_HOST -- shared by both fetches
     * below, since both paths live on the same host. */
    r = magb_dns_query(ctx, TEST_HTTP_HOST, host_ip);
    if (r != MAGB_OK) { result_fail_code(out, r, kMsgDnsQueryFailed, kCode15000); isp_http_cleanup(ctx, 0U, false, true); return; }

    r = gb00_fetch(ctx, host_ip, TEST_HTTP_PORT, TEST_HTTP_HOST, TEST_HTTP_NEWS_CONFIG_PATH,
                    id.login, password, cfg_status, &resp_len, &did_auth, &fail_stage);
    if (r != MAGB_OK) {
        /* fail_stage (e.g. "NO HTTP/ AFTER AUTH", 19 chars) already
         * fills most of detail[0]'s 20-char budget on its own -- no
         * room for a "CONFIG: "/"ARTICLE: " prefix there. detail[1]
         * (normally "LOGIN <id>") carries which stage failed instead. */
        result_fail_code(out, r, fail_stage, kCode32401);
        strcpy(out->detail[1], "STAGE: CONFIG");
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }
    sprintf(out->detail[0], "CFG %s", cfg_status);

    r = gb00_fetch(ctx, host_ip, TEST_HTTP_PORT, TEST_HTTP_HOST, TEST_HTTP_NEWS_PATH,
                    id.login, password, art_status, &resp_len, &did_auth, &fail_stage);
    if (r != MAGB_OK) {
        result_fail_code(out, r, fail_stage, kCode32401);
        strcpy(out->detail[1], "STAGE: ARTICLE");
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

    isp_http_cleanup(ctx, 0U, false, true);
    out->rx_bytes = resp_len;
    out->passed = true;
    out->result = MAGB_OK;
    sprintf(out->detail[0], "CFG %s ART %s", cfg_status, art_status);
    sprintf(out->official_code, "32-%s", art_status);
}

/* ---- Test 2b/2c: ISP Email (SMTP send / POP3 receive) ------------------
 * Neither SMTP nor POP3 is a Mobile Adapter command -- both are just
 * ordinary line-based text protocols run over a plain TCP connection
 * (port 25 / 110), exactly like the HTTP test above uses port 80. The
 * exact dialogue below was confirmed against REON's real mail server
 * source (REON's mail/smtp.js, smtpConnection.js,
 * pop3Connection.js), not guessed: SMTP accepts mail with no
 * authentication at all (a message only actually gets delivered if
 * RCPT TO matches a real account's email -- see
 * `_isMailAddressedToUs()`); POP3 authenticates with
 * `USER <local-part-of-email>` / `PASS <same password used for ISP
 * login>` (REON's pop3Connection.js checks PASS against the identical
 * `log_in_password` column the GB00/ISP-facing auth uses).
 *
 * The email address, SMTP host and POP host are not compile-time
 * constants here -- they're read from the adapter's own Read
 * Configuration Data (0x19) response, exactly like a real game would
 * (and per the project owner's own suggestion). */

static uint16_t parse_leading_uint(const char *s)
{
    uint16_t v = 0U;
    while (*s >= '0' && *s <= '9') {
        v = (uint16_t)(v * 10U + (uint8_t)(*s - '0'));
        s++;
    }
    return v;
}

static magb_result_t tcp_send_line(magb_context_t *ctx, uint8_t conn_id, const char *line)
{
    uint8_t discard[1];
    uint8_t got_len;
    bool remote_closed;
    return magb_transfer_data(ctx, conn_id, (const uint8_t *)line, (uint8_t)strlen(line),
                               discard, 0U, &got_len, &remote_closed, MAGB_TIMEOUT_FRAMES_LONG);
}

#define LINE_RECV_MAX_POLLS 60U

/* A single TCP receive can carry more than one protocol line -- a real
 * BGB/libmobile-bgb capture showed an SMTP server reply "250 OK\r\n"
 * and a second, unrelated "500 command not recognized\r\n" line
 * arriving together in one Transfer Data response. tcp_recv_line()
 * below only wants the first line at a time, but must not throw away
 * whatever comes after it in the same chunk -- POP3 header scanning in
 * particular (see delete_matching_test_emails()) reads many lines in a
 * row and would desync if any got silently dropped here. Bytes past
 * the first '\n' are stashed here and drained before the next real
 * network read. Reset via tcp_line_reset() right after each fresh
 * magb_tcp_open(), so leftovers from a previous connection can never
 * bleed into a new one. */
static uint8_t s_line_pending[MAGB_MAX_PAYLOAD];
static uint8_t s_line_pending_len;
static uint8_t s_line_pending_pos;

static void tcp_line_reset(void)
{
    s_line_pending_len = 0U;
    s_line_pending_pos = 0U;
}

/* Accumulates response bytes into `buf` (always NUL-terminated) until
 * a '\n' is seen, the connection closes, or LINE_RECV_MAX_POLLS is
 * exhausted -- whichever comes first. Returns whatever was
 * accumulated even on a timeout/close, so the caller can still
 * inspect a partial line (e.g. to tell a real "-ERR" apart from
 * nothing at all). */
static magb_result_t tcp_recv_line(magb_context_t *ctx, uint8_t conn_id,
                                    char *buf, uint8_t buf_cap, bool *remote_closed)
{
    uint8_t len = 0U;
    uint8_t poll;

    *remote_closed = false;
    buf[0] = '\0';

    for (poll = 0U; poll < LINE_RECV_MAX_POLLS; poll++) {
        uint8_t got_len;
        bool closed = false;
        magb_result_t r;
        uint8_t cap = (uint8_t)(buf_cap - 1U - len);
        uint8_t i;

        if (cap == 0U) {
            break;
        }

        if (s_line_pending_pos < s_line_pending_len) {
            got_len = (uint8_t)(s_line_pending_len - s_line_pending_pos);
            if (got_len > cap) {
                got_len = cap;
            }
            memcpy(&buf[len], &s_line_pending[s_line_pending_pos], got_len);
            s_line_pending_pos = (uint8_t)(s_line_pending_pos + got_len);
        } else {
            r = magb_transfer_data(ctx, conn_id, NULL, 0U,
                                    (uint8_t *)&buf[len], cap, &got_len, &closed,
                                    MAGB_TIMEOUT_FRAMES_LONG);
            if (r != MAGB_OK) {
                return r;
            }
            if (closed) {
                *remote_closed = true;
                break;
            }
        }

        for (i = 0U; i < got_len; i++) {
            if (buf[len + i] == '\n') {
                uint8_t consumed = (uint8_t)(i + 1U);
                uint8_t leftover = (uint8_t)(got_len - consumed);
                if (leftover > 0U) {
                    memcpy(s_line_pending, &buf[len + consumed], leftover);
                    s_line_pending_len = leftover;
                    s_line_pending_pos = 0U;
                }
                len = (uint8_t)(len + consumed);
                buf[len] = '\0';
                return MAGB_OK;
            }
        }
        len = (uint8_t)(len + got_len);
        buf[len] = '\0';
        if (got_len == 0U) {
            vsync(); /* nothing yet -- see the P2P poll-spacing comment above */
        }
    }
    return MAGB_OK;
}

/* Sends `cmd`, reads one response line into `line`, and reports
 * whether it starts with `expect` (e.g. "250" or "+OK"). `*r` carries
 * any hardware/protocol-level failure separately from a plain
 * wrong-response mismatch. */
static bool line_step(magb_context_t *ctx, uint8_t conn_id, const char *cmd,
                       char *line, uint8_t line_cap, const char *expect,
                       magb_result_t *r, bool *remote_closed)
{
    *r = tcp_send_line(ctx, conn_id, cmd);
    if (*r != MAGB_OK) {
        return false;
    }
    *r = tcp_recv_line(ctx, conn_id, line, line_cap, remote_closed);
    if (*r != MAGB_OK) {
        return false;
    }
    return strncmp(line, expect, strlen(expect)) == 0;
}

void test_isp_email_send(magb_context_t *ctx, test_result_t *out, const char *password)
{
    magb_isp_identity_t id;
    uint8_t dns1[4] = { TEST_DNS_PRIMARY_A, TEST_DNS_PRIMARY_B, TEST_DNS_PRIMARY_C, TEST_DNS_PRIMARY_D };
    uint8_t dns2[4] = { TEST_DNS_SECONDARY_A, TEST_DNS_SECONDARY_B, TEST_DNS_SECONDARY_C, TEST_DNS_SECONDARY_D };
    magb_isp_login_result_t isp;
    uint8_t host_ip[4];
    uint8_t conn_id = 0U;
    /* Large enough for the biggest single line_step() argument this
     * function builds: the full message (MIME-Version/From/To/Subject/
     * Content-Type headers + blank line + test body + terminator, see
     * the DATA line_step() call below), which embeds id.email twice
     * (From:/To:) at up to MAGB_CONFIG_EMAIL_LEN each. */
    static char line[2U * MAGB_CONFIG_EMAIL_LEN + 160U];
    bool remote_closed;
    magb_result_t r;

    result_init(out, MAGB_CMD_TRANSFER);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, kMsgBeginSessionFailed); return; }

    r = read_isp_identity(ctx, &id);
    if (r != MAGB_OK) { result_fail(out, r, kMsgReadConfigFailed); (void)magb_end_session(ctx); return; }
    if (id.email[0] == '\0' || id.smtp[0] == '\0') {
        result_fail(out, MAGB_ERR_ISP, "NO EMAIL/SMTP IN CFG");
        (void)magb_end_session(ctx);
        return;
    }
    strncpy(out->detail[0], id.email, sizeof(out->detail[0]) - 1U);

    r = magb_dial(ctx, id.phone, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgDialIspFailed, kCode20000);
        (void)magb_end_session(ctx);
        return;
    }

    r = magb_isp_login(ctx, id.login, password, dns1, dns2, &isp);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgIspLoginFailed, kCode25000);
        isp_http_cleanup(ctx, 0U, false, false);
        return;
    }

    r = magb_dns_query(ctx, id.smtp, host_ip);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgDnsQueryFailed, kCode15000);
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

    r = magb_tcp_open(ctx, host_ip, 25U, &conn_id);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgTcpOpenFailed, kCode24000);
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }
    tcp_line_reset();

    r = tcp_recv_line(ctx, conn_id, line, sizeof(line), &remote_closed);
    if (r != MAGB_OK || strncmp(line, "220", 3) != 0) {
        result_fail(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "NO SMTP GREETING");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    if (!line_step(ctx, conn_id, "HELO magbtestsuite\r\n", line, sizeof(line), "250", &r, &remote_closed)) {
        result_fail(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "HELO REJECTED");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    sprintf(line, "MAIL FROM:<%s>\r\n", id.email);
    if (!line_step(ctx, conn_id, line, line, sizeof(line), "250", &r, &remote_closed)) {
        result_fail(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "MAIL FROM REJECTED");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    sprintf(line, "RCPT TO:<%s>\r\n", id.email);
    if (!line_step(ctx, conn_id, line, line, sizeof(line), "250", &r, &remote_closed)) {
        result_fail(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "RCPT TO REJECTED");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    if (!line_step(ctx, conn_id, "DATA\r\n", line, sizeof(line), "354", &r, &remote_closed)) {
        result_fail(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "DATA REJECTED");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    /* Real Mobile Trainer messages (dandocs-magb.md, "Mobile Trainer",
     * "Email") always carry at least MIME-Version/From/To/Content-Type
     * -- a bare "Subject: ...\r\n\r\nbody" (this test's original shape)
     * sends and round-trips fine over raw SMTP/POP3, and REON itself
     * doesn't reject it, but Mobile Trainer's own inbox couldn't
     * display a message received in that shape (confirmed by injecting
     * a header-less test message directly into a real test mailbox and
     * trying to open it in Mobile Trainer, then retrying with these
     * headers added -- the header-less version failed to open, this one
     * didn't). charset=iso-2022-jp is the value Mobile Trainer always
     * sends and is safe to declare even for plain ASCII text (which is
     * a valid subset of ISO-2022-JP's default/ASCII-mode state, no
     * escape sequences needed) -- see "GB00 HTTP authentication"-
     * adjacent notes in protocol-notes.md for how this was confirmed. */
    sprintf(line,
            "MIME-Version: 1.0\r\n"
            "From: %s\r\n"
            "To: %s\r\n"
            "Subject: MAGB TestSuite\r\n"
            "Content-Type: text/plain; charset=iso-2022-jp\r\n"
            "\r\n"
            "Hello from the Mobile Adapter GB TestSuite ROM.\r\n"
            ".\r\n",
            id.email, id.email);
    if (!line_step(ctx, conn_id, line, line, sizeof(line), "250", &r, &remote_closed)) {
        result_fail(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "MESSAGE REJECTED");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    (void)tcp_send_line(ctx, conn_id, "QUIT\r\n"); /* best-effort */
    isp_http_cleanup(ctx, conn_id, true, true);

    out->passed = true;
    out->result = MAGB_OK;
    sprintf(out->detail[1], "SENT OK");
}

/* Caps how many messages this scans/DELEs per run -- the mailbox is a
 * shared test account (not something this ROM owns exclusively), and a
 * bounded loop keeps a single test run's POP3 traffic (and its worst-
 * case runtime) predictable regardless of how many unrelated messages
 * happen to be sitting in it. */
#define EMAIL_DELETE_MAX_SCAN 20U

/* Removes only the messages this ROM's own test sent -- identified by
 * TOP <n> 0 (headers only, no body) containing exactly this ROM's own
 * kTestEmailSubjectLine. Never deletes anything else in the mailbox:
 * if TOP isn't supported by the server (no "+OK"), a message's headers
 * don't match, or a header line arrives split oddly, that message is
 * simply left alone rather than guessed at. DELE only *marks* messages
 * for removal -- POP3 doesn't actually purge them until a clean QUIT,
 * which the caller still sends afterwards. Returns how many were
 * marked, for the result screen (the project owner has seen more than
 * one identical test message accumulate in the same mailbox across
 * repeated runs, so this can legitimately delete more than one). */
static uint8_t delete_matching_test_emails(magb_context_t *ctx, uint8_t conn_id,
                                            char *line, uint8_t line_cap,
                                            uint16_t msg_count, bool *remote_closed)
{
    uint16_t msg;
    uint16_t scan_count = (msg_count > EMAIL_DELETE_MAX_SCAN) ? EMAIL_DELETE_MAX_SCAN : msg_count;
    uint8_t deleted = 0U;

    for (msg = 1U; msg <= scan_count; msg++) {
        bool matched = false;
        uint8_t header_lines;
        magb_result_t r;

        sprintf(line, "TOP %u 0\r\n", msg);
        if (!line_step(ctx, conn_id, line, line, line_cap, "+OK", &r, remote_closed)) {
            if (*remote_closed || r != MAGB_OK) {
                break;
            }
            continue; /* TOP unsupported/message missing -- skip, never guess */
        }

        for (header_lines = 0U; header_lines < 40U; header_lines++) {
            r = tcp_recv_line(ctx, conn_id, line, line_cap, remote_closed);
            if (r != MAGB_OK || *remote_closed) {
                break;
            }
            if (strcmp(line, ".\r\n") == 0 || strcmp(line, ".\n") == 0) {
                break; /* end of headers (RFC 1939 multi-line terminator) */
            }
            if (strncmp(line, kTestEmailSubjectLine, strlen(kTestEmailSubjectLine)) == 0) {
                matched = true;
            }
        }
        if (*remote_closed) {
            break;
        }

        if (matched) {
            sprintf(line, "DELE %u\r\n", msg);
            if (line_step(ctx, conn_id, line, line, line_cap, "+OK", &r, remote_closed)) {
                deleted++;
            }
            if (*remote_closed) {
                break;
            }
        }
    }
    return deleted;
}

void test_isp_email_recv(magb_context_t *ctx, test_result_t *out, const char *password)
{
    magb_isp_identity_t id;
    char user[MAGB_CONFIG_EMAIL_LEN + 1U];
    uint8_t dns1[4] = { TEST_DNS_PRIMARY_A, TEST_DNS_PRIMARY_B, TEST_DNS_PRIMARY_C, TEST_DNS_PRIMARY_D };
    uint8_t dns2[4] = { TEST_DNS_SECONDARY_A, TEST_DNS_SECONDARY_B, TEST_DNS_SECONDARY_C, TEST_DNS_SECONDARY_D };
    magb_isp_login_result_t isp;
    uint8_t host_ip[4];
    uint8_t conn_id = 0U;
    static char line[96];
    bool remote_closed;
    magb_result_t r;
    uint8_t i;

    if (!require_password(out, password)) { return; }
    result_init(out, MAGB_CMD_TRANSFER);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, kMsgBeginSessionFailed); return; }

    r = read_isp_identity(ctx, &id);
    if (r != MAGB_OK) { result_fail(out, r, kMsgReadConfigFailed); (void)magb_end_session(ctx); return; }
    if (id.email[0] == '\0' || id.pop[0] == '\0') {
        result_fail(out, MAGB_ERR_ISP, "NO EMAIL/POP IN CFG");
        (void)magb_end_session(ctx);
        return;
    }
    /* user = the local part of email, up to '@' -- no strchr() in
     * GBDK's minimal string.h, so a plain scan it is. */
    strncpy(user, id.email, sizeof(user) - 1U);
    user[sizeof(user) - 1U] = '\0';
    for (i = 0U; user[i] != '\0'; i++) {
        if (user[i] == '@') {
            user[i] = '\0';
            break;
        }
    }
    strncpy(out->detail[0], id.email, sizeof(out->detail[0]) - 1U);

    r = magb_dial(ctx, id.phone, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgDialIspFailed, kCode20000);
        (void)magb_end_session(ctx);
        return;
    }

    r = magb_isp_login(ctx, id.login, password, dns1, dns2, &isp);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgIspLoginFailed, kCode25000);
        isp_http_cleanup(ctx, 0U, false, false);
        return;
    }

    r = magb_dns_query(ctx, id.pop, host_ip);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgDnsQueryFailed, kCode15000);
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

    r = magb_tcp_open(ctx, host_ip, 110U, &conn_id);
    if (r != MAGB_OK) {
        result_fail_code(out, r, kMsgTcpOpenFailed, kCode24000);
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }
    tcp_line_reset();

    r = tcp_recv_line(ctx, conn_id, line, sizeof(line), &remote_closed);
    if (r != MAGB_OK || strncmp(line, "+OK", 3) != 0) {
        result_fail_code(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "NO POP3 GREETING", kCode31002);
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    sprintf(line, "USER %s\r\n", user);
    if (!line_step(ctx, conn_id, line, line, sizeof(line), "+OK", &r, &remote_closed)) {
        result_fail_code(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "USER REJECTED", kCode31002);
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    sprintf(line, "PASS %s\r\n", password);
    if (!line_step(ctx, conn_id, line, line, sizeof(line), "+OK", &r, &remote_closed)) {
        result_fail_code(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "LOGIN FAILED", kCode31002);
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    if (!line_step(ctx, conn_id, "STAT\r\n", line, sizeof(line), "+OK", &r, &remote_closed)) {
        result_fail_code(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "STAT FAILED", kCode31002);
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    {
        uint16_t msg_count = parse_leading_uint(line + 4);
        uint8_t deleted = 0U;

        if (!remote_closed) {
            deleted = delete_matching_test_emails(ctx, conn_id, line, sizeof(line),
                                                   msg_count, &remote_closed);
        }

        (void)tcp_send_line(ctx, conn_id, "QUIT\r\n"); /* best-effort; commits any DELE marks */
        isp_http_cleanup(ctx, conn_id, true, true);

        out->passed = true;
        out->result = MAGB_OK;
        if (deleted > 0U) {
            sprintf(out->detail[1], "MSGS %u DEL %u", msg_count, deleted);
        } else {
            sprintf(out->detail[1], "MESSAGES: %u", msg_count);
        }
    }
}

/* ---- Test 2d: ISP Raw TCP (interactive "netcat viewer") ---------------
 * Matches the real "ISP call (PPP)" mode gba-link-connection's own
 * LinkMobile documents: dial the ISP, open a TCP socket to an
 * arbitrary address, and transfer arbitrary data -- no fixed request/
 * response shape, no auth. Point `ip_digits` at a machine running
 * `nc -l <port>`; whatever gets typed there streams to this ROM and is
 * printed live, one incoming Transfer Data poll at a time, until the
 * remote closes the connection or the user cancels with B.
 *
 * This is deliberately the one test in this file that does NOT return
 * through a test_result_t -- there is no fixed "correct" response to
 * validate, and the whole point is a live, open-ended view, which
 * doesn't fit the "run once, report PASS/FAIL" shape every other test
 * here uses. It draws its own screen directly (cls()/gotoxy()/printf())
 * instead, the same way ui_show_trace()/ui_show_config() do in ui.c --
 * unlike those, this one has to live here rather than in ui.c because
 * it's interleaved with live magb_network.h calls, not a fixed buffer
 * to render once.
 *
 * Received bytes are printed through GBDK's stock console, which wraps
 * back to the top of the screen once full (it does not implement true
 * scrolling) -- long output will eventually overwrite the header; this
 * is a known, accepted limitation of a deliberately simple viewer. */
static void wait_ab(void)
{
    for (;;) {
        vsync();
        if (joypad() & (J_A | J_B)) {
            return;
        }
    }
}

static void parse_ip12(const char *digits, uint8_t ip[4])
{
    uint8_t i;
    for (i = 0U; i < 4U; i++) {
        ip[i] = (uint8_t)((digits[i * 3U] - '0') * 100
                         + (digits[i * 3U + 1U] - '0') * 10
                         + (digits[i * 3U + 2U] - '0'));
    }
}

#define RAW_TCP_POLL_BUF_SIZE 32U

void test_isp_raw_tcp(magb_context_t *ctx, const char *ip_digits, uint16_t port)
{
    magb_isp_identity_t id;
    uint8_t dns1[4] = { TEST_DNS_PRIMARY_A, TEST_DNS_PRIMARY_B, TEST_DNS_PRIMARY_C, TEST_DNS_PRIMARY_D };
    uint8_t dns2[4] = { TEST_DNS_SECONDARY_A, TEST_DNS_SECONDARY_B, TEST_DNS_SECONDARY_C, TEST_DNS_SECONDARY_D };
    magb_isp_login_result_t isp;
    uint8_t ip[4];
    uint8_t conn_id = 0U;
    uint8_t buf[RAW_TCP_POLL_BUF_SIZE];
    uint8_t got_len;
    bool remote_closed = false;
    bool have_conn = false;
    bool logged_in = false;
    magb_result_t r;
    const char *end_reason = "ENDED";

    cls();
    printf("ISP RAW TCP\n\n");

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { printf("BEGIN SESSION FAILED\n"); goto done_no_cleanup; }

    r = read_isp_identity(ctx, &id);
    if (r != MAGB_OK) { printf("READ CONFIG FAILED\n"); (void)magb_end_session(ctx); goto done_no_cleanup; }

    r = magb_dial(ctx, id.phone, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) { printf("DIAL ISP FAILED\n"); (void)magb_end_session(ctx); goto done_no_cleanup; }

    r = magb_isp_login(ctx, id.login, "", dns1, dns2, &isp);
    if (r != MAGB_OK) { printf("ISP LOGIN FAILED\n"); isp_http_cleanup(ctx, 0U, false, false); goto done_no_cleanup; }
    logged_in = true;

    parse_ip12(ip_digits, ip);
    r = magb_tcp_open(ctx, ip, port, &conn_id);
    if (r != MAGB_OK) { printf("TCP OPEN FAILED\n"); isp_http_cleanup(ctx, 0U, false, true); goto done_no_cleanup; }
    have_conn = true;

    printf("%u.%u.%u.%u:%u\nB: STOP\n\n", ip[0], ip[1], ip[2], ip[3], port);

    for (;;) {
        if (ctx->cancel_check != NULL && ctx->cancel_check()) {
            end_reason = "STOPPED (B)";
            break;
        }
        r = magb_transfer_data(ctx, conn_id, NULL, 0U, buf, (uint8_t)(RAW_TCP_POLL_BUF_SIZE - 1U),
                                &got_len, &remote_closed, MAGB_TIMEOUT_FRAMES_SHORT);
        if (r == MAGB_ERR_TIMEOUT) {
            continue; /* nothing arrived within this poll window -- keep waiting */
        }
        if (r != MAGB_OK) {
            end_reason = "XFER ERROR";
            break;
        }
        if (got_len > 0U) {
            uint8_t i;
            for (i = 0U; i < got_len; i++) {
                uint8_t c = buf[i];
                /* Binary-safe display: pass through newlines (so lines
                 * typed at `nc` look right) but replace other control
                 * bytes, matching print_ascii_field()'s convention
                 * elsewhere in this project rather than assuming the
                 * peer only ever sends printable text. */
                if (c < 0x20U && c != '\n' && c != '\r') {
                    c = '.';
                }
                putchar((char)c);
            }
        }
        if (remote_closed) {
            end_reason = "REMOTE CLOSED";
            break;
        }
        if (got_len == 0U) {
            vsync();
        }
    }

    /* conn_id is already 0 whenever have_conn is false (its initializer
     * above), so no ternary is needed here -- avoids a spurious SDCC
     * "conditional flow changed by optimizer" warning that a ternary
     * in this exact spot was triggering. */
    isp_http_cleanup(ctx, conn_id, have_conn, logged_in);

    gotoxy(0U, 17U);
    printf("%s -- A/B:MENU", end_reason);
    wait_ab();
    return;

done_no_cleanup:
    gotoxy(0U, 17U);
    printf("A/B:MENU");
    wait_ab();
}

/* ---- Test 3: P2P Caller / Listener ------------------------------------ */
static magb_result_t p2p_send_frame(magb_context_t *ctx, uint8_t sequence,
                                     const uint8_t *payload, uint8_t payload_len)
{
    uint8_t frame[MATS_HEADER_LEN + MATS_MAX_PAYLOAD];
    uint8_t frame_len = mats_build(frame, sequence, payload, payload_len);
    uint8_t discard[1];
    uint8_t got_len;
    bool remote_closed = false;

    return magb_transfer_data(ctx, MAGB_P2P_CONNECTION_ID, frame, frame_len,
                               discard, 0U, &got_len, &remote_closed,
                               MAGB_TIMEOUT_FRAMES_SHORT);
}

/* libmobile's command_data() only applies its "wait up to 1s for
 * data" grace period in internet (TCP) mode, not for a P2P call --
 * see docs/protocol-notes.md. So each poll here returns almost
 * instantly when nothing is available yet, unlike an HTTP receive.
 * One VBlank (~16.7ms) per empty poll spaces the polling out so it
 * doesn't spin the link at full CPU speed.
 *
 * This used to give up after a fixed poll count (first 180 -- ~3s --
 * then a bumped 1800 -- ~30s). A real two-machine BGB test proved even
 * the bigger bound wrong: the Caller dialed, got 0x92, and sent its
 * PING immediately; the Listener got 0x94 and started polling for it,
 * but the two independently operated machines don't reach this point
 * in lockstep, and giving up here tears down the connection (see
 * p2p_cleanup() below) out from under whichever side is still waiting
 * -- which is exactly what showed up as a real adapter Error Status on
 * the *other* side (command 0x15) instead of a plain timeout;
 * libmobile-bgb's own debug log confirmed it: "recv: Foi forcado o
 * cancelamento de uma conexao existente pelo host remoto."
 *
 * The 20-30s bound belongs to *connection establishment* only (Dial /
 * Wait For Call, MAGB_TIMEOUT_FRAMES_P2P_CALL below) -- once the
 * adapter has actually connected the two peers, there is no reason to
 * cap how long this side waits for the other to catch up, so this
 * loop is intentionally unbounded except for the B cancel check every
 * iteration (magb_transfer_data() itself still bounds each individual
 * local serial exchange via MAGB_TIMEOUT_FRAMES_SHORT, so a dead local
 * adapter still surfaces as MAGB_ERR_TIMEOUT, not a permanent hang). */

/* How long the Caller's Dial (0x12) waits, in one single request,
 * before giving up -- matches Pokemon Crystal's own P2P
 * call-establishment behavior (roughly 20-30s before dropping), not
 * MAGB_TIMEOUT_FRAMES_LONG's 15s. A real Dial to an unreachable/
 * firewalled peer is a raw TCP connect() at the adapter/relay level
 * (see docs/protocol-notes.md's P2P section), and OS-level connect
 * timeouts commonly run 20s+ on their own; cutting this TestSuite's
 * own wait shorter than that just means it reports its own timeout
 * before the adapter ever gets to report the real failure reason.
 * Confirmed against libmobile's commands.c
 * (command_tel_ip(): no internal cutoff, just polls
 * mobile_cb_sock_connect() until it succeeds or truly fails) that a
 * single long-timeout request is the right shape for Dial specifically
 * -- see P2P_WAIT_CALL_MAX_ATTEMPTS below for why the Listener's Wait
 * For Call needs a different (retry-loop) shape instead. */
#define MAGB_TIMEOUT_FRAMES_P2P_CALL 1500U /* ~25s @ ~60Hz */

/* Unlike Dial, libmobile's own Wait For Call (direct-IP) only waits
 * ~1 real second internally before giving up with an Error Status,
 * regardless of the timeout_frames this ROM asks for --
 * libmobile's commands.c's command_wait_call(),
 * MOBILE_CONNECTION_WAIT case: it latches MOBILE_TIMER_COMMAND once
 * at the start and, from then on, unconditionally returns
 * error_packet(packet, 0) once 1000ms have passed, on every single
 * poll, forever -- it never gets re-latched. This isn't a bug to work
 * around quietly: it's confirmed as the *intended* protocol shape by
 * the real Pokemon Crystal disassembly (pokecrystal-mobile-eng's
 * lib/mobile/main.asm, Function1123b6 / .asm_1123c6): when the response
 * to Wait For Call is command 0xEE (Error Status), the game just
 * resends the exact same Wait For Call packet again. So this ROM does
 * the same -- retries Wait For Call itself, once per "no call yet"
 * Error Status, instead of expecting one call to block for the whole
 * wait. Each attempt only needs MAGB_TIMEOUT_FRAMES_SHORT (libmobile
 * answers within ~1s either way); the attempt count is what gives the
 * same overall ~20-30s connection-establishment budget as Dial's
 * MAGB_TIMEOUT_FRAMES_P2P_CALL. B still cancels immediately via
 * magb_wait_for_call()'s own cancel_check on every attempt. */
#define P2P_WAIT_CALL_MAX_ATTEMPTS 20U

/* No separate "press B" reminder is printed partway through this wait:
 * ui_show_testing(true) already put "B:CANCEL" on screen before this
 * test started, and it stays there for the whole (now unbounded) wait
 * below -- a second, timed reprint of the same instruction would only
 * cost ROM bytes this already-full-32KiB build doesn't have to spare
 * (see the Makefile's -autobank comment) without telling the user
 * anything "TESTING\nB:CANCEL" hasn't already said since before the
 * connection was even made. */
static magb_result_t p2p_recv_frame(magb_context_t *ctx, uint8_t *sequence,
                                     uint8_t *payload, uint8_t *payload_len)
{
    uint8_t buf[MATS_HEADER_LEN + MATS_MAX_PAYLOAD];
    uint8_t got_len;
    bool remote_closed;

    for (;;) {
        magb_result_t r;

        if (ctx->cancel_check != NULL && ctx->cancel_check()) {
            return MAGB_ERR_CANCELLED;
        }

        r = magb_transfer_data(ctx, MAGB_P2P_CONNECTION_ID, NULL, 0U,
                                buf, sizeof(buf), &got_len, &remote_closed,
                                MAGB_TIMEOUT_FRAMES_SHORT);
        if (r != MAGB_OK) {
            return r;
        }
        if (remote_closed) {
            return MAGB_ERR_P2P;
        }
        if (got_len > 0U) {
            if (!mats_parse(buf, got_len, sequence, payload, payload_len)) {
                return MAGB_ERR_P2P;
            }
            return MAGB_OK;
        }
        vsync();
    }
}

static void p2p_cleanup(magb_context_t *ctx)
{
    (void)magb_hangup(ctx);
    (void)magb_end_session(ctx);
}

/* p2p_recv_frame() can fail with MAGB_ERR_REMOTE_STATUS when the far
 * end's connection drops mid-exchange -- confirmed on a real BGB
 * session: after the listener side's connection died, the adapter
 * answered a Transfer Data poll with an Error Status packet (command
 * 0x15, code 0x00 -- "invalid connection / communication failed", Dan
 * Docs' "6E - Error Status" table) instead of more data. Showing the
 * generic kMsgTransferTimeout for that would be actively misleading,
 * since nothing timed out; show the adapter's own reported command/
 * code instead. */
static void p2p_recv_fail(test_result_t *out, magb_context_t *ctx, magb_result_t r)
{
    result_fail(out, r, kMsgTransferTimeout);
    if (r == MAGB_ERR_REMOTE_STATUS) {
        sprintf(out->detail[0], "CMD %hx ERR %hx", (unsigned char)ctx->remote_error_command,
                (unsigned char)ctx->remote_error_code);
    }
}

void test_p2p_caller(magb_context_t *ctx, test_result_t *out, const char *number)
{
    static const uint8_t pattern[8] = { 0x00, 0x01, 0x55, 0xAA, 0xFE, 0xFF, 0x10, 0xEF };
    uint8_t recv_payload[MATS_MAX_PAYLOAD];
    uint8_t recv_seq;
    uint8_t recv_len;
    magb_result_t r;

    result_init(out, MAGB_CMD_DIAL);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, kMsgBeginSessionFailed); return; }

    r = magb_dial(ctx, number, MAGB_TIMEOUT_FRAMES_P2P_CALL);
    if (r != MAGB_OK) {
        result_fail(out, r, kMsgNoCall);
        (void)magb_end_session(ctx);
        return;
    }

    r = p2p_send_frame(ctx, 1U, (const uint8_t *)"PING", 4U);
    if (r != MAGB_OK) { result_fail(out, r, "PING SEND FAILED"); p2p_cleanup(ctx); return; }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { p2p_recv_fail(out, ctx, r); p2p_cleanup(ctx); return; }
    if (recv_len != 4U || memcmp(recv_payload, "PONG", 4U) != 0 || recv_seq != 1U) {
        result_fail(out, MAGB_ERR_P2P, kMsgBadTestFrame);
        p2p_cleanup(ctx);
        return;
    }

    r = p2p_send_frame(ctx, 2U, pattern, sizeof(pattern));
    if (r != MAGB_OK) { result_fail(out, r, "PATTERN SEND FAILED"); p2p_cleanup(ctx); return; }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { p2p_recv_fail(out, ctx, r); p2p_cleanup(ctx); return; }
    if (recv_len != sizeof(pattern) || memcmp(recv_payload, pattern, sizeof(pattern)) != 0 ||
            recv_seq != 2U) {
        result_fail(out, MAGB_ERR_P2P, "BAD PAYLOAD");
        p2p_cleanup(ctx);
        return;
    }

    /* PING/PONG and the binary pattern above already prove the link
     * byte-for-byte, including 0x00/0xFF edge cases -- this step adds
     * nothing new protocol-wise. It exists purely so the result screen
     * can show an actual human-readable message that made it across
     * the link and back, as a plain, at-a-glance "yes, this really
     * worked" on top of the raw byte counts. */
    r = p2p_send_frame(ctx, 3U, (const uint8_t *)kHelloWorld, 11U);
    if (r != MAGB_OK) { result_fail(out, r, "HELLO SEND FAILED"); p2p_cleanup(ctx); return; }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { p2p_recv_fail(out, ctx, r); p2p_cleanup(ctx); return; }
    if (recv_len != 11U || memcmp(recv_payload, kHelloWorld, 11U) != 0 || recv_seq != 3U) {
        result_fail(out, MAGB_ERR_P2P, "BAD HELLO ECHO");
        p2p_cleanup(ctx);
        return;
    }

    p2p_cleanup(ctx);

    out->passed = true;
    out->result = MAGB_OK;
    out->tx_bytes = (uint16_t)(4U + sizeof(pattern) + 11U);
    out->rx_bytes = (uint16_t)(4U + sizeof(pattern) + 11U);
    sprintf(out->detail[0], "TX %u RX %u", out->tx_bytes, out->rx_bytes);
    sprintf(out->detail[1], kMsgHelloWorldOk);
}

void test_p2p_listener(magb_context_t *ctx, test_result_t *out)
{
    uint8_t recv_payload[MATS_MAX_PAYLOAD];
    uint8_t recv_seq;
    uint8_t recv_len;
    magb_result_t r;

    result_init(out, MAGB_CMD_WAIT_CALL);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, kMsgBeginSessionFailed); return; }

    /* See P2P_WAIT_CALL_MAX_ATTEMPTS's comment: the adapter itself only
     * waits ~1s per attempt, so this ROM supplies the retry loop, not
     * one long blocking request. */
    {
        uint8_t attempt;
        r = MAGB_ERR_TIMEOUT;
        for (attempt = 0U; attempt < P2P_WAIT_CALL_MAX_ATTEMPTS; attempt++) {
            r = magb_wait_for_call(ctx, MAGB_TIMEOUT_FRAMES_SHORT);
            if (r != MAGB_ERR_REMOTE_STATUS) {
                break;
            }
        }
    }
    if (r == MAGB_ERR_CANCELLED) {
        result_fail(out, r, "CANCELLED");
        (void)magb_end_session(ctx);
        return;
    }
    if (r != MAGB_OK) {
        result_fail(out, r, kMsgNoCall);
        (void)magb_end_session(ctx);
        return;
    }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { p2p_recv_fail(out, ctx, r); p2p_cleanup(ctx); return; }
    if (recv_len != 4U || memcmp(recv_payload, "PING", 4U) != 0) {
        result_fail(out, MAGB_ERR_P2P, kMsgBadTestFrame);
        p2p_cleanup(ctx);
        return;
    }

    r = p2p_send_frame(ctx, recv_seq, (const uint8_t *)"PONG", 4U);
    if (r != MAGB_OK) { result_fail(out, r, "PONG SEND FAILED"); p2p_cleanup(ctx); return; }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { p2p_recv_fail(out, ctx, r); p2p_cleanup(ctx); return; }

    r = p2p_send_frame(ctx, recv_seq, recv_payload, recv_len);
    if (r != MAGB_OK) { result_fail(out, r, kMsgEchoSendFailed); p2p_cleanup(ctx); return; }

    /* Third round-trip: the caller's human-readable "HELLO WORLD"
     * message (see test_p2p_caller()) -- echoed back generically like
     * the pattern step above, since this side doesn't need to know
     * what the payload actually is to prove the link works both ways. */
    {
        uint8_t hello_len;
        r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &hello_len);
        if (r != MAGB_OK) { p2p_recv_fail(out, ctx, r); p2p_cleanup(ctx); return; }

        r = p2p_send_frame(ctx, recv_seq, recv_payload, hello_len);
        if (r != MAGB_OK) { result_fail(out, r, kMsgEchoSendFailed); p2p_cleanup(ctx); return; }

        recv_len = (uint8_t)(recv_len + hello_len);
    }

    p2p_cleanup(ctx);

    out->passed = true;
    out->result = MAGB_OK;
    out->tx_bytes = (uint16_t)(8U + recv_len);
    out->rx_bytes = (uint16_t)(8U + recv_len);
    sprintf(out->detail[0], "TX %u RX %u", out->tx_bytes, out->rx_bytes);
    sprintf(out->detail[1], kMsgHelloWorldOk);
}
