#include "magb_network.h"
#include "magb_commands.h"

#include <string.h>

#define MAGB_MAX_PHONE_NUMBER_LEN 32U

magb_result_t magb_telephone_status(magb_context_t *ctx, magb_phone_status_t *out)
{
    magb_packet_t response;
    magb_result_t r = magb_execute(ctx, MAGB_CMD_PHONE_STATUS, NULL, 0U, &response,
                                    MAGB_TIMEOUT_FRAMES_SHORT);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_PHONE_STATUS)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    if (response.payload_len != 3U) {
        return MAGB_ERR_BAD_LENGTH;
    }

    out->call_state = response.payload[0];
    out->adapter_type = response.payload[1];
    out->unmetered = (response.payload[2] & 0xF0U) != 0U;
    return MAGB_OK;
}

magb_result_t magb_dial(magb_context_t *ctx, const char *number)
{
    uint8_t payload[1U + MAGB_MAX_PHONE_NUMBER_LEN];
    uint8_t len;
    magb_packet_t response;
    magb_result_t r;

    len = (uint8_t)strlen(number);
    if (len > MAGB_MAX_PHONE_NUMBER_LEN) {
        return MAGB_ERR_PAYLOAD_TOO_LARGE;
    }

    /* Dial Telephone's first byte is a per-adapter-type validation
     * value (libmobile/commands.c command_tel_begin): Blue requires
     * exactly 0x00, Yellow doesn't check it at all, Green/Red accept
     * 0x01 (also 0x09 for Green/Red per the same check). 0x00 is only
     * safe for Blue, so pick based on the device id captured at
     * Begin Session; 0x01 covers Yellow (unchecked) and Green/Red. */
    payload[0] = (ctx->adapter_device == MAGB_DEVICE_ADAPTER_BLUE) ? 0x00U : 0x01U;
    memcpy(&payload[1], number, len);

    r = magb_execute(ctx, MAGB_CMD_DIAL, payload, (uint8_t)(1U + len), &response,
                      MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_DIAL)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    return MAGB_OK;
}

magb_result_t magb_hangup(magb_context_t *ctx)
{
    magb_packet_t response;
    magb_result_t r = magb_execute(ctx, MAGB_CMD_HANGUP, NULL, 0U, &response,
                                    MAGB_TIMEOUT_FRAMES_SHORT);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_HANGUP)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    return MAGB_OK;
}

magb_result_t magb_wait_for_call(magb_context_t *ctx, uint16_t timeout_frames)
{
    magb_packet_t response;
    magb_result_t r = magb_execute(ctx, MAGB_CMD_WAIT_CALL, NULL, 0U, &response,
                                    timeout_frames);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_WAIT_CALL)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    return MAGB_OK;
}

magb_result_t magb_isp_login(magb_context_t *ctx, const char *login, const char *password,
                              const uint8_t dns1[4], const uint8_t dns2[4],
                              magb_isp_login_result_t *out)
{
    uint8_t payload[1U + 32U + 1U + 32U + 4U + 4U];
    uint8_t login_len = (uint8_t)strlen(login);
    uint8_t pass_len = (uint8_t)strlen(password);
    uint8_t pos = 0U;
    magb_packet_t response;
    magb_result_t r;

    if (login_len > 32U || pass_len > 32U) {
        return MAGB_ERR_PAYLOAD_TOO_LARGE;
    }

    payload[pos++] = login_len;
    memcpy(&payload[pos], login, login_len);
    pos = (uint8_t)(pos + login_len);

    payload[pos++] = pass_len;
    memcpy(&payload[pos], password, pass_len);
    pos = (uint8_t)(pos + pass_len);

    memcpy(&payload[pos], dns1, 4U);
    pos = (uint8_t)(pos + 4U);
    memcpy(&payload[pos], dns2, 4U);
    pos = (uint8_t)(pos + 4U);

    r = magb_execute(ctx, MAGB_CMD_ISP_LOGIN, payload, pos, &response,
                      MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_ISP_LOGIN)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    if (response.payload_len != 12U) {
        return MAGB_ERR_BAD_LENGTH;
    }

    memcpy(out->assigned_ip, &response.payload[0], 4U);
    memcpy(out->dns1, &response.payload[4], 4U);
    memcpy(out->dns2, &response.payload[8], 4U);
    return MAGB_OK;
}

magb_result_t magb_isp_logout(magb_context_t *ctx)
{
    magb_packet_t response;
    magb_result_t r = magb_execute(ctx, MAGB_CMD_ISP_LOGOUT, NULL, 0U, &response,
                                    MAGB_TIMEOUT_FRAMES_SHORT);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_ISP_LOGOUT)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    return MAGB_OK;
}

