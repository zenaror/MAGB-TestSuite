; ---- "BIG BUFFER" stress test: GB00-authenticated download/upload of a
; body far larger than any buffer this ROM could hold at once -----------
;
; Port of gbdk's test_isp_big_buffer() (src/app/test_runner.c) and the
; gb00_stream_*() engine it sits on. The whole point of this test is a
; body (BB_SIZE, 8192 bytes) an order of magnitude larger than
; GB00_RESP_BUF_SIZE, so nothing here ever holds the body: the download
; leg runs every byte through a running 16-bit additive checksum (the
; same algorithm the Mobile Adapter's own packet checksum uses, see
; gbdk/docs/protocol-notes.md) and compares the total against the
; response's own X-Test-Checksum header; the upload leg regenerates the
; identical deterministic pattern one chunk at a time and lets the
; server report pass/fail in the first byte of its response body.
;
; Wire contract agreed with the REON side (not invented here):
;   GET  /cgb/download?name=/01/MAGBTEST/0.bigbuffer.cgb
;   POST /cgb/upload?name=/01/MAGBTEST/0.bigbuffer.cgb
;   body[i] == i & 0xFF, for i in 0..BB_SIZE-1
;   X-Test-Checksum: 4 zero-padded ASCII hex digits, 16-bit additive
;                    sum over the body only (no headers)
;   upload response body[0]: 0x01 = accepted, anything else = rejected
; Both paths sit under REON's MAGBTEST fixture rather than a real
; title's game code -- this is a synthetic test endpoint and is
; deliberately not dressed up as one of Nintendo's CGB-XXXX paths.
;
; This file holds the engine, the request blobs and the buffers; the
; session/dial/login/DNS orchestration around it lives in main.asm's
; RunBigBufferTest, next to the other tests and the helpers it shares
; with them.

INCLUDE "hardware.inc"
INCLUDE "protocol.inc"
INCLUDE "gb00.inc"

; PROTO_MAX_PAYLOAD_LEN(254) minus the leading connection-id byte every
; Transfer Data payload carries -- the real ceiling on one send.
DEF BB_UPLOAD_CHUNK EQU PROTO_MAX_PAYLOAD_LEN - 1

DEF BB_SIZE EQU 8192

; Caps the body-streaming poll loop -- BB_SIZE bytes at up to 254 bytes
; per poll needs ~33 polls; this leaves generous margin for real-world
; chunks smaller than the protocol maximum. Every poll still carries its
; own MAGB_TIMEOUT_FRAMES_LONG bound, so this is a finite ceiling on the
; whole operation rather than an unbounded wait (repo-root CLAUDE.md's
; "Timeouts": never create indefinite loops waiting for hardware).
DEF BB_MAX_BODY_POLLS EQU 128

; Largest request this file builds is the upload leg's authenticated
; POST header at 261 bytes (61 request line + 32 Host + 121
; Authorization + 22 Content-Length + 23 X-Test-Checksum + 2 blank
; line). That is NOT under BB_UPLOAD_CHUNK, which is exactly why
; BbSendAll exists -- gbdk hit this as a real bug first, truncating the
; length to (uint8_t)261 == 5 and sending the literal "POST ".
DEF BB_REQ_BUF_SIZE EQU 288

DEF BB_BODY_START_NONE EQU $FFFF
DEF BB_AUTH_ID_MAX EQU 48

; The small half of the pair. Fits one Transfer Data payload, which is
; the regime BIG BUFFER never reaches. Expected checksum is
; 127*128/2 = 8128 = $1FC0.
DEF BB_SMALL_SIZE EQU 128

; ---- Buffers ----------------------------------------------------------
;
; WRAM0 is down to ~123 free bytes, so everything here goes in WRAM bank
; 1 at $D000 instead. Nothing else in this ROM touches WRAMX or writes
; rSVBK (verified across src/), and both SVBK=0 and SVBK=1 select bank 1
; on CGB, so this region is mapped from power-on with no setup and no
; bank juggling. If a second WRAMX user ever appears, that assumption
; has to be revisited here first.
SECTION "Big Buffer Buffers", WRAMX, BANK[1]

wBbReqBuf: ds BB_REQ_BUF_SIZE
wBbReqLen: dw

; The upload body is regenerated into here one chunk at a time -- the
; pattern is never stored in ROM or held in full anywhere.
wBbChunk: ds BB_UPLOAD_CHUNK

SECTION "Big Buffer State", WRAMX, BANK[1]

wBbHeadLen:         dw ; status+headers accumulated in wGb00RespBuf
wBbBodyLen:         dw ; body bytes streamed so far (never all held)
wBbFirstBodyByte:   db
wBbChecksum:        dw ; running 16-bit additive sum over the body
wBbExpected:        dw ; value parsed from X-Test-Checksum
wBbChecksumPresent: db
wBbRemoteClosed:    db
wBbEmptyPolls:      db
wBbPollCount:       dw
wBbBodyStart:       dw
wBbDlChecksum:      dw ; download's verified checksum, resent on upload
wBbDlBodyLen:       dw
wBbSent:            dw

; Failure message shown by main.asm on a non-zero return.
wBbFailMsgPtr:: dw

; Two screen lines main.asm prints verbatim, mirroring gbdk's
; out->detail[0]/detail[1].
wBbDetail0:: ds 21
wBbDetail1:: ds 21

; REON's session id is bin2hex(random_bytes(16)) = 32 characters today.
; Sized past that because nothing documents it as fixed; BbFindAuthId
; refuses rather than truncates if it ever outgrows this.
wBbAuthId: ds BB_AUTH_ID_MAX + 1

SECTION "Big Buffer Code", ROMX, BANK[1]

; ---- small shared helpers ---------------------------------------------

; Appends B bytes from [DE] to the write cursor in HL, advancing both.
; Input: HL = write cursor, DE = source, B = length
; Output: HL/DE advanced past the copied bytes
; Clobbers: A, B, DE, HL
BbAppend:
    ld a, b
    or a, a
    ret z
.loop
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .loop
    ret

; Appends the NUL-terminated string at [DE] (terminator not copied).
; Input: HL = write cursor, DE = source
; Output: HL advanced past the copied bytes
; Clobbers: A, DE, HL
BbAppendStr:
    ld a, [de]
    or a, a
    ret z
    ld [hl+], a
    inc de
    jr BbAppendStr

; Waits MAGB_PACING_RECV_FRAMES VBlanks between receive polls, matching
; what the real Mobile Trainer does rather than pulling as fast as the
; link allows -- see protocol.inc for the measurements. Same halt/nop
; frame wait MagbWakeAdapter uses; only VBlank is unmasked, so each halt
; is one frame. A zero setting means no wait at all.
; Clobbers: A, B
BbPace:
IF MAGB_PACING_RECV_FRAMES > 0
    ld b, MAGB_PACING_RECV_FRAMES
.wait
    halt
    nop
    dec b
    jr nz, .wait
ENDC
    ret

sBbHexDigits: db "0123456789ABCDEF"

; Writes A as two uppercase hex digits at [HL], advancing HL.
; Input: A = byte, HL = write cursor
; Clobbers: A, DE, HL
BbAppendHexByte:
    push af
    swap a
    and a, $0F
    call .digit
    pop af
    and a, $0F
    ; fall through
.digit
    push bc
    ld c, a
    ld b, 0
    push hl
    ld hl, sBbHexDigits
    add hl, bc
    ld a, [hl]
    pop hl
    ld [hl+], a
    pop bc
    ret

; Writes BC as four uppercase hex digits at [HL], advancing HL. Used for
; both the X-Test-Checksum value sent on upload and the mismatch detail
; line -- the wire format is 4 zero-padded digits, so this never trims
; leading zeroes.
; Input: BC = value, HL = write cursor
; Clobbers: A, DE, HL
BbAppendHex16:
    ld a, b
    call BbAppendHexByte
    ld a, c
    jp BbAppendHexByte

; ---- HTTP header scanning ---------------------------------------------

; Finds the blank line ($0D$0A$0D$0A) that ends an HTTP header block in
; wGb00RespBuf, searching the first [wBbHeadLen] bytes. Matches gbdk's
; gb00_find_body_start().
; Output: wBbBodyStart = offset of the first body byte, or
;         BB_BODY_START_NONE if the separator is not present yet
; Clobbers: everything
BbFindBodyStart:
    ld a, BB_BODY_START_NONE & $FF
    ld [wBbBodyStart], a
    ld a, BB_BODY_START_NONE >> 8
    ld [wBbBodyStart + 1], a

    ; Nothing to do unless at least 4 bytes are present.
    ld a, [wBbHeadLen + 1]
    or a, a
    jr nz, .haveEnough
    ld a, [wBbHeadLen]
    cp a, 4
    ret c
.haveEnough

    ; DE = scan index, BC = head_len - 4 (last index worth testing)
    ld a, [wBbHeadLen]
    ld c, a
    ld a, [wBbHeadLen + 1]
    ld b, a
    ld a, c
    sub a, 4
    ld c, a
    ld a, b
    sbc a, 0
    ld b, a

    ld de, 0
