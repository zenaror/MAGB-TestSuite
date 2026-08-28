/** Layer 2 -- Mobile Adapter GB command wrappers: telephone, ISP, DNS,
 * TCP and configuration-readout. Each function builds the documented
 * payload for its command, calls magb_execute(), and validates the
 * response shape before handing back a parsed result.
 *
 * Payload formats were derived directly from libmobile/commands.c
 * (see docs/protocol-notes.md for file:line citations), not guessed.
 */
#ifndef MAGB_NETWORK_H
#define MAGB_NETWORK_H

#include "magb_session.h"
#include <stdint.h>
#include <stdbool.h>

/* ---- Telephone Status (0x17) --------------------------------------- */
typedef struct {
    uint8_t call_state;    /* MAGB_PHONE_STATE_* */
    uint8_t adapter_type;  /* MAGB_PHONE_ADAPTER_* */
    bool unmetered;
} magb_phone_status_t;

magb_result_t magb_telephone_status(magb_context_t *ctx, magb_phone_status_t *out);

/* ---- Dial Telephone (0x12) / Hang Up (0x13) ------------------------ */
/** `number` is an ASCII digit string (digits, '#', '*'), NUL-terminated,
 * at most 31 characters (kept well under the 254-byte payload cap).
 * `timeout_frames` is the caller's choice on purpose: ISP dial-up
 * resolves quickly, but a P2P dial has to wait out however long the
 * adapter takes to actually attempt (and possibly fail/time out) a raw
 * TCP connect to the dialed peer, which can legitimately take much
 * longer -- see MAGB_TIMEOUT_FRAMES_P2P_CALL in test_runner.c. */
magb_result_t magb_dial(magb_context_t *ctx, const char *number, uint16_t timeout_frames);
magb_result_t magb_hangup(magb_context_t *ctx);

/* ---- Wait For Telephone Call (0x14) --------------------------------
 * libmobile treats this as a single request that blocks (from the
 * Game Boy's point of view, inside the normal RESPONSE_WAITING poll)
 * until a call arrives or the adapter gives up -- there is no partial/
 * repeat-until-ready handshake at the MAGB payload level. `timeout_frames`
 * should be generous (this is a real "wait for someone to dial in"). */
magb_result_t magb_wait_for_call(magb_context_t *ctx, uint16_t timeout_frames);

/* ---- ISP Login (0x21) ----------------------------------------------- */
typedef struct {
    uint8_t assigned_ip[4];
    uint8_t dns1[4];
    uint8_t dns2[4];
} magb_isp_login_result_t;

/** `dns1`/`dns2` may be {0,0,0,0} to request the adapter's own
 * configured DNS servers (confirmed libmobile behavior: a zeroed DNS
 * entry is replaced with the locally configured one in the response). */
magb_result_t magb_isp_login(magb_context_t *ctx, const char *login, const char *password,
                              const uint8_t dns1[4], const uint8_t dns2[4],
                              magb_isp_login_result_t *out);
magb_result_t magb_isp_logout(magb_context_t *ctx);

/* ---- DNS Query (0x28) ------------------------------------------------ */
magb_result_t magb_dns_query(magb_context_t *ctx, const char *hostname, uint8_t out_ip[4]);

/* ---- TCP Open (0x23) / Close (0x24) ----------------------------------- */
magb_result_t magb_tcp_open(magb_context_t *ctx, const uint8_t ip[4], uint16_t port,
                             uint8_t *out_conn_id);
magb_result_t magb_tcp_close(magb_context_t *ctx, uint8_t conn_id);

/* ---- Transfer Data (0x15) --------------------------------------------
 * `conn_id` selects the TCP connection (as returned by magb_tcp_open())
 * or MAGB_P2P_CONNECTION_ID (0xFF) for a P2P/telephone session -- see
 * magb_commands.h. On return, *out_len holds the number of response
 * bytes actually copied into `out` (capped at out_cap). *remote_closed
 * is set if the adapter reported MAGB_CMD_TRANSFER_DATA_END (0x1F|0x80)
 * instead of the normal 0x15|0x80, i.e. the remote peer closed the
 * connection. */
magb_result_t magb_transfer_data(magb_context_t *ctx, uint8_t conn_id,
                                  const uint8_t *data, uint8_t data_len,
                                  uint8_t *out, uint8_t out_cap, uint8_t *out_len,
                                  bool *remote_closed, uint16_t timeout_frames);

/* ---- Read Configuration Data (0x19) -----------------------------------
 * Mirrors gba-link-connection's LinkMobile::readConfiguration(): the
 * documented configuration blob is exactly 192 bytes, read as two
 * 96-byte halves (libmobile's own 0x19 handler caps a single read at
 * 128 bytes). See docs/protocol-notes.md for the full field layout
 * (registration state, DNS servers, login id, email, SMTP/POP hosts,
 * ISP dial-string slots, trailing checksum). */
#define MAGB_CONFIG_SIZE 192U
#define MAGB_CONFIG_CHUNK (MAGB_CONFIG_SIZE / 2U)

magb_result_t magb_read_config(magb_context_t *ctx, uint8_t out[MAGB_CONFIG_SIZE]);

/* Field offsets within the 192-byte configuration blob, per the
 * documented Mobile Adapter GB configuration layout (cross-checked
 * against gba-link-connection's LinkMobile::ConfigurationData; see
 * docs/protocol-notes.md, "Read Configuration Data (0x19) payload/
 * response, and the config layout"). */
#define MAGB_CONFIG_OFF_MAGIC        0U
#define MAGB_CONFIG_OFF_REG_STATE    2U
#define MAGB_CONFIG_OFF_DNS1         4U
#define MAGB_CONFIG_OFF_DNS2         8U
#define MAGB_CONFIG_OFF_LOGIN_ID     12U
#define MAGB_CONFIG_LOGIN_ID_LEN     10U
#define MAGB_CONFIG_OFF_EMAIL        44U
#define MAGB_CONFIG_EMAIL_LEN        24U
#define MAGB_CONFIG_OFF_SMTP         74U
#define MAGB_CONFIG_SMTP_LEN         20U
#define MAGB_CONFIG_OFF_POP          94U
#define MAGB_CONFIG_POP_LEN          19U

#endif /* MAGB_NETWORK_H */
