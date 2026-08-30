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

; The conventional "software" send-side max (repo-root CLAUDE.md:
; "maximum payload = 254 bytes, length high = 0"; gbdk/docs/
; dandocs-magb.md's "Packet length limits": "supported software limits
; Packet Data to 254 bytes"). Used only for what THIS ROM builds and
; sends (BuildRequestFrame/MagbTransferData's own outgoing cap) --
; matches gbdk's own MAGB_MAX_PAYLOAD, used the same way in
; magb_build_frame(). See PROTO_MAX_RX_PAYLOAD_LEN below for what this
; ROM must accept when *receiving*, which is a different, larger number
; for a real, documented reason.
;
; BuildRequestFrame/ReadResponseFrame both do their length/checksum
; arithmetic in 16-bit BC specifically so this can sit at the true
; ceiling without overflowing -- see packet.asm's BuildRequestFrame
; comment for why an 8-bit sum used to break here.
DEF PROTO_MAX_PAYLOAD_LEN EQU 254

; The real adapter's actual receive-side limit -- same Dan Docs section
; as above, next sentence: "the real Mobile Adapter discards packets
; larger than 255 bytes. In practical terms, the high byte of the
; length remains zero." 254 is only what *software* conventionally
; chooses to send, not a hard ceiling the adapter itself enforces on
; what it returns -- confirmed the hard way against a real
; libmobile-bgb Transfer Data response (ISP/HTTP's Tamago Egg fetch)
; that legitimately carried payload_len = 255 (conn_id byte + a full
; 254-byte HTTP response chunk) and was wrongly rejected as
; MAGB_ERR_BAD_LENGTH before this constant existed. 255 is also the
; natural maximum of the wire's 8-bit length-low byte, so there is no
; larger legal value to guard against here -- ReadResponseFrame has no
; upper-bound check at all now, matching gbdk's own parser
; (magb_packet.c's magb_parser_feed()), which never checks
; payload_len against MAGB_MAX_PAYLOAD on receive either.
DEF PROTO_MAX_RX_PAYLOAD_LEN EQU 255

DEF PROTO_FRAME_OVERHEAD  EQU 8 ; magic(2) + header(4) + checksum(2)

; ---- Handshake / flow-control bytes -----------------------------------
DEF MAGB_ADAPTER_WAIT EQU $D2 ; adapter -> GBC: "still processing"
DEF MAGB_GBC_WAIT     EQU $4B ; GBC -> adapter: clock-filler while reading
DEF MAGB_GBC_DEVICE_ACK EQU $80 ; GBC -> adapter: MAGB_DEVICE_GAMEBOY | RESPONSE_BIT

DEF MAGB_ACK_ERR_UNSUPPORTED EQU $F0
DEF MAGB_ACK_ERR_CHECKSUM    EQU $F1
DEF MAGB_ACK_ERR_INTERNAL    EQU $F2

DEF MAGB_MAX_RETRANSMIT EQU 4

; ---- Diagnostic trace ring buffer --------------------------------------
; Matches gbdk/include/magb_session.h's MAGB_TRACE_LEN/MAGB_TRACE_TX/
; MAGB_TRACE_RX exactly. Deliberately a power of two -- the ring
; buffer's wraparound (session.asm's RecordTraceByte, main.asm's
; ShowTrace) is a plain AND instead of a modulo because of it.
DEF MAGB_TRACE_LEN EQU 128
DEF MAGB_TRACE_TX  EQU 0
DEF MAGB_TRACE_RX  EQU 1

; ---- Adapter device IDs (Begin Session ACK1/ACK2) ---------------------
DEF MAGB_DEVICE_ADAPTER_BLUE EQU $08
DEF MAGB_DEVICE_ADAPTER_RED  EQU $0B
DEF DEVICE_ID_MASK EQU $7F ; clears the response bit to get the raw device id

; ---- Commands used so far ----------------------------------------------
DEF MAGB_CMD_BEGIN_SESSION EQU $10
DEF MAGB_CMD_END_SESSION   EQU $11
DEF MAGB_CMD_DIAL          EQU $12
DEF MAGB_CMD_HANGUP        EQU $13
DEF MAGB_CMD_WAIT_CALL     EQU $14
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
DEF MAGB_CMD_READ_CONFIG   EQU $19
DEF MAGB_CMD_ERROR_STATUS  EQU $6E

; ---- Read Configuration Data (0x19) ------------------------------------
; libmobile's own 0x19 handler caps a single read at 96 bytes, so the
; real 192-byte configuration blob is always read as two halves -- see
; gbdk/include/magb_network.h's MAGB_CONFIG_SIZE/MAGB_CONFIG_CHUNK for
; the same split, and gbdk/include/magb_config.h for the fuller layout
; (BCD phone slots, registration state) this port doesn't decode yet.
DEF MAGB_CONFIG_SIZE       EQU 192
DEF MAGB_CONFIG_CHUNK      EQU 96
DEF MAGB_CONFIG_OFF_CHECKSUM EQU 190

; Field layout within the 192-byte blob -- matches
; gbdk/include/magb_network.h (session/network/mail fields) and
; gbdk/include/magb_config.h (Configuration Slot 1, registration
; state) exactly; both cite Dan Docs' "Configuration Data" section as
; the primary source. Used by main.asm's ShowConfigScreen to decode and
; display the same fields gbdk's ui_show_config() does.
DEF MAGB_CONFIG_OFF_MAGIC     EQU 0
DEF MAGB_CONFIG_OFF_REG_STATE EQU 2
DEF MAGB_CONFIG_OFF_DNS1      EQU 4
DEF MAGB_CONFIG_OFF_DNS2      EQU 8
DEF MAGB_CONFIG_OFF_LOGIN_ID  EQU 12
DEF MAGB_CONFIG_LOGIN_ID_LEN  EQU 10
DEF MAGB_CONFIG_OFF_EMAIL     EQU 44
DEF MAGB_CONFIG_EMAIL_LEN     EQU 24
DEF MAGB_CONFIG_OFF_SMTP      EQU 74
DEF MAGB_CONFIG_SMTP_LEN      EQU 20
DEF MAGB_CONFIG_OFF_POP       EQU 94
DEF MAGB_CONFIG_POP_LEN       EQU 19
DEF MAGB_CONFIG_OFF_SLOT1        EQU 118
DEF MAGB_CONFIG_SLOT_PHONE_LEN   EQU 8
DEF MAGB_CONFIG_SLOT_ID_LEN      EQU 16

; Registration state byte (offset MAGB_CONFIG_OFF_REG_STATE): both
; documented values have bit 0 set -- bit 7 is what actually
; distinguishes them (gbdk/include/magb_config.h's comment, confirmed
; there against a real captured config.bin).
DEF MAGB_REG_STATE_COMPLETE EQU $81
DEF MAGB_REG_STATE_PENDING  EQU $01

; BCD phone nibble codes (Configuration Slot's first 8 bytes, two
; digits/symbols per byte, high nibble first) -- gbdk/include/
; magb_config.h.
DEF MAGB_CONFIG_PHONE_NIBBLE_HASH EQU $A
DEF MAGB_CONFIG_PHONE_NIBBLE_STAR EQU $B
DEF MAGB_CONFIG_PHONE_NIBBLE_END  EQU $F

DEF MAGB_NINTENDO_MAGIC_LEN EQU 8
DEF MAGB_MAX_PHONE_NUMBER_LEN EQU 12 ; matches gbdk/include/magb_network.h

; The special "connection id" used for a P2P/telephone session's
; Transfer Data calls (there's no real Open/Close handshake for P2P the
; way there is for TCP -- Dial/Wait For Call itself establishes the
; link) -- matches gbdk/include/magb_commands.h's MAGB_P2P_CONNECTION_ID.
DEF MAGB_P2P_CONNECTION_ID EQU $FF

; ---- Session-command timeouts (in VBlank-counted "frames") ------------
DEF MAGB_TIMEOUT_FRAMES_SHORT EQU 180 ; ~3s @ ~59.7Hz: session control commands
; Dial needs real connect()-timeout headroom, not a control-command
; budget -- matches gbdk/include/magb_session.h's MAGB_TIMEOUT_FRAMES_LONG
; (see that file's comment: a real Dial is a raw TCP connect() at the
; adapter/relay level, and OS-level connect timeouts commonly run past
; a few seconds on their own).
DEF MAGB_TIMEOUT_FRAMES_LONG EQU 900 ; ~15s @ ~59.7Hz
; A P2P Dial needs even more headroom than an ISP Dial -- matches
; gbdk/src/app/test_runner.c's MAGB_TIMEOUT_FRAMES_P2P_CALL exactly,
; there confirmed against a real two-machine BGB session and against
; libmobile's commands.c's command_tel_ip() (no internal
; cutoff of its own, just polls connect() until it succeeds or truly
; fails) as the right shape for a single long-timeout Dial request.
DEF MAGB_TIMEOUT_FRAMES_P2P_CALL EQU 1500 ; ~25s @ ~59.7Hz

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
; Not a wire-protocol error at all -- MATS (this TestSuite's own P2P
; payload framing, carried inside Transfer Data payloads, see main.asm)
; failed to parse, or the received test frame's content didn't match
; what was expected. Matches gbdk/include/magb_protocol.h's MAGB_ERR_P2P.
DEF MAGB_ERR_P2P                EQU 12
; The user pressed B to abort a long P2P wait (main.asm's P2pRecvFrame/
; RunP2pListener's Wait For Call retry loop) -- matches gbdk's
; MAGB_ERR_CANCELLED (there, gbdk's generic ctx->cancel_check() result
; for any long protocol-layer wait; here, checked directly in the
; app-layer P2P loops instead, since this port has no protocol-layer
; cancel hook -- see docs/integration-guide.md).
DEF MAGB_ERR_CANCELLED          EQU 13
; Not a wire-protocol error either -- an application-level HTTP/SMTP/
; POP3 response parsed fine at the transport level but didn't contain
; what the test needed (e.g. no "HTTP/" prefix, no WWW-Authenticate
; header on a 401, no SMTP/POP3 greeting). Matches gbdk's reuse of
; MAGB_ERR_ISP for exactly these cases (test_runner.c's gb00_fetch()/
; test_isp_email_send()/test_isp_email_recv()) -- the actual message
; shown to the user is a specific stage string set alongside this code,
; not a generic "ISP error", the same way gbdk's out->detail[] carries
; fail_stage rather than a fixed per-code string for it.
DEF MAGB_ERR_ISP                EQU 14
