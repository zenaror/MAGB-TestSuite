#include "test_runner.h"
#include "magb_network.h"
#include "magb_commands.h"
#include "test_config.h"
#include "gb00_auth.h"

#include <gb/gb.h> /* vsync() only, for the P2P receive poll spacing below */
#include <string.h>
#include <stdio.h>

/* ---- MATS: TestSuite-only P2P payload framing (Section 33) --------
 * This is carried *inside* MAGB Transfer Data (0x15) payloads. It is
 * not part of the Mobile Adapter protocol itself. */
#define MATS_HEADER_LEN 7U /* magic(4) + version(1) + sequence(1) + length(1) */
#define MATS_MAX_PAYLOAD 8U
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
        result_fail(out, r, "BEGIN SESSION FAILED");
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
        result_fail(out, r, "READ CONFIG FAILED");
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

void test_isp_http(magb_context_t *ctx, test_result_t *out,
                    const char *host, uint16_t port, const char *path)
{
    static char s_request[224];
    magb_result_t r;
    magb_phone_status_t phone;
    magb_isp_login_result_t isp;
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
    if (r != MAGB_OK) { result_fail(out, r, "BEGIN SESSION FAILED"); return; }

    r = magb_telephone_status(ctx, &phone);
    if (r != MAGB_OK) {
        result_fail(out, r, "PHONE STATUS FAILED");
        (void)magb_end_session(ctx);
        return;
    }

    r = magb_dial(ctx, TEST_ISP_PHONE);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "DIAL ISP FAILED", "20-000");
        (void)magb_end_session(ctx);
        return;
    }

    r = magb_isp_login(ctx, TEST_ISP_LOGIN, TEST_ISP_PASSWORD, dns1, dns2, &isp);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "ISP LOGIN FAILED", "25-000");
        isp_http_cleanup(ctx, 0U, false, false);
        return;
    }

    r = magb_dns_query(ctx, host, host_ip);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "DNS QUERY FAILED", "15-000");
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }
    sprintf(out->detail[0], "DNS %u.%u.%u.%u",
            host_ip[0], host_ip[1], host_ip[2], host_ip[3]);

    r = magb_tcp_open(ctx, host_ip, port, &conn_id);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "TCP OPEN FAILED", "24-000");
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
        result_fail_code(out, r, "HTTP SEND FAILED", "32-000");
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
            result_fail_code(out, r, "HTTP RECV FAILED", "32-000");
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
            strcpy(out->official_code, "32-000");
        }
        sprintf(out->detail[1], "RX TOTAL %u B", total_received);
    } else {
        out->passed = false;
        out->result = MAGB_OK; /* transport worked; this is an application-layer mismatch */
        sprintf(out->detail[0], "TRANSPORT OK");
        sprintf(out->detail[1], "NO HTTP/ PREFIX");
        strcpy(out->official_code, "15-000");
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
 * The GB00 login (dionId) is read live from the adapter's own Read
 * Configuration Data (0x19) response (offset MAGB_CONFIG_OFF_LOGIN_ID,
 * the real "gXXXXXXXXX"-style registered ID -- see Dan Docs' Mobile
 * Adapter GB configuration layout), the same way the email tests read
 * the email/SMTP/POP fields -- not TEST_ISP_LOGIN. A real REON account
 * is provisioned against that registered ID, not an arbitrary string,
 * so hardcoding "test" here would 401 against any real deployment even
 * with perfectly correct crypto. TEST_ISP_PASSWORD is still used for
 * the password, since no password is ever stored in the adapter's
 * configuration memory (see CLAUDE.md's Test Configuration section). */
#define GB00_RESP_BUF_SIZE 200U
static uint8_t s_gb00_resp[GB00_RESP_BUF_SIZE];

/* Copies printable bytes from a config field until a 0x00 byte or
 * `max_len`, NUL-terminating. Config fields observed 0x00-padded past
 * their actual content. Shared with the email tests further below. */
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

/* Sends one HTTP/1.0 GET (optionally with an extra header line, e.g.
 * "Authorization: ...\r\n", or NULL for none) over `conn_id` and
 * accumulates the response into s_gb00_resp. Mirrors test_isp_http()'s
 * receive loop, kept separate because this flow needs to do it twice
 * (once to provoke the 401, once with the computed Authorization). */
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

    sprintf(s_gb00_req, "GET %s HTTP/1.0\r\nHost: %s\r\n%s\r\n",
            path, host, (extra_header != NULL) ? extra_header : "");
    req_len = (uint16_t)strlen(s_gb00_req);

    r = magb_transfer_data(ctx, conn_id, (const uint8_t *)s_gb00_req, (uint8_t)req_len,
                            &s_gb00_resp[0], (uint8_t)GB00_RESP_BUF_SIZE,
                            &got_len, remote_closed, MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        return r;
    }
    resp_len = got_len;

    while (!*remote_closed && resp_len < GB00_RESP_BUF_SIZE && empty_polls < HTTP_MAX_EMPTY_POLLS) {
        uint8_t cap = (uint8_t)(GB00_RESP_BUF_SIZE - resp_len);
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

void test_isp_http_gb00(magb_context_t *ctx, test_result_t *out,
                         const char *host, uint16_t port, const char *path)
{
    magb_result_t r;
    magb_phone_status_t phone;
    magb_isp_login_result_t isp;
    uint8_t dns1[4] = { TEST_DNS_PRIMARY_A, TEST_DNS_PRIMARY_B, TEST_DNS_PRIMARY_C, TEST_DNS_PRIMARY_D };
    uint8_t dns2[4] = { TEST_DNS_SECONDARY_A, TEST_DNS_SECONDARY_B, TEST_DNS_SECONDARY_C, TEST_DNS_SECONDARY_D };
    uint8_t host_ip[4];
    uint8_t conn_id = 0U;
    uint16_t resp_len;
    bool remote_closed;
    char challenge[GB00_CHALLENGE_LEN + 1U];
    static char auth_header[16U + GB00_AUTHORIZATION_LEN + 4U];
    char status[4];
    uint8_t config[MAGB_CONFIG_SIZE];
    char gb00_login[MAGB_CONFIG_LOGIN_ID_LEN + 1U];

    result_init(out, MAGB_CMD_TRANSFER);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, "BEGIN SESSION FAILED"); return; }

    r = magb_read_config(ctx, config);
    if (r != MAGB_OK) { result_fail(out, r, "READ CONFIG FAILED"); (void)magb_end_session(ctx); return; }
    config_field_to_cstr(&config[MAGB_CONFIG_OFF_LOGIN_ID], MAGB_CONFIG_LOGIN_ID_LEN,
                          gb00_login, sizeof(gb00_login));
    if (gb00_login[0] == '\0') {
        /* Adapter never registered via Mobile Trainer (config blank) --
         * fall back to the compile-time login rather than failing
         * outright; a real deployment will still reject it with 401,
         * but this keeps the test runnable against libmobile's default
         * unregistered config. */
        strncpy(gb00_login, TEST_ISP_LOGIN, sizeof(gb00_login) - 1U);
        gb00_login[sizeof(gb00_login) - 1U] = '\0';
    }
    /* detail[1] is only otherwise touched by "RX %u B" at the very end
     * of this function (removed in favor of this) -- result_fail()
     * only ever overwrites detail[0], so this survives to the result
     * screen on every exit path, success or failure, which matters
     * here specifically because a wrong login is the single most
     * likely cause of a 401-after-retry. */
    sprintf(out->detail[1], "LOGIN %s", gb00_login);

    r = magb_telephone_status(ctx, &phone);
    if (r != MAGB_OK) { result_fail(out, r, "PHONE STATUS FAILED"); (void)magb_end_session(ctx); return; }

    r = magb_dial(ctx, TEST_ISP_PHONE);
    if (r != MAGB_OK) { result_fail_code(out, r, "DIAL ISP FAILED", "20-000"); (void)magb_end_session(ctx); return; }

    r = magb_isp_login(ctx, TEST_ISP_LOGIN, TEST_ISP_PASSWORD, dns1, dns2, &isp);
    if (r != MAGB_OK) { result_fail_code(out, r, "ISP LOGIN FAILED", "25-000"); isp_http_cleanup(ctx, 0U, false, false); return; }

    r = magb_dns_query(ctx, host, host_ip);
    if (r != MAGB_OK) { result_fail_code(out, r, "DNS QUERY FAILED", "15-000"); isp_http_cleanup(ctx, 0U, false, true); return; }
    sprintf(out->detail[0], "DNS %u.%u.%u.%u", host_ip[0], host_ip[1], host_ip[2], host_ip[3]);

    r = magb_tcp_open(ctx, host_ip, port, &conn_id);
    if (r != MAGB_OK) { result_fail_code(out, r, "TCP OPEN FAILED", "24-000"); isp_http_cleanup(ctx, 0U, false, true); return; }

    r = gb00_http_get(ctx, conn_id, host, path, NULL, &resp_len, &remote_closed);
    if (r != MAGB_OK) { result_fail_code(out, r, "HTTP SEND FAILED", "32-000"); isp_http_cleanup(ctx, conn_id, true, true); return; }

    if (!gb00_status_code(s_gb00_resp, resp_len, status)) {
        result_fail_code(out, MAGB_OK, "NO HTTP/ PREFIX", "15-000");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    if (strncmp(status, "401", 3) != 0) {
        /* No auth needed after all (or something else entirely) --
         * report the status directly, same shape as test_isp_http(). */
        isp_http_cleanup(ctx, conn_id, true, true);
        out->passed = true;
        out->result = MAGB_OK;
        sprintf(out->detail[0], "HTTP STATUS %s", status);
        sprintf(out->detail[1], "(NO AUTH NEEDED)");
        sprintf(out->official_code, "32-%s", status);
        return;
    }

    if (!gb00_find_challenge(s_gb00_resp, resp_len, challenge)) {
        result_fail_code(out, MAGB_OK, "NO WWW-AUTH HDR", "32-401");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    /* REON's PHP closes the connection after the 401 (Connection: close
     * is implied by HTTP/1.0); re-open before the authenticated retry. */
    (void)magb_tcp_close(ctx, conn_id);
    r = magb_tcp_open(ctx, host_ip, port, &conn_id);
    if (r != MAGB_OK) { result_fail_code(out, r, "TCP REOPEN FAILED", "24-000"); isp_http_cleanup(ctx, 0U, false, true); return; }

    {
        char auth_value[GB00_AUTHORIZATION_LEN + 1U];
        gb00_build_authorization(challenge, gb00_login, TEST_ISP_PASSWORD, auth_value);
        sprintf(auth_header, "Authorization: GB00 name=\"%s\"\r\n", auth_value);
    }

    r = gb00_http_get(ctx, conn_id, host, path, auth_header, &resp_len, &remote_closed);
    if (r != MAGB_OK) { result_fail_code(out, r, "AUTH SEND FAILED", "32-000"); isp_http_cleanup(ctx, conn_id, true, true); return; }

    isp_http_cleanup(ctx, conn_id, true, true);

    out->tx_bytes = GB00_AUTHORIZATION_LEN;
    out->rx_bytes = resp_len;

    if (!gb00_status_code(s_gb00_resp, resp_len, status)) {
        result_fail_code(out, MAGB_OK, "NO HTTP/ AFTER AUTH", "15-000");
        return;
    }

    out->passed = true;
    out->result = MAGB_OK;
    sprintf(out->detail[0], "AUTH -> HTTP %s", status);
    /* detail[1] is left as the "LOGIN <id>" line set right after Read
     * Config -- more useful here than the RX byte count (already in
     * out->rx_bytes) for telling a crypto/transport bug apart from a
     * wrong-account 401. */
    sprintf(out->official_code, "32-%s", status);
}

/* ---- Test 2b/2c: ISP Email (SMTP send / POP3 receive) ------------------
 * Neither SMTP nor POP3 is a Mobile Adapter command -- both are just
 * ordinary line-based text protocols run over a plain TCP connection
 * (port 25 / 110), exactly like the HTTP test above uses port 80. The
 * exact dialogue below was confirmed against REON's real mail server
 * source (references/reon/mail/smtp.js, smtpConnection.js,
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
        for (i = 0U; i < got_len; i++) {
            if (buf[len + i] == '\n') {
                len = (uint8_t)(len + i + 1U);
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

void test_isp_email_send(magb_context_t *ctx, test_result_t *out)
{
    uint8_t config[MAGB_CONFIG_SIZE];
    char email[MAGB_CONFIG_EMAIL_LEN + 1U];
    char smtp_host[MAGB_CONFIG_SMTP_LEN + 1U];
    uint8_t dns1[4] = { TEST_DNS_PRIMARY_A, TEST_DNS_PRIMARY_B, TEST_DNS_PRIMARY_C, TEST_DNS_PRIMARY_D };
    uint8_t dns2[4] = { TEST_DNS_SECONDARY_A, TEST_DNS_SECONDARY_B, TEST_DNS_SECONDARY_C, TEST_DNS_SECONDARY_D };
    magb_isp_login_result_t isp;
    uint8_t host_ip[4];
    uint8_t conn_id = 0U;
    static char line[MAGB_CONFIG_EMAIL_LEN + 48U];
    bool remote_closed;
    magb_result_t r;

    result_init(out, MAGB_CMD_TRANSFER);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, "BEGIN SESSION FAILED"); return; }

    r = magb_read_config(ctx, config);
    if (r != MAGB_OK) {
        result_fail(out, r, "READ CONFIG FAILED");
        (void)magb_end_session(ctx);
        return;
    }
    config_field_to_cstr(&config[MAGB_CONFIG_OFF_EMAIL], MAGB_CONFIG_EMAIL_LEN,
                          email, sizeof(email));
    config_field_to_cstr(&config[MAGB_CONFIG_OFF_SMTP], MAGB_CONFIG_SMTP_LEN,
                          smtp_host, sizeof(smtp_host));
    if (email[0] == '\0' || smtp_host[0] == '\0') {
        result_fail(out, MAGB_ERR_ISP, "NO EMAIL/SMTP IN CFG");
        (void)magb_end_session(ctx);
        return;
    }
    strncpy(out->detail[0], email, sizeof(out->detail[0]) - 1U);

    r = magb_dial(ctx, TEST_ISP_PHONE);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "DIAL ISP FAILED", "20-000");
        (void)magb_end_session(ctx);
        return;
    }

    r = magb_isp_login(ctx, TEST_ISP_LOGIN, TEST_ISP_PASSWORD, dns1, dns2, &isp);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "ISP LOGIN FAILED", "25-000");
        isp_http_cleanup(ctx, 0U, false, false);
        return;
    }

    r = magb_dns_query(ctx, smtp_host, host_ip);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "DNS QUERY FAILED", "15-000");
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

    r = magb_tcp_open(ctx, host_ip, 25U, &conn_id);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "TCP OPEN FAILED", "24-000");
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

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

    sprintf(line, "MAIL FROM:<%s>\r\n", email);
    if (!line_step(ctx, conn_id, line, line, sizeof(line), "250", &r, &remote_closed)) {
        result_fail(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "MAIL FROM REJECTED");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    sprintf(line, "RCPT TO:<%s>\r\n", email);
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

    if (!line_step(ctx, conn_id,
            "Subject: MAGB TestSuite\r\n\r\nHello from the Mobile Adapter GB TestSuite ROM.\r\n.\r\n",
            line, sizeof(line), "250", &r, &remote_closed)) {
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

void test_isp_email_recv(magb_context_t *ctx, test_result_t *out)
{
    uint8_t config[MAGB_CONFIG_SIZE];
    char email[MAGB_CONFIG_EMAIL_LEN + 1U];
    char pop_host[MAGB_CONFIG_POP_LEN + 1U];
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

    result_init(out, MAGB_CMD_TRANSFER);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, "BEGIN SESSION FAILED"); return; }

    r = magb_read_config(ctx, config);
    if (r != MAGB_OK) {
        result_fail(out, r, "READ CONFIG FAILED");
        (void)magb_end_session(ctx);
        return;
    }
    config_field_to_cstr(&config[MAGB_CONFIG_OFF_EMAIL], MAGB_CONFIG_EMAIL_LEN,
                          email, sizeof(email));
    config_field_to_cstr(&config[MAGB_CONFIG_OFF_POP], MAGB_CONFIG_POP_LEN,
                          pop_host, sizeof(pop_host));
    if (email[0] == '\0' || pop_host[0] == '\0') {
        result_fail(out, MAGB_ERR_ISP, "NO EMAIL/POP IN CFG");
        (void)magb_end_session(ctx);
        return;
    }
    /* user = the local part of email, up to '@' -- no strchr() in
     * GBDK's minimal string.h, so a plain scan it is. */
    strncpy(user, email, sizeof(user) - 1U);
    user[sizeof(user) - 1U] = '\0';
    for (i = 0U; user[i] != '\0'; i++) {
        if (user[i] == '@') {
            user[i] = '\0';
            break;
        }
    }
    strncpy(out->detail[0], email, sizeof(out->detail[0]) - 1U);

    r = magb_dial(ctx, TEST_ISP_PHONE);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "DIAL ISP FAILED", "20-000");
        (void)magb_end_session(ctx);
        return;
    }

    r = magb_isp_login(ctx, TEST_ISP_LOGIN, TEST_ISP_PASSWORD, dns1, dns2, &isp);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "ISP LOGIN FAILED", "25-000");
        isp_http_cleanup(ctx, 0U, false, false);
        return;
    }

    r = magb_dns_query(ctx, pop_host, host_ip);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "DNS QUERY FAILED", "15-000");
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

    r = magb_tcp_open(ctx, host_ip, 110U, &conn_id);
    if (r != MAGB_OK) {
        result_fail_code(out, r, "TCP OPEN FAILED", "24-000");
        isp_http_cleanup(ctx, 0U, false, true);
        return;
    }

    r = tcp_recv_line(ctx, conn_id, line, sizeof(line), &remote_closed);
    if (r != MAGB_OK || strncmp(line, "+OK", 3) != 0) {
        result_fail_code(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "NO POP3 GREETING", "31-002");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    sprintf(line, "USER %s\r\n", user);
    if (!line_step(ctx, conn_id, line, line, sizeof(line), "+OK", &r, &remote_closed)) {
        result_fail_code(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "USER REJECTED", "31-002");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    sprintf(line, "PASS %s\r\n", TEST_ISP_PASSWORD);
    if (!line_step(ctx, conn_id, line, line, sizeof(line), "+OK", &r, &remote_closed)) {
        result_fail_code(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "LOGIN FAILED", "31-002");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    if (!line_step(ctx, conn_id, "STAT\r\n", line, sizeof(line), "+OK", &r, &remote_closed)) {
        result_fail_code(out, (r == MAGB_OK) ? MAGB_ERR_ISP : r, "STAT FAILED", "31-002");
        isp_http_cleanup(ctx, conn_id, true, true);
        return;
    }

    (void)tcp_send_line(ctx, conn_id, "QUIT\r\n"); /* best-effort */
    isp_http_cleanup(ctx, conn_id, true, true);

    out->passed = true;
    out->result = MAGB_OK;
    sprintf(out->detail[1], "MESSAGES: %u", parse_leading_uint(line + 4));
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
 * Without a real per-poll delay, P2P_RECV_MAX_POLLS empty polls could
 * exhaust in well under a frame, giving the *other*, separately
 * operated ROM instance no realistic wall-clock time to catch up.
 * One VBlank (~16.7ms) per empty poll times 180 polls bounds the wait
 * at ~3s while still resolving near-instantly once data is flowing. */
#define P2P_RECV_MAX_POLLS 180U

static magb_result_t p2p_recv_frame(magb_context_t *ctx, uint8_t *sequence,
                                     uint8_t *payload, uint8_t *payload_len)
{
    uint8_t buf[MATS_HEADER_LEN + MATS_MAX_PAYLOAD];
    uint8_t got_len;
    bool remote_closed;
    uint8_t poll;

    for (poll = 0U; poll < P2P_RECV_MAX_POLLS; poll++) {
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
    return MAGB_ERR_TIMEOUT;
}

static void p2p_cleanup(magb_context_t *ctx)
{
    (void)magb_hangup(ctx);
    (void)magb_end_session(ctx);
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
    if (r != MAGB_OK) { result_fail(out, r, "BEGIN SESSION FAILED"); return; }

    r = magb_dial(ctx, number);
    if (r != MAGB_OK) {
        result_fail(out, r, "NO CALL");
        (void)magb_end_session(ctx);
        return;
    }

    r = p2p_send_frame(ctx, 1U, (const uint8_t *)"PING", 4U);
    if (r != MAGB_OK) { result_fail(out, r, "PING SEND FAILED"); p2p_cleanup(ctx); return; }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { result_fail(out, r, "TRANSFER TIMEOUT"); p2p_cleanup(ctx); return; }
    if (recv_len != 4U || memcmp(recv_payload, "PONG", 4U) != 0 || recv_seq != 1U) {
        result_fail(out, MAGB_ERR_P2P, "BAD TEST FRAME");
        p2p_cleanup(ctx);
        return;
    }

    r = p2p_send_frame(ctx, 2U, pattern, sizeof(pattern));
    if (r != MAGB_OK) { result_fail(out, r, "PATTERN SEND FAILED"); p2p_cleanup(ctx); return; }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { result_fail(out, r, "TRANSFER TIMEOUT"); p2p_cleanup(ctx); return; }
    if (recv_len != sizeof(pattern) || memcmp(recv_payload, pattern, sizeof(pattern)) != 0 ||
            recv_seq != 2U) {
        result_fail(out, MAGB_ERR_P2P, "BAD PAYLOAD");
        p2p_cleanup(ctx);
        return;
    }

    p2p_cleanup(ctx);

    out->passed = true;
    out->result = MAGB_OK;
    out->tx_bytes = 4U + sizeof(pattern);
    out->rx_bytes = 4U + sizeof(pattern);
    sprintf(out->detail[0], "TX %u RX %u", out->tx_bytes, out->rx_bytes);
    sprintf(out->detail[1], "DATA OK");
}

void test_p2p_listener(magb_context_t *ctx, test_result_t *out)
{
    uint8_t recv_payload[MATS_MAX_PAYLOAD];
    uint8_t recv_seq;
    uint8_t recv_len;
    magb_result_t r;

    result_init(out, MAGB_CMD_WAIT_CALL);

    r = magb_begin_session(ctx);
    if (r != MAGB_OK) { result_fail(out, r, "BEGIN SESSION FAILED"); return; }

    r = magb_wait_for_call(ctx, MAGB_TIMEOUT_FRAMES_LONG * 4U);
    if (r == MAGB_ERR_CANCELLED) {
        result_fail(out, r, "CANCELLED");
        (void)magb_end_session(ctx);
        return;
    }
    if (r != MAGB_OK) {
        result_fail(out, r, "NO CALL");
        (void)magb_end_session(ctx);
        return;
    }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { result_fail(out, r, "TRANSFER TIMEOUT"); p2p_cleanup(ctx); return; }
    if (recv_len != 4U || memcmp(recv_payload, "PING", 4U) != 0) {
        result_fail(out, MAGB_ERR_P2P, "BAD TEST FRAME");
        p2p_cleanup(ctx);
        return;
    }

    r = p2p_send_frame(ctx, recv_seq, (const uint8_t *)"PONG", 4U);
    if (r != MAGB_OK) { result_fail(out, r, "PONG SEND FAILED"); p2p_cleanup(ctx); return; }

    r = p2p_recv_frame(ctx, &recv_seq, recv_payload, &recv_len);
    if (r != MAGB_OK) { result_fail(out, r, "TRANSFER TIMEOUT"); p2p_cleanup(ctx); return; }

    r = p2p_send_frame(ctx, recv_seq, recv_payload, recv_len);
    if (r != MAGB_OK) { result_fail(out, r, "ECHO SEND FAILED"); p2p_cleanup(ctx); return; }

    p2p_cleanup(ctx);

    out->passed = true;
    out->result = MAGB_OK;
    out->tx_bytes = (uint16_t)(4U + recv_len);
    out->rx_bytes = (uint16_t)(4U + recv_len);
    sprintf(out->detail[0], "TX %u RX %u", out->tx_bytes, out->rx_bytes);
    sprintf(out->detail[1], "DATA OK");
}
