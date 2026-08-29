; Mobile Adapter GB transport-level session handling.
;
; A faithful port of gbdk/src/protocol/magb_session.c -- same wire
; sequence, same retry/ACK/timeout logic, same function boundaries where
; practical. See that file's own top-of-file comment for the full
; request/response byte-sequence diagram (derived from libmobile/serial.c
; and cross-checked on real hardware/BGB); not repeated here verbatim.
;
; Register pressure on SM83 (only BC/DE/HL/AF, and SerialTransferByte
; itself clobbers HL) made a pure register-passing calling convention
; painful for functions with several parameters that must survive a
; retry loop -- MagbExecute's own inputs (command/payload
; pointer/length/timeout) are stashed into WRAM immediately on entry and
; re-loaded into registers only where a specific instruction needs them,
; rather than fought over across every call. This is a bigger RAM
; footprint than strictly necessary, not a bigger ROM one; correctness
; here matters far more than cleverness (this exact protocol logic has
; already needed several real hardware-driven fixes on the GBDK side --
; see gbdk/docs/journal.md).

INCLUDE "hardware.inc"
INCLUDE "protocol.inc"

SECTION "Session State", WRAM0

wSessionActive:: db
wAdapterDevice:: db
wLastCmdSent:: db
wLastCmdRecv:: db
wRemoteErrorCommand:: db
wRemoteErrorCode:: db

; Parsed response, filled by ReadResponseFrame and left in place by
; MagbExecute on success for the caller (MagbBeginSession etc.) to
; inspect.
wRxCommand:: db
wRxReserved:: db
wRxPayloadLen:: db
wRxPayload:: ds PROTO_MAX_PAYLOAD_LEN

; MagbExecute's own call-parameter block (see the file header comment
; for why) and small scratch flags used across calls that would
; otherwise fight over registers.
wExecCommand:: db
wExecPayloadPtr:: dw
wExecPayloadLen:: db
wExecTimeoutFrames:: dw
wRetry:: db          ; set by RequestAckPhase: 1 if the caller should resend the request
wChecksumOkFlag:: db ; input to ResponseAckPhase: 1 if the just-read response's checksum matched
wReadResult:: db     ; MagbExecute's scratch: ReadResponseFrame's result, survives the ResponseAckPhase call

; Optional live-status notification (see MagbSetStatusCallback below) --
; 0 means "no callback registered", the safe default a caller gets by
; just calling MagbProtocolInit and never touching this. This is what
; lets src/hw/ and src/protocol/ be copied into someone else's homebrew
; without also forcing them to define a UI function just to satisfy the
; linker (see docs/integration-guide.md) -- this TestSuite's own
; main.asm registers its SetStatus here instead of session.asm calling
; it directly.
wStatusCallback:: dw
wStatusArg: db ; NotifyStatus's own scratch, not meant for callers

SECTION "Session Code", ROM0

; ---- One-time protocol-layer init / optional status callback -------------
;
; Zeroes wStatusCallback (WRAM is not guaranteed zero at boot on real
; hardware -- same reasoning as SerialHwInit zeroing wSysTime). Callers
; that don't want live status notifications need only call this once
; and never call MagbSetStatusCallback at all.
;
; Output: none
; Clobbers: A
MagbProtocolInit::
    xor a, a
    ld [wStatusCallback], a
    ld [wStatusCallback + 1], a
    ret