.scan
    ld hl, wGb00RespBuf
    add hl, de
    ld a, [hl+]
    cp a, $0D
    jr nz, .next
    ld a, [hl+]
    cp a, $0A
    jr nz, .next
    ld a, [hl+]
    cp a, $0D
    jr nz, .next
    ld a, [hl]
    cp a, $0A
    jr nz, .next
    ; Found -- body starts 4 bytes past the match.
    ld hl, 4
    add hl, de
    ld a, l
    ld [wBbBodyStart], a
    ld a, h
    ld [wBbBodyStart + 1], a
    ret
.next
    inc de
    ; continue while de <= bc
    ld a, c
    cp a, e
    ld a, b
    sbc a, d
    jr nc, .scan
    ret

sBbChecksumHdr: db "X-Test-Checksum:", 0
DEF BB_CHECKSUM_HDR_LEN EQU 16

; Searches the first [wBbHeadLen] bytes of wGb00RespBuf for
; "X-Test-Checksum:" and parses the 4 hex digits after it (leading
; spaces skipped, upper- and lowercase both accepted) into wBbExpected.
; Matches gbdk's gb00_find_hex_header(). Never guesses a value: a
; missing header, or one not followed by exactly 4 valid hex digits,
; leaves wBbChecksumPresent clear.
; Output: wBbChecksumPresent = 1 and wBbExpected set, or 0
; Clobbers: everything
BbFindChecksumHeader:
    xor a, a
    ld [wBbChecksumPresent], a

    ; Need at least the needle plus one byte after it.
    ld a, [wBbHeadLen + 1]
    or a, a
    jr nz, .sizeOk
    ld a, [wBbHeadLen]
    cp a, BB_CHECKSUM_HDR_LEN + 1
    ret c
.sizeOk

    ; BC = head_len - needle_len (exclusive upper bound on the index)
    ld a, [wBbHeadLen]
    ld c, a
    ld a, [wBbHeadLen + 1]
    ld b, a
    ld a, c
    sub a, BB_CHECKSUM_HDR_LEN
    ld c, a
    ld a, b
    sbc a, 0
    ld b, a

    ld de, 0
.scan
    push bc
    push de
    ld hl, wGb00RespBuf
    add hl, de
    ld de, sBbChecksumHdr
    ld b, BB_CHECKSUM_HDR_LEN
.cmp
    ld a, [de]
    cp a, [hl]
    jr nz, .cmpFail
    inc hl
    inc de
    dec b
    jr nz, .cmp
    ; Matched. HL already points just past the needle.
    pop de
    pop bc
    jr .parseValue
.cmpFail
    pop de
    pop bc
    inc de
    ld a, c
    cp a, e
    ld a, b
    sbc a, d
    jr nc, .scan
    ret ; not found -- wBbChecksumPresent stays 0

; HL = first byte after the needle. Skip spaces, then require exactly
; four hex digits. Guarded against running past the accumulated data:
; DE counts bytes remaining in wGb00RespBuf from HL onward.
.parseValue
    ld a, [wBbHeadLen]
    ld e, a
    ld a, [wBbHeadLen + 1]
    ld d, a
    push hl
    ld bc, wGb00RespBuf
    ld a, l
    sub a, c
    ld c, a
    ld a, h
    sbc a, b
    ld b, a       ; BC = offset of HL within the buffer
    ld a, e
    sub a, c
    ld e, a
    ld a, d
    sbc a, b
    ld d, a       ; DE = bytes remaining from HL
    pop hl

.skipSpaces
    ld a, d
    or a, e
    ret z ; ran out of data before a digit -- not present
    ld a, [hl]
    cp a, " "
    jr nz, .digits
    inc hl
    dec de
    jr .skipSpaces

.digits
    ; BC accumulates the value; DE stays the bytes-remaining guard, so
    ; the digit counter needs its own byte rather than a register.
    ld bc, 0
    ld a, 4
    ld [wBbHexDigitsLeft], a
.digitLoop
    ld a, d
    or a, e
    ret z ; ran out mid-value -- reject rather than guess
    ld a, [hl+]
    dec de
    ; classify: '0'-'9', 'A'-'F', 'a'-'f'
    cp a, "0"
    ret c
    cp a, "9" + 1
    jr c, .isDigit
    cp a, "A"
    ret c
    cp a, "F" + 1
    jr c, .isUpper
    cp a, "a"
    ret c
    cp a, "f" + 1
    ret nc
    sub a, "a" - 10
    jr .haveNibble
.isUpper
    sub a, "A" - 10
    jr .haveNibble
.isDigit
    sub a, "0"
.haveNibble
    ; value = (value << 4) | nibble
    push af
    sla c
    rl b
    sla c
    rl b
    sla c
    rl b
    sla c
    rl b
    pop af
    or a, c
    ld c, a

    ld a, [wBbHexDigitsLeft]
    dec a
    ld [wBbHexDigitsLeft], a
    jr nz, .digitLoop

    ld a, c
    ld [wBbExpected], a
    ld a, b
    ld [wBbExpected + 1], a
    ld a, 1
    ld [wBbChecksumPresent], a
    ret

sBbAuthIdHdr:  db "Gb-Auth-ID:"
sBbAuthIdHdrEnd:
sBbTestUserHdr: db "X-Test-User:"
sBbTestUserHdrEnd:

; Caller-set inputs for BbFindHeaderToken (WRAM rather than registers:
; SM83 runs out of pairs fast, and the rest of this file already passes
; descriptors this way).
SECTION "Big Buffer Token Scratch", WRAMX, BANK[1]
wBbTokenNeedlePtr: dw
wBbTokenNeedleLen: db
wBbTokenDestPtr:   dw

SECTION "Big Buffer Token Code", ROMX, BANK[1]

; Convenience wrappers, so call sites read as intent rather than as
; four stores.
; Clobbers: everything
BbFindAuthId:
    ld hl, sBbAuthIdHdr
    ld b, sBbAuthIdHdrEnd - sBbAuthIdHdr
    ld de, wBbAuthId
    jr BbFindHeaderToken

BbFindTestUser:
    ld hl, sBbTestUserHdr
    ld b, sBbTestUserHdrEnd - sBbTestUserHdr
    ld de, wBbAuthId
    ; fall through

; Copies the value of the "Gb-Auth-ID:" header out of the first
; [wBbHeadLen] bytes of wGb00RespBuf into wBbAuthId, NUL-terminated:
; leading spaces skipped, stopping at CR or LF. Same shape as gbdk's
; gb00_find_header_token().
; Output: A = 1 on success, 0 if the header is absent, empty, or longer
;         than BB_AUTH_ID_MAX (refused rather than truncated -- a
;         half-copied session id would fail in a far more confusing way)
; Clobbers: everything
BbFindHeaderToken:
    ld a, l
    ld [wBbTokenNeedlePtr], a
    ld a, h
    ld [wBbTokenNeedlePtr + 1], a
    ld a, b
    ld [wBbTokenNeedleLen], a
    ld a, e
    ld [wBbTokenDestPtr], a
    ld a, d
    ld [wBbTokenDestPtr + 1], a

    ; Empty destination up front: every failure path below returns with
    ; the caller seeing an empty string, never a partial one.
    ld h, d
    ld l, e
    xor a, a
    ld [hl], a

    ld a, [wBbHeadLen + 1]
    or a, a
    jr nz, .sizeOk
    ld a, [wBbHeadLen]
    ld hl, wBbTokenNeedleLen
    inc a
    cp a, [hl]
    jr c, .tooShort
    jr .sizeOk
.tooShort
    ret c
.sizeOk
    ld a, [wBbHeadLen]
    ld c, a
    ld a, [wBbHeadLen + 1]
    ld b, a
    ld a, c
    push af
    ld a, [wBbTokenNeedleLen]
    ld l, a
    pop af
    sub a, l
    ld c, a
    ld a, b
    sbc a, 0
    ld b, a

    ld de, 0
.scan
    push bc
    push de
    ld hl, wGb00RespBuf
    add hl, de
    ld a, [wBbTokenNeedlePtr]
    ld e, a
    ld a, [wBbTokenNeedlePtr + 1]
    ld d, a
    ld a, [wBbTokenNeedleLen]
    ld b, a
.cmp
    ld a, [de]
    cp a, [hl]
    jr nz, .cmpFail
    inc hl
    inc de
    dec b
    jr nz, .cmp
    pop de
    pop bc
    jr .copyValue
.cmpFail
    pop de
    pop bc
    inc de
    ld a, c
    cp a, e
    ld a, b
    sbc a, d
    jr nc, .scan
    xor a, a
    ret

; HL = first byte after the header name. DE = bytes remaining from HL.
.copyValue
    ld a, [wBbHeadLen]
    ld e, a
    ld a, [wBbHeadLen + 1]
    ld d, a
    push hl
    ld bc, wGb00RespBuf
    ld a, l
    sub a, c
    ld c, a
    ld a, h
    sbc a, b
    ld b, a
    ld a, e
    sub a, c
    ld e, a
    ld a, d
    sbc a, b
    ld d, a
    pop hl

.skipSpaces
    ld a, d
    or a, e
    jr z, .empty
    ld a, [hl]
    cp a, " "
    jr nz, .copyLoop
    inc hl
    dec de
    jr .skipSpaces

.copyLoop
    ld a, [wBbTokenDestPtr]
    ld c, a
    ld a, [wBbTokenDestPtr + 1]
    ld b, a
