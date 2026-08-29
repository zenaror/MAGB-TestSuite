; Mobile Adapter GB TestSuite -- RGBDS assembly implementation.
;
; Seventh milestone of the RGBDS port (see rgbds/docs/status.md):
; Transfer Data (0x15) and a real HTTP/1.0 GET over the TCP connection,
; completing the GBDK side's Test 2 (ISP / Internet) shape:
;   Begin Session -> Dial -> ISP Login -> DNS -> TCP Open -> HTTP GET
;   -> TCP Close -> ISP Logout -> Hang Up -> End Session
; Dials the real DION PDC ISP number ("#9677",
; gbdk/include/test_config.h's TEST_ISP_PHONE) and resolves + fetches
; from the real historical Mobile System GB datacenter hostname
; ("gameboy.datacenter.ne.jp", TEST_HTTP_HOST, real TEST_HTTP_PATH) --
; the same real, documented targets the GBDK side's test uses ("Mystery
; Egg" metadata), not invented ones. ISP Login uses the same "test"/
; "test" fallback credentials and 0.0.0.0/0.0.0.0 DNS (meaning "use your
; own configured DNS") as TEST_ISP_LOGIN and TEST_DNS_*; libmobile's PPP
; login handler doesn't check credentials against a real account, so
; this works regardless.
;
; Screen layout (fixed positions, no scrolling/wrapping):
;   row 0: title "MAGB TEST 2"
;   row 1: which command is currently running ("SESSION", "DIAL",
;          "ISP LOGIN", "DNS", "TCP OPEN", "HTTP GET", "TCP CLOSE",
;          "ISP LOGOUT", "HANGUP", "END SESS") -- since all of these go
;          through the same MagbExecute/SetStatus machinery, this is
;          what actually says *which* command a hang is stuck in; row 2
;          alone can't.
;   row 2: current stage within that command ("WAKE", "SEND", "WAIT",
;          "READ") -- updated live as the exchange progresses
;   row 4: final result, "PASS" or "FAIL"
;   row 5: (after a successful HTTP GET only) "HTTP <3-digit-status>",
;          or "NO HTTP PREFIX"/"HTTP/ (SHORT)" if the transport worked
;          but the response wasn't recognizable HTTP -- see
;          HttpShowResult; never a reason to fail the whole sequence
;   row 6: (FAIL only) the specific MAGB_ERR_* code, e.g. "TIMEOUT",
;          "BAD CHECKSUM"
;
; This ROM stops at the first failing command (matching the previous
; milestone's shape) rather than attempting best-effort Hang Up/End
; Session cleanup after an earlier failure -- see rgbds/docs/status.md
; for why that's a known, deliberate simplification for now.

INCLUDE "hardware.inc"
INCLUDE "protocol.inc"

SECTION "Header", ROM0[$100]
    jp EntryPoint
    ds $150 - @, 0 ; rgbfix fills in the logo, title, and checksums

SECTION "Main", ROM0

EntryPoint:
    ; A still holds the boot-time hardware ID ($11 CGB / $01 DMG) here --
    ; nothing before this touches A. SerialHwInit halts forever if this
    ; isn't a CGB.
    call SerialHwInit

    ; Registers this ROM's own SetStatus (row 2, below) as the protocol
    ; layer's live-status notification -- see session.asm's
    ; MagbProtocolInit/MagbSetStatusCallback and docs/integration-guide.md.
    ; This is what lets src/hw/+src/protocol/ be copied into someone
    ; else's homebrew without also forcing them to define a SetStatus of
    ; their own: they simply never call MagbSetStatusCallback, and
    ; MagbProtocolInit's zeroed default means no callback ever fires.
    call MagbProtocolInit
    ld hl, SetStatus
    call MagbSetStatusCallback

    call InitDisplayBlank
    call LoadFont
    call ClearTextScreen

    ld hl, sTitle
    ld de, $9801
    call PrintString

    ld a, CMD_SESSION
    call SetCommand
    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jp nz, .showFail

    ld a, CMD_DIAL
    call SetCommand
    ld hl, sIspPhoneNumber
    ld b, sIspPhoneNumberEnd - sIspPhoneNumber
    call MagbDial
    or a, a
    jp nz, .showFail

    ld a, CMD_ISP_LOGIN
    call SetCommand
    ld de, sIspLoginPayload
    ld c, sIspLoginPayloadEnd - sIspLoginPayload
    call MagbIspLogin
    or a, a
    jp nz, .showFail

    ld a, CMD_DNS
    call SetCommand
    ld hl, sDnsHostname
    ld b, sDnsHostnameEnd - sDnsHostname
    call MagbDnsQuery
    or a, a
    jp nz, .showFail

    ld a, CMD_TCP_OPEN
    call SetCommand
    ld hl, wDnsResultIp
    ld bc, TEST_HTTP_PORT
    call MagbTcpOpen
    or a, a
    jp nz, .showFail

    ld a, CMD_HTTP
    call SetCommand
    call HttpFetch
    or a, a
    jp nz, .showFail
    call HttpShowResult

    ld a, CMD_TCP_CLOSE
    call SetCommand
    call MagbTcpClose
    or a, a
    jp nz, .showFail

    ld a, CMD_ISP_LOGOUT
    call SetCommand
    call MagbIspLogout
    or a, a
    jp nz, .showFail

    ld a, CMD_HANGUP
    call SetCommand
    call MagbHangup
    or a, a
    jp nz, .showFail

    ld a, CMD_END_SESSION
    call SetCommand
    call MagbEndSession
    or a, a
    jp nz, .showFail

    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
.forever
    jr .forever

.showFail
    ; A holds the MAGB_ERR_* code that failed -- stash it, since
    ; PrintString (called next, for the "RESULT: FAIL" line) clobbers A.
    push af

    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString

    pop af
    call PrintErrorCode
.foreverFail
    jr .foreverFail

; ---- Display bring-up (tiles/palette only -- text.asm owns the font) ----

; Turns the LCD off (safely, after waiting for VBlank), clears tile 0
; (kept blank; unused now that text.asm's font occupies the tile block
; starting there, but zeroing it first keeps FillMemory's role obvious)
; and the tilemap, then sets a plain black-on-white BG palette 0 and
; turns the LCD on. LoadFont/ClearTextScreen (text.asm) do their own
; VRAM writes safely afterwards.
; Clobbers: A, BC, HL
InitDisplayBlank:
    call WaitVBlank
    xor a, a
    ldh [rLCDC], a ; LCD off: only safe to touch VRAM freely while off

    ld hl, $9800 ; the 32x32 BG tilemap RGBDS/hardware default location
    ld bc, 32 * 32
    call FillMemory

    ld a, BCPS_AUTO_INCREMENT ; palette 0, color 0, auto-increment
    ldh [rBCPS], a
    ld a, low(COLOR_WHITE)
    ldh [rBCPD], a
    ld a, high(COLOR_WHITE)
    ldh [rBCPD], a
    ld a, low(COLOR_BLACK)
    ldh [rBCPD], a
    ld a, high(COLOR_BLACK)
    ldh [rBCPD], a

    ld a, LCDC_ON | LCDC_BG_ON | LCDC_BG_TILEDATA
    ldh [rLCDC], a
    ret

DEF COLOR_WHITE EQU $7FFF ; CGB RGB555: BG palette 0 color 0 (background)
DEF COLOR_BLACK EQU $0000 ; BG palette 0 color 1 (text)

; Fills BC bytes starting at HL with 0.
;
; The zero-check is done *before* each write, not after -- an earlier
; version checked after writing (`ld [hl+],a` / `dec bc` / `ld a,b` /
; `or a,c` / `jr nz`), which reused A for both "the value being
; written" and "BC==0 scratch": after the first byte, A held leftover
; bits of the countdown instead of 0, so only the very first byte
; actually got cleared and everything after it was garbage. Confirmed
; the hard way by reading VRAM after a "cleared" screen still showed a
; clearly non-zero, structured pattern.
; Clobbers: A, BC, HL
FillMemory:
.loop
    ld a, b
    or a, c
    ret z
    xor a, a
    ld [hl+], a
    dec bc
    jr .loop

; Blocks until the start of the next VBlank period (LY becomes 144).
; Clobbers: A
WaitVBlank::
    ldh a, [rLY]
    cp a, 144
    jr nc, WaitVBlank ; already past the start of VBlank, wait for the next one
.wait
    ldh a, [rLY]
    cp a, 144
    jr c, .wait
    ret

; ---- Command line (row 1) -------------------------------------------------

DEF CMD_SESSION     EQU 0
DEF CMD_DIAL         EQU 1
DEF CMD_ISP_LOGIN    EQU 2
DEF CMD_DNS          EQU 3
DEF CMD_TCP_OPEN     EQU 4
DEF CMD_HTTP         EQU 5
DEF CMD_TCP_CLOSE    EQU 6
DEF CMD_ISP_LOGOUT   EQU 7
DEF CMD_HANGUP       EQU 8
DEF CMD_END_SESSION  EQU 9

DEF TEST_HTTP_PORT EQU 80 ; gbdk/include/test_config.h's TEST_HTTP_PORT

DEF CMD_ADDR EQU $9821 ; row 1, col 1

; Prints one of the short command names at the fixed command line
; (row 1), overwriting whatever was there before. Same table-lookup
; shape as SetStatus below; kept separate since they're conceptually
; different axes (which command vs. which stage within it) shown on
; different rows.
;
; Input: A = CMD_* index
; Clobbers: everything (calls PrintString)
SetCommand:
    push hl
    push de
    ld hl, CommandStrings
    ld e, a
    ld d, 0
    add hl, de
    add hl, de
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a
    ld h, d
    ld l, e
    ld de, CMD_ADDR
    call PrintString
    pop de
    pop hl
    ret

CommandStrings:
    dw sCmdSession
    dw sCmdDial
    dw sCmdIspLogin
    dw sCmdDns
    dw sCmdTcpOpen
    dw sCmdHttp
    dw sCmdTcpClose
    dw sCmdIspLogout
    dw sCmdHangup
    dw sCmdEndSession

sCmdSession:    db "SESSION", 0
sCmdDial:       db "DIAL", 0
sCmdIspLogin:   db "ISP LOGIN", 0
sCmdDns:        db "DNS", 0
sCmdTcpOpen:    db "TCP OPEN", 0
sCmdHttp:       db "HTTP GET", 0
sCmdTcpClose:   db "TCP CLOSE", 0
sCmdIspLogout:  db "ISP LOGOUT", 0
sCmdHangup:     db "HANGUP", 0
sCmdEndSession: db "END SESS", 0

; DION PDC ISP dial number -- gbdk/include/test_config.h's TEST_ISP_PHONE,
; hardcoded as a recognized special case in libmobile/commands.c's own
; isp_numbers[] table (see that file's comment for the full citation).
sIspPhoneNumber: db "#9677"
sIspPhoneNumberEnd:

; ISP Login request payload, pre-built as static data since every field
; is a fixed test value: login_len, login, password_len, password,
; dns1[4], dns2[4] (see gbdk/src/protocol/magb_network.c's
; magb_isp_login() for the exact same layout). "test"/"test" and
; 0.0.0.0/0.0.0.0 match TEST_ISP_LOGIN and TEST_DNS_* -- libmobile's PPP
; login handler doesn't check credentials against a real account, and
; an all-zero DNS entry means "use your own configured DNS servers"
; (confirmed libmobile behavior, same file's comment).
sIspLoginPayload:
    db 4
    db "test"
    db 4
    db "test"
    db 0, 0, 0, 0
    db 0, 0, 0, 0
sIspLoginPayloadEnd:

; Real historical Mobile System GB / DION datacenter hostname --
; gbdk/include/test_config.h's TEST_HTTP_HOST, REON's own DNS entry and
; the exact host embedded in Pokemon Crystal's real "Mystery Egg"
; metadata file (see that file's comment for the full citation).
sDnsHostname: db "gameboy.datacenter.ne.jp"
sDnsHostnameEnd:

; ---- HTTP GET request (Transfer Data, 0x15) --------------------------------

; Same real request gbdk/src/app/test_runner.c's test_isp_http() sends
; (path = TEST_HTTP_PATH, host = TEST_HTTP_HOST) -- the real Mystery Egg
; metadata file, not an invented URL. CRLFs are written as explicit
; $0D,$0A bytes rather than a "\r\n" string escape, since RGBDS string
; literals don't uniformly support \r. 148 bytes total (checked against
; PROTO_MAX_PAYLOAD_LEN - 1 = 253, the most MagbTransferData can send in
; one call -- comfortably under it).
sHttpRequest:
    db "GET /cgb/download?name=/01/CGB-BXTJ/tamago/index.txt HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "User-Agent: MAGB-TestSuite/1.0", $0D, $0A
    db "Connection: close", $0D, $0A
    db $0D, $0A
sHttpRequestEnd:

sHttpMagic: db "HTTP/" ; compared by fixed 5-byte count, no null needed
sHttpShort: db "HTTP/ (SHORT)", 0
sHttpNoPrefix: db "NO HTTP PREFIX", 0

DEF HTTP_RESP_BUF_SIZE   EQU 240  ; gbdk/src/app/test_runner.c's HTTP_RESP_BUF_SIZE
DEF HTTP_MAX_TOTAL_BYTES EQU 8192 ; gbdk's HTTP_MAX_TOTAL_BYTES
DEF HTTP_MAX_EMPTY_POLLS EQU 5    ; gbdk's HTTP_MAX_EMPTY_POLLS

; ---- HTTP GET: send + poll-until-closed, then parse the response ----------
;
; Mirrors gbdk/src/app/test_runner.c's test_isp_http(): one MagbTransferData
; carrying the full GET request (which may already come back with the
; first response bytes piggybacked on the same reply), then zero-length
; "just checking" polls -- each one asking for whatever's left of
; wHttpRespBuf's remaining capacity -- until Transfer Data End arrives,
; the response buffer fills, the total-bytes safety cap is hit, or too
; many consecutive empty polls suggest the peer stalled.
;
; Any MagbTransferData failure here is a transport-level failure, shown
; through PrintErrorCode exactly like every other command in this ROM.
;
; Output: A = result (0=OK, transport-level only -- a response that
;         doesn't start with "HTTP/" is NOT a failure here, see
;         HttpShowResult)
; Clobbers: everything
HttpFetch:
    xor a, a
    ld [wHttpRespLen], a
    ld [wHttpTotalRecv], a
    ld [wHttpTotalRecv + 1], a
    ld [wHttpEmptyPolls], a

    ld de, sHttpRequest
    ld c, sHttpRequestEnd - sHttpRequest
    ld hl, wHttpRespBuf
    ld b, HTTP_RESP_BUF_SIZE
    call MagbTransferData
    or a, a
    ret nz

    ld a, [wXferGotLen]
    ld [wHttpRespLen], a
    ld e, a
    ld d, 0
    ld hl, wHttpTotalRecv
    ld a, [hl]
    add a, e
    ld [hl+], a
    ld a, [hl]
    adc a, d
    ld [hl], a

.pollLoop
    ld a, [wXferRemoteClosed]
    or a, a
    jr nz, .fetchDone

    ld a, [wHttpTotalRecv]
    ld l, a
    ld a, [wHttpTotalRecv + 1]
    ld h, a
    ld de, HTTP_MAX_TOTAL_BYTES
    ld a, l
    sub a, e
    ld a, h
    sbc a, d
    jr nc, .fetchDone ; total_received >= HTTP_MAX_TOTAL_BYTES

    ld a, [wHttpEmptyPolls]
    cp a, HTTP_MAX_EMPTY_POLLS
    jr nc, .fetchDone

    ld a, [wHttpRespLen]
    ld b, a
    ld a, HTTP_RESP_BUF_SIZE
    sub a, b
    jr nc, .haveCap
    xor a, a
.haveCap
    ld [wHttpLastCap], a
    ld b, a ; cap, for MagbTransferData's B input

    ld a, [wHttpRespLen]
    ld l, a
    ld h, 0
    ld de, wHttpRespBuf
    add hl, de

    ld c, 0 ; zero-length send: a poll, not a new send
    call MagbTransferData
    or a, a
    ret nz

    ld a, [wXferGotLen]
    or a, a
    jr nz, .gotSomething
    ld a, [wXferRemoteClosed]
    or a, a
    jr nz, .skipEmptyCount
    ld a, [wHttpEmptyPolls]
    inc a
    ld [wHttpEmptyPolls], a
    jr .skipEmptyCount
.gotSomething
    xor a, a
    ld [wHttpEmptyPolls], a
.skipEmptyCount

    ld a, [wHttpLastCap]
    or a, a
    jr z, .skipGrow
    ld a, [wXferGotLen]
    ld e, a
    ld a, [wHttpRespLen]
    add a, e
    ld [wHttpRespLen], a
.skipGrow

    ld a, [wXferGotLen]
    ld e, a
    ld d, 0
    ld hl, wHttpTotalRecv
    ld a, [hl]
    add a, e
    ld [hl+], a
    ld a, [hl]
    adc a, d
    ld [hl], a

    jr .pollLoop

.fetchDone
    xor a, a
    ret

; Parses whatever HttpFetch collected into wHttpRespBuf and prints a
; one-line summary at HTTP_ADDR (row 5). Never fails -- a response that
; doesn't start with "HTTP/" means the transport worked but there's an
; application-layer mismatch (bad connection, wrong port on the peer's
; side, etc.), which is worth showing but not a reason to abort the rest
; of the sequence, exactly matching gbdk's out->result = MAGB_OK in that
; case (test_isp_http()'s final if/else).
;
; Clobbers: everything (calls PrintString)
HttpShowResult:
    ld a, [wHttpRespLen]
    cp a, 5
    jr c, .noPrefix

    ld hl, wHttpRespBuf
    ld de, sHttpMagic
    ld b, 5
.magicCmp
    ld a, [de]
    inc de
    cp a, [hl]
    jr nz, .noPrefix
    inc hl
    dec b
    jr nz, .magicCmp

    ld a, [wHttpRespLen]
    cp a, 12
    jr c, .short

    ld hl, wHttpStatusMsg
    ld a, "H"
    ld [hl+], a
    ld a, "T"
    ld [hl+], a
    ld a, "T"
    ld [hl+], a
    ld a, "P"
    ld [hl+], a
    ld a, " "
    ld [hl+], a
    ld de, wHttpRespBuf + 9
    ld a, [de]
    ld [hl+], a
    inc de
    ld a, [de]
    ld [hl+], a
    inc de
    ld a, [de]
    ld [hl+], a
    xor a, a
    ld [hl], a

    ld hl, wHttpStatusMsg
    ld de, HTTP_ADDR
    jp PrintString

.short
    ld hl, sHttpShort
    ld de, HTTP_ADDR
    jp PrintString

.noPrefix
    ld hl, sHttpNoPrefix
    ld de, HTTP_ADDR
    jp PrintString

; ---- Status line (row 2) -------------------------------------------------

DEF STATUS_WAKE EQU 0
DEF STATUS_SEND EQU 1
DEF STATUS_WAIT EQU 2
DEF STATUS_READ EQU 3

DEF STATUS_ADDR EQU $9841 ; row 2, col 1
DEF RESULT_ADDR EQU $9881 ; row 4, col 1
DEF HTTP_ADDR   EQU $98A1 ; row 5, col 1 -- HTTP GET's own status/response note
DEF ERROR_ADDR  EQU $98C1 ; row 6, col 1

; Prints one of the short stage names at the fixed status line (row 2),
; overwriting whatever was there before. Called from session.asm at each
; stage of MagbExecute -- the RGBDS equivalent of the previous
; milestone's SetCheckpointColor, just readable instead of a color.
;
; Input: A = STATUS_* index
; Clobbers: everything (calls PrintString)
SetStatus::
    push hl
    push de
    ld hl, StatusStrings
    ld e, a
    ld d, 0
    add hl, de
    add hl, de ; hl = &StatusStrings[index] (2 bytes per entry)
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a ; de = the string pointer
    ld h, d
    ld l, e ; hl = the string pointer (PrintString's expected input)
    ld de, STATUS_ADDR
    call PrintString
    pop de
    pop hl
    ret

StatusStrings:
    dw sStatusWake
    dw sStatusSend
    dw sStatusWait
    dw sStatusRead

sStatusWake: db "WAKE", 0
sStatusSend: db "SEND", 0
sStatusWait: db "WAIT", 0
sStatusRead: db "READ", 0

; ---- Result / error text --------------------------------------------------

sTitle: db "MAGB TEST 2", 0
sPass:  db "RESULT: PASS", 0
sFail:  db "RESULT: FAIL", 0

; Prints the short name for a MAGB_ERR_* code at the fixed error line
; (row 6). Only the codes this milestone's call paths can actually
; produce are covered -- see protocol.inc's result-code comment.
;
; Input: A = MAGB_ERR_* code (1-11)
; Clobbers: everything (calls PrintString)
PrintErrorCode:
    dec a ; codes start at 1; table is 0-based
    ld h, 0
    ld l, a
    add hl, hl ; hl = index*2
    ld de, ErrorStrings
    add hl, de
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a
    ld h, d
    ld l, e
    ld de, ERROR_ADDR
    jp PrintString

ErrorStrings:
    dw sErrTimeout            ; MAGB_ERR_TIMEOUT
    dw sErrBadMagic           ; MAGB_ERR_BAD_MAGIC
    dw sErrBadLength          ; MAGB_ERR_BAD_LENGTH
    dw sErrBadChecksum        ; MAGB_ERR_BAD_CHECKSUM
    dw sErrUnexpectedCommand  ; MAGB_ERR_UNEXPECTED_COMMAND
    dw sErrRemoteUnsupported  ; MAGB_ERR_REMOTE_UNSUPPORTED
    dw sErrRemoteChecksum     ; MAGB_ERR_REMOTE_CHECKSUM
    dw sErrRemoteInternal     ; MAGB_ERR_REMOTE_INTERNAL
    dw sErrSession            ; MAGB_ERR_SESSION
    dw sErrPayloadTooLarge    ; MAGB_ERR_PAYLOAD_TOO_LARGE
    dw sErrRemoteStatus       ; MAGB_ERR_REMOTE_STATUS

sErrTimeout:           db "TIMEOUT", 0
sErrBadMagic:           db "BAD MAGIC", 0
sErrBadLength:          db "BAD LENGTH", 0
sErrBadChecksum:        db "BAD CHECKSUM", 0
sErrUnexpectedCommand:  db "UNEXPECTED CMD", 0
sErrRemoteUnsupported:  db "REMOTE UNSUPPORTED", 0
sErrRemoteChecksum:     db "REMOTE CHECKSUM", 0
sErrRemoteInternal:     db "REMOTE INTERNAL", 0
sErrSession:            db "BAD SESSION ECHO", 0
sErrPayloadTooLarge:    db "PAYLOAD TOO LARGE", 0
sErrRemoteStatus:       db "ADAPTER ERR STATUS", 0

SECTION "HTTP Scratch", WRAM0
wHttpRespBuf: ds HTTP_RESP_BUF_SIZE
wHttpRespLen: db   ; bytes currently held in wHttpRespBuf (0..HTTP_RESP_BUF_SIZE)
wHttpTotalRecv: dw ; total bytes received across every poll (for the 8192 cap)
wHttpEmptyPolls: db
wHttpLastCap: db   ; the capacity HttpFetch's poll loop passed on its most
                    ; recent MagbTransferData call -- MagbTransferData
                    ; clobbers everything, so this can't just live in a
                    ; register across that call
wHttpStatusMsg: ds 9 ; "HTTP " (5) + 3 status digits + null
