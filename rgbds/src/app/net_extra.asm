; Line-based TCP protocol engine -- shared by Email Send (SMTP, port 25)
; and Email Recv (POP3, port 110) in main.asm. Neither SMTP nor POP3 is
; a Mobile Adapter command; both are just ordinary line-based text
; protocols run over a plain TCP connection opened the same way the
; HTTP tests open theirs (MagbTcpOpen/MagbTransferData/MagbTcpClose).
;
; Ported from gbdk/src/app/test_runner.c's tcp_send_line()/
; tcp_recv_line() -- the non-obvious part worth preserving here is why
; tcp_recv_line() carries a one-call "pending" byte buffer at all: a
; single TCP receive can carry more than one protocol line (a real
; BGB/libmobile-bgb capture showed an SMTP "250 OK\r\n" reply and a
; second, unrelated line arriving together in one Transfer Data
; response), so bytes past the first '\n' in any one receive must be
; kept for the *next* tcp_recv_line() call, not read again from the
; network or silently dropped. POP3's TOP-command header scanning in
; particular (main.asm's Email Recv) reads many lines in a row and
; would desync the moment any leftover byte went missing.
;
; The pending buffer is always refilled from the destination buffer
; that was just written into, not from wherever the bytes originally
; came from (pending-drain or a fresh network read) -- matches gbdk's
; tcp_recv_line() exactly: it always does
; `memcpy(s_line_pending, &buf[len+consumed], leftover)`, i.e. it
; re-derives "what's left over" by scanning what it just wrote to `buf`
; either way, rather than tracking the two sources separately. This
; port keeps that same simplification.
;
; Placed in ROMX BANK[1] alongside gb00_auth.asm -- see that file's own
; header comment for why (mapperless 32KB cart's fixed upper 16KB,
; otherwise unused by RGBDS's default ROM0 placement).

INCLUDE "protocol.inc"

DEF LINE_RECV_MAX_POLLS EQU 60 ; matches gbdk's LINE_RECV_MAX_POLLS
DEF LINE_PENDING_MAX EQU PROTO_MAX_RX_PAYLOAD_LEN ; worst case: one whole
                                                 ; Transfer Data response
                                                 ; (up to the real
                                                 ; adapter's actual
                                                 ; receive ceiling, not
                                                 ; the smaller send-only
                                                 ; PROTO_MAX_PAYLOAD_LEN
                                                 ; -- see that constant's
                                                 ; comment), all of it
                                                 ; past the '\n', or (as
                                                 ; of TcpSendLine below)
                                                 ; an entire reply that
                                                 ; came back bundled
                                                 ; with our own send

SECTION "Line Recv Scratch", WRAM0
wLinePendingBuf: ds LINE_PENDING_MAX
wLinePendingLen: db
wLinePendingPos: db
wLineRemoteClosed:: db ; output: 1 if the connection closed while waiting
wLineDestPtr: dw
wLineDestCap: db  ; caller's buf_cap, including room for the NUL
wLineLen: db      ; bytes written into the caller's buffer so far
wLinePoll: db
wLineCap: db      ; this iteration's remaining destination capacity
wLineGotLen: db   ; bytes obtained this iteration (pending-drain or network)
wLineWritePtr: dw ; this iteration's destination write position

SECTION "Line Recv Code", ROMX, BANK[1]

; Clears the pending-byte carryover -- call once right after every fresh
; MagbTcpOpen, so leftovers from a previous connection can never bleed
; into a new one (matches gbdk's tcp_line_reset()).
; Clobbers: A
TcpLineReset::
    xor a, a
    ld [wLinePendingLen], a
    ld [wLinePendingPos], a
    ret

; Sends a line (or any raw bytes) over wTcpConnId, and stashes whatever
; the adapter hands back *with that same send* into the pending buffer
; above -- instead of discarding it -- so the next TcpRecvLine() call
; picks it up naturally. A real, slow POP3/SMTP server never has a
; reply ready that fast, so this always came back empty against any of
; those -- but REON's device-auth interception synthesizes some
; replies (e.g. a faked local "+OK user accepted" for POP3 USER)
; instantly, with no real network round trip at all, and a real
; capture confirmed the adapter delivers that reply bundled with the
; ack for the USER send itself, not via a later poll. Discarding it
; here (the previous behavior: HL=0/B=0, a 0-capacity destination)
; threw that entire reply away with nowhere left to recover it from --
; every later TcpRecvLine() poll then legitimately got nothing back,
; hanging forever waiting for a "+OK" line that had already arrived
; and been dropped. Matches gbdk's identical tcp_send_line() fix for
; the same real-world bug.
;
; Input: HL = bytes to send, B = length
; Output: A = result (0=OK)
; Clobbers: everything
TcpSendLine::
    ld d, h
    ld e, l
    ld c, b
    ld hl, wLinePendingBuf
    ld b, LINE_PENDING_MAX
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    call MagbTransferData
    or a, a
    ret nz ; real transport error -- propagate, nothing to stash

    ld a, [wXferGotLen]
    or a, a
    ret z ; nothing came back bundled with this send -- the normal case
    ld [wLinePendingLen], a
    xor a, a
    ld [wLinePendingPos], a
    ret

; Accumulates response bytes into [DE] (always NUL-terminated) until a
; '\n' is seen, the connection closes, or LINE_RECV_MAX_POLLS is
; exhausted -- whichever comes first. Returns whatever was accumulated
; even on a timeout/close, so the caller can still inspect a partial
; line. Matches gbdk's tcp_recv_line() -- see this file's header
; comment for the pending-buffer rationale.
;
; Input: DE = dest buffer, B = dest capacity (including the NUL)
; Output: A = result (0=OK; a real transport error otherwise, at which
;         point the caller should treat this as fatal exactly like any
;         other MagbTransferData failure). On A=0: [DE..] is
;         NUL-terminated; wLineRemoteClosed = 1 if the peer closed the
;         connection while this call was waiting.
; Clobbers: everything
TcpRecvLine::
    ld a, d
    ld [wLineDestPtr + 1], a
    ld a, e
    ld [wLineDestPtr], a
    ld a, b
    ld [wLineDestCap], a
    xor a, a
    ld [wLineRemoteClosed], a
    ld [wLineLen], a
    ld [wLinePoll], a
    ld [de], a ; buf[0] = '\0' up front

.pollLoop
    ld a, [wLinePoll]
    cp a, LINE_RECV_MAX_POLLS
    jp nc, .done
    inc a
    ld [wLinePoll], a

    ; cap = destCap - 1 - len
    ld a, [wLineDestCap]
    sub a, 1
    ld b, a
    ld a, [wLineLen]
    ld c, a
    ld a, b
    sub a, c
    jr nc, .haveCap
    xor a, a
.haveCap
    or a, a
    jr nz, .capNonzero
    ; Dest buffer filled up without '\n' yet -- a real production mail
    ; server (Postfix) prepends its own `Received:` header, which
    ; routinely runs well past any of this ROM's small line buffers
    ; (confirmed by a hang report against mail.reon.zsrv.com.br: POP3
    ; TOP's header scan stalled right after such a header). Rewind to
    ; the top of the dest buffer and keep reading -- overwriting it --
    ; instead of stopping here, so the unread remainder of this same
    ; line never desyncs the next TcpRecvLine call onto the wrong byte
    ; offset for the rest of the scan; that's the failure mode
    ; reported (this loop never outright breaks, LINE_RECV_MAX_POLLS
    ; still bounds it, but line after line stops lining up with
    ; anything the caller expects). The dest buffer ends up holding
    ; only the last chunk once this happens, not the true line content
    ; -- fine, since every caller already treats a header it doesn't
    ; recognize as "skip, never guess" rather than matching it.
    ; Matches gbdk's identical tcp_recv_line() fix.
    xor a, a
    ld [wLineLen], a
    ld a, [wLineDestCap]
    dec a
.capNonzero
    ld [wLineCap], a

    ; write pointer for this iteration = destPtr + len
    ld a, [wLineDestPtr]
    ld l, a
    ld a, [wLineDestPtr + 1]
    ld h, a
    ld a, [wLineLen]
    ld e, a
    ld d, 0
    add hl, de
    ld a, l
    ld [wLineWritePtr], a
    ld a, h
    ld [wLineWritePtr + 1], a

    ld a, [wLinePendingPos]
    ld b, a
    ld a, [wLinePendingLen]
    cp a, b
    jr z, .doNetworkRead ; pos == len -- nothing pending right now

    ; drain pending: got_len = min(pendingLen - pendingPos, cap)
    sub a, b
    ld c, a
    ld a, [wLineCap]
    cp a, c
    jr nc, .pendingFits
    ld c, a
.pendingFits
    ld a, c
    ld [wLineGotLen], a

    or a, a
    jr z, .afterCopyPending
    ld a, [wLinePendingPos]
    ld l, a
    ld h, 0
    ld de, wLinePendingBuf
    add hl, de
    ld a, [wLineWritePtr]
    ld e, a
    ld a, [wLineWritePtr + 1]
    ld d, a
    ld b, c
.copyPending
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyPending
.afterCopyPending
    ld a, [wLinePendingPos]
    ld b, a
    ld a, [wLineGotLen]
    add a, b
    ld [wLinePendingPos], a
    jr .scanForNewline

.doNetworkRead
    ld a, [wLineWritePtr]
    ld l, a
    ld a, [wLineWritePtr + 1]
    ld h, a
    ld a, [wLineCap]
    ld b, a
    ld c, 0 ; zero-length send: a poll, not a new send
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    call MagbTransferData
    or a, a
    ret nz ; real transport error -- propagate

    ld a, [wXferRemoteClosed]
    or a, a
    jr z, .notClosed
    ld a, 1
    ld [wLineRemoteClosed], a
    jp .done
.notClosed
    ld a, [wXferGotLen]
    ld [wLineGotLen], a

.scanForNewline
    ld a, [wLineGotLen]
    or a, a
    jr z, .afterScan ; nothing new this round (an empty network poll)

    ld a, [wLineWritePtr]
    ld l, a
    ld a, [wLineWritePtr + 1]
    ld h, a
    ld a, [wLineGotLen]
    ld b, a
    ld c, 0
.scanLoop
    ld a, [hl+]
    cp a, $0A
    jr z, .foundNewline
    inc c
    dec b
    jr nz, .scanLoop
    jr .afterScan

.foundNewline
    inc c ; c = consumed (bytes of this batch belonging to the line, incl. '\n')
    xor a, a
    ld [wLinePendingLen], a
    ld [wLinePendingPos], a
    ld a, [wLineGotLen]
    sub a, c
    jr z, .haveConsumed ; no leftover -- pending already cleared above
    ld [wLinePendingLen], a
    ld b, a
    push bc
    ld a, [wLineWritePtr]
    ld l, a
    ld a, [wLineWritePtr + 1]
    ld h, a
    ld d, 0
    ld e, c
    add hl, de ; hl = wLineWritePtr + consumed -- start of the leftover
    ld de, wLinePendingBuf
    pop bc
.copyLeftover
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyLeftover
.haveConsumed
    ld a, [wLineLen]
    add a, c
    ld [wLineLen], a
    ld a, [wLineDestPtr]
    ld e, a
    ld a, [wLineDestPtr + 1]
    ld d, a
    ld a, [wLineLen]
    ld l, a
    ld h, 0
    add hl, de
    xor a, a
    ld [hl], a
    ret ; A = 0: line complete

.afterScan
    ld a, [wLineLen]
    ld c, a
    ld a, [wLineGotLen]
    add a, c
    ld [wLineLen], a
    ld a, [wLineDestPtr]
    ld e, a
    ld a, [wLineDestPtr + 1]
    ld d, a
    ld a, [wLineLen]
    ld l, a
    ld h, 0
    add hl, de
    xor a, a
    ld [hl], a

    ld a, [wLineGotLen]
    or a, a
    jp nz, .pollLoop
    call WaitVBlank ; nothing arrived this round -- don't spin the link
    jp .pollLoop

.done
    xor a, a
    ret

SECTION "Email Step Scratch", WRAM0
; Caller-set descriptor -- see EmailLineStep's own doc comment. A WRAM
; descriptor rather than registers because TcpSendLine's own "Clobbers:
; everything" would otherwise destroy the recv/expect parameters before
; EmailLineStep ever gets to use them.
wEmailStepSendPtr:: dw
wEmailStepSendLen:: db
wEmailStepRecvPtr:: dw
wEmailStepRecvCap:: db
wEmailStepExpectPtr:: dw
wEmailStepExpectLen:: db

SECTION "Email Step Code", ROMX, BANK[1]

; Sends one command line, reads one reply line, and reports whether it
; started with the expected prefix -- matches gbdk's line_step()
; (test_runner.c), used by both Email Send (SMTP) and Email Recv (POP3)
; for every USER/PASS/HELO/MAIL FROM/RCPT TO/DATA/STAT/TOP/DELE
; exchange.
;
; Input: wEmailStepSendPtr/Len, wEmailStepRecvPtr/Cap,
;        wEmailStepExpectPtr/Len -- all set by the caller first
; Output: A = 0 (OK, the reply matched) or a MAGB_ERR_* code -- a real
;         transport error propagated as-is, or MAGB_ERR_ISP if the
;         transport worked but the reply didn't start with the expected
;         prefix (e.g. a real SMTP/POP3 rejection). The received line
;         (NUL-terminated) is always left at wEmailStepRecvPtr, matched
;         or not.
; Clobbers: everything
EmailLineStep::
    ld a, [wEmailStepSendPtr]
    ld l, a
    ld a, [wEmailStepSendPtr + 1]
    ld h, a
    ld a, [wEmailStepSendLen]
    ld b, a
    call TcpSendLine
    or a, a
    ret nz

    ld a, [wEmailStepRecvPtr]
    ld e, a
    ld a, [wEmailStepRecvPtr + 1]
    ld d, a
    ld a, [wEmailStepRecvCap]
    ld b, a
    call TcpRecvLine
    or a, a
    ret nz

    ld a, [wEmailStepRecvPtr]
    ld l, a
    ld a, [wEmailStepRecvPtr + 1]
    ld h, a
    ld a, [wEmailStepExpectPtr]
    ld e, a
    ld a, [wEmailStepExpectPtr + 1]
    ld d, a
    ld a, [wEmailStepExpectLen]
    ld b, a
    call StrPrefixMatch
    or a, a
    jr nz, .matched
    ld a, MAGB_ERR_ISP
    ret
.matched
    xor a, a
    ret

; Checks whether [HL] starts with the B-byte prefix at [DE] -- used by
; main.asm's Email Send/Recv to test an SMTP/POP3 reply's leading
; status code ("250", "354", "220", "+OK", ...) without needing a
; NUL-terminated comparison. Matches gbdk's strncmp(line, expect,
; strlen(expect)) == 0 check inside line_step().
;
; Input: HL = buffer to check, DE = prefix bytes, B = prefix length
; Output: A = 1 on match, 0 otherwise
; Clobbers: everything
StrPrefixMatch::
.loop
    ld a, b
    or a, a
    jr z, .match
    ld a, [de]
    cp a, [hl]
    jr nz, .noMatch
    inc hl
    inc de
    dec b
    jr .loop
.match
    ld a, 1
    ret
.noMatch
    xor a, a
    ret