.copyNext
    ld a, d
    or a, e
    jr z, .done
    ld a, [hl]
    cp a, $0D
    jr z, .done
    cp a, $0A
    jr z, .done
    ; refuse an over-long value rather than truncating it
    push hl
    ld a, [wBbTokenDestPtr]
    ld l, a
    ld a, [wBbTokenDestPtr + 1]
    ld h, a
    ld a, l
    add a, BB_AUTH_ID_MAX
    ld l, a
    ld a, h
    adc a, 0
    ld h, a
    ld a, c
    cp a, l
    ld a, b
    sbc a, h
    pop hl
    jr nc, .tooLong
    ld a, [hl+]
    push hl
    ld h, b
    ld l, c
    ld [hl+], a
    ld b, h
    ld c, l
    pop hl
    dec de
    jr .copyNext

.done
    ld h, b
    ld l, c
    xor a, a
    ld [hl], a
    ld a, [wBbTokenDestPtr]
    ld l, a
    ld a, [wBbTokenDestPtr + 1]
    ld h, a
    ld a, [hl]
    or a, a
    ret z ; empty value
    ld a, 1
    ret

.empty
.tooLong
    ld a, [wBbTokenDestPtr]
    ld l, a
    ld a, [wBbTokenDestPtr + 1]
    ld h, a
    xor a, a
    ld [hl], a
    ret

SECTION "Big Buffer Hex Scratch", WRAMX, BANK[1]
wBbHexDigitsLeft: db

SECTION "Big Buffer Code 2", ROMX, BANK[1]

; ---- sending ----------------------------------------------------------

