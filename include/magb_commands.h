/** Layer 2 -- Mobile Adapter GB command IDs and device IDs.
 *
 * Values cross-checked against three independent, source-level
 * implementations (see docs/protocol-notes.md for exact file:line
 * citations):
 *   - libmobile/commands.h      (MOBILE_COMMAND_*)
 *   - libma/ma_var.h            (MACMD_*)
 *   - pokecrystal-mobile-eng/lib/mobile/main.asm (MOBILE_COMMAND_*)
 * All three agree on every numeric value below without exception.
 */
#ifndef MAGB_COMMANDS_H
#define MAGB_COMMANDS_H

#include <stdint.h>

#define MAGB_CMD_EMPTY             0x0FU
#define MAGB_CMD_BEGIN_SESSION     0x10U
#define MAGB_CMD_END_SESSION       0x11U
#define MAGB_CMD_DIAL              0x12U
#define MAGB_CMD_HANGUP            0x13U
#define MAGB_CMD_WAIT_CALL         0x14U
#define MAGB_CMD_TRANSFER          0x15U
#define MAGB_CMD_RESET             0x16U
#define MAGB_CMD_PHONE_STATUS      0x17U
#define MAGB_CMD_SIO32             0x18U /* declared for completeness; NEVER sent by this TestSuite */
#define MAGB_CMD_READ_CONFIG       0x19U
#define MAGB_CMD_WRITE_CONFIG      0x1AU
/* 0x1F never appears as a request the Game Boy sends. The adapter
 * substitutes it for the response *command* byte of a Transfer Data
 * (0x15) reply to signal that the remote TCP peer closed the
 * connection (libmobile commands.c: packet->command = MOBILE_COMMAND_DATA_END).
 * It must be recognized when parsing 0x15 responses, never transmitted. */
#define MAGB_CMD_TRANSFER_DATA_END 0x1FU
#define MAGB_CMD_ISP_LOGIN         0x21U
#define MAGB_CMD_ISP_LOGOUT        0x22U
#define MAGB_CMD_TCP_OPEN          0x23U
#define MAGB_CMD_TCP_CLOSE         0x24U
#define MAGB_CMD_UDP_OPEN          0x25U
#define MAGB_CMD_UDP_CLOSE         0x26U
#define MAGB_CMD_DNS               0x28U

/* Mobile Adapter device IDs (libmobile/commands.h: enum mobile_adapter_device). */
#define MAGB_DEVICE_GAMEBOY        0x00U /* what this TestSuite always identifies as */
#define MAGB_DEVICE_GAMEBOY_ADVANCE 0x01U
#define MAGB_DEVICE_ADAPTER_BLUE   0x08U /* PDC/DoCoMo -- libmobile's default adapter */
#define MAGB_DEVICE_ADAPTER_YELLOW 0x09U /* cdmaOne/au-KDDI */
#define MAGB_DEVICE_ADAPTER_GREEN  0x0AU /* PHS/DDI-Pocket */
#define MAGB_DEVICE_ADAPTER_RED    0x0BU /* PHS/DDI variant */

/** True if `id` is one of the documented adapter device IDs (0x08-0x0B).
 * The parser accepts any of these rather than hardcoding one model. */
#define MAGB_IS_KNOWN_ADAPTER_DEVICE(id) \
    ((id) >= MAGB_DEVICE_ADAPTER_BLUE && (id) <= MAGB_DEVICE_ADAPTER_RED)

/** Byte the Game Boy transmits during the request-ACK phase to
 * identify itself: MAGB_DEVICE_GAMEBOY | MAGB_RESPONSE_BIT. */
#define MAGB_GBC_DEVICE_ACK 0x80U

/** Begin Session payload: exactly 8 bytes, no trailing NUL. */
#define MAGB_NINTENDO_MAGIC "NINTENDO"
#define MAGB_NINTENDO_MAGIC_LEN 8U

/** Telephone Status (0x17) response byte 1: which physical adapter the
 * response identifies as (independent of the MAGB_DEVICE_ADAPTER_* id
 * captured during Begin Session). Meaning of the value itself is
 * otherwise undocumented; only these three observed values are known
 * (Dan Docs, "Mobile Adapter GB" -> "17 - Telephone Status"). Red
 * shares Yellow's value here -- it is not grouped with Blue. */
#define MAGB_PHONE_ADAPTER_BLUE   0x4DU
#define MAGB_PHONE_ADAPTER_RED    0x48U
#define MAGB_PHONE_ADAPTER_YELLOW 0x48U

/** Telephone Status (0x17) response byte 0: call state. */
#define MAGB_PHONE_STATE_DISCONNECTED   0x00U
#define MAGB_PHONE_STATE_CALLING_ESTABLISHED  0x04U
#define MAGB_PHONE_STATE_RECEIVE_ESTABLISHED  0x05U

/** Transfer Data (0x15) connection selector: P2P calls are not indexed
 * by libmobile at all (the byte is ignored while a P2P call is active),
 * but 0xFF is the documented/conventional value real titles send. */
#define MAGB_P2P_CONNECTION_ID 0xFFU

#endif /* MAGB_COMMANDS_H */
