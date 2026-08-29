; Mobile Adapter GB protocol constants shared across the packet-framing
; and session/ACK layers. Values cross-checked against the same three
; independent sources gbdk/include/magb_commands.h cites (libmobile,
; libma, pokecrystal-mobile-eng's own asm) -- see that file and
; gbdk/docs/protocol-notes.md for the full citations; not re-derived
; here, just carried over.
;
; DEF/EQU constants are assembler-time only and do NOT cross object file
; boundaries by themselves (unlike `::`-exported labels, which the linker
; resolves) -- every .asm file that needs these must INCLUDE this file
; itself, including packet.asm and session.asm both needing the exact
; same PROTO_MAX_PAYLOAD_LEN.

; ---- Wire framing ----------------------------------------------------
DEF MAGB_MAGIC_1 EQU $99
DEF MAGB_MAGIC_2 EQU $66
DEF MAGB_RESPONSE_BIT EQU $80

; The protocol's real documented max (repo-root CLAUDE.md: "maximum
; payload = 254 bytes, length high = 0"). Needed for Transfer Data/HTTP
; (gbdk/src/app/test_runner.c's test_isp_http() sends a ~150-byte GET
; request and reads up to HTTP_RESP_BUF_SIZE=240 bytes per response
; chunk). BuildRequestFrame/ReadResponseFrame both do their length/
; checksum arithmetic in 16-bit BC specifically so this can sit at the
; true 254-byte ceiling without overflowing -- see packet.asm's
; BuildRequestFrame comment for why an 8-bit sum used to break here.
DEF PROTO_MAX_PAYLOAD_LEN EQU 254
DEF PROTO_FRAME_OVERHEAD  EQU 8 ; magic(2) + header(4) + checksum(2)

; ---- Handshake / flow-control bytes -----------------------------------
DEF MAGB_ADAPTER_WAIT EQU $D2 ; adapter -> GBC: "still processing"
DEF MAGB_GBC_WAIT     EQU $4B ; GBC -> adapter: clock-filler while reading
DEF MAGB_GBC_DEVICE_ACK EQU $80 ; GBC -> adapter: MAGB_DEVICE_GAMEBOY | RESPONSE_BIT

DEF MAGB_ACK_ERR_UNSUPPORTED EQU $F0
DEF MAGB_ACK_ERR_CHECKSUM    EQU $F1
DEF MAGB_ACK_ERR_INTERNAL    EQU $F2

DEF MAGB_MAX_RETRANSMIT EQU 4

; ---- Adapter device IDs (Begin Session ACK1/ACK2) ---------------------
DEF MAGB_DEVICE_ADAPTER_BLUE EQU $08
DEF MAGB_DEVICE_ADAPTER_RED  EQU $0B
DEF DEVICE_ID_MASK EQU $7F ; clears the response bit to get the raw device id

; ---- Commands used so far ----------------------------------------------
DEF MAGB_CMD_BEGIN_SESSION EQU $10
DEF MAGB_CMD_END_SESSION   EQU $11
DEF MAGB_CMD_DIAL          EQU $12
DEF MAGB_CMD_HANGUP        EQU $13
DEF MAGB_CMD_TRANSFER      EQU $15
; 0x1F never appears as a request the Game Boy sends -- the adapter uses
; it in place of a normal 0x15 response's command byte to signal that
; the remote TCP peer closed the connection (gbdk/include/magb_commands.h).
; Must be recognized when parsing 0x15 responses, never transmitted.
DEF MAGB_CMD_TRANSFER_DATA_END EQU $1F
DEF MAGB_CMD_ISP_LOGIN     EQU $21
DEF MAGB_CMD_ISP_LOGOUT    EQU $22
DEF MAGB_CMD_TCP_OPEN      EQU $23
DEF MAGB_CMD_TCP_CLOSE     EQU $24
DEF MAGB_CMD_DNS           EQU $28
DEF MAGB_CMD_ERROR_STATUS  EQU $6E

DEF MAGB_NINTENDO_MAGIC_LEN EQU 8
DEF MAGB_MAX_PHONE_NUMBER_LEN EQU 12 ; matches gbdk/include/magb_network.h

; ---- Session-command timeouts (in VBlank-counted "frames") ------------
DEF MAGB_TIMEOUT_FRAMES_SHORT EQU 180 ; ~3s @ ~59.7Hz: session control commands
; Dial needs real connect()-timeout headroom, not a control-command
; budget -- matches gbdk/include/magb_session.h's MAGB_TIMEOUT_FRAMES_LONG
; (see that file's comment: a real Dial is a raw TCP connect() at the
; adapter/relay level, and OS-level connect timeouts commonly run past
; a few seconds on their own).
DEF MAGB_TIMEOUT_FRAMES_LONG EQU 900 ; ~15s @ ~59.7Hz

; ---- Result codes -------------------------------------------------------
; 0 always means success; every function in this codebase returns its
; result in register A using these codes. Not a 1:1 copy of
; gbdk/include/magb_protocol.h's enum (fewer members -- only what this
; milestone's call paths can actually produce) but the same shape and
; the same names, so cross-referencing the two isn't guesswork.
DEF MAGB_OK                     EQU 0
DEF MAGB_ERR_TIMEOUT            EQU 1
DEF MAGB_ERR_BAD_MAGIC          EQU 2
DEF MAGB_ERR_BAD_LENGTH         EQU 3
DEF MAGB_ERR_BAD_CHECKSUM       EQU 4
DEF MAGB_ERR_UNEXPECTED_COMMAND EQU 5
DEF MAGB_ERR_REMOTE_UNSUPPORTED EQU 6
DEF MAGB_ERR_REMOTE_CHECKSUM    EQU 7
DEF MAGB_ERR_REMOTE_INTERNAL    EQU 8
DEF MAGB_ERR_SESSION            EQU 9
DEF MAGB_ERR_PAYLOAD_TOO_LARGE  EQU 10
DEF MAGB_ERR_REMOTE_STATUS      EQU 11