magb_result_t magb_dns_query(magb_context_t *ctx, const char *hostname, uint8_t out_ip[4])
{
    uint8_t len = (uint8_t)strlen(hostname);
    magb_packet_t response;
    magb_result_t r;

    if (len > MAGB_MAX_PAYLOAD) {
        return MAGB_ERR_PAYLOAD_TOO_LARGE;
    }

    /* No length-prefix or NUL: the hostname is the raw payload, its
     * size taken entirely from the MAGB header's length field
     * (libmobile/commands.c command_dns_request_begin). */
    r = magb_execute(ctx, MAGB_CMD_DNS, (const uint8_t *)hostname, len, &response,
                      MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_DNS)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    if (response.payload_len != 4U) {
        return MAGB_ERR_BAD_LENGTH;
    }

    memcpy(out_ip, response.payload, 4U);
    return MAGB_OK;
}

magb_result_t magb_tcp_open(magb_context_t *ctx, const uint8_t ip[4], uint16_t port,
                             uint8_t *out_conn_id)
{
    uint8_t payload[6];
    magb_packet_t response;
    magb_result_t r;

    memcpy(payload, ip, 4U);
    payload[4] = (uint8_t)(port >> 8);
    payload[5] = (uint8_t)(port & 0xFFU);

    r = magb_execute(ctx, MAGB_CMD_TCP_OPEN, payload, sizeof(payload), &response,
                      MAGB_TIMEOUT_FRAMES_LONG);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_TCP_OPEN)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    if (response.payload_len != 1U) {
        return MAGB_ERR_BAD_LENGTH;
    }

    *out_conn_id = response.payload[0];
    return MAGB_OK;
}

magb_result_t magb_tcp_close(magb_context_t *ctx, uint8_t conn_id)
{
    magb_packet_t response;
    magb_result_t r = magb_execute(ctx, MAGB_CMD_TCP_CLOSE, &conn_id, 1U, &response,
                                    MAGB_TIMEOUT_FRAMES_SHORT);
    if (r != MAGB_OK) {
        return r;
    }
    if (response.command != magb_response_command(MAGB_CMD_TCP_CLOSE)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    return MAGB_OK;
}

magb_result_t magb_transfer_data(magb_context_t *ctx, uint8_t conn_id,
                                  const uint8_t *data, uint8_t data_len,
                                  uint8_t *out, uint8_t out_cap, uint8_t *out_len,
                                  bool *remote_closed, uint16_t timeout_frames)
{
    uint8_t payload[MAGB_MAX_PAYLOAD];
    magb_packet_t response;
    magb_result_t r;
    uint8_t n;

    if ((uint16_t)data_len + 1U > MAGB_MAX_PAYLOAD) {
        return MAGB_ERR_PAYLOAD_TOO_LARGE;
    }

    payload[0] = conn_id;
    memcpy(&payload[1], data, data_len);

    r = magb_execute(ctx, MAGB_CMD_TRANSFER, payload, (uint8_t)(1U + data_len), &response,
                      timeout_frames);
    if (r != MAGB_OK) {
        return r;
    }

    *remote_closed = (response.command == magb_response_command(MAGB_CMD_TRANSFER_DATA_END));
    if (!*remote_closed && response.command != magb_response_command(MAGB_CMD_TRANSFER)) {
        return MAGB_ERR_UNEXPECTED_COMMAND;
    }
    if (response.payload_len < 1U) {
        return MAGB_ERR_BAD_LENGTH;
    }

    n = (uint8_t)(response.payload_len - 1U);
    if (n > out_cap) {
        n = out_cap;
    }
    memcpy(out, &response.payload[1], n);
    *out_len = n;
    return MAGB_OK;
}

magb_result_t magb_read_config(magb_context_t *ctx, uint8_t out[MAGB_CONFIG_SIZE])
{
    uint8_t half;

    for (half = 0U; half < 2U; half++) {
        uint8_t payload[2];
        magb_packet_t response;
        magb_result_t r;
        uint8_t offset = (uint8_t)(half * MAGB_CONFIG_CHUNK);

        payload[0] = offset;
        payload[1] = MAGB_CONFIG_CHUNK;

        r = magb_execute(ctx, MAGB_CMD_READ_CONFIG, payload, sizeof(payload), &response,
                          MAGB_TIMEOUT_FRAMES_SHORT);
        if (r != MAGB_OK) {
            return r;
        }
        if (response.command != magb_response_command(MAGB_CMD_READ_CONFIG)) {
            return MAGB_ERR_UNEXPECTED_COMMAND;
        }
        if (response.payload_len != (uint8_t)(MAGB_CONFIG_CHUNK + 1U) ||
                response.payload[0] != offset) {
            return MAGB_ERR_BAD_LENGTH;
        }

        memcpy(&out[offset], &response.payload[1], MAGB_CONFIG_CHUNK);
    }

    return MAGB_OK;
}