; Registers a function to be notified of MagbExecute's request/ACK/wait/
; response progress -- this TestSuite's own main.asm registers its
; SetStatus here (see EntryPoint) to drive the row-2 status line;
; someone reusing just src/hw/+src/protocol/ can skip this call entirely
; (MagbProtocolInit's zeroed default means no callback ever fires).
;
; Input: HL = callback address (0 to disable). Contract the callback
;        must follow: Input A = 0 (about to wake the adapter/send a
;        request), 1 (request sent, awaiting ACK), 2 (ACK'd, awaiting
;        the response), 3 (response magic seen, reading the rest) --
;        see docs/integration-guide.md. Index 0 is never invoked by
;        this file itself, only by a caller before MagbBeginSession, so
;        it's fine to leave unhandled if you don't need it.
; Output: none
; Clobbers: A
MagbSetStatusCallback::
    ld a, l
    ld [wStatusCallback], a
    ld a, h
    ld [wStatusCallback + 1], a
    ret

; Internal replacement for a direct `call SetStatus`: calls through
; [wStatusCallback] with A forwarded unchanged, or does nothing if no
; callback is registered. SM83 has no indirect-call instruction, hence
; the CallHL trampoline below -- `call CallHL` pushes the return address
; (back into NotifyStatus's own `ret`) before `jp hl` hands control to
; the real callback, so the callback's own `ret` lands correctly back
; here regardless of what address it was.
;
; Input: A = status index to forward
; Clobbers: everything (whatever the registered callback clobbers)
NotifyStatus:
    ld [wStatusArg], a
    ld a, [wStatusCallback]
    ld l, a
    ld a, [wStatusCallback + 1]
    ld h, a
    ld a, l
    or a, h
    ret z ; no callback registered

    ld a, [wStatusArg]
    call CallHL
    ret

CallHL:
    jp hl

; ---- Small shared helper -------------------------------------------------

; If A (already masked to 7 bits, response bit cleared) is one of the
; documented adapter device IDs, records it. Mirrors
; MAGB_IS_KNOWN_ADAPTER_DEVICE in gbdk/include/magb_commands.h; never
; fatal on a value outside that range, matching magb_session.c's
; "validated best-effort, never fatally" comment on this exact check.
;
; Input: A = candidate device id
; Clobbers: none (flags only)
MaybeSetAdapterDevice:
    cp a, MAGB_DEVICE_ADAPTER_BLUE
    ret c
    cp a, MAGB_DEVICE_ADAPTER_RED + 1
    ret nc
    ld [wAdapterDevice], a
    ret

; ---- Request phase: send magic+header+payload+checksum ------------------
;
; Mirrors send_request_frame(): builds the frame via BuildRequestFrame
; (packet.asm) and clocks it out one byte at a time. Per libmobile's
; state machine, the adapter's ACK1 (device id | 0x80) is piggybacked on
; the very last transfer (the checksum-low byte) -- there is no separate
; transfer for it, so the last RX byte from this loop IS ack1.
;
; Input:  A = command, DE = payload pointer, C = payload length
; Output: A = result (0=OK); on success, [wAck1Out] left with the ACK1 byte
; Clobbers: everything
SendRequestFrame:
    call BuildRequestFrame ; HL=buffer, BC=length; carry set if payload too large
    jr c, .tooLarge

    ld d, h
    ld e, l ; DE = send pointer (HL itself will be clobbered by SerialTransferByte)
.loop
    push bc ; BC = remaining length, must survive the transfer call
    ld a, [de]
    inc de
    call SerialTransferByte
    pop bc
    jr c, .timeout
    ld [wAck1Out], a
    dec bc
    ld a, b
    or a, c
    jr nz, .loop

    xor a, a
    ret

.timeout
    ld a, MAGB_ERR_TIMEOUT
    ret
.tooLarge
    ld a, MAGB_ERR_PAYLOAD_TOO_LARGE
    ret

SECTION "Session Scratch", WRAM0
wAck1Out: db

SECTION "Session Code 2", ROM0

; ---- Request-ACK phase: device ack, command echo / transport error ------
;
; See magb_session.c's request_ack_phase() comment for the full
; rationale (real, observed relay latency meant only the three
; documented transport-error codes 0xF0/F1/F2 can be treated as fatal
; here -- everything else, including an unexpected-looking ACK2, must be
; tolerated and the fixed handshake bytes sent regardless). Ported
; behavior-for-behavior, not just structurally.
;
; Input: [wAck1Out] = the byte SendRequestFrame captured
; Output: A = result (0=OK); [wRetry] = 1 if the caller should resend
;         the whole request (only for the three transport-error codes)
; Clobbers: everything
RequestAckPhase:
    xor a, a
    ld [wRetry], a

    ld a, [wAck1Out]
    and a, DEVICE_ID_MASK
    call MaybeSetAdapterDevice

    ld a, MAGB_GBC_DEVICE_ACK
    call SerialTransferByte
    jr c, .timeout

    cp a, MAGB_ACK_ERR_UNSUPPORTED
    jr z, .transportError
    cp a, MAGB_ACK_ERR_CHECKSUM
    jr z, .checksumError
    cp a, MAGB_ACK_ERR_INTERNAL
    jr z, .internalError

    ; Not one of the three documented transport errors: proceed. This
    ; may be the real ACK2, or (per the relay-latency finding) a
    ; one-transfer-delayed ACK1 -- catch a device id here too either way.
    and a, DEVICE_ID_MASK
    call MaybeSetAdapterDevice

    ld a, MAGB_GBC_WAIT ; filler
    call SerialTransferByte
    jr c, .timeout
    ld a, MAGB_GBC_WAIT ; mandatory "go ahead and process"
    call SerialTransferByte
    jr c, .timeout

    xor a, a
    ret

.transportError
    ld a, 1
    ld [wRetry], a
    ld a, MAGB_ERR_REMOTE_UNSUPPORTED
    ret
.checksumError
    ld a, 1
    ld [wRetry], a
    ld a, MAGB_ERR_REMOTE_CHECKSUM
    ret
.internalError
    ld a, 1
    ld [wRetry], a
    ld a, MAGB_ERR_REMOTE_INTERNAL
    ret
.timeout
    ld a, MAGB_ERR_TIMEOUT
    ret

; ---- Wait for the adapter to finish processing and start replying -------
;
; Input: DE = timeout budget, in VBlank-counted frames
; Output: A = result (0=OK -- the response's first magic byte was
;         consumed and matched; the caller must not re-read it)
; Clobbers: everything
WaitForResponseStart:
    ld a, e
    ld [wWaitBudget], a
    ld a, d
    ld [wWaitBudget + 1], a
    call SerialNow
    ld a, e
    ld [wWaitStart], a
    ld a, d
    ld [wWaitStart + 1], a

.loop
    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    jr c, .timeout

    cp a, MAGB_ADAPTER_WAIT
    jr nz, .notWaiting

    ld a, [wWaitStart]
    ld c, a
    ld a, [wWaitStart + 1]
    ld b, a
    call SerialElapsedFrames ; DE = elapsed frames since wWaitStart

    ld a, [wWaitBudget]
    ld c, a
    ld a, [wWaitBudget + 1]
    ld b, a
    ; Is elapsed (DE) > budget (BC)? Strict, matching the C ">" exactly.
    ld a, e
    sub a, c
    ld l, a ; stash the low byte of (elapsed - budget); HL is free here
    ld a, d
    sbc a, b
    jr c, .loop ; borrow: elapsed < budget, keep waiting
    or a, l ; Z iff both bytes of (elapsed - budget) are zero, i.e. elapsed == budget
    jr z, .loop ; equal is not yet "greater than": keep waiting
    ld a, MAGB_ERR_TIMEOUT
    ret

.notWaiting
    cp a, MAGB_MAGIC_1
    jr nz, .badMagic
    xor a, a
    ret

.badMagic
    ld a, MAGB_ERR_BAD_MAGIC
    ret
.timeout
    ld a, MAGB_ERR_TIMEOUT
    ret

SECTION "Session Scratch 2", WRAM0
wWaitStart: dw
wWaitBudget: dw

SECTION "Session Code 3", ROM0

; ---- Receive magic(2nd)+header+payload+checksum --------------------------
;
; Called right after WaitForResponseStart has already consumed and
; matched the first magic byte. Fills wRxCommand/wRxReserved/
; wRxPayloadLen/wRxPayload as bytes arrive.
;
; Output: A = result:
;           MAGB_OK              -- framing AND checksum both fine
;           MAGB_ERR_BAD_CHECKSUM -- framing fine, checksum mismatched
;                                    (the caller may still ACK/NACK and
;                                    retry -- this is not fatal by itself)
;           anything else         -- framing broke down (bad magic/
;                                    length, or a hardware timeout);
;                                    fatal, the caller must not retry
; Clobbers: everything
; Many of this function's jumps to the shared .timeout/.badMagic/
; .badLength labels below are further than a `jr`'s +-127 byte reach
; from the earlier transfer sites -- `jp` throughout instead (verified
; needed by the assembler/linker, not applied speculatively everywhere
; else in this file).
ReadResponseFrame:
    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    jp c, .timeout
    cp a, MAGB_MAGIC_2
    jp nz, .badMagic

    ld de, 0 ; running checksum accumulator

    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    jp c, .timeout
    ld [wRxCommand], a
    call ChecksumAddByte

    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    jp c, .timeout
    ld [wRxReserved], a
    call ChecksumAddByte

    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    jp c, .timeout
    push af
    call ChecksumAddByte
    pop af
    or a, a
    jp nz, .badLength ; length_hi must be 0: this ROM never expects a >254 byte payload

    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    jp c, .timeout
    push af
    call ChecksumAddByte
    pop af
    cp a, PROTO_MAX_PAYLOAD_LEN + 1
    jp nc, .badLength ; also catches a genuinely oversized payload this build can't buffer
    ld [wRxPayloadLen], a

    ld b, a
    or a, a
    jr z, .payloadDone
    ld hl, wRxPayload
.payloadLoop
    push hl ; SerialTransferByte clobbers HL; DE is already committed to the checksum
    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    pop hl
    jp c, .timeout
    ld [hl+], a
    call ChecksumAddByte
    dec b
    jr nz, .payloadLoop

.payloadDone
    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    jp c, .timeout
    ld [wChecksumRecvHi], a

    ld a, MAGB_GBC_WAIT
    call SerialTransferByte
    jp c, .timeout
    ld c, a ; C = checksum_lo
    ld a, [wChecksumRecvHi]
    ld b, a ; BC = received checksum

    ld a, e
    cp a, c
    jr nz, .checksumMismatch
    ld a, d
    cp a, b
    jr nz, .checksumMismatch

    xor a, a
    ret

.checksumMismatch
    ld a, MAGB_ERR_BAD_CHECKSUM
    ret
.badMagic
    ld a, MAGB_ERR_BAD_MAGIC
    ret
.badLength
    ld a, MAGB_ERR_BAD_LENGTH
    ret
.timeout
    ld a, MAGB_ERR_TIMEOUT
    ret

SECTION "Session Scratch 3", WRAM0
wChecksumRecvHi: db

SECTION "Session Code 4", ROM0

; ---- Response-ACK phase: GBC acknowledges (or NACKs) the response -------
;
; Input:  A = 1 if the just-read response's checksum matched, else 0
; Output: A = result (0=OK, MAGB_ERR_BAD_CHECKSUM, or MAGB_ERR_TIMEOUT)
; Clobbers: everything
ResponseAckPhase:
    ld [wChecksumOkFlag], a

    ld a, MAGB_GBC_WAIT ; adapter device id, opportunistic
    call SerialTransferByte
    jr c, .timeout
    and a, DEVICE_ID_MASK
    call MaybeSetAdapterDevice

    ld a, MAGB_GBC_WAIT ; always 0x00 from the adapter, don't-care
    call SerialTransferByte
    jr c, .timeout

    ld a, [wChecksumOkFlag]
    or a, a
    ld a, 0
    jr nz, .sendAck
    ld a, MAGB_ACK_ERR_CHECKSUM
.sendAck
    call SerialTransferByte
    jr c, .timeout

    ld a, [wChecksumOkFlag]
    or a, a
    jr z, .badChecksum
    xor a, a
    ret

.badChecksum
    ld a, MAGB_ERR_BAD_CHECKSUM
    ret
.timeout
    ld a, MAGB_ERR_TIMEOUT
    ret

; ---- The full request/ACK/wait/response/ACK cycle for one command -------
;
; Input:  A = command, DE = payload pointer, C = payload length
;         [wExecTimeoutFrames] = response-wait budget, in VBlank frames
;         (set by the caller beforehand -- see MagbBeginSession/
;         MagbEndSession for the pattern)
; Output: A = result (0=OK). On OK, wRxCommand/wRxPayloadLen/wRxPayload
;         hold the response, and [wLastCmdRecv] is updated. A remote
;         Error Status response (see gbdk/include/magb_commands.h's
;         MAGB_CMD_ERROR_STATUS comment) is recognized here, centrally,
;         exactly like magb_execute() does -- not per-caller.
; Clobbers: everything
MagbExecute::
    ld [wExecCommand], a
    ld a, e
    ld [wExecPayloadPtr], a
    ld a, d
    ld [wExecPayloadPtr + 1], a
    ld a, c
    ld [wExecPayloadLen], a
    ld a, [wExecCommand]
    ld [wLastCmdSent], a

    ld b, 0 ; attempt counter for the send/request-ACK retry loop
.sendLoop
    push bc
    ld a, [wExecPayloadPtr]
    ld e, a
    ld a, [wExecPayloadPtr + 1]
    ld d, a
    ld a, [wExecPayloadLen]
    ld c, a
    ld a, [wExecCommand]
    call SendRequestFrame
    pop bc
    or a, a
    ret nz ; SendRequestFrame's own errors are always fatal, never retried

    call RequestAckPhase
    or a, a
    jr z, .ackOk

    ld [wReadResult], a ; reuse as generic "pending error" scratch here
    ld a, [wRetry]
    or a, a
    jr z, .returnPending
    inc b
    ld a, b
    cp a, MAGB_MAX_RETRANSMIT
    jr c, .sendLoop
.returnPending
    ld a, [wReadResult]
    ret

.ackOk
    push bc
    ld a, 2 ; STATUS_WAIT (see MagbSetStatusCallback) -- request+ACK done, waiting for response
    call NotifyStatus
    pop bc

    ld a, [wExecTimeoutFrames]
    ld e, a
    ld a, [wExecTimeoutFrames + 1]
    ld d, a
    call WaitForResponseStart
    or a, a
    ret nz

    push bc
    ld a, 3 ; STATUS_READ (see MagbSetStatusCallback) -- response magic seen, reading the rest
    call NotifyStatus
    pop bc

    ld b, 0 ; attempt counter for the response-read/ACK retry loop
.readLoop
    push bc
    call ReadResponseFrame
    ld [wReadResult], a
    pop bc

    or a, a
    jr z, .csOk
    cp a, MAGB_ERR_BAD_CHECKSUM
    ret nz ; a genuine framing desync: fatal, matches magb_execute()'s "give up immediately"
    xor a, a
    jr .doAck
.csOk
    ld a, 1
.doAck
    call ResponseAckPhase
    cp a, MAGB_ERR_TIMEOUT
    jr z, .ackTimeout

    ld a, [wReadResult]
    or a, a
    jr z, .responseGood
    inc b
    ld a, b
    cp a, MAGB_MAX_RETRANSMIT
    jr c, .readLoop
    ld a, MAGB_ERR_BAD_CHECKSUM
    ret

.ackTimeout
    ld a, MAGB_ERR_TIMEOUT
    ret

.responseGood
    ld a, [wRxCommand]
    ld [wLastCmdRecv], a
    cp a, MAGB_CMD_ERROR_STATUS | MAGB_RESPONSE_BIT
    jr nz, .notErrorStatus

    ld a, [wRxPayloadLen]
    cp a, 2
    jr c, .skipRemoteFields
    ld a, [wRxPayload]
    ld [wRemoteErrorCommand], a
    ld a, [wRxPayload + 1]
    ld [wRemoteErrorCode], a
.skipRemoteFields
    ld a, MAGB_ERR_REMOTE_STATUS
    ret

.notErrorStatus
    xor a, a
    ret

; ---- Adapter wake-up ------------------------------------------------------
;
; A sacrificial transfer (response discarded either way) followed by a
; short wait, matching magb_wake_adapter()/CLAUDE.md's "Adapter Wake-Up"
; section (~7 VBlanks =~ 100ms @ ~59.7Hz).
;
; Output: A = result (0=OK)
; Clobbers: everything
MagbWakeAdapter::
    xor a, a
    call SerialTransferByte
    jr c, .timeout

    ld b, 7
.wait
    halt
    nop
    dec b
    jr nz, .wait

    xor a, a
    ret
.timeout
    ld a, MAGB_ERR_TIMEOUT
    ret

; ---- Begin Session (0x10) -------------------------------------------------
;
; Output: A = result (0=OK); [wSessionActive] = 1 on success
; Clobbers: everything
MagbBeginSession::
    xor a, a
    ld [wSessionActive], a

    call MagbWakeAdapter
    or a, a
    ret nz

    ld a, 1 ; STATUS_SEND (see MagbSetStatusCallback) -- wake succeeded, about to send the request
    call NotifyStatus

    ld a, MAGB_TIMEOUT_FRAMES_SHORT & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT >> 8
    ld [wExecTimeoutFrames + 1], a

    ld a, MAGB_CMD_BEGIN_SESSION
    ld de, sNintendo
    ld c, MAGB_NINTENDO_MAGIC_LEN
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_BEGIN_SESSION | MAGB_RESPONSE_BIT
    jr nz, .unexpected

    ld a, [wRxPayloadLen]
    cp a, MAGB_NINTENDO_MAGIC_LEN
    jr nz, .badLength

    ld hl, wRxPayload
    ld de, sNintendo
    ld b, MAGB_NINTENDO_MAGIC_LEN
.compareLoop
    ld a, [de]
    cp a, [hl]
    jr nz, .sessionMismatch
    inc hl
    inc de
    dec b
    jr nz, .compareLoop

    ld a, 1
    ld [wSessionActive], a
    xor a, a
    ret

.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret
.badLength
    ld a, MAGB_ERR_BAD_LENGTH
    ret
.sessionMismatch
    ld a, MAGB_ERR_SESSION
    ret

sNintendo:
    db "NINTENDO"

; ---- End Session (0x11) ---------------------------------------------------
;
; Output: A = result (0=OK); [wSessionActive] is always cleared,
;         regardless of outcome, matching magb_end_session()
; Clobbers: everything
MagbEndSession::
    ld a, MAGB_TIMEOUT_FRAMES_SHORT & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT >> 8
    ld [wExecTimeoutFrames + 1], a

    ld a, MAGB_CMD_END_SESSION
    ld de, 0
    ld c, 0
    call MagbExecute
    ld [wReadResult], a ; reuse as scratch to survive the state-clear below

    xor a, a
    ld [wSessionActive], a

    ld a, [wReadResult]
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_END_SESSION | MAGB_RESPONSE_BIT
    jr nz, .unexpected
    xor a, a
    ret
.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret

; ---- Dial Telephone (0x12) ------------------------------------------------
;
; Builds the request payload [validation_byte, ...digits] and sends it.
; The validation byte is per-adapter-type (libmobile/commands.c
; command_tel_begin(): Blue requires exactly 0x00, everything else this
; ROM might be talking to accepts 0x01) -- ctx->adapter_device was
; already captured by whichever earlier MagbExecute call saw a real
; device id (Begin Session, always run first).
;
; Input:  HL = phone number ASCII digits (ROM, NOT null-terminated --
;         length given explicitly), B = digit count (1..MAGB_MAX_PHONE_NUMBER_LEN)
; Output: A = result (0=OK)
; Clobbers: everything
MagbDial::
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a

    push bc ; preserve the digit count across the validation-byte lookup
    ld a, [wAdapterDevice]
    cp a, MAGB_DEVICE_ADAPTER_BLUE
    ld a, 1
    jr nz, .notBlue
    xor a, a
.notBlue
    ld [wDialPayload], a

    ld de, wDialPayload + 1
.copyLoop
    ld a, b
    or a, a
    jr z, .copyDone
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr .copyLoop
.copyDone
    pop bc ; bc = the original digit count again

    ld a, b
    inc a ; payload length = digit count + 1 (validation byte)
    ld c, a
    ld de, wDialPayload
    ld a, MAGB_CMD_DIAL
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_DIAL | MAGB_RESPONSE_BIT
    jr nz, .unexpected
    xor a, a
    ret
.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret

SECTION "Dial Scratch", WRAM0
; validation_byte + up to MAGB_MAX_PHONE_NUMBER_LEN digits.
wDialPayload: ds 1 + MAGB_MAX_PHONE_NUMBER_LEN

SECTION "Session Code 5", ROM0

; ---- Hang Up Telephone (0x13) ----------------------------------------------
;
; Output: A = result (0=OK)
; Clobbers: everything
MagbHangup::
    ld a, MAGB_TIMEOUT_FRAMES_SHORT & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT >> 8
    ld [wExecTimeoutFrames + 1], a

    ld a, MAGB_CMD_HANGUP
    ld de, 0
    ld c, 0
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_HANGUP | MAGB_RESPONSE_BIT
    jr nz, .unexpected
    xor a, a
    ret
.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret

; ---- ISP Login (0x21) ------------------------------------------------------
;
; Unlike MagbDial, the caller builds the whole payload (login_len +
; login + password_len + password + dns1[4] + dns2[4], matching
; gbdk/src/protocol/magb_network.c's magb_isp_login() layout exactly)
; and just hands it over -- there's no adapter-specific prefix byte to
; compute here the way Dial's validation byte needs one, so a thin
; wrapper is enough. libmobile's PPP login handler doesn't check
; login/password against any real account system, it only echoes back
; an assigned IP + DNS servers (see gbdk's test_config.h) -- so any
; short test credentials work here at the Mobile-Adapter-protocol
; level regardless of what a real ISP account needs.
;
; Input:  DE = payload pointer (ROM), C = payload length
; Output: A = result (0=OK); on success wIspAssignedIp[0:4]/[4:8]/[8:12]
;         hold the assigned IP / DNS1 / DNS2
; Clobbers: everything
MagbIspLogin::
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a

    ld a, MAGB_CMD_ISP_LOGIN
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_ISP_LOGIN | MAGB_RESPONSE_BIT
    jr nz, .unexpected

    ld a, [wRxPayloadLen]
    cp a, 12
    jr nz, .badLength

    ld hl, wRxPayload
    ld de, wIspAssignedIp
    ld b, 12
.copyLoop
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyLoop

    xor a, a
    ret
.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret
.badLength
    ld a, MAGB_ERR_BAD_LENGTH
    ret

SECTION "ISP Scratch", WRAM0
; [0:4] assigned IP, [4:8] DNS1, [8:12] DNS2 -- gbdk's magb_isp_login_result_t.
wIspAssignedIp: ds 12

SECTION "Session Code 6", ROM0

; ---- ISP Logout (0x22) ------------------------------------------------------
;
; Output: A = result (0=OK)
; Clobbers: everything
MagbIspLogout::
    ld a, MAGB_TIMEOUT_FRAMES_SHORT & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT >> 8
    ld [wExecTimeoutFrames + 1], a

    ld a, MAGB_CMD_ISP_LOGOUT
    ld de, 0
    ld c, 0
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_ISP_LOGOUT | MAGB_RESPONSE_BIT
    jr nz, .unexpected
    xor a, a
    ret
.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret

; ---- DNS Query (0x28) -------------------------------------------------------
;
; The hostname is the raw payload, no length-prefix or terminator --
; its size comes entirely from the MAGB header's own length field
; (gbdk/src/protocol/magb_network.c's magb_dns_query() comment, citing
; libmobile/commands.c command_dns_request_begin()).
;
; Input:  HL = hostname ASCII pointer (ROM, NOT null-terminated), B = hostname length
; Output: A = result (0=OK); on success wDnsResultIp[0:4] holds the resolved IPv4
; Clobbers: everything
MagbDnsQuery::
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a

    ld d, h
    ld e, l ; de = hostname pointer (MagbExecute's payload-pointer input)
    ld c, b ; c = hostname length (MagbExecute's payload-length input)
    ld a, MAGB_CMD_DNS
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_DNS | MAGB_RESPONSE_BIT
    jr nz, .unexpected

    ld a, [wRxPayloadLen]
    cp a, 4
    jr nz, .badLength

    ld hl, wRxPayload
    ld de, wDnsResultIp
    ld b, 4
.copyLoop
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyLoop

    xor a, a
    ret
.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret
.badLength
    ld a, MAGB_ERR_BAD_LENGTH
    ret

SECTION "DNS Scratch", WRAM0
wDnsResultIp:: ds 4

SECTION "Session Code 7", ROM0

; ---- TCP Open Connection (0x23) --------------------------------------------
;
; Input:  HL = pointer to a 4-byte IPv4 address (e.g. wDnsResultIp),
;         BC = port, B = high byte / C = low byte (network/big-endian
;         order, matching how the payload is transmitted)
; Output: A = result (0=OK); on success wTcpConnId holds the connection id
; Clobbers: everything
MagbTcpOpen::
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a

    push bc ; preserve the port across the IP-copy loop
    ld de, wTcpOpenPayload
    ld b, 4
.copyIp
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyIp
    pop bc ; bc = the port again

    ld a, b
    ld [de], a
    inc de
    ld a, c
    ld [de], a

    ld de, wTcpOpenPayload
    ld c, 6
    ld a, MAGB_CMD_TCP_OPEN
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_TCP_OPEN | MAGB_RESPONSE_BIT
    jr nz, .unexpected

    ld a, [wRxPayloadLen]
    cp a, 1
    jr nz, .badLength

    ld a, [wRxPayload]
    ld [wTcpConnId], a
    xor a, a
    ret
.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret
.badLength
    ld a, MAGB_ERR_BAD_LENGTH
    ret

SECTION "TCP Scratch", WRAM0
wTcpOpenPayload: ds 6 ; ip[4] + port_hi + port_lo
wTcpConnId: ds 1

SECTION "Session Code 8", ROM0

; ---- TCP Close Connection (0x24) -------------------------------------------
;
; Closes the connection opened by the most recent MagbTcpOpen (reads
; wTcpConnId directly -- this test flow only ever has one connection
; open at a time, so there's no need to take a connection id parameter
; yet).
;
; Output: A = result (0=OK)
; Clobbers: everything
MagbTcpClose::
    ld a, MAGB_TIMEOUT_FRAMES_SHORT & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT >> 8
    ld [wExecTimeoutFrames + 1], a

    ld de, wTcpConnId
    ld c, 1
    ld a, MAGB_CMD_TCP_CLOSE
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_TCP_CLOSE | MAGB_RESPONSE_BIT
    jr nz, .unexpected
    xor a, a
    ret
.unexpected
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret

SECTION "Transfer Scratch", WRAM0
; conn_id + data, built fresh by every MagbTransferData call. Sized for
; the protocol's true 254-byte payload ceiling (see protocol.inc).
wXferPayload: ds 1 + PROTO_MAX_PAYLOAD_LEN
wXferOutPtr: dw
wXferOutCap: db
wXferGotLen:: db
wXferRemoteClosed:: db

SECTION "Session Code 9", ROM0

; ---- Transfer Data (0x15) -------------------------------------------------
;
; Sends up to (PROTO_MAX_PAYLOAD_LEN - 1) bytes over the connection opened
; by MagbTcpOpen (reads wTcpConnId directly, same one-connection-at-a-time
; simplification as MagbTcpClose), and copies whatever the adapter sends
; back -- which is not necessarily an echo of what was just sent, see
; gbdk/src/protocol/magb_network.c's magb_transfer_data() -- into the
; caller's output buffer, clamped to the capacity given. A zero-length
; send (C=0) is how a caller polls for more incoming data without sending
; anything new, matching test_isp_http()'s receive loop.
;
; Input:  DE = data pointer (ignored if C == 0), C = data length
;         (0..PROTO_MAX_PAYLOAD_LEN-1)
;         HL = output buffer pointer, B = output buffer capacity
; Output: A = result (0=OK). On OK: [wXferGotLen] = bytes actually copied
;         into the output buffer (may be less than what the adapter sent,
;         the caller re-polls for the rest), [wXferRemoteClosed] = 1 if
;         the response was Transfer Data End (0x1F|0x80), meaning the
;         remote TCP peer closed the connection.
; Clobbers: everything
MagbTransferData::
    ld a, c
    cp a, PROTO_MAX_PAYLOAD_LEN ; conn_id(1) + data_len must fit
    jr nc, .tooLarge

    ld a, b
    ld [wXferOutCap], a
    ld a, l
    ld [wXferOutPtr], a
    ld a, h
    ld [wXferOutPtr + 1], a

    push bc ; c = data len, must survive the payload-build copy
    push de

    ld hl, wXferPayload
    ld a, [wTcpConnId]
    ld [hl+], a

    pop de
    pop bc
    ld a, c
    or a, a
    jr z, .noData
    ld b, a
.copyData
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .copyData
.noData

    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a

    ld a, c ; c still holds data_len (the copy loop only touched b)
    inc a ; +1 for the conn_id byte
    ld c, a
    ld de, wXferPayload
    ld a, MAGB_CMD_TRANSFER
    call MagbExecute
    or a, a
    ret nz

    ld a, [wRxCommand]
    cp a, MAGB_CMD_TRANSFER_DATA_END | MAGB_RESPONSE_BIT
    jr nz, .checkTransfer
    ld a, 1
    ld [wXferRemoteClosed], a
    jr .gotResponseKind
.checkTransfer
    cp a, MAGB_CMD_TRANSFER | MAGB_RESPONSE_BIT
    jr nz, .unexpectedXfer
    xor a, a
    ld [wXferRemoteClosed], a
.gotResponseKind

    ld a, [wRxPayloadLen]
    or a, a
    jr z, .badLengthXfer ; must include at least the conn_id echo byte

    dec a ; n = payload_len - 1 (bytes received, after the conn_id echo)
    ld c, a

    ld a, [wXferOutCap]
    cp a, c
    jr nc, .capOk ; cap >= n: copy every received byte
    ld c, a ; clamp: copy only cap bytes, drop the rest (caller re-polls)
.capOk
    ld a, c
    ld [wXferGotLen], a

    or a, a
    jr z, .doneXferCopy

    ld hl, wRxPayload + 1 ; skip the conn_id echo byte
    ld a, [wXferOutPtr]
    ld e, a
    ld a, [wXferOutPtr + 1]
    ld d, a
    ld b, c
.copyOut
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyOut

.doneXferCopy
    xor a, a
    ret

.unexpectedXfer
    ld a, MAGB_ERR_UNEXPECTED_COMMAND
    ret
.badLengthXfer
    ld a, MAGB_ERR_BAD_LENGTH
    ret
.tooLarge
    ld a, MAGB_ERR_PAYLOAD_TOO_LARGE
    ret