; Sends C bytes from [DE] over [wTcpConnId], discarding whatever comes
; back. Safe to discard here specifically because HTTP/1.0 servers do
; not reply mid-request (unlike POP3's line-at-a-time exchange, whose
; response-bundling bug this project already hit once in
; net_extra.asm's TcpSendLine): REON's PHP waits for the full
; Content-Length body before responding, so nothing meaningful can
; arrive bundled with one of these intermediate sends.
; Input: DE = data, C = length (0..BB_UPLOAD_CHUNK)
; Output: A = result (0=OK)
; Clobbers: everything
; Resets the bundled-response accumulator. Call before each request
; whose body goes out through BbSendRaw/BbSendAll.
; Clobbers: A
BbSendBegin::
    xor a, a
    ld [wBbPendingLen], a
    ld [wBbPendingLen + 1], a
    ld [wBbPendingClosed], a
    ret

; This used to pass a zero-capacity output buffer, on the reasoning that
; an HTTP/1.0 server does not reply mid-request. True of the reply's
; TIMING, but not of its FRAMING: one Transfer Data both sends and
; receives, so when the server answers quickly enough -- a 128-byte body
; to a server on the same machine -- its whole response arrives bundled
; with the very send that completed the request, and dropping it loses
; the response. The poll that follows then finds only Transfer Data End.
;
; The GBDK ROM failed exactly that way on the SMALL BUFFER upload. This
; side passed, but only because its response happened to land in a later
; poll -- the bug was here too, waiting on timing. Keep what arrives.
BbSendRaw:
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a

    ; hl = wGb00RespBuf + pending, b = min(GB00_RESP_BUF_SIZE - pending, 255)
    push bc
    ld a, [wBbPendingLen]
    ld e, a
    ld a, [wBbPendingLen + 1]
    ld d, a
    ld hl, GB00_RESP_BUF_SIZE
    ld a, l
    sub a, e
    ld l, a
    ld a, h
    sbc a, d
    ld h, a
    jr c, .noRoom
    ld a, h
    or a, a
    jr z, .roomFits
    ld a, 255
    jr .haveCap
.roomFits
    ld a, l
    jr .haveCap
.noRoom
    xor a, a
.haveCap
    pop bc
    ld b, a
    push bc
    ld hl, wGb00RespBuf
    add hl, de
    pop bc

    call MagbTransferData
    or a, a
    ret nz

    ; pending += got; remember a close
    ld a, [wXferGotLen]
    ld e, a
    ld d, 0
    ld hl, wBbPendingLen
    ld a, [hl]
    add a, e
    ld [hl+], a
    ld a, [hl]
    adc a, d
    ld [hl], a
    ld a, [wXferRemoteClosed]
    or a, a
    jr z, .notClosed
    ld a, 1
    ld [wBbPendingClosed], a
.notClosed
    xor a, a
    ret

; BbSendRaw for anything that can exceed one Transfer Data payload,
; splitting it across as many sends as it takes. See BB_REQ_BUF_SIZE's
; comment for why this is not hypothetical headroom.
; Input: HL = data, BC = length (16-bit)
; Output: A = result (0=OK)
; Clobbers: everything
BbSendAll:
    ld a, b
    or a, c
    jr nz, .haveWork
    xor a, a
    ret
.haveWork
    ; chunk = min(remaining, BB_UPLOAD_CHUNK)
    ld a, b
    or a, a
    jr nz, .useMax
    ld a, c
    cp a, BB_UPLOAD_CHUNK + 1
    jr c, .haveChunk
.useMax
    ld a, BB_UPLOAD_CHUNK
.haveChunk
    push bc
    push hl
    ld e, l
    ld d, h
    ld c, a
    ld a, c
    ld [wBbChunkLen], a
    call BbSendRaw
    pop hl
    pop bc
    or a, a
    ret nz

    ld a, [wBbChunkLen]
    ld e, a
    ld d, 0
    add hl, de       ; advance source
    ld a, c
    sub a, e
    ld c, a
    ld a, b
    sbc a, 0
    ld b, a          ; remaining -= chunk
    jr BbSendAll

SECTION "Big Buffer Send Scratch", WRAMX, BANK[1]
wBbChunkLen: db
; Bytes the server sent back while we were still sending, accumulated
; in wGb00RespBuf. See BbSendRaw.
wBbPendingLen: dw
wBbPendingClosed: db

SECTION "Big Buffer Code 3", ROMX, BANK[1]

; ---- the streaming engine ---------------------------------------------

; Shared engine behind BbStreamRequest/BbStreamRecv. Assumes
; [wBbHeadLen] bytes are ALREADY sitting in wGb00RespBuf (from whatever
; got the connection to this point) and [wBbRemoteClosed] reflects the
; connection state as of that same read.
;
; Keeps polling (reusing wGb00RespBuf as pure scratch, one chunk at a
; time) until the header/body separator turns up, parses the status code
; and the optional X-Test-Checksum header, then streams every remaining
; body byte through the running additive checksum instead of ever
; buffering the body in full.
;
; Output: A = result (0=OK); wGb00FetchStatusText holds the 3-digit
;         status; wBbBodyLen/wBbChecksum/wBbFirstBodyByte describe the
;         streamed body. wBbFailMsgPtr set on failure.
; Clobbers: everything
BbStreamContinue:
    xor a, a
    ld [wBbBodyLen], a
    ld [wBbBodyLen + 1], a
    ld [wBbFirstBodyByte], a
    ld [wBbChecksum], a
    ld [wBbChecksum + 1], a
    ld [wBbChecksumPresent], a
    ld [wBbEmptyPolls], a

    call BbFindBodyStart

.headerLoop
    ; while body_start == NONE && !remote_closed && head_len <
    ;       GB00_RESP_BUF_SIZE && empty_polls < GB00_MAX_EMPTY_POLLS
    ld a, [wBbBodyStart + 1]
    cp a, BB_BODY_START_NONE >> 8
    jp nz, .headerDone
    ld a, [wBbBodyStart]
    cp a, BB_BODY_START_NONE & $FF
    jp nz, .headerDone

    ld a, [wBbRemoteClosed]
    or a, a
    jp nz, .headerDone

    ld a, [wBbEmptyPolls]
    cp a, GB00_MAX_EMPTY_POLLS
    jp nc, .headerDone

    ; cap = min(GB00_RESP_BUF_SIZE - head_len, 255); 0 -> buffer full
    ld a, [wBbHeadLen]
    ld e, a
    ld a, [wBbHeadLen + 1]
    ld d, a
    ld hl, GB00_RESP_BUF_SIZE
    ld a, l
    sub a, e
    ld l, a
    ld a, h
    sbc a, d
    ld h, a
    jp c, .headerDone ; already past the buffer -- stop rather than wrap
    ld a, h
    or a, a
    jr z, .capFits
    ld a, 255
    jr .haveCap
.capFits
    ld a, l
    or a, a
    jp z, .headerDone ; buffer full
.haveCap
    ld b, a

    ld hl, wGb00RespBuf
    ld a, [wBbHeadLen]
    ld e, a
    ld a, [wBbHeadLen + 1]
    ld d, a
    add hl, de

    ld c, 0 ; zero-length send: a poll, not a new send
    push bc
    push hl
    call BbPace
    pop hl
    pop bc
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    call MagbTransferData
    or a, a
    jp nz, .recvFail

    ld a, [wXferRemoteClosed]
    ld [wBbRemoteClosed], a

    ld a, [wXferGotLen]
    or a, a
    jr nz, .gotHeaderBytes
    ld a, [wBbRemoteClosed]
    or a, a
    jr nz, .headerCounted
    ld a, [wBbEmptyPolls]
    inc a
    ld [wBbEmptyPolls], a
    jr .headerCounted
.gotHeaderBytes
    xor a, a
    ld [wBbEmptyPolls], a
.headerCounted

    ld a, [wXferGotLen]
    ld e, a
    ld d, 0
    ld hl, wBbHeadLen
    ld a, [hl]
    add a, e
    ld [hl+], a
    ld a, [hl]
    adc a, d
    ld [hl], a

    call BbFindBodyStart
    jp .headerLoop

.headerDone
    ; Gb00StatusCode and Gb00FindChallenge (gb00_auth.asm) both read
    ; wGb00RespLen, which THIS engine does not maintain -- it tracks the
    ; accumulated header length in wBbHeadLen instead, because the body
    ; deliberately never lands in wGb00RespBuf. Publish it here, once,
    ; before either of them runs; without this they see a stale length
    ; from whatever fetch ran last and reject a perfectly good response.
    ld a, [wBbHeadLen]
    ld [wGb00RespLen], a
    ld a, [wBbHeadLen + 1]
    ld [wGb00RespLen + 1], a

    call Gb00StatusCode
    or a, a
    jr nz, .haveStatus
    ld hl, sBbNoHttpPrefix
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret
.haveStatus

    ; No separator found at all: a headers-only reply (or a truncated
    ; one). Nothing to stream -- the caller decides whether the status
    ; alone is acceptable (a 401 challenge legitimately lands here).
    ld a, [wBbBodyStart + 1]
    cp a, BB_BODY_START_NONE >> 8
    jr nz, .haveBody
    ld a, [wBbBodyStart]
    cp a, BB_BODY_START_NONE & $FF
    jr nz, .haveBody
    xor a, a
    ret

.haveBody
    call BbFindChecksumHeader

    ; Fold the body bytes already sitting in the buffer
    ; (wBbBodyStart .. wBbHeadLen) into the checksum.
    ld a, [wBbBodyStart]
    ld e, a
    ld a, [wBbBodyStart + 1]
    ld d, a
    ; while DE < head_len. Computed as a full 16-bit head_len - DE:
    ; `sbc` only sets Z from the high byte, so an 8-bit Z test here
    ; would wrongly stop (or run on) whenever the two halves disagree.
.foldLoop
    ld a, [wBbHeadLen]
    sub a, e
    ld l, a
    ld a, [wBbHeadLen + 1]
    sbc a, d
    ld h, a
    jr c, .foldDone  ; DE past head_len
    ld a, h
    or a, l
    jr z, .foldDone  ; DE == head_len
    ld hl, wGb00RespBuf
    add hl, de
    ld a, [hl]
    call BbAccumulateByte
    inc de
    jr .foldLoop
.foldDone

    ; Stream the rest of the body, one Transfer Data chunk at a time.
    xor a, a
    ld [wBbEmptyPolls], a
    ld [wBbPollCount], a
    ld [wBbPollCount + 1], a

.bodyLoop
    ld a, [wBbRemoteClosed]
    or a, a
    jr nz, .bodyDone

    ld a, [wBbPollCount + 1]
    or a, a
    jr nz, .bodyDone ; >= 256 polls, well past BB_MAX_BODY_POLLS
    ld a, [wBbPollCount]
    cp a, BB_MAX_BODY_POLLS
    jr nc, .bodyDone

    ld a, [wBbEmptyPolls]
    cp a, GB00_MAX_EMPTY_POLLS
    jr nc, .bodyDone

    call BbPace
    ld hl, wGb00RespBuf
    ld b, BB_UPLOAD_CHUNK + 1 ; 254: the receive ceiling, not the send one
    ld c, 0
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    call MagbTransferData
    or a, a
    jr nz, .recvFail

    ld a, [wXferRemoteClosed]
    ld [wBbRemoteClosed], a

    ld a, [wBbPollCount]
    inc a
    ld [wBbPollCount], a
    jr nz, .pollCounted
    ld a, [wBbPollCount + 1]
    inc a
    ld [wBbPollCount + 1], a
.pollCounted

    ld a, [wXferGotLen]
    or a, a
    jr nz, .bodyGot
    ld a, [wBbRemoteClosed]
    or a, a
    jr nz, .bodyLoop
    ld a, [wBbEmptyPolls]
    inc a
    ld [wBbEmptyPolls], a
    jr .bodyLoop
.bodyGot
    xor a, a
    ld [wBbEmptyPolls], a

    ld a, [wXferGotLen]
    ld b, a
    ld hl, wGb00RespBuf
.bodyFold
    ld a, [hl+]
    push hl
    push bc
    call BbAccumulateByte
    pop bc
    pop hl
    dec b
    jr nz, .bodyFold
    jr .bodyLoop

.bodyDone
    xor a, a
    ret

.recvFail
    push af
    ld hl, sBbRecvFail
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
    ret

; Folds one body byte into the running checksum and body length, and
; records the very first body byte (the upload leg's pass/fail signal).
; Input: A = byte
; Clobbers: A, HL (BC/DE preserved)
BbAccumulateByte:
    push bc
    ld c, a

    ld a, [wBbBodyLen]
    ld b, a
    ld a, [wBbBodyLen + 1]
    or a, b
    jr nz, .notFirst
    ld a, c
    ld [wBbFirstBodyByte], a
.notFirst

    ld hl, wBbChecksum
    ld a, [hl]
    add a, c
    ld [hl+], a
    ld a, [hl]
    adc a, 0
    ld [hl], a

    ld hl, wBbBodyLen
    ld a, [hl]
    inc a
    ld [hl+], a
    jr nz, .noCarry
    ld a, [hl]
    inc a
    ld [hl], a
.noCarry
    pop bc
    ret

; Sends a complete request (line + headers, no body) and streams the
; response exactly like BbStreamContinue documents.
;
; The length is 16-bit and chunked rather than a single byte: the
; requests built here run 96-261 bytes, and a longer host or path would
; silently wrap a byte length instead of failing. Everything but the
; final chunk goes out send-only; the last send carries the receive, so
; the first slice of the response still lands in wGb00RespBuf.
;
; Reusing wGb00RespBuf as both the request source and the response
; destination would be safe (MagbTransferData copies the send data into
; wXferPayload before any receive), but this file deliberately keeps the
; request in its own wBbReqBuf instead -- that ordering is an internal
; detail of the transfer routine, not part of its documented contract.
;
; Input: HL = request bytes, BC = request length
; Output: A = result (0=OK)
; Clobbers: everything
BbStreamRequest::
    push hl
    push bc
    call BbSendBegin
    pop bc
    pop hl
    xor a, a
    ld [wBbRemoteClosed], a
    ld [wBbHeadLen], a
    ld [wBbHeadLen + 1], a

    ; If the request exceeds one payload, send all but the last
    ; BB_UPLOAD_CHUNK bytes first.
    ld a, b
    or a, a
    jr nz, .needsSplit
    ld a, c
    cp a, BB_UPLOAD_CHUNK + 1
    jr c, .singleSend
.needsSplit
    push bc
    push hl
    ld a, c
    sub a, BB_UPLOAD_CHUNK
    ld c, a
    ld a, b
    sbc a, 0
    ld b, a          ; BC = head_sent
    push bc
    call BbSendAll
    pop de           ; DE = head_sent
    pop hl
    pop bc
    or a, a
    jp nz, .sendFail
    add hl, de       ; advance past what was already sent
    ld c, BB_UPLOAD_CHUNK
    ld b, 0
.singleSend
    ld e, l
    ld d, h
    ; C already holds the (<= BB_UPLOAD_CHUNK) length.
    ;
    ; Receive AFTER whatever BbSendAll already accumulated -- it shares
    ; wGb00RespBuf with us now (see BbSendRaw), so receiving at offset 0
    ; would overwrite a reply that arrived during the earlier chunks.
    push de
    push bc
    ld a, [wBbPendingLen]
    ld e, a
    ld a, [wBbPendingLen + 1]
    ld d, a
    ld hl, GB00_RESP_BUF_SIZE
    ld a, l
    sub a, e
    ld l, a
    ld a, h
    sbc a, d
    ld h, a
    jr c, .noRoom
    ld a, h
    or a, a
    jr z, .roomFits
    ld a, 255
    jr .haveCap
.roomFits
    ld a, l
    jr .haveCap
.noRoom
    xor a, a
.haveCap
    ld c, a          ; cap
    ld hl, wGb00RespBuf
    add hl, de       ; receive cursor
    ld a, c
    pop bc
    ld b, a          ; B = cap, C = send length (restored)
    pop de

    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    call MagbTransferData
    or a, a
    jr nz, .sendFail

    ; head_len = pending + got
    ld a, [wXferGotLen]
    ld e, a
    ld d, 0
    ld a, [wBbPendingLen]
    add a, e
    ld [wBbHeadLen], a
    ld a, [wBbPendingLen + 1]
    adc a, d
    ld [wBbHeadLen + 1], a

    ld a, [wXferRemoteClosed]
    ld [wBbRemoteClosed], a
    ld a, [wBbPendingClosed]
    or a, a
    jr z, .notPreClosed
    ld a, 1
    ld [wBbRemoteClosed], a
.notPreClosed
    jp BbStreamContinue

.sendFail
    push af
    ld hl, sBbSendFail
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
    ret

; Like BbStreamRequest, but for when the request was already sent in
; full by the caller (the upload leg's header + 8192-byte body, across
; many BbSendAll/BbSendRaw calls) and all that is left is to poll for
; and stream the response.
; Output: A = result (0=OK)
; Clobbers: everything
; Starts from whatever arrived bundled with the sends -- see
; BbSendRaw. Zeroing here would throw the response away again.
BbStreamRecv::
    ld a, [wBbPendingLen]
    ld [wBbHeadLen], a
    ld a, [wBbPendingLen + 1]
    ld [wBbHeadLen + 1], a
    ld a, [wBbPendingClosed]
    ld [wBbRemoteClosed], a
    jp BbStreamContinue

sBbNoHttpPrefix: db "NO HTTP/ PREFIX", 0
sBbSendFail:     db "HTTP SEND FAIL", 0
sBbRecvFail:     db "HTTP RECV FAIL", 0

SECTION "Big Buffer Requests", ROMX, BANK[1]

; ---- request blobs ----------------------------------------------------
;
; Same convention as main.asm's News Config/Article strings: whole
; compile-time request bodies rather than a runtime formatter, since
; this project has no sprintf (repo-root CLAUDE.md's "no packed structs,
; explicit serialization"). Host matches sDnsHostname in main.asm.

; No "Connection: close" on either GET: gbdk's GB00 path
; (gb00_http_get(), and test_isp_big_buffer()'s own sprintf) omits it,
; and these two ROMs are meant to put identical bytes on the wire so a
; capture from either one is comparable against the other. HTTP/1.0
; closes by default anyway, which is why gbdk never needed it here.
; (The older News Config/Article blobs in main.asm do send it and so
; diverge from gbdk -- pre-existing, left alone rather than changed as
; a drive-by edit to working protocol code.)
sBbDlNoAuthReq:
    db "GET /cgb/download?name=/01/MAGBTEST/0.bigbuffer.cgb HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db $0D, $0A
sBbDlNoAuthReqEnd:

sBbDlAuthPrefix:
    db "GET /cgb/download?name=/01/MAGBTEST/0.bigbuffer.cgb HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Authorization: GB00 name=", $22
sBbDlAuthPrefixEnd:

; Closing quote for the Authorization value, then the blank line that
; ends the header block. Deliberately NOT gb00_auth.asm's
; sGb00AuthSuffix, which also carries "Connection: close" -- see the
; note on sBbDlNoAuthReq above.
sBbAuthSuffix:
    db $22, $0D, $0A
    db $0D, $0A
sBbAuthSuffixEnd:

; The upload probe deliberately sends Content-Length: 0 rather than no
; body header at all: it exists purely to draw the 401 challenge, and a
; POST with no declared length invites the server to wait for one.
sBbUpProbeReq:
    db "POST /cgb/upload?name=/01/MAGBTEST/0.bigbuffer.cgb HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Content-Length: 0", $0D, $0A
    db $0D, $0A
sBbUpProbeReqEnd:

sBbUpAuthPrefix:
    db "POST /cgb/upload?name=/01/MAGBTEST/0.bigbuffer.cgb HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Authorization: GB00 name=", $22
sBbUpAuthPrefixEnd:

; Closes the Authorization value for upload request 2, which carries NO
; body on purpose: REON's upload.php runs doAuth() (type 0), and that
; branch answers a valid Authorization with 200 + a Gb-Auth-ID header
; and exit()s -- it never reaches the upload handler, so any body sent
; here is discarded. See BbRunTransfer's upload comment.
sBbUpAuthCl0:
    db $22, $0D, $0A
    db "Content-Length: 0", $0D, $0A
    db $0D, $0A
sBbUpAuthCl0End:

; Upload request 3 -- the actual upload, identified by the Gb-Auth-ID
; the server just issued rather than by repeating the Authorization.
sBbUpIdPrefix:
    db "POST /cgb/upload?name=/01/MAGBTEST/0.bigbuffer.cgb HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Gb-Auth-ID: "
sBbUpIdPrefixEnd:

; Between the Gb-Auth-ID value and the checksum digits. Content-Length
; is the literal BB_SIZE -- if that constant ever changes, this string
; must change with it (asserted below rather than left to drift).
sBbUpIdMid:
    db $0D, $0A
    db "Content-Length: 8192", $0D, $0A
    db "X-Test-Checksum: "
sBbUpIdMidEnd:

sBbUpAuthTail:
    db $0D, $0A, $0D, $0A
sBbUpAuthTailEnd:

ASSERT BB_SIZE == 8192, "sBbUpIdMid's Content-Length is hardcoded to 8192"

; The authenticated POST header is the one request that exceeds a single
; Transfer Data payload; assert the buffer holds it rather than
; discovering a silent overrun at runtime.
DEF BB_UP_AUTH_LEN EQU (sBbUpAuthPrefixEnd - sBbUpAuthPrefix) + GB00_AUTHORIZATION_LEN + \
                       (sBbUpAuthCl0End - sBbUpAuthCl0)
ASSERT BB_UP_AUTH_LEN <= BB_REQ_BUF_SIZE, "wBbReqBuf too small for upload request 2"

DEF BB_UP_ID_LEN EQU (sBbUpIdPrefixEnd - sBbUpIdPrefix) + BB_AUTH_ID_MAX + \
                     (sBbUpIdMidEnd - sBbUpIdMid) + 4 + \
                     (sBbUpAuthTailEnd - sBbUpAuthTail)
ASSERT BB_UP_ID_LEN <= BB_REQ_BUF_SIZE, "wBbReqBuf too small for upload request 3"

DEF BB_DL_AUTH_LEN EQU (sBbDlAuthPrefixEnd - sBbDlAuthPrefix) + GB00_AUTHORIZATION_LEN + \
                       (sBbAuthSuffixEnd - sBbAuthSuffix)
ASSERT BB_DL_AUTH_LEN <= BB_REQ_BUF_SIZE, "wBbReqBuf too small for the download GET"

SECTION "Big Buffer Code 4", ROMX, BANK[1]

; Copies a static request blob into wBbReqBuf and records its length.
; Input: DE = blob, BC = blob length
; Clobbers: everything
BbLoadStaticReq:
    ld a, c
    ld [wBbReqLen], a
    ld a, b
    ld [wBbReqLen + 1], a
    ld hl, wBbReqBuf
.loop
    ld a, b
    or a, c
    ret z
    ld a, [de]
    ld [hl+], a
    inc de
    dec bc
    jr .loop

; Builds the authenticated download GET into wBbReqBuf: prefix +
; wGb00Authorization (92 chars) + suffix. Assumes Gb00BuildAuthorization
; has already run.
; Clobbers: everything
BbBuildDlAuthReq:
    ld hl, wBbReqBuf
    ld de, sBbDlAuthPrefix
    ld b, sBbDlAuthPrefixEnd - sBbDlAuthPrefix
    call BbAppend
    ld de, wGb00Authorization
    ld b, GB00_AUTHORIZATION_LEN
    call BbAppend
    ld de, sBbAuthSuffix
    ld b, sBbAuthSuffixEnd - sBbAuthSuffix
    call BbAppend
    ld a, BB_DL_AUTH_LEN & $FF
    ld [wBbReqLen], a
    ld a, BB_DL_AUTH_LEN >> 8
    ld [wBbReqLen + 1], a
    ret

; Builds the authenticated upload POST header into wBbReqBuf, embedding
; the download leg's verified checksum as the four X-Test-Checksum hex
; digits -- the server re-derives the same sum over what we upload and
; compares, which is what makes the upload leg a real round-trip rather
; than a write we never check.
; Clobbers: everything
BbBuildUpAuthReq:
    ld hl, wBbReqBuf
    ld de, sBbUpAuthPrefix
    ld b, sBbUpAuthPrefixEnd - sBbUpAuthPrefix
    call BbAppend
    ld de, wGb00Authorization
    ld b, GB00_AUTHORIZATION_LEN
    call BbAppend
    ld de, sBbUpAuthCl0
    ld b, sBbUpAuthCl0End - sBbUpAuthCl0
    call BbAppend

    ld a, BB_UP_AUTH_LEN & $FF
    ld [wBbReqLen], a
    ld a, BB_UP_AUTH_LEN >> 8
    ld [wBbReqLen + 1], a
    ret

; Builds upload request 3 into wBbReqBuf: the Gb-Auth-ID the server just
; issued, the real Content-Length, and the download's verified checksum.
; Length is computed rather than constant -- the id is a server-chosen
; token, not a fixed-width field.
; Clobbers: everything
BbBuildUpIdReq:
    ld hl, wBbReqBuf
    ld de, sBbUpIdPrefix
    ld b, sBbUpIdPrefixEnd - sBbUpIdPrefix
    call BbAppend
    ld de, wBbAuthId
    call BbAppendStr
    ld de, sBbUpIdMid
    ld b, sBbUpIdMidEnd - sBbUpIdMid
    call BbAppend

    ld a, [wBbDlChecksum]
    ld c, a
    ld a, [wBbDlChecksum + 1]
    ld b, a
    call BbAppendHex16

    ld de, sBbUpAuthTail
    ld b, sBbUpAuthTailEnd - sBbUpAuthTail
    call BbAppend

    ; length = write cursor - buffer start
    ld a, l
    sub a, LOW(wBbReqBuf)
    ld [wBbReqLen], a
    ld a, h
    sbc a, HIGH(wBbReqBuf)
    ld [wBbReqLen + 1], a
    ret

; Sends whatever is in wBbReqBuf/wBbReqLen and streams the response.
; Output: A = result (0=OK)
; Clobbers: everything
BbSendBuiltRequest:
    ld hl, wBbReqBuf
    ld a, [wBbReqLen]
    ld c, a
    ld a, [wBbReqLen + 1]
    ld b, a
    jp BbStreamRequest

; Answers a 401 by computing the Authorization value from the challenge
; sitting in wGb00RespBuf. Shared by both legs.
; Output: A = 1 on success, 0 if the WWW-Authenticate header wasn't
;         usable (wBbFailMsgPtr set in that case)
; Clobbers: everything
BbChallengeAuth:
    ; wGb00RespLen was published by BbStreamContinue (see its own note),
    ; and nothing between that return and here touches wBbHeadLen, so
    ; Gb00FindChallenge sees the right length.
    call Gb00FindChallenge
    or a, a
    jr nz, .found
    ld hl, sBbNoAuthHeader
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    xor a, a
    ret
.found
    ld hl, wGb00FetchChallenge
    ld de, wIdentityLogin
    ld bc, wIspPassword
    call Gb00BuildAuthorization
    ld a, 1
    ret

; True (Z set) when the status just parsed into wGb00FetchStatusText is
; "401".
; Clobbers: A, B, DE, HL
BbStatusIs401:
    ld hl, wGb00FetchStatusText
    ld de, sBb401
    ld b, 3
.loop
    ld a, [de]
    inc de
    cp a, [hl]
    ret nz
    inc hl
    dec b
    jr nz, .loop
    xor a, a ; Z set
    ret

sBb401: db "401"

; Uploads the deterministic body: BB_SIZE bytes where body[i] == i&$FF,
; regenerated one BB_UPLOAD_CHUNK slice at a time into wBbChunk. The
; pattern is never stored -- that is the point, this ROM has nowhere to
; put 8 KiB.
; Output: A = result (0=OK)
; Clobbers: everything
BbUploadBody:
    xor a, a
    ld [wBbSent], a
    ld [wBbSent + 1], a

.chunkLoop
    ; remaining = BB_SIZE - sent; done when zero
    ld a, [wBbSent]
    ld e, a
    ld a, [wBbSent + 1]
    ld d, a
    ld hl, BB_SIZE
    ld a, l
    sub a, e
    ld l, a
    ld a, h
    sbc a, d
    ld h, a
    ld a, h
    or a, l
    jr z, .done

    ; chunk_len = min(remaining, BB_UPLOAD_CHUNK)
    ld a, h
    or a, a
    jr nz, .useMax
    ld a, l
    cp a, BB_UPLOAD_CHUNK + 1
    jr c, .haveLen
.useMax
    ld a, BB_UPLOAD_CHUNK
.haveLen
    ld c, a ; chunk_len

    ; Fill wBbChunk with (sent + i) & $FF. Only the low byte of `sent`
    ; matters for the pattern, so this is a plain 8-bit counter.
    push bc
    ld hl, wBbChunk
    ld a, [wBbSent]
    ld b, a ; running byte value
.fill
    ld a, b
    ld [hl+], a
    inc b
    dec c
    jr nz, .fill
    pop bc

    push bc
    ld de, wBbChunk
    call BbSendRaw
    pop bc
    or a, a
    jr nz, .sendFail

    ; sent += chunk_len
    ld a, [wBbSent]
    add a, c
    ld [wBbSent], a
    ld a, [wBbSent + 1]
    adc a, 0
    ld [wBbSent + 1], a
    jr .chunkLoop

.done
    xor a, a
    ret

.sendFail
    push af
    ld hl, sBbUpBodyFail
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
    ret

sBbNoAuthHeader: db "NO WWW-AUTH HDR", 0
sBbNoAuthId:     db "NO GB-AUTH-ID", 0
sBbUpBodyFail:   db "UPLD BODY SEND FAIL", 0
sBbUpHdrFail:    db "UPLD HDR SEND FAIL", 0
sBbDlChecksumBad: db "DL CHECKSUM BAD", 0
sBbUploadMismatch: db "UPLOAD MISMATCH", 0
sBbTcpReopenFail: db "TCP REOPEN FAIL", 0

SECTION "Big Buffer Transfer", ROMX, BANK[1]

; ---- the network phase ------------------------------------------------
;
; Everything between DNS Query and ISP Logout. main.asm owns the session
; around this (Begin Session -> Read Identity -> Dial -> ISP Login -> DNS,
; then cleanup), exactly like it does for News Article; keeping the two
; legs and their retries here rather than in ROM0 is also what keeps this
; test's ~2 KiB out of an almost-full bank 0.
;
; Requires wDnsResultIp, wIdentityLogin and wIspPassword to be set.
; Output: A = result (0=OK); on failure wBbFailMsgPtr points at a
;         printable reason. wBbDetail0/wBbDetail1 always hold the two
;         summary lines main.asm prints.
; Clobbers: everything
BbRunTransfer::
    call BbClearDetails

    ; ---- Download leg -------------------------------------------------
    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    jp nz, .tcpOpenFail

    ld de, sBbDlNoAuthReq
    ld bc, sBbDlNoAuthReqEnd - sBbDlNoAuthReq
    call BbLoadStaticReq
    call BbSendBuiltRequest
    or a, a
    jp nz, .closeAndReturn

    call BbStatusIs401
    jp nz, .downloadDone ; no auth required for this path

    call BbChallengeAuth
    or a, a
    jp nz, .dlHaveAuth
    call MagbTcpClose
    ld a, MAGB_ERR_ISP
    ret
.dlHaveAuth
    ; REON requires the TCP connection to be closed and reopened between
    ; the challenge and the authenticated retry (see gbdk's
    ; docs/protocol-notes.md, "GB00 HTTP authentication") -- this is not
    ; an optimisation, the retry fails on a reused connection.
    call MagbTcpClose
    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    jp nz, .reopenFail

    call BbBuildDlAuthReq
    call BbSendBuiltRequest
    or a, a
    jp nz, .closeAndReturn

.downloadDone
    call MagbTcpClose

    ; Verify the streamed checksum against the header's own value.
    ld a, [wBbChecksumPresent]
    or a, a
    jp z, .checksumBad
    ld a, [wBbChecksum]
    ld hl, wBbExpected
    cp a, [hl]
    jp nz, .checksumBad
    ld a, [wBbChecksum + 1]
    ld hl, wBbExpected + 1
    cp a, [hl]
    jp nz, .checksumBad

    ; Stash the verified checksum/length -- the upload leg re-sends the
    ; checksum in its own X-Test-Checksum header, and the length is
    ; reported on screen.
    ld a, [wBbChecksum]
    ld [wBbDlChecksum], a
    ld a, [wBbChecksum + 1]
    ld [wBbDlChecksum + 1], a
    ld a, [wBbBodyLen]
    ld [wBbDlBodyLen], a
    ld a, [wBbBodyLen + 1]
    ld [wBbDlBodyLen + 1], a
    call BbBuildDlOkDetail

    ; ---- Upload leg ---------------------------------------------------
    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    jp nz, .tcpOpenFail

    ld de, sBbUpProbeReq
    ld bc, sBbUpProbeReqEnd - sBbUpProbeReq
    call BbLoadStaticReq
    call BbSendBuiltRequest
    or a, a
    jp nz, .closeAndReturn

    ; Unlike the download, the upload endpoint must challenge us: an
    ; unauthenticated 200 here would mean the write was accepted without
    ; auth, which is a finding, not a pass.
    call BbStatusIs401
    jp nz, .uploadNoChallenge
    call BbChallengeAuth
    or a, a
    jp nz, .upHaveAuth
    call MagbTcpClose
    ld a, MAGB_ERR_ISP
    ret
.uploadNoChallenge
    call MagbTcpClose
    ld hl, sBbNoAuthHeader
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret

.upHaveAuth
    call MagbTcpClose
    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    jp nz, .reopenFail

    ; Upload request 2: authenticate ONLY, with no body. REON's
    ; upload.php runs doAuth() (type 0), whose success branch sets a
    ; Gb-Auth-ID header, sends 200 and exit()s -- it never reaches the
    ; upload handler, so a body sent here would be silently discarded.
    ; The real upload is request 3 below, carrying that id. (download.php
    ; differs: it calls doAuth(1), which RETURNS instead of exiting, so
    ; the authenticated GET does carry the content -- which is why the
    ; download leg above needs only two requests.)
    call BbBuildUpAuthReq
    call BbSendBuiltRequest
    or a, a
    jp nz, .closeAndReturn

    call BbFindAuthId
    or a, a
    jr nz, .haveAuthId
    call MagbTcpClose
    ld hl, sBbNoAuthId
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret

.haveAuthId
    call MagbTcpClose
    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    jp nz, .reopenFail

    ; Upload request 3: the actual upload, identified by the Gb-Auth-ID
    ; the server just issued rather than by repeating the Authorization.
    call BbSendBegin
    call BbBuildUpIdReq
    ld hl, wBbReqBuf
    ld a, [wBbReqLen]
    ld c, a
    ld a, [wBbReqLen + 1]
    ld b, a
    call BbSendAll
    or a, a
    jp nz, .upHdrFail

    call BbUploadBody
    or a, a
    jp nz, .closeAndReturn

    call BbStreamRecv
    or a, a
    jp nz, .closeAndReturn
    call MagbTcpClose

    ; The server reports its own verdict in the first body byte.
    ld a, [wBbBodyLen]
    ld hl, wBbBodyLen + 1
    or a, [hl]
    jp z, .uploadMismatch
    ld a, [wBbFirstBodyByte]
    cp a, 1
   jp nz, .uploadMismatch

    call BbBuildUploadOkDetail
    xor a, a
    ret

.uploadMismatch
    call BbBuildUploadByteDetail
    ld hl, sBbUploadMismatch
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret

.checksumBad
    call BbBuildChecksumDetail
    ld hl, sBbDlChecksumBad
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret

.upHdrFail
    push af
    ld hl, sBbUpHdrFail
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
    ; fall through
.closeAndReturn
    push af
    call MagbTcpClose
    pop af
    ret

.reopenFail
    push af
    ld hl, sBbTcpReopenFail
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
    ret

.tcpOpenFail
    push af
    ld hl, sBbTcpOpenFail
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
    ret

sBbTcpOpenFail: db "TCP OPEN FAILED", 0

; ---- on-screen detail lines -------------------------------------------

BbClearDetails:
    ld hl, wBbDetail0
    xor a, a
    ld [hl], a
    ld hl, wBbDetail1
    ld [hl], a
    ret

sBbDlPrefix: db "DL "
sBbDlPrefixEnd:
sBbDlSuffix: db " B OK", 0
sBbDlSuffixEnd:

; "DL <n> B OK"
BbBuildDlOkDetail:
    ld hl, wBbDetail0
    ld de, sBbDlPrefix
    ld b, sBbDlPrefixEnd - sBbDlPrefix
    call BbAppend
    ld a, [wBbDlBodyLen]
    ld c, a
    ld a, [wBbDlBodyLen + 1]
    ld b, a
    call BbAppendDecimal16
    ld de, sBbDlSuffix
    ld b, sBbDlSuffixEnd - sBbDlSuffix
    jp BbAppend

sBbUploadOk: db "UPLOAD OK", 0
sBbUploadOkEnd:

BbBuildUploadOkDetail:
    ld hl, wBbDetail1
    ld de, sBbUploadOk
    ld b, sBbUploadOkEnd - sBbUploadOk
    jp BbAppend

sBbUpBytePrefix: db "UP BYTE="
sBbUpBytePrefixEnd:

; "UP BYTE=<hh>"
sBbSrvPrefix: db "SRV "
sBbSrvPrefixEnd:
sBbWeLabel:   db " WE "
sBbWeLabelEnd:

; On an upload rejection the handler echoes, in the response's own
; X-Test-Checksum, the checksum it computed over what it ACTUALLY
; received -- already parsed by BbStreamContinue. Printing that beside
; ours turns "the upload failed" into "the server saw THIS instead",
; which is the difference between a retry and a diagnosis (a truncated
; body lands on a recognisably smaller sum). Falls back to the raw
; verdict byte when the response carried no checksum header.
BbBuildUploadByteDetail:
    ld hl, wBbDetail1
    ld a, [wBbChecksumPresent]
    or a, a
    jr z, .rawByte

    ld de, sBbSrvPrefix
    ld b, sBbSrvPrefixEnd - sBbSrvPrefix
    call BbAppend
    ld a, [wBbExpected]
    ld c, a
    ld a, [wBbExpected + 1]
    ld b, a
    call BbAppendHex16
    ld de, sBbWeLabel
    ld b, sBbWeLabelEnd - sBbWeLabel
    call BbAppend
    ld a, [wBbDlChecksum]
    ld c, a
    ld a, [wBbDlChecksum + 1]
    ld b, a
    call BbAppendHex16
    xor a, a
    ld [hl], a
    ret

.rawByte
    ld de, sBbUpBytePrefix
    ld b, sBbUpBytePrefixEnd - sBbUpBytePrefix
    call BbAppend
    ld a, [wBbFirstBodyByte]
    call BbAppendHexByte
    xor a, a
    ld [hl], a
    ret

; "<computed>!=<expected>", both as 4 hex digits -- the same shape gbdk
; prints, so a screenshot from either ROM reads identically.
BbBuildChecksumDetail:
    ld hl, wBbDetail0
    ld a, [wBbChecksum]
    ld c, a
    ld a, [wBbChecksum + 1]
    ld b, a
    call BbAppendHex16
    ld a, "!"
    ld [hl+], a
    ld a, "="
    ld [hl+], a
    ld a, [wBbExpected]
    ld c, a
    ld a, [wBbExpected + 1]
    ld b, a
    call BbAppendHex16
    xor a, a
    ld [hl], a
    ret

; Writes BC as decimal at [HL] (no leading zeroes), advancing HL. Only
; used for the byte count on the result screen, so the plain
; repeated-subtraction form is fine -- SM83 has no divide.
; Input: BC = value, HL = write cursor
; Clobbers: everything except HL's role as cursor
BbAppendDecimal16:
    xor a, a
    ld [wBbDecStarted], a
    ld de, 10000
    call .digit
    ld de, 1000
    call .digit
    ld de, 100
    call .digit
    ld de, 10
    call .digit
    ; final units digit, always emitted so "0" prints as "0"
    ld a, c
    add a, "0"
    ld [hl+], a
    xor a, a
    ld [hl], a
    ret

.digit
    ld a, "0" - 1
    ld [wBbDecDigit], a
.sub
    ld a, [wBbDecDigit]
    inc a
    ld [wBbDecDigit], a
    ld a, c
    sub a, e
    ld c, a
    ld a, b
    sbc a, d
    ld b, a
    jr nc, .sub
    ; overshot by one -- add the divisor back
    ld a, c
    add a, e
    ld c, a
    ld a, b
    adc a, d
    ld b, a

    ld a, [wBbDecDigit]
    cp a, "0"
    jr nz, .emit
    ; leading zero: emit only if something was already written
    ld a, [wBbDecStarted]
    or a, a
    ret z
    ld a, "0"
.emit
    ld [hl+], a
    ld a, 1
    ld [wBbDecStarted], a
    ret

SECTION "Big Buffer Decimal Scratch", WRAMX, BANK[1]
wBbDecDigit:   db
wBbDecStarted: db

; ---- SMALL BUFFER ------------------------------------------------------
;
; The small half of the synthetic pair. Same body contract and same
; checksum format as BIG BUFFER, but the opposite regime on both axes
; that matter:
;
;   size  BB_SMALL_SIZE fits in ONE Transfer Data response, so nothing
;         streams and nothing is chunked -- headers and body arrive
;         together, which BIG BUFFER never exercises.
;   auth  Both legs go through REON's doAuth(2) ("utility" auth) on the
;         SAME URL. The POST goes to the download path, NOT /cgb/upload,
;         and REUSES the Authorization from the GET with no second
;         challenge.
;
; That reuse is the reason this exists rather than being BIG BUFFER with
; a smaller number. auth.php caches utility_authed_user_id for 15
; minutes precisely so the official client can POST after authenticating
; once (news.php's own comment: "Ranking queries are POSTed without
; replaying a GB00 auth challenge"). It is the only piece of
; server-side state on that path, and it would have left with the
; NEWS ARTICLE test this replaced.
;
; Contrast with BIG BUFFER's type-0 upload, which trades the
; Authorization for a Gb-Auth-ID and needs a third request carrying it.
; Nothing here ever sends a Gb-Auth-ID; if one ever appears on this
; path, something is routed wrong.

SECTION "Small Buffer Requests", ROMX, BANK[1]

sBbSmallNoAuthReq:
    db "GET /cgb/download?name=/01/MAGBTEST/0.smallbuffer.cgb HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db $0D, $0A
sBbSmallNoAuthReqEnd:

sBbSmallAuthPrefix:
    db "GET /cgb/download?name=/01/MAGBTEST/0.smallbuffer.cgb HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Authorization: GB00 name=", $22
sBbSmallAuthPrefixEnd:

; Note the POST target: the DOWNLOAD path, deliberately.
sBbSmallPostPrefix:
    db "POST /cgb/download?name=/01/MAGBTEST/0.smallbuffer.cgb HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Authorization: GB00 name=", $22
sBbSmallPostPrefixEnd:

sBbSmallPostMid:
    db $22, $0D, $0A
    db "Content-Length: 128", $0D, $0A
    db "X-Test-Checksum: "
sBbSmallPostMidEnd:

ASSERT BB_SMALL_SIZE == 128, "sBbSmallPostMid's Content-Length is hardcoded to 128"

DEF BB_SMALL_GET_LEN EQU (sBbSmallAuthPrefixEnd - sBbSmallAuthPrefix) + GB00_AUTHORIZATION_LEN + \
                         (sBbAuthSuffixEnd - sBbAuthSuffix)
ASSERT BB_SMALL_GET_LEN <= BB_REQ_BUF_SIZE, "wBbReqBuf too small for the small GET"

DEF BB_SMALL_POST_LEN EQU (sBbSmallPostPrefixEnd - sBbSmallPostPrefix) + GB00_AUTHORIZATION_LEN + \
                          (sBbSmallPostMidEnd - sBbSmallPostMid) + 4 + \
                          (sBbUpAuthTailEnd - sBbUpAuthTail)
ASSERT BB_SMALL_POST_LEN <= BB_REQ_BUF_SIZE, "wBbReqBuf too small for the small POST"

SECTION "Small Buffer Code", ROMX, BANK[1]

; Builds the authenticated GET into wBbReqBuf.
; Clobbers: everything
BbBuildSmallAuthReq:
    ld hl, wBbReqBuf
    ld de, sBbSmallAuthPrefix
    ld b, sBbSmallAuthPrefixEnd - sBbSmallAuthPrefix
    call BbAppend
    ld de, wGb00Authorization
    ld b, GB00_AUTHORIZATION_LEN
    call BbAppend
    ld de, sBbAuthSuffix
    ld b, sBbAuthSuffixEnd - sBbAuthSuffix
    call BbAppend
    ld a, BB_SMALL_GET_LEN & $FF
    ld [wBbReqLen], a
    ld a, BB_SMALL_GET_LEN >> 8
    ld [wBbReqLen + 1], a
    ret

; Builds the POST into wBbReqBuf, reusing the SAME Authorization value
; the GET was accepted with -- no new challenge is fetched.
; Clobbers: everything
BbBuildSmallPostReq:
    ld hl, wBbReqBuf
    ld de, sBbSmallPostPrefix
    ld b, sBbSmallPostPrefixEnd - sBbSmallPostPrefix
    call BbAppend
    ld de, wGb00Authorization
    ld b, GB00_AUTHORIZATION_LEN
    call BbAppend
    ld de, sBbSmallPostMid
    ld b, sBbSmallPostMidEnd - sBbSmallPostMid
    call BbAppend

    ld a, [wBbDlChecksum]
    ld c, a
    ld a, [wBbDlChecksum + 1]
    ld b, a
    call BbAppendHex16

    ld de, sBbUpAuthTail
    ld b, sBbUpAuthTailEnd - sBbUpAuthTail
    call BbAppend

    ld a, BB_SMALL_POST_LEN & $FF
    ld [wBbReqLen], a
    ld a, BB_SMALL_POST_LEN >> 8
    ld [wBbReqLen + 1], a
    ret

; Same contract as BbRunTransfer: everything between DNS Query and ISP
; Logout. Requires wDnsResultIp, wIdentityLogin and wIspPassword set.
; Output: A = result (0=OK); wBbFailMsgPtr set on failure, and
;         wBbDetail0/wBbDetail1 hold the two summary lines.
; Clobbers: everything
BbRunSmallTransfer::
    call BbClearDetails

    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    jp nz, .tcpOpenFail

    ld de, sBbSmallNoAuthReq
    ld bc, sBbSmallNoAuthReqEnd - sBbSmallNoAuthReq
    call BbLoadStaticReq
    call BbSendBuiltRequest
    or a, a
    jp nz, .closeAndReturn

    ; This endpoint MUST challenge us. Being served without one would
    ; mean doAuth(2) is not being enforced, and the whole point of this
    ; test -- that the reuse below is a real reuse -- would be void.
    call BbStatusIs401
    jp nz, .noChallenge

    call BbChallengeAuth
    or a, a
    jp nz, .haveAuth
    call MagbTcpClose
    ld a, MAGB_ERR_ISP
    ret

.haveAuth
    call MagbTcpClose
    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    jp nz, .reopenFail

    call BbBuildSmallAuthReq
    call BbSendBuiltRequest
    or a, a
    jp nz, .closeAndReturn
    call MagbTcpClose

    ; Checksum must be present and must agree.
    ld a, [wBbChecksumPresent]
    or a, a
    jp z, .checksumBad
    ld a, [wBbChecksum]
    ld hl, wBbExpected
    cp a, [hl]
    jp nz, .checksumBad
    ld a, [wBbChecksum + 1]
    ld hl, wBbExpected + 1
    cp a, [hl]
    jp nz, .checksumBad

    ; Size is part of the contract, not incidental: a short read that
    ; happened to checksum correctly would otherwise pass silently.
    ld a, [wBbBodyLen]
    cp a, BB_SMALL_SIZE & $FF
    jp nz, .shortBody
    ld a, [wBbBodyLen + 1]
    cp a, BB_SMALL_SIZE >> 8
    jp nz, .shortBody

    ld a, [wBbChecksum]
    ld [wBbDlChecksum], a
    ld a, [wBbChecksum + 1]
    ld [wBbDlChecksum + 1], a
    ld a, [wBbBodyLen]
    ld [wBbDlBodyLen], a
    ld a, [wBbBodyLen + 1]
    ld [wBbDlBodyLen + 1], a
    call BbBuildDlOkDetail

    ; The server reports which user its utility auth resolved, in
    ; X-Test-User. A correct body with user 0 would mean the request was
    ; served without ever authenticating -- a pass that proves nothing,
    ; which is exactly what this test exists to catch.
    call BbFindTestUser
    or a, a
    jp z, .notAuthed
    ld a, [wBbAuthId]
    cp a, "0"
    jr nz, .userOk
    ld a, [wBbAuthId + 1]
    or a, a
    jp z, .notAuthed ; the value is exactly "0"
.userOk

    ; ---- POST: same URL, same Authorization, no re-challenge --------
    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    jp nz, .tcpOpenFail

    call BbSendBegin
    call BbBuildSmallPostReq
    ld hl, wBbReqBuf
    ld a, [wBbReqLen]
    ld c, a
    ld a, [wBbReqLen + 1]
    ld b, a
    call BbSendAll
    or a, a
    jp nz, .upHdrFail

    ; Body: BB_SMALL_SIZE bytes of body[i] == i & $FF, in one send --
    ; it fits a single Transfer Data payload, which is the regime this
    ; half of the pair is here to cover.
    ld hl, wBbChunk
    ld b, BB_SMALL_SIZE
    ld c, 0
.fill
    ld a, c
    ld [hl+], a
    inc c
    dec b
    jr nz, .fill

    ld de, wBbChunk
    ld c, BB_SMALL_SIZE
    call BbSendRaw
    or a, a
    jp nz, .upBodyFail

    call BbStreamRecv
    or a, a
    jp nz, .closeAndReturn
    call MagbTcpClose

    ; A 401 here means the utility-auth window did not hold -- the one
    ; thing this leg exists to check, and worth naming separately from a
    ; checksum disagreement.
    call BbStatusIs401
    jp z, .authReuseRejected

    ld a, [wBbBodyLen]
    ld hl, wBbBodyLen + 1
    or a, [hl]
    jp z, .uploadMismatch
    ld a, [wBbFirstBodyByte]
    cp a, 1
    jp nz, .uploadMismatch

    call BbBuildUploadOkDetail
    xor a, a
    ret

.noChallenge
    call MagbTcpClose
    ld hl, sBbNoChallenge
    jr .failIsp
.notAuthed
    ld hl, sBbNotAuthed
    jr .failIsp
.authReuseRejected
    ld hl, sBbAuthReuseRejected
    jr .failIsp
.shortBody
    call BbBuildShortBodyDetail
    ld hl, sBbShortBody
    jr .failIsp
.checksumBad
    call BbBuildChecksumDetail
    ld hl, sBbDlChecksumBad
    jr .failIsp
.uploadMismatch
    call BbBuildUploadByteDetail
    ld hl, sBbUploadMismatch
.failIsp
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret

.upHdrFail
    push af
    ld hl, sBbUpHdrFail
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
    jr .closeAndReturn
.upBodyFail
    push af
    ld hl, sBbUpBodyFail
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
.closeAndReturn
    push af
    call MagbTcpClose
    pop af
    ret

.reopenFail
    push af
    ld hl, sBbTcpReopenFail
    jr .storeAndReturn
.tcpOpenFail
    push af
    ld hl, sBbTcpOpenFail
.storeAndReturn
    ld a, l
    ld [wBbFailMsgPtr], a
    ld a, h
    ld [wBbFailMsgPtr + 1], a
    pop af
    ret

sBbNoChallenge:        db "NO CHALLENGE", 0
sBbNotAuthed:          db "NOT AUTHENTICATED", 0
sBbAuthReuseRejected:  db "AUTH REUSE REJECTED", 0
sBbShortBody:          db "SHORT BODY", 0

sBbGotPrefix: db "GOT "
sBbGotPrefixEnd:
sBbWantLabel: db " WANT "
sBbWantLabelEnd:

; "GOT <n> WANT <n>"
BbBuildShortBodyDetail:
    ld hl, wBbDetail0
    ld de, sBbGotPrefix
    ld b, sBbGotPrefixEnd - sBbGotPrefix
    call BbAppend
    ld a, [wBbBodyLen]
    ld c, a
    ld a, [wBbBodyLen + 1]
    ld b, a
    call BbAppendDecimal16
    ld de, sBbWantLabel
    ld b, sBbWantLabelEnd - sBbWantLabel
    call BbAppend
    ld bc, BB_SMALL_SIZE
    jp BbAppendDecimal16
