; Mobile Adapter GB TestSuite -- RGBDS assembly implementation.
;
; Eighth milestone of the RGBDS port (see rgbds/docs/status.md): a real
; joypad-driven main menu, matching gbdk/src/app/ui.c's ui_main_menu()
; shell (same 6 items, same order, same wording, same title/footer
; layout) instead of running one fixed test straight from boot.
;
; Only two items are backed by a real implementation on this side:
;   ADAPTER/SESSION -- Test 1 (RunAdapterSessionTest, below): Begin
;     Session, capture+show the adapter device id, End Session. Mirrors
;     gbdk's test_adapter_session() output text exactly ("ADAPTER ID:
;     <hex>" / "NINTENDO ECHO OK").
;   ISP/HTTP -- opens a 7-item submenu (RunIspHttpMenu/ShowIspSubMenu,
;     below), matching gbdk's ui_select_submenu()/kIspLabels[] (same
;     wording, same order: Tamago Egg, News Config, News Article,
;     Trainer Home, Email Send, Email Recv, Raw TCP). Tamago Egg and
;     Trainer Home are backed by a real implementation
;     (RunIspHttpCore's full Begin Session -> Read Identity -> Dial ->
;     ISP Login -> DNS -> TCP Open -> HTTP GET -> TCP Close -> ISP
;     Logout -> Hang Up -> End Session sequence); the other five show an
;     honest "NOT IMPLEMENTED" -- see docs/status.md for that gap.
; READ CONFIG, ISP PASSWORD, P2P CALLER, P2P LISTENER, and SELECT's
; trace viewer have no protocol/UI implementation behind them yet on
; this side (no Read Configuration wrapper, no P2P dial/answer, no
; trace ring buffer) -- selecting any of them shows an honest
; "NOT IMPLEMENTED" instead of a fake result (repo-root CLAUDE.md's "No
; Fake Implementations"), rather than being left off the menu; the menu
; shell itself is what needed to match gbdk here, not every item behind
; it yet.
;
; RunIspHttpTest's own screen layout (fixed positions, no
; scrolling/wrapping) is unchanged from the previous milestone:
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
; RunIspHttpTest still stops at the first failing command rather than
; attempting best-effort Hang Up/End Session cleanup after an earlier
; failure -- see rgbds/docs/status.md for why that's a known, deliberate
; simplification for now. B does not cancel a running test (gbdk only
; honors that for P2P Caller/Listener, neither implemented on this side
; yet either) -- B only returns to the menu from an already-finished
; result screen.

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

    ; wMenuSelected is only zeroed here, once -- ShowMenu itself doesn't
    ; touch it, so the highlighted item survives a round trip into a
    ; test and back, matching gbdk's own `static uint8_t sel` in
    ; ui_main_menu() (persists across calls, only ever initialized once).
    xor a, a
    ld [wMenuSelected], a
    ld [wIspPassword], a ; starts empty -- WRAM isn't guaranteed zeroed at boot

    ld hl, sP2pDefaultNumber
    ld de, wP2pNumber
    ld b, 13
.copyP2pDefault
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyP2pDefault

    ; Raw TCP's default IP happens to be the exact same loopback text
    ; gbdk's own TEST_ISP_RAW_IP uses -- reuses sP2pDefaultNumber rather
    ; than a second identical ROM string.
    ld hl, sP2pDefaultNumber
    ld de, wRawTcpIp
    ld b, 13
.copyRawTcpDefault
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyRawTcpDefault

    jp ShowMenu

; ---- Main menu --------------------------------------------------------

; SM83 has no indirect-call instruction -- `call CallHL` pushes the
; return address, then `jp hl` jumps into the handler with that return
; address still on the stack, so the handler's own `ret` returns here
; exactly as if it had been `call`ed directly. Same idiom session.asm
; uses for its status-callback trampoline; kept as a separate copy here
; since that one isn't exported and app-layer code has no business
; reaching into the protocol layer's internals for it anyway.
CallHL:
    jp hl

; Looks up MenuItemAddrs[b] and prints a single character there (a
; cursor glyph, ">" or " ") -- the only thing that actually needs to
; change when the selection moves. ShowMenu's .storeSel uses this twice
; (erase old, draw new) instead of having DrawMenu redraw the whole
; screen on every keypress: every PrintString call turns the LCD off
; and back on, which resets LY to 0, so each call after the first in a
; fast back-to-back run has to wait out a nearly-full new frame before
; it may safely proceed. DrawMenu's own ~14 PrintString calls (title +
; 6 items x 2 + footer) cost roughly that many frames (~230ms) with the
; joypad not being polled at all during the redraw -- long enough to
; drop a real button press made during it. Two calls instead of
; fourteen keeps that window small enough not to matter.
;
; Input: B = item index (0..MENU_ITEM_COUNT-1), HL = cursor string
;        (sCursorOn/sCursorOff)
; Clobbers: everything (calls PrintString)
DrawMenuCursor:
    push hl
    ld a, b
    add a, a
    ld l, a
    ld h, 0
    ld de, MenuItemAddrs
    add hl, de
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a
    pop hl
    jp PrintString

; Draws the title, all MENU_ITEM_COUNT items with '>' on the selected
; one, and the footer hint. Called once per menu entry (boot, or
; returning from a test/stub screen that already cleared and redrew the
; whole display itself) -- ShowMenu's .storeSel uses the much cheaper
; DrawMenuCursor above for a plain selection move instead of calling
; this again.
; Clobbers: everything (calls PrintString repeatedly)
DrawMenu:
    call ClearTextScreen
    ld hl, sMenuTitle1
    ld de, $9800
    call PrintString
    ld hl, sMenuTitle2
    ld de, $9820
    call PrintString

    ld b, 0 ; item index -- PrintString only clobbers A/HL/DE, so B survives it
.itemLoop
    ld hl, sCursorOff
    ld a, [wMenuSelected]
    cp a, b
    jr nz, .drawCursor
    ld hl, sCursorOn
.drawCursor
    call DrawMenuCursor

    ld a, b
    add a, a
    ld l, a
    ld h, 0
    ld de, MenuItemAddrs
    add hl, de
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a
    inc de ; label starts one column after the cursor
    push de
    ld a, b
    add a, a
    ld l, a
    ld h, 0
    ld de, MenuLabels
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    pop de
    call PrintString

    ld a, b
    inc a
    ld b, a
    cp a, MENU_ITEM_COUNT
    jr c, .itemLoop

    ld hl, sMenuFooter
    ld de, $9A00
    jp PrintString

; Blocks until B is newly pressed, then returns -- used after a test's
; result (or "NOT IMPLEMENTED") screen so it stays up until the user is
; done reading it, matching gbdk's ui_prompt_continue()/wait_key_edge()
; (only the B half of that -- nothing here needs A to confirm).
; Clobbers: A
WaitForBackButton:
    call WaitVBlank
    call ReadJoypadPressed
    and a, PAD_B
    jr z, WaitForBackButton
    ret

ShowMenu:
    call DrawMenu

.loop
    call WaitVBlank
    call ReadJoypadPressed
    ld b, a

    ld a, b
    and a, PAD_DOWN
    jr z, .checkUp
    ld a, [wMenuSelected]
    inc a
    cp a, MENU_ITEM_COUNT
    jr c, .storeSel
    xor a, a
    jr .storeSel

.checkUp
    ld a, b
    and a, PAD_UP
    jr z, .checkA
    ld a, [wMenuSelected]
    or a, a
    jr nz, .decSel
    ld a, MENU_ITEM_COUNT
.decSel
    dec a
    jr .storeSel

.checkA
    ld a, b
    and a, PAD_A
    jr z, .checkSelect
    ld a, [wMenuSelected]
    ld l, a
    ld h, 0
    add hl, hl
    ld de, MenuHandlers
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    call CallHL
    jp ShowMenu

.checkSelect
    ld a, b
    and a, PAD_SELECT
    jr z, .loop
    call ShowTrace
    jp ShowMenu

.storeSel
    ld [wMenuNewSel], a

    ld a, [wMenuSelected]
    ld b, a
    ld hl, sCursorOff
    call DrawMenuCursor ; erase the cursor at the old position

    ld a, [wMenuNewSel]
    ld [wMenuSelected], a
    ld b, a
    ld hl, sCursorOn
    call DrawMenuCursor ; draw it at the new position

    jp .loop

; ---- Test 1: Adapter / Session --------------------------------------------
;
; Wake -> Begin Session -> capture+show the adapter device id -> End
; Session, matching repo-root CLAUDE.md's Test 1 flow and gbdk's own
; test_adapter_session() (src/app/test_runner.c) -- same title, same
; "ADAPTER ID: <hex>" / "NINTENDO ECHO OK" success detail text. Doesn't
; touch the phone line at all (no Dial/Hangup) -- the smallest possible
; real exchange with the adapter, useful for confirming basic
; wiring/wake/ACK behavior before attempting the full ISP/HTTP sequence.
;
; End Session's own result is discarded (matches gbdk's
; `(void)magb_end_session(ctx);`) and only even attempted after a
; successful Begin Session, unlike gbdk which always attempts it --
; sending End Session for a session that never began isn't a real
; cleanup path this milestone models; matches this ROM's existing
; "stop at the first failure" simplification elsewhere.
; Clobbers: everything
RunAdapterSessionTest:
    call ClearTextScreen
    ld hl, sMenuAdapterSession
    ld de, $9800
    call PrintString

    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jr nz, .fail

    ld hl, sAdapterIdLabel
    ld de, HTTP_ADDR
    call PrintString
    ld a, [wAdapterDevice]
    ld de, HTTP_ADDR + 12 ; right after "ADAPTER ID: " (12 chars)
    call PrintHexByte

    ld hl, sNintendoEchoOk
    ld de, ERROR_ADDR
    call PrintString

    call MagbEndSession ; best-effort -- result discarded, see comment above

    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

.fail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

; Generic "not implemented" screen for menu items with no real protocol/
; UI implementation behind them yet on this side (see docs/status.md) --
; shows the real title so it's clear the button worked, then an honest
; "NOT IMPLEMENTED" rather than a fake PASS (repo-root CLAUDE.md's
; "No Fake Implementations").
;
; Input: HL = title string pointer
; Clobbers: everything
ShowNotImplemented:
    push hl
    call ClearTextScreen
    pop hl
    ld de, $9800
    call PrintString
    ld hl, sNotImplemented
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

; ---- Protocol trace (SELECT) -----------------------------------------
;
; Shows the most recent TRACE_SHOWN_PAIRS TX/RX byte pairs recorded by
; session.asm's RecordTraceByte (every byte TracedTransferByte moves
; over the wire, TX then RX, in order), one "TX xx RX xx" line per pair
; -- same shape and page size as gbdk's ui_show_trace(). MAGB_TRACE_LEN
; (128) is a power of two, so the ring buffer's wraparound is a plain
; AND instead of a modulo.
;
; Deliberately reads session.asm's wTraceHead/wTraceCount/wTraceBuf
; directly rather than adding protocol-layer "give me trace entry N"
; accessors -- matches gbdk's own ui_show_trace()/trace_physical_index(),
; which index ctx->trace[] directly from the UI layer too.
; Clobbers: everything
DEF TRACE_SHOWN_PAIRS EQU 14

ShowTrace:
    call ClearTextScreen
    ld hl, sTraceTitle
    ld de, $9800
    call PrintString

    ld a, [wTraceCount]
    or a, a
    jp z, .empty

    ld a, [wTraceCount]
    srl a ; total_pairs = trace_count / 2
    ld [wTraceTotalPairs], a

    cp a, TRACE_SHOWN_PAIRS
    jr nc, .clampStart
    xor a, a
    jr .haveStart
.clampStart
    sub a, TRACE_SHOWN_PAIRS
.haveStart
    ld [wTraceRowIndex], a ; loop counter i, starts at start_pair

    ld a, [wTraceCount]
    cp a, MAGB_TRACE_LEN
    jr c, .oldestZero
    ld a, [wTraceHead] ; buffer already wrapped once: head IS the oldest slot
    jr .haveOldest
.oldestZero
    xor a, a
.haveOldest
    ld [wTraceOldest], a

    ld a, low($9840) ; row 2, col 0 -- row 0 is the title, row 1 left blank
    ld [wTraceRowAddr], a
    ld a, high($9840)
    ld [wTraceRowAddr + 1], a

.rowLoop
    ; idx_tx = (oldest + i*2) & (MAGB_TRACE_LEN-1); idx_rx = idx_tx+1 (same AND)
    ld a, [wTraceRowIndex]
    add a, a
    ld c, a
    ld a, [wTraceOldest]
    add a, c
    and a, MAGB_TRACE_LEN - 1
    ld [wTraceIdxTx], a
    inc a
    and a, MAGB_TRACE_LEN - 1
    ld [wTraceIdxRx], a

    ld hl, sTraceTxLabel ; "TX " -- columns 0-2
    ld a, [wTraceRowAddr]
    ld e, a
    ld a, [wTraceRowAddr + 1]
    ld d, a
    call PrintString

    ld a, [wTraceIdxTx]
    call TraceEntryValue ; -> A = trace[idx].value
    ld b, a
    ld a, [wTraceRowAddr]
    add a, 3 ; column 3-4
    ld e, a
    ld a, [wTraceRowAddr + 1]
    adc a, 0
    ld d, a
    ld a, b
    call PrintHexByte

    ld hl, sTraceRxLabel ; " RX " -- columns 5-8
    ld a, [wTraceRowAddr]
    add a, 5
    ld e, a
    ld a, [wTraceRowAddr + 1]
    adc a, 0
    ld d, a
    call PrintString

    ld a, [wTraceIdxRx]
    call TraceEntryValue
    ld b, a
    ld a, [wTraceRowAddr]
    add a, 9 ; column 9-10
    ld e, a
    ld a, [wTraceRowAddr + 1]
    adc a, 0
    ld d, a
    ld a, b
    call PrintHexByte

    ld a, [wTraceRowAddr]
    add a, 32 ; next tilemap row
    ld [wTraceRowAddr], a
    ld a, [wTraceRowAddr + 1]
    adc a, 0
    ld [wTraceRowAddr + 1], a

    ld a, [wTraceRowIndex]
    inc a
    ld [wTraceRowIndex], a
    ld b, a
    ld a, [wTraceTotalPairs]
    cp a, b
    jr nz, .rowLoop

    jr .showBackHint

.empty
    ld hl, sTraceEmpty
    ld de, $9840
    call PrintString

.showBackHint
    ld hl, sTraceBackHint
    ld de, $9A00
    call PrintString
    jp WaitForBackButton

; Input: A = trace ring-buffer index (0..MAGB_TRACE_LEN-1)
; Output: A = trace[index].value
; Clobbers: HL, BC
TraceEntryValue:
    ld l, a
    ld h, 0
    add hl, hl ; *2 (2 bytes per entry: direction, value)
    ld bc, wTraceBuf + 1
    add hl, bc
    ld a, [hl]
    ret

; ---- Read Configuration Data (0x19) ----------------------------------------
;
; Begin Session -> Read Configuration Data (both 96-byte halves,
; MagbReadConfig) -> verify the blob's own trailing checksum
; (MagbConfigChecksumOk, config.asm) -> End Session. Matches gbdk's
; test_read_config()'s real success text ("192 BYTES READ"); gbdk then
; shows a full field-by-field config screen (ui_show_config()) this side
; doesn't have yet (see docs/status.md) -- shown instead as a real,
; computed "CHECKSUM OK"/"CHECKSUM BAD" line, which is at least as
; meaningful a pass/fail signal and doesn't require decoding the blob's
; field layout (BCD phone slots, registration state, ...) first.
;
; End Session is only attempted after a successful read (unlike gbdk,
; which always attempts it) -- matches this ROM's existing "stop at the
; first failure" simplification elsewhere.
; Clobbers: everything
RunReadConfigTest:
    call ClearTextScreen
    ld hl, sMenuReadConfig
    ld de, $9800
    call PrintString

    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jr nz, .fail

    call MagbReadConfig
    or a, a
    jr nz, .fail

    call MagbEndSession ; best-effort -- result discarded, see comment above
    jp ShowConfigScreen ; success: paged field viewer instead of a PASS line

.fail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

; ---- Config screen (RunReadConfigTest's success path) ---------------------
;
; A paged field-by-field view of the 192-byte blob RunReadConfigTest
; just read into wConfigData, matching gbdk's ui_show_config() -- same
; 3 pages (session/network, mail, ISP dial slot 1), same fields, same
; field offsets (protocol.inc's MAGB_CONFIG_OFF_*). LEFT/RIGHT changes
; page (wrapping), A or B exits back to the menu. Simplifications
; from gbdk's version: no "(ascii)" rendering of the 2 magic bytes next
; to their hex (always the fixed 0x99/0x66, low information value, and
; this font has no lowercase for when a byte like 'f' would need it
; anyway), and the checksum line always fits on the one page it's
; already showing DNS/login info on, so there's no separate line-wrap
; workaround needed here the way gbdk's fixed-width printf hit.
DEF CONFIG_PAGE_COUNT EQU 3

ShowConfigScreen:
    xor a, a
    ld [wConfigPage], a
    call DrawConfigPage

.loop
    call WaitVBlank
    call ReadJoypadPressed
    ld b, a

    ld a, b
    and a, PAD_LEFT
    jr z, .checkRight
    ld a, [wConfigPage]
    or a, a
    jr nz, .decPage
    ld a, CONFIG_PAGE_COUNT
.decPage
    dec a
    jr .storePage

.checkRight
    ld a, b
    and a, PAD_RIGHT
    jr z, .checkExit
    ld a, [wConfigPage]
    inc a
    cp a, CONFIG_PAGE_COUNT
    jr c, .storePage
    xor a, a
    jr .storePage

.checkExit
    ld a, b
    and a, PAD_A | PAD_B
    jr z, .loop
    ret

.storePage
    ld [wConfigPage], a
    call DrawConfigPage
    jr .loop

; Clears the screen, draws the title (with the current page number),
; the footer hint, and dispatches to the current page's fields.
; Clobbers: everything
DrawConfigPage:
    call ClearTextScreen

    ld a, [wConfigPage]
    ld l, a
    ld h, 0
    add hl, hl
    ld de, ConfigPageTitles
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ld de, $9800
    call PrintString

    ld hl, sConfigFooter
    ld de, $9A00
    call PrintString

    ld a, [wConfigPage]
    or a, a
    jp z, DrawConfigPage0
    cp a, 1
    jp z, DrawConfigPage1
    jp DrawConfigPage2

ConfigPageTitles:
    dw sConfigTitle1
    dw sConfigTitle2
    dw sConfigTitle3

; ---- Page 1/3: header, registration, DNS, login id, checksum --------------
DrawConfigPage0:
    ld hl, sHdrLabel
    ld de, $9840
    call PrintString
    ld a, [wConfigData + MAGB_CONFIG_OFF_MAGIC]
    ld de, $9840 + 5
    call PrintHexByte
    ld a, [wConfigData + MAGB_CONFIG_OFF_MAGIC + 1]
    ld de, $9840 + 8
    call PrintHexByte

    ld hl, sRegStateLabel
    ld de, $9860
    call PrintString
    ld a, [wConfigData + MAGB_CONFIG_OFF_REG_STATE]
    ld de, $9860 + 10
    push af
    call PrintHexByte
    pop af
    cp a, MAGB_REG_STATE_COMPLETE
    jr z, .regComplete
    cp a, MAGB_REG_STATE_PENDING
    jr z, .regPending
    ld hl, sRegNone
    jr .showReg
.regComplete
    ld hl, sRegComplete
    jr .showReg
.regPending
    ld hl, sRegPending
.showReg
    ld de, $9860 + 12
    call PrintString

    ld hl, sDns1Label
    ld de, $9880
    call PrintString
    ld hl, wConfigData + MAGB_CONFIG_OFF_DNS1
    ld de, $9880 + 5
    call PrintDottedQuad

    ld hl, sDns2Label
    ld de, $98A0
    call PrintString
    ld hl, wConfigData + MAGB_CONFIG_OFF_DNS2
    ld de, $98A0 + 5
    call PrintDottedQuad

    ld hl, sLoginIdLabel
    ld de, $98E0
    call PrintString
    ld hl, wConfigData + MAGB_CONFIG_OFF_LOGIN_ID
    ld b, MAGB_CONFIG_LOGIN_ID_LEN
    ld de, $9900
    call PrintAsciiField

    call MagbConfigChecksumOk
    or a, a
    jr z, .checksumBad
    ld hl, sConfigChecksumOk
    jr .showChecksum
.checksumBad
    ld hl, sConfigChecksumBad
.showChecksum
    ld de, $9940
    jp PrintString

; ---- Page 2/3: email, SMTP, POP --------------------------------------------
DrawConfigPage1:
    ld hl, sEmailLabel
    ld de, $9840
    call PrintString
    ld hl, wConfigData + MAGB_CONFIG_OFF_EMAIL
    ld b, 20
    ld de, $9860
    call PrintAsciiField
    ld hl, wConfigData + MAGB_CONFIG_OFF_EMAIL + 20
    ld b, MAGB_CONFIG_EMAIL_LEN - 20
    ld de, $9880
    call PrintAsciiField

    ld hl, sSmtpLabel
    ld de, $98C0
    call PrintString
    ld hl, wConfigData + MAGB_CONFIG_OFF_SMTP
    ld b, MAGB_CONFIG_SMTP_LEN
    ld de, $98E0
    call PrintAsciiField

    ld hl, sPopLabel
    ld de, $9920
    call PrintString
    ld hl, wConfigData + MAGB_CONFIG_OFF_POP
    ld b, MAGB_CONFIG_POP_LEN
    ld de, $9940
    jp PrintAsciiField

; ---- Page 3/3: Configuration Slot 1 (the ISP dial string Mobile
; Trainer actually configured, not this ROM's own compile-time default
; -- Dial (0x12) still sends the compile-time default; nothing cross-
; checks the two yet, shown here purely for comparison) ---------------
DrawConfigPage2:
    ld hl, sSlotPhoneLabel
    ld de, $9840
    call PrintString

    ld hl, wConfigData + MAGB_CONFIG_OFF_SLOT1
    ld de, wPhoneScratch
    call MagbConfigDecodePhone
    or a, a
    jr nz, .havePhone
    ld hl, sConfigEmpty
    jr .printPhone
.havePhone
    ld hl, wPhoneScratch
.printPhone
    ld de, $9860
    call PrintString

    ld hl, sSlotIdLabel
    ld de, $98A0
    call PrintString
    ld hl, wConfigData + MAGB_CONFIG_OFF_SLOT1 + MAGB_CONFIG_SLOT_PHONE_LEN
    ld b, MAGB_CONFIG_SLOT_ID_LEN
    ld de, $98C0
    jp PrintAsciiField

sConfigTitle1: db "ADAPTER CONFIG 1/3", 0
sConfigTitle2: db "ADAPTER CONFIG 2/3", 0
sConfigTitle3: db "ADAPTER CONFIG 3/3", 0
sConfigFooter: db "L/R:PAGE A/B:MENU", 0
sConfigEmpty:  db "(EMPTY)", 0

sHdrLabel:      db "HDR: ", 0
sRegStateLabel: db "REG STATE:", 0
sRegComplete:   db " (REG)", 0
sRegPending:    db " (PENDING)", 0
sRegNone:       db " (NONE)", 0
sDns1Label:     db "DNS1 ", 0
sDns2Label:     db "DNS2 ", 0
sLoginIdLabel:  db "LOGIN ID:", 0

sEmailLabel: db "EMAIL:", 0
sSmtpLabel:  db "SMTP:", 0
sPopLabel:   db "POP:", 0

sSlotPhoneLabel: db "SLOT 1 PHONE:", 0
sSlotIdLabel:    db "SLOT 1 ID:", 0

; ---- ISP PASSWORD (menu item) ----------------------------------------
;
; Real ISP account password, edited in place with EditText below and
; kept only in wIspPassword -- matches gbdk's own isp_password[]:
; starts EMPTY (no compiled-in default; a real account secret is never
; a guessable constant, repo-root memory's "Never invent credentials"),
; RAM-only (this ROM has no mapper/save, resets to empty on power-off),
; capped at ISP_PASSWORD_MAX_LEN(8) matching gbdk's
; TEST_ISP_PASSWORD_MAX_LEN. Nothing on this side reads it yet -- no
; GB00-authenticated test (News/Email/Trainer Home) has been ported
; here (see docs/status.md) -- so this editor is real and functional on
; its own terms, just not wired to a consumer yet, the same shape as
; gbdk's UI_MENU_ISP_PASSWORD case in main.c before any GB00 test runs.
DEF ISP_PASSWORD_MAX_LEN EQU 8

RunIspPasswordEdit:
    ld hl, wIspPassword
    ld b, ISP_PASSWORD_MAX_LEN + 1 ; buf_cap, including the NUL
    ld de, sMenuIspPassword
    jp EditText

; In-place editor for a short fixed-capacity text field -- UP/DOWN
; cycles the character under the cursor through sTextCharset below
; (space, then lowercase, then uppercase, then digits -- same order and
; same charset as gbdk's kTextCharset, now that this font actually has
; lowercase tiles), LEFT/RIGHT moves the cursor (wrapping), A saves
; (trailing spaces trimmed) and returns, B leaves the buffer unchanged
; and returns. The RGBDS-side equivalent of gbdk's ui_edit_text(), with
; one real difference: no held-direction auto-repeat (gbdk's
; wait_key_repeat()) -- one press moves the cursor/cycles one step.
; Simpler edge-triggered polling only, same as everywhere else in this
; ROM's UI.
;
; Input: HL = buffer (NUL-terminated on entry, may be empty), B = buffer
;        capacity including the NUL (capped at EDIT_TEXT_MAX_LEN+1),
;        DE = label string pointer
; Clobbers: everything
DEF EDIT_TEXT_MAX_LEN EQU 20 ; matches gbdk's UI_EDIT_TEXT_MAX_LEN

EditText:
    ld a, l
    ld [wEditBufPtr], a
    ld a, h
    ld [wEditBufPtr + 1], a
    ld a, e
    ld [wEditLabelPtr], a
    ld a, d
    ld [wEditLabelPtr + 1], a

    ld a, b
    dec a
    cp a, EDIT_TEXT_MAX_LEN
    jr c, .capOk
    ld a, EDIT_TEXT_MAX_LEN
.capOk
    ld [wEditMaxLen], a
    ld b, a ; b = max_len, this function's loop bound throughout setup

    ld c, 0 ; chars copied so far
    ld de, wEditWork
.copyLoop
    ld a, c
    cp a, b
    jr nc, .padLoop
    ld a, [hl]
    or a, a
    jr z, .padLoop
    ld [de], a
    inc hl
    inc de
    inc c
    jr .copyLoop
.padLoop
    ld a, c
    cp a, b
    jr nc, .terminate
    ld a, " "
    ld [de], a
    inc de
    inc c
    jr .padLoop
.terminate
    xor a, a
    ld [de], a ; wEditWork[max_len] = 0
    ld [wEditCursor], a ; cursor = 0

    call DrawEditScreen

.loop
    call WaitVBlank
    call ReadJoypadPressed
    ld b, a
    or a, a
    jr z, .loop

    ld a, b
    and a, PAD_LEFT
    jr z, .checkRight
    ld a, [wEditCursor]
    or a, a
    jr nz, .decCursor
    ld a, [wEditMaxLen]
.decCursor
    dec a
    ld [wEditCursor], a
    call DrawEditScreen
    jr .loop

.checkRight
    ld a, b
    and a, PAD_RIGHT
    jr z, .checkUp
    ld a, [wEditCursor]
    inc a
    ld c, a
    ld a, [wEditMaxLen]
    cp a, c
    jr nz, .haveRight
    ld c, 0
.haveRight
    ld a, c
    ld [wEditCursor], a
    call DrawEditScreen
    jr .loop

.checkUp
    ld a, b
    and a, PAD_UP
    jr z, .checkDown
    ld a, [wEditCursor]
    ld e, a
    ld d, 0
    ld hl, wEditWork
    add hl, de
    ld a, [hl]
    push hl
    call CharsetIndex
    inc a
    cp a, TEXT_CHARSET_LEN
    jr nz, .upIdxOk
    xor a, a
.upIdxOk
    ld e, a
    ld d, 0
    ld hl, sTextCharset
    add hl, de
    ld a, [hl]
    pop hl
    ld [hl], a
    call DrawEditScreen
    jr .loop

.checkDown
    ld a, b
    and a, PAD_DOWN
    jr z, .checkA
    ld a, [wEditCursor]
    ld e, a
    ld d, 0
    ld hl, wEditWork
    add hl, de
    ld a, [hl]
    push hl
    call CharsetIndex
    or a, a
    jr nz, .downIdxOk
    ld a, TEXT_CHARSET_LEN
.downIdxOk
    dec a
    ld e, a
    ld d, 0
    ld hl, sTextCharset
    add hl, de
    ld a, [hl]
    pop hl
    ld [hl], a
    call DrawEditScreen
    jp .loop

.checkA
    ld a, b
    and a, PAD_A
    jr z, .checkB

    ld a, [wEditMaxLen]
    ld c, a
.trimLoop
    ld a, c
    or a, a
    jr z, .trimDone
    ld e, a
    dec e
    ld d, 0
    ld hl, wEditWork
    add hl, de
    ld a, [hl]
    cp a, " "
    jr nz, .trimDone
    dec c
    jr .trimLoop
.trimDone
    ld a, [wEditBufPtr]
    ld e, a
    ld a, [wEditBufPtr + 1]
    ld d, a
    ld hl, wEditWork
    ld b, c
    ld a, b
    or a, a
    jr z, .copyDone
.copyLoop2
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyLoop2
.copyDone
    xor a, a
    ld [de], a
    ret

.checkB
    ld a, b
    and a, PAD_B
    jp z, .loop
    ret

; Redraws the whole edit screen: label, the work-in-progress text, the
; cursor, and the control hint. Called once on entry and again after
; every change -- an input event, not a hot path.
; Clobbers: everything
DrawEditScreen:
    call ClearTextScreen

    ld a, [wEditLabelPtr]
    ld l, a
    ld a, [wEditLabelPtr + 1]
    ld h, a
    ld de, $9800
    call PrintString

    ld hl, wEditWork
    ld de, $9860 ; row 3
    call PrintString

    ld a, [wEditCursor]
    ld e, a
    ld d, 0
    ld hl, $9880 ; row 4, col 0 + cursor
    add hl, de
    ld d, h
    ld e, l
    ld hl, sCursorOn
    call PrintString

    ld hl, sEditHint1
    ld de, $98E0 ; row 7
    call PrintString
    ld hl, sEditHint2
    ld de, $9900 ; row 8
    call PrintString
    ld hl, sEditHint3
    ld de, $9920 ; row 9
    jp PrintString

; Input: A = character
; Output: A = its index in sTextCharset (0 if not found -- shouldn't
;         happen for a character this same editor put there)
; Clobbers: BC, HL
CharsetIndex:
    ld c, a
    ld hl, sTextCharset
    ld b, 0
.loop
    ld a, [hl+]
    cp a, c
    jr z, .found
    inc b
    ld a, b
    cp a, TEXT_CHARSET_LEN
    jr nz, .loop
    ld b, 0
.found
    ld a, b
    ret

; Space first (the "blank slot" sentinel used to pad unused positions),
; then lowercase, then uppercase, then digits -- matches gbdk's
; kTextCharset order exactly (most real account passwords are
; lowercase, per that file's own comment).
DEF TEXT_CHARSET_LEN EQU 63
sTextCharset: db " abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

sEditHint1: db "L/R:MOVE", 0
sEditHint2: db "U/D:CHAR", 0
sEditHint3: db "A:OK B:BACK", 0

; ---- MATS: TestSuite-only P2P payload framing --------------------------
;
; Carried *inside* MAGB Transfer Data (0x15) payloads on the P2P
; connection id -- not part of the Mobile Adapter protocol itself, and
; not something a real Mobile Adapter/libmobile ever sees or interprets
; (it's just this ROM's own bytes, echoed back by whatever's on the
; other end of the P2P link -- another instance of this same ROM, or of
; gbdk's, which defines the identical framing in test_runner.c so the
; two interoperate). Exact same layout as gbdk: magic "MATS", a version
; byte, a sequence byte, a length byte, then up to MATS_MAX_PAYLOAD
; payload bytes.
DEF MATS_HEADER_LEN EQU 7 ; magic(4) + version(1) + sequence(1) + length(1)
DEF MATS_MAX_PAYLOAD EQU 16 ; covers the "HELLO WORLD" (11 bytes) exchange below
DEF MATS_VERSION EQU 1

; Input: A = sequence, HL = payload ptr, C = payload length (0..MATS_MAX_PAYLOAD)
; Output: wMatsFrame holds the built frame, B = its total length
; Clobbers: everything
MatsBuild:
    ld [wMatsSeqScratch], a
    ld de, wMatsFrame
    ld a, "M"
    ld [de], a
    inc de
    ld a, "A"
    ld [de], a
    inc de
    ld a, "T"
    ld [de], a
    inc de
    ld a, "S"
    ld [de], a
    inc de
    ld a, MATS_VERSION
    ld [de], a
    inc de
    ld a, [wMatsSeqScratch]
    ld [de], a
    inc de
    ld a, c
    ld [de], a
    inc de

    ld a, c
    or a, a
    jr z, .noPayload
    ld b, a
.copyLoop
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyLoop
.noPayload
    ld a, c
    add a, MATS_HEADER_LEN
    ld b, a
    ret

; Input: HL = source bytes, B = source length
; Output: A = 1 if a valid MATS frame was parsed, 0 otherwise; on
;         success [wMatsRecvSeq]/[wMatsRecvLen]/wMatsRecvPayload hold
;         the parsed sequence/length/payload
; Clobbers: everything
MatsParse:
    ld a, b
    ld [wMatsInLen], a
    cp a, MATS_HEADER_LEN
    jr c, .bad

    ld a, [hl+]
    cp a, "M"
    jr nz, .bad
    ld a, [hl+]
    cp a, "A"
    jr nz, .bad
    ld a, [hl+]
    cp a, "T"
    jr nz, .bad
    ld a, [hl+]
    cp a, "S"
    jr nz, .bad
    ld a, [hl+]
    cp a, MATS_VERSION
    jr nz, .bad

    ld a, [hl+]
    ld [wMatsRecvSeq], a

    ld a, [hl+] ; declared payload length
    cp a, MATS_MAX_PAYLOAD + 1
    jr nc, .bad

    ld c, a ; c = declared payload len (survives the availability check below)
    ld a, [wMatsInLen]
    sub a, MATS_HEADER_LEN ; a = bytes actually available past the header
    cp a, c
    jr c, .bad ; available < declared

    ld b, c
    ld a, b
    or a, a
    jr z, .noPayload
    ld de, wMatsRecvPayload
.copyLoop
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyLoop
.noPayload
    ld a, c
    ld [wMatsRecvLen], a
    ld a, 1
    ret
.bad
    xor a, a
    ret

; Builds a MATS frame and sends it as one Transfer Data call on the P2P
; connection id. Matches gbdk's p2p_send_frame() -- MAGB_TIMEOUT_FRAMES_SHORT
; here (not _LONG): this is one local serial exchange with this Game
; Boy's own adapter, not a wait on the far end (P2pRecvFrame below is
; where waiting on the far end actually happens, deliberately unbounded).
;
; Input: A = sequence, HL = payload ptr, C = payload length
; Output: A = result (0=OK)
; Clobbers: everything
P2pSendFrame:
    call MatsBuild
    ld a, b
    ld c, a

    ld a, MAGB_P2P_CONNECTION_ID
    ld [wTcpConnId], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT >> 8
    ld [wExecTimeoutFrames + 1], a

    ld de, wMatsFrame
    ld hl, wP2pDiscardByte
    ld b, 0 ; output cap 0: discard any response payload, matching gbdk
    jp MagbTransferData

; Polls Transfer Data (zero-length sends) on the P2P connection until a
; valid MATS frame arrives, the remote closes, or B is pressed.
; Deliberately UNBOUNDED other than the B check -- matches gbdk's
; p2p_recv_frame() exactly, for a real, hard-won reason (see
; protocol.inc's MAGB_TIMEOUT_FRAMES_P2P_CALL comment and
; docs/status.md): a real two-machine test proved the two independently
; -run peers do not reach each protocol step in lockstep, and giving up
; here tears the connection down under whichever side is still waiting,
; which then shows up as a real adapter Error Status on the *other*
; side instead of a clean timeout. Each individual poll is still
; bounded by MAGB_TIMEOUT_FRAMES_SHORT internally (MagbTransferData's
; own MagbExecute call), so a genuinely dead local adapter still
; surfaces as MAGB_ERR_TIMEOUT here, never a permanent hang.
;
; Output: A = result (0=OK); on success wMatsRecvSeq/wMatsRecvLen/
;         wMatsRecvPayload hold the parsed frame
; Clobbers: everything
P2pRecvFrame:
    call ReadJoypadPressed
    and a, PAD_B
    jr z, .noCancel
    ld a, MAGB_ERR_CANCELLED
    ret
.noCancel
    ld a, MAGB_P2P_CONNECTION_ID
    ld [wTcpConnId], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT >> 8
    ld [wExecTimeoutFrames + 1], a

    ld de, 0
    ld c, 0 ; zero-length send: a poll
    ld hl, wP2pPollBuf
    ld b, MATS_HEADER_LEN + MATS_MAX_PAYLOAD
    call MagbTransferData
    or a, a
    ret nz

    ld a, [wXferRemoteClosed]
    or a, a
    jr z, .checkGotLen
    ld a, MAGB_ERR_P2P
    ret
.checkGotLen
    ld a, [wXferGotLen]
    or a, a
    jr nz, .haveFrame

    call WaitVBlank ; nothing yet -- space polls out, don't spin at full CPU speed
    jp P2pRecvFrame

.haveFrame
    ld hl, wP2pPollBuf
    ld a, [wXferGotLen]
    ld b, a
    call MatsParse
    or a, a
    jr nz, .parsed
    ld a, MAGB_ERR_P2P
    ret
.parsed
    xor a, a
    ret

; Best-effort teardown after a P2P test finishes (pass or fail) --
; matches gbdk's p2p_cleanup(): Hang Up then End Session, neither
; result checked (same reasoning as RunIspHttpTest's own cleanup, see
; docs/status.md's "TCP Close after Transfer Data End" hard-won bug).
; Clobbers: everything
P2pCleanup:
    call MagbHangup
    jp MagbEndSession

; ---- Test 3: P2P Caller ----------------------------------------------
;
; Begin Session -> Dial (the edited P2P number, MAGB_TIMEOUT_FRAMES_P2P_CALL)
; -> PING/PONG -> an 8-byte binary test pattern (0x00/0x01/0x55/0xAA/
; 0xFE/0xFF/0x10/0xEF, same bytes gbdk uses -- covers both all-zero/
; all-one-bit and alternating-bit edge cases) -> a human-readable
; "HELLO WORLD" round trip (adds no new protocol coverage over the
; pattern step; it's here purely so the result screen can show an
; actual message that made it across the link and back) -> Hang Up ->
; End Session. Matches gbdk's test_p2p_caller() sequence and byte
; patterns exactly, so this side and a gbdk-built ROM can interoperate.
;
; Lets the user cancel out of the number editor (B) without dialing at
; all; once dialing starts, only the P2P_WAIT_CALL/P2pRecvFrame B-checks
; below can still cancel.
RunP2pCaller:
    ld hl, wP2pNumber
    ld de, sMenuP2pCaller
    call EditNumber
    or a, a
    ret z ; cancelled -- back to the menu, buffer unchanged

    call ClearTextScreen
    ld hl, sMenuP2pCaller
    ld de, $9800
    call PrintString

    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jp nz, .fail

    ld a, MAGB_TIMEOUT_FRAMES_P2P_CALL & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_P2P_CALL >> 8
    ld [wExecTimeoutFrames + 1], a
    ld hl, wP2pNumber
    ld b, 0
.numLenLoop
    ld a, [hl+]
    or a, a
    jr z, .haveNumLen
    inc b
    jr .numLenLoop
.haveNumLen
    ld hl, wP2pNumber
    call MagbDial
    or a, a
    jp nz, .failNoSession

    ld a, 1
    ld hl, sPing
    ld c, 4
    call P2pSendFrame
    or a, a
    jp nz, .failNoSession

    call P2pRecvFrame
    or a, a
    jr nz, .failNoSession
    ld a, [wMatsRecvLen]
    cp a, 4
    jr nz, .badFrameNoSession
    ld hl, wMatsRecvPayload
    ld de, sPong
    ld b, 4
    call MemCompare
    or a, a
    jr nz, .badFrameNoSession

    ld a, 2
    ld hl, sP2pPattern
    ld c, 8
    call P2pSendFrame
    or a, a
    jr nz, .failNoSession

    call P2pRecvFrame
    or a, a
    jr nz, .failNoSession
    ld a, [wMatsRecvLen]
    cp a, 8
    jr nz, .badFrameNoSession
    ld hl, wMatsRecvPayload
    ld de, sP2pPattern
    ld b, 8
    call MemCompare
    or a, a
    jr nz, .badFrameNoSession

    ld a, 3
    ld hl, sHelloWorld
    ld c, sHelloWorldEnd - sHelloWorld
    call P2pSendFrame
    or a, a
    jr nz, .failNoSession

    call P2pRecvFrame
    or a, a
    jr nz, .failNoSession
    ld a, [wMatsRecvLen]
    cp a, sHelloWorldEnd - sHelloWorld
    jr nz, .badFrameNoSession
    ld hl, wMatsRecvPayload
    ld de, sHelloWorld
    ld b, sHelloWorldEnd - sHelloWorld
    call MemCompare
    or a, a
    jr nz, .badFrameNoSession

    call P2pCleanup

    ld hl, sHelloWorldOk
    ld de, HTTP_ADDR
    call PrintString
    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

.badFrameNoSession
    ld a, MAGB_ERR_P2P
.failNoSession
    push af
    call P2pCleanup
    pop af
    jr .showP2pFail

.fail
    push af
.showP2pFail
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    push af
    call PrintErrorCode
    pop af
    cp a, MAGB_ERR_REMOTE_STATUS
    jr nz, .noRemoteDetail
    ld hl, sP2pRemoteErrLabel
    ld de, HTTP_ADDR
    call PrintString
    ld a, [wRemoteErrorCommand]
    ld de, HTTP_ADDR + 4
    call PrintHexByte
    ld hl, sP2pRemoteErrMid
    ld de, HTTP_ADDR + 6
    call PrintString
    ld a, [wRemoteErrorCode]
    ld de, HTTP_ADDR + 11
    call PrintHexByte
.noRemoteDetail
    jp WaitForBackButton

; ---- Test 3: P2P Listener ----------------------------------------------
;
; Begin Session -> Wait For Telephone Call (retried up to
; P2P_WAIT_CALL_MAX_ATTEMPTS times -- libmobile's own handler only waits
; ~1s before an Error Status meaning "no call yet", unlike Dial, so this
; ROM supplies the retry loop, matching gbdk's test_p2p_listener())
; -> receive PING, reply PONG -> receive the pattern, echo it back
; -> receive "HELLO WORLD", echo it back -> Hang Up -> End Session.
; No number to enter -- this side answers, it doesn't dial.
DEF P2P_WAIT_CALL_MAX_ATTEMPTS EQU 20

RunP2pListener:
    call ClearTextScreen
    ld hl, sMenuP2pListener
    ld de, $9800
    call PrintString

    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jp nz, .fail

    ld b, P2P_WAIT_CALL_MAX_ATTEMPTS
.waitCallLoop
    call MagbWaitForCall
    cp a, MAGB_ERR_REMOTE_STATUS
    jr nz, .waitCallDone
    dec b
    jr nz, .waitCallLoop
.waitCallDone
    or a, a
    jr nz, .failNoSession

    call P2pRecvFrame
    or a, a
    jr nz, .failNoSession
    ld a, [wMatsRecvLen]
    cp a, 4
    jr nz, .badFrameNoSession
    ld hl, wMatsRecvPayload
    ld de, sPing
    ld b, 4
    call MemCompare
    or a, a
    jr nz, .badFrameNoSession

    ld a, [wMatsRecvSeq]
    ld hl, sPong
    ld c, 4
    call P2pSendFrame
    or a, a
    jr nz, .failNoSession

    call P2pRecvFrame
    or a, a
    jr nz, .failNoSession
    ld a, [wMatsRecvSeq]
    ld hl, wMatsRecvPayload
    ld c, 8
    call P2pSendFrame
    or a, a
    jr nz, .failNoSession

    call P2pRecvFrame
    or a, a
    jr nz, .failNoSession
    ld a, [wMatsRecvSeq]
    ld hl, wMatsRecvPayload
    ld c, sHelloWorldEnd - sHelloWorld
    call P2pSendFrame
    or a, a
    jr nz, .failNoSession

    call P2pCleanup

    ld hl, sHelloWorldOk
    ld de, HTTP_ADDR
    call PrintString
    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

.badFrameNoSession
    ld a, MAGB_ERR_P2P
.failNoSession
    push af
    call P2pCleanup
    pop af
    jr .showP2pFail

.fail
    push af
.showP2pFail
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    push af
    call PrintErrorCode
    pop af
    cp a, MAGB_ERR_REMOTE_STATUS
    jr nz, .noRemoteDetail
    ld hl, sP2pRemoteErrLabel
    ld de, HTTP_ADDR
    call PrintString
    ld a, [wRemoteErrorCommand]
    ld de, HTTP_ADDR + 4
    call PrintHexByte
    ld hl, sP2pRemoteErrMid
    ld de, HTTP_ADDR + 6
    call PrintString
    ld a, [wRemoteErrorCode]
    ld de, HTTP_ADDR + 11
    call PrintHexByte
.noRemoteDetail
    jp WaitForBackButton

; Byte-for-byte comparison, since this codebase has no libc.
; Input: HL = ptr A, DE = ptr B, B = length
; Output: A = 0 if equal, nonzero otherwise
; Clobbers: everything
MemCompare:
.loop
    ld a, [de]
    cp a, [hl]
    jr nz, .differ
    inc hl
    inc de
    dec b
    jr nz, .loop
    xor a, a
    ret
.differ
    ld a, 1
    ret

; Copied into wP2pNumber once at boot (see EntryPoint) -- matches gbdk's
; TEST_P2P_PHONE (test_config.h), a loopback-style direct-IP P2P address.
sP2pDefaultNumber: db "127000000001", 0

sPing: db "PING"
sPong: db "PONG"
sP2pPattern: db $00, $01, $55, $AA, $FE, $FF, $10, $EF
sHelloWorld: db "HELLO WORLD"
sHelloWorldEnd:
sHelloWorldOk: db "HELLO WORLD OK", 0
sP2pRemoteErrLabel: db "CMD ", 0
sP2pRemoteErrMid:   db " ERR ", 0

; ---- P2P phone number editor (Caller only) -----------------------------
;
; Fixed-length-12-digit editor (gbdk's ui_edit_number(..., variable_len:
; true) additionally lets SELECT/START shrink/grow the length for a
; relay-style shorter number -- not offered here, since this side only
; ever dials a direct-IP-style P2P number via MagbDial, and every digit
; MagbDial receives is sent as-is regardless of length anyway; a fixed
; 12 keeps this editor simpler without losing anything this ROM
; actually uses length for). UP/DOWN cycles the digit 0-9, LEFT/RIGHT
; moves the cursor (wrapping), A saves and returns 1, B cancels and
; returns 0 (buffer left unchanged).
;
; Input: HL = 13-byte buffer (12 digits + NUL, NUL-terminated on entry),
;        DE = label string pointer
; Output: A = 1 if saved, 0 if cancelled
; Clobbers: everything
DEF P2P_NUMBER_LEN EQU 12

EditNumber:
    ld a, l
    ld [wNumBufPtr], a
    ld a, h
    ld [wNumBufPtr + 1], a
    ld a, e
    ld [wNumLabelPtr], a
    ld a, d
    ld [wNumLabelPtr + 1], a

    ld b, P2P_NUMBER_LEN
    ld de, wNumWork
.copyLoop
    ld a, [hl]
    or a, a
    jr z, .padLoop
    ld [de], a
    inc hl
    inc de
    dec b
    jr nz, .copyLoop
.padLoop
    ld a, b
    or a, a
    jr z, .terminate
    ld a, "0"
    ld [de], a
    inc de
    dec b
    jr .padLoop
.terminate
    xor a, a
    ld [de], a
    ld [wNumCursor], a

    call DrawEditNumberScreen

.loop
    call WaitVBlank
    call ReadJoypadPressed
    ld b, a
    or a, a
    jr z, .loop

    ld a, b
    and a, PAD_LEFT
    jr z, .checkRight
    ld a, [wNumCursor]
    or a, a
    jr nz, .decCursor
    ld a, P2P_NUMBER_LEN
.decCursor
    dec a
    ld [wNumCursor], a
    call DrawEditNumberScreen
    jp .loop

.checkRight
    ld a, b
    and a, PAD_RIGHT
    jr z, .checkUp
    ld a, [wNumCursor]
    inc a
    ld c, a
    ld a, P2P_NUMBER_LEN
    cp a, c
    jr nz, .haveRight
    ld c, 0
.haveRight
    ld a, c
    ld [wNumCursor], a
    call DrawEditNumberScreen
    jp .loop

.checkUp
    ld a, b
    and a, PAD_UP
    jr z, .checkDown
    ld a, [wNumCursor]
    ld e, a
    ld d, 0
    ld hl, wNumWork
    add hl, de
    ld a, [hl]
    sub a, "0"
    inc a
    cp a, 10
    jr nz, .upOk
    xor a, a
.upOk
    add a, "0"
    ld [hl], a
    call DrawEditNumberScreen
    jp .loop

.checkDown
    ld a, b
    and a, PAD_DOWN
    jr z, .checkA
    ld a, [wNumCursor]
    ld e, a
    ld d, 0
    ld hl, wNumWork
    add hl, de
    ld a, [hl]
    sub a, "0"
    or a, a
    jr nz, .downOk
    ld a, 10
.downOk
    dec a
    add a, "0"
    ld [hl], a
    call DrawEditNumberScreen
    jp .loop

.checkA
    ld a, b
    and a, PAD_A
    jr z, .checkB
    ld a, [wNumBufPtr]
    ld e, a
    ld a, [wNumBufPtr + 1]
    ld d, a
    ld hl, wNumWork
    ld b, P2P_NUMBER_LEN
.copyOut
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyOut
    xor a, a
    ld [de], a
    ld a, 1
    ret

.checkB
    ld a, b
    and a, PAD_B
    jp z, .loop
    xor a, a
    ret

; Clobbers: everything
DrawEditNumberScreen:
    call ClearTextScreen

    ld a, [wNumLabelPtr]
    ld l, a
    ld a, [wNumLabelPtr + 1]
    ld h, a
    ld de, $9800
    call PrintString

    ld hl, wNumWork
    ld de, $9860 ; row 3
    call PrintString

    ld a, [wNumCursor]
    ld e, a
    ld d, 0
    ld hl, $9880 ; row 4, col 0 + cursor
    add hl, de
    ld d, h
    ld e, l
    ld hl, sCursorOn
    call PrintString

    ld hl, sEditHint1
    ld de, $98E0 ; row 7
    call PrintString
    ld hl, sEditNumHint2
    ld de, $9900 ; row 8
    call PrintString
    ld hl, sEditHint3
    ld de, $9920 ; row 9
    jp PrintString

sEditNumHint2: db "U/D:DIGIT", 0

; ---- Live ISP identity (login id + Configuration Slot 1 phone) --------
;
; Reads real Read Configuration Data (0x19) fields instead of always
; using this ROM's compile-time TEST_ISP_LOGIN/TEST_ISP_PHONE-equivalent
; defaults -- matches gbdk's read_isp_identity() (test_runner.c), added
; there per the project owner's own request: "se algo exigir
; autenticacao, voce tem que ler todas as infos necessarias da config
; do adaptador". Every ISP/HTTP target uses this, not just
; GB00-authenticated ones -- falls back to the exact same compile-time
; defaults this ROM already used when the field is blank (an adapter
; that never ran Mobile Trainer registration), so an unregistered
; adapter sees unchanged behavior.
;
; Output: A = result (0=OK); on success wIdentityLogin/wIdentityPhone
;         hold real, NUL-terminated strings ready to feed straight into
;         MagbIspLogin/MagbDial
; Clobbers: everything
ReadIdentity:
    call MagbReadConfig
    ret nz

    ld hl, wConfigData + MAGB_CONFIG_OFF_LOGIN_ID
    ld b, MAGB_CONFIG_LOGIN_ID_LEN
    ld de, wIdentityLogin
    ld c, MAGB_CONFIG_LOGIN_ID_LEN + 1
    call ConfigFieldToCstr

    ld a, [wIdentityLogin]
    or a, a
    jr nz, .haveLogin
    ld hl, sIspLoginDefault
    ld de, wIdentityLogin
    call StrCopy
.haveLogin

    ld hl, wConfigData + MAGB_CONFIG_OFF_SLOT1
    ld de, wIdentityPhone
    call MagbConfigDecodePhone
    or a, a
    jr nz, .havePhone
    ld hl, sIspPhoneDefault
    ld de, wIdentityPhone
    call StrCopy
.havePhone
    ; Email/SMTP/POP -- no compile-time fallback here, unlike
    ; login/phone above: matches gbdk's read_isp_identity() exactly,
    ; which leaves these blank on a genuinely unregistered adapter and
    ; lets Email Send/Recv detect that explicitly (RunEmailSendTest/
    ; RunEmailRecvTest's own "NO EMAIL/SMTP IN CFG" checks) rather than
    ; silently dialing an invented mail server.
    ld hl, wConfigData + MAGB_CONFIG_OFF_EMAIL
    ld b, MAGB_CONFIG_EMAIL_LEN
    ld de, wIdentityEmail
    ld c, MAGB_CONFIG_EMAIL_LEN + 1
    call ConfigFieldToCstr

    ld hl, wConfigData + MAGB_CONFIG_OFF_SMTP
    ld b, MAGB_CONFIG_SMTP_LEN
    ld de, wIdentitySmtp
    ld c, MAGB_CONFIG_SMTP_LEN + 1
    call ConfigFieldToCstr

    ld hl, wConfigData + MAGB_CONFIG_OFF_POP
    ld b, MAGB_CONFIG_POP_LEN
    ld de, wIdentityPop
    ld c, MAGB_CONFIG_POP_LEN + 1
    call ConfigFieldToCstr

    xor a, a
    ret

sIspLoginDefault: db "test", 0
; NOT the same bytes as sIspPhoneNumber above -- that one is used with
; an explicit byte count (no NUL needed there) by RunIspHttpTest's own
; fallback-free Dial call before this existed; this is a separate,
; NUL-terminated copy for StrCopy's sake.
sIspPhoneDefault: db "#9677", 0

; Copies bytes from [HL] (a fixed-width, not-necessarily-NUL-terminated
; config field) to [DE], stopping at the first 0x00 byte, after B source
; bytes, or after C-1 dest bytes, whichever comes first, then
; NUL-terminates. Matches gbdk's config_field_to_cstr() (test_runner.c).
;
; Input: HL = field ptr, B = max field length, DE = dest buffer,
;        C = dest capacity including the NUL
; Output: [DE] NUL-terminated
; Clobbers: everything
ConfigFieldToCstr:
    dec c
.loop
    ld a, b
    or a, a
    jr z, .done
    ld a, c
    or a, a
    jr z, .done
    ld a, [hl]
    or a, a
    jr z, .done
    ld [de], a
    inc hl
    inc de
    dec b
    dec c
    jr .loop
.done
    xor a, a
    ld [de], a
    ret

; Returns the length of the NUL-terminated string at [HL] -- used for
; MagbDnsQuery's hostname-length input when the hostname comes from live
; config (wIdentitySmtp/wIdentityPop) rather than a fixed compile-time
; byte count.
; Input: HL = NUL-terminated string
; Output: B = length (0-255)
; Clobbers: A, HL, B
StrLen8:
    ld b, 0
.loop
    ld a, [hl+]
    or a, a
    ret z
    inc b
    jr .loop

; Copies a NUL-terminated string from [HL] to [DE], including the NUL.
; Clobbers: A, HL, DE
StrCopy:
    ld a, [hl+]
    ld [de], a
    inc de
    or a, a
    jr nz, StrCopy
    ret

; Builds the ISP Login payload from wIdentityLogin (see ReadIdentity)
; and wIspPassword (the ISP PASSWORD menu's live value, possibly empty
; -- libmobile's PPP login handler doesn't check credentials against a
; real account, so this is safe even empty) -- matches gbdk's
; magb_isp_login(id.login, password, ...) call in test_isp_http()
; exactly: real login, real (possibly empty) password, 0.0.0.0/0.0.0.0
; DNS meaning "use your own configured DNS". A running byte counter is
; used for the total length rather than subtracting the final pointer
; from the start address -- see the MD5 code's wMd5PadPos comment for
; why that subtraction trick isn't safe in general.
;
; Output: DE = wIspLoginBuiltPayload, C = total payload length
; Clobbers: everything
DEF ISP_LOGIN_PAYLOAD_MAX EQU 1 + MAGB_CONFIG_LOGIN_ID_LEN + 1 + ISP_PASSWORD_MAX_LEN + 8

BuildIspLoginPayload:
    xor a, a
    ld [wIspLoginBuiltLen], a
    ld de, wIspLoginBuiltPayload

    ld hl, wIdentityLogin
    ld b, 0
.loginLenLoop
    ld a, [hl+]
    or a, a
    jr z, .haveLoginLen
    inc b
    jr .loginLenLoop
.haveLoginLen
    ld a, b
    ld [de], a
    inc de
    call BumpIspLoginLen

    ld hl, wIdentityLogin
.copyLogin
    ld a, b
    or a, a
    jr z, .loginDone
    ld a, [hl+]
    ld [de], a
    inc de
    call BumpIspLoginLen
    dec b
    jr .copyLogin
.loginDone

    ld hl, wIspPassword
    ld b, 0
.passLenLoop
    ld a, [hl+]
    or a, a
    jr z, .havePassLen
    inc b
    jr .passLenLoop
.havePassLen
    ld a, b
    ld [de], a
    inc de
    call BumpIspLoginLen

    ld hl, wIspPassword
.copyPass
    ld a, b
    or a, a
    jr z, .passDone
    ld a, [hl+]
    ld [de], a
    inc de
    call BumpIspLoginLen
    dec b
    jr .copyPass
.passDone

    ld b, 8
    xor a, a
.dnsZero
    ld [de], a
    inc de
    call BumpIspLoginLen
    dec b
    jr nz, .dnsZero

    ld de, wIspLoginBuiltPayload
    ld a, [wIspLoginBuiltLen]
    ld c, a
    ret

; Same shape as BuildIspLoginPayload above, but with an explicit
; zero-length password regardless of the live ISP PASSWORD menu value --
; matches gbdk's test_isp_raw_tcp() calling
; magb_isp_login(ctx, id.login, "", ...) with a literal empty string,
; never the isp_password[] variable: Raw TCP has no auth step of its
; own (libmobile doesn't validate ISP Login credentials either way), so
; there's nothing for a real password to help with here, and this way a
; password set for News Config/Email Recv testing never leaks into an
; unrelated Raw TCP session by accident. A separate function rather than
; parameterizing BuildIspLoginPayload -- that one is already used by the
; hardware-confirmed Tamago Egg path; duplicating this specific ~25-line
; block keeps that path untouched.
; Output: DE = wIspLoginBuiltPayload, C = length (MagbIspLogin's own
;         expected input, ready to call immediately)
; Clobbers: everything
BuildIspLoginPayloadNoPassword:
    xor a, a
    ld [wIspLoginBuiltLen], a
    ld de, wIspLoginBuiltPayload

    ld hl, wIdentityLogin
    ld b, 0
.loginLenLoop
    ld a, [hl+]
    or a, a
    jr z, .haveLoginLen
    inc b
    jr .loginLenLoop
.haveLoginLen
    ld a, b
    ld [de], a
    inc de
    call BumpIspLoginLen

    ld hl, wIdentityLogin
.copyLogin
    ld a, b
    or a, a
    jr z, .loginDone
    ld a, [hl+]
    ld [de], a
    inc de
    call BumpIspLoginLen
    dec b
    jr .copyLogin
.loginDone

    xor a, a
    ld [de], a ; password_len = 0 -- no password bytes follow
    inc de
    call BumpIspLoginLen

    ld b, 8
    xor a, a
.dnsZero
    ld [de], a
    inc de
    call BumpIspLoginLen
    dec b
    jr nz, .dnsZero

    ld de, wIspLoginBuiltPayload
    ld a, [wIspLoginBuiltLen]
    ld c, a
    ret

; Clobbers: A
BumpIspLoginLen:
    push af
    ld a, [wIspLoginBuiltLen]
    inc a
    ld [wIspLoginBuiltLen], a
    pop af
    ret

; ---- Test 2: ISP / HTTP (see the file header comment for the exact
; command sequence and this screen's row layout) -----------------------
;
; Tamago Egg and Trainer Home are both plain unauthenticated GETs against
; the same host, differing only in path/title -- these two entry points
; just stage that difference into WRAM (wHttpRequestPtr/wHttpRequestLen/
; wHttpTestTitle) and fall into the shared RunIspHttpCore below, instead
; of duplicating the whole Begin-Session..End-Session sequence.
; Clobbers: everything
RunTamagoEggTest:
    ld a, low(sHttpRequest)
    ld [wHttpRequestPtr], a
    ld a, high(sHttpRequest)
    ld [wHttpRequestPtr + 1], a
    ld a, sHttpRequestEnd - sHttpRequest
    ld [wHttpRequestLen], a
    ld a, low(sTitle)
    ld [wHttpTestTitle], a
    ld a, high(sTitle)
    ld [wHttpTestTitle + 1], a
    jp RunIspHttpCore

; Clobbers: everything
RunTrainerHomeTest:
    ld a, low(sHttpRequestTrainerHome)
    ld [wHttpRequestPtr], a
    ld a, high(sHttpRequestTrainerHome)
    ld [wHttpRequestPtr + 1], a
    ld a, sHttpRequestTrainerHomeEnd - sHttpRequestTrainerHome
    ld [wHttpRequestLen], a
    ld a, low(sTrainerHomeTitle)
    ld [wHttpTestTitle], a
    ld a, high(sTrainerHomeTitle)
    ld [wHttpTestTitle + 1], a
    jp RunIspHttpCore

; Clobbers: everything
RunIspHttpCore:
    call ClearTextScreen

    ld a, [wHttpTestTitle]
    ld l, a
    ld a, [wHttpTestTitle + 1]
    ld h, a
    ld de, $9801
    call PrintString

    ld a, CMD_SESSION
    call SetCommand
    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jp nz, .showFail

    ld a, CMD_READ_ID
    call SetCommand
    call ReadIdentity
    or a, a
    jp nz, .showFail

    ld a, CMD_DIAL
    call SetCommand
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    ld hl, wIdentityPhone
    ld b, 0
.phoneLenLoop
    ld a, [hl+]
    or a, a
    jr z, .havePhoneLen
    inc b
    jr .phoneLenLoop
.havePhoneLen
    ld hl, wIdentityPhone
    call MagbDial
    or a, a
    jp nz, .showFail

    ld a, CMD_ISP_LOGIN
    call SetCommand
    call BuildIspLoginPayload
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

    ; Best-effort cleanup from here on -- matches gbdk's own
    ; isp_http_cleanup(), which calls magb_tcp_close()/magb_isp_logout()/
    ; magb_hangup()/magb_end_session() as `(void)`, never treating their
    ; result as fatal. Confirmed necessary against a real libmobile-bgb
    ; run: after Transfer Data End (the remote peer closing its side of
    ; the TCP connection), the adapter answered this ROM's own explicit
    ; TCP Close with an Error Status response (0x6E|0x80) -- a real,
    ; legitimate "that connection is already gone" from the adapter's
    ; point of view, not a transport failure -- which this code used to
    ; treat as a fatal MAGB_ERR_REMOTE_STATUS and fail the whole
    ; sequence even though the actual HTTP GET had already fully
    ; succeeded (a real "HTTP 200" was already on screen). The session
    ; still gets torn down as well as it can be either way; only
    ; whether a *teardown* hiccup fails the *test* changes here.
    ld a, CMD_TCP_CLOSE
    call SetCommand
    call MagbTcpClose

    ld a, CMD_ISP_LOGOUT
    call SetCommand
    call MagbIspLogout

    ld a, CMD_HANGUP
    call SetCommand
    call MagbHangup

    ld a, CMD_END_SESSION
    call SetCommand
    call MagbEndSession

    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

.showFail
    ; A holds the MAGB_ERR_* code that failed -- stash it, since
    ; PrintString (called next, for the "RESULT: FAIL" line) clobbers A.
    push af

    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString

    pop af
    call PrintErrorCode
    jp WaitForBackButton

; ---- ISP/HTTP submenu --------------------------------------------------
;
; Matches gbdk/src/app/ui.c's ui_select_submenu()/kIspLabels[]: title on
; row 0, items starting row 2 (one blank row under the title, unlike the
; main menu's items starting row 4 under a 2-row title), "A:RUN B:BACK"
; footer on row 16. Selection resets to item 0 every time this is
; entered (a plain local-ish WRAM byte, not persisted across calls like
; wMenuSelected is) -- matches gbdk's `uint8_t sel = 0U;` being a normal
; local, not `static`, in ui_select_submenu().
;
; Only TAMAGO EGG and TRAINER HOME are backed by a real implementation
; (RunIspHttpCore, see above); the other five show the same honest
; "NOT IMPLEMENTED" screen everything else unimplemented on this side
; already uses (repo-root CLAUDE.md's "No Fake Implementations").
DEF ISP_SUBMENU_COUNT EQU 7

IspSubMenuItemAddrs: ; rows 2-8, column 0 (cursor); matches gotoxy(0, 2+i)
    dw $9840
    dw $9860
    dw $9880
    dw $98A0
    dw $98C0
    dw $98E0
    dw $9900

; Exact wording/order matches gbdk's kIspLabels[] in src/main.c.
IspSubMenuLabels:
    dw sSubTamagoEgg
    dw sSubNewsConfig
    dw sSubNewsArticle
    dw sSubTrainerHome
    dw sSubEmailSend
    dw sSubEmailRecv
    dw sSubRawTcp

IspSubMenuHandlers:
    dw RunTamagoEggTest
    dw RunNewsConfigTest
    dw RunNewsArticleTest
    dw RunTrainerHomeTest
    dw RunEmailSendTest
    dw RunEmailRecvTest
    dw RunRawTcpTest

sSubTamagoEgg:   db "TAMAGO EGG", 0
sSubNewsConfig:  db "NEWS CONFIG", 0
sSubNewsArticle: db "NEWS ARTICLE", 0
sSubTrainerHome: db "TRAINER HOME", 0
sSubEmailSend:   db "EMAIL SEND", 0
sSubEmailRecv:   db "EMAIL RECV", 0
sSubRawTcp:      db "RAW TCP(NC)", 0
sIspSubMenuTitle: db "ISP/HTTP", 0
sSubMenuFooter:   db "A:RUN B:BACK", 0

sSetIspPassword: db "SET ISP PASSWORD", 0

; Prints "HTTP <status>" (+" (AUTH)" if the GB00 challenge/response
; retry actually happened) at HTTP_ADDR (row 5) -- shorter than gbdk's
; "AUTH -> HTTP %s"/"HTTP %s (NO AUTH)" (out->detail[0]) since this
; ROM's screen is narrower, same information. Shared by
; RunNewsConfigTest and RunNewsArticleTest (both call Gb00FetchOne).
; Clobbers: everything (calls PrintString)
ShowGb00StatusLine:
    ld hl, sGb00HttpLabel
    ld de, wGb00StatusMsg
    ld b, 5
.copyLabel
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyLabel

    ld hl, wGb00FetchStatusText
    ld b, 3
.copyStatus
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyStatus

    ld a, [wGb00FetchDidAuth]
    or a, a
    jr z, .noAuthMarker
    ld hl, sGb00AuthMarker
    ld b, sGb00AuthMarkerEnd - sGb00AuthMarker
.copyMarker
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyMarker
    xor a, a
    ld [de], a
    jr .printIt
.noAuthMarker
    xor a, a
    ld [de], a
.printIt
    ld hl, wGb00StatusMsg
    ld de, HTTP_ADDR
    jp PrintString

sGb00HttpLabel:   db "HTTP "
sGb00AuthMarker:  db " (AUTH)"
sGb00AuthMarkerEnd:

; Real REON path, gbdk/include/test_config.h's TEST_HTTP_NEWS_CONFIG_PATH
; -- same host as Tamago Egg/Trainer Home. get_news_parameters_bin()
; unconditionally calls doAuth(2) (confirmed by reading news.php, not
; assumed), so this always attempts the no-auth GET first and expects a
; 401 in practice; Gb00FetchOne handles that transparently either way.
sNewsConfigNoAuthReq:
    db "GET /cgb/download?name=/01/CGB-BXTJ/news/config.php HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Connection: close", $0D, $0A
    db $0D, $0A
sNewsConfigNoAuthReqEnd:

; Same request line/host as above, minus the no-auth-only headers, plus
; the start of the Authorization header -- Gb00FetchOne appends the
; computed 92-char value and a shared closing suffix itself (see
; gb00_auth.asm's sGb00AuthSuffix). 120 bytes; + 92 + 24 = 236 total,
; comfortably under MagbTransferData's 253-byte cap (confirmed by
; counting the exact strings, not assumed).
sNewsConfigAuthPrefix:
    db "GET /cgb/download?name=/01/CGB-BXTJ/news/config.php HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Authorization: GB00 name=", $22
sNewsConfigAuthPrefixEnd:

; ---- News Config (GB00-authenticated single fetch) ---------------------
;
; Matches gbdk's test_isp_http_gb00() with TEST_HTTP_NEWS_CONFIG_PATH:
; Begin Session -> Read Identity -> Dial -> ISP Login -> DNS Query (same
; TEST_HTTP_HOST as Tamago Egg/Trainer Home) -> one Gb00FetchOne (see
; gb00_auth.asm) -> best-effort ISP Logout/Hang Up/End Session (TCP
; Close already happened inside Gb00FetchOne itself, on every exit
; path). Requires a non-empty ISP PASSWORD up front -- unlike Dial/ISP
; Login (which libmobile accepts with any password), REON's GB00 auth
; validates this against a real account and fails with a real
; 401-after-retry if it's wrong, so an empty password is refused before
; even trying rather than being sent and reported as a confusing
; generic failure -- matches gbdk's require_password().
; Clobbers: everything
RunNewsConfigTest:
    call ClearTextScreen
    ld hl, sSubNewsConfig
    ld de, $9801
    call PrintString

    ld a, [wIspPassword]
    or a, a
    jp z, .noPassword

    ld a, CMD_SESSION
    call SetCommand
    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jp nz, .showFail

    ld a, CMD_READ_ID
    call SetCommand
    call ReadIdentity
    or a, a
    jp nz, .showFail

    ld a, CMD_DIAL
    call SetCommand
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    ld hl, wIdentityPhone
    ld b, 0
.phoneLenLoop
    ld a, [hl+]
    or a, a
    jr z, .havePhoneLen
    inc b
    jr .phoneLenLoop
.havePhoneLen
    ld hl, wIdentityPhone
    call MagbDial
    or a, a
    jp nz, .showFail

    ld a, CMD_ISP_LOGIN
    call SetCommand
    call BuildIspLoginPayload
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

    ld a, CMD_HTTP
    call SetCommand
    ld hl, sNewsConfigNoAuthReq
    ld a, l
    ld [wGb00FetchNoAuthPtr], a
    ld a, h
    ld [wGb00FetchNoAuthPtr + 1], a
    ld a, sNewsConfigNoAuthReqEnd - sNewsConfigNoAuthReq
    ld [wGb00FetchNoAuthLen], a
    ld hl, sNewsConfigAuthPrefix
    ld a, l
    ld [wGb00FetchAuthPrefixPtr], a
    ld a, h
    ld [wGb00FetchAuthPrefixPtr + 1], a
    ld a, sNewsConfigAuthPrefixEnd - sNewsConfigAuthPrefix
    ld [wGb00FetchAuthPrefixLen], a
    ld hl, wIdentityLogin
    ld a, l
    ld [wGb00FetchLoginPtr], a
    ld a, h
    ld [wGb00FetchLoginPtr + 1], a
    ld hl, wIspPassword
    ld a, l
    ld [wGb00FetchPasswordPtr], a
    ld a, h
    ld [wGb00FetchPasswordPtr + 1], a
    call Gb00FetchOne
    or a, a
    jp nz, .showGb00Fail

    call ShowGb00StatusLine

    ld a, CMD_ISP_LOGOUT
    call SetCommand
    call MagbIspLogout

    ld a, CMD_HANGUP
    call SetCommand
    call MagbHangup

    ld a, CMD_END_SESSION
    call SetCommand
    call MagbEndSession

    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

.noPassword
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld hl, sSetIspPassword
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton

.showGb00Fail
    cp a, MAGB_ERR_ISP
    jr nz, .showFail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld a, [wGb00FetchFailMsgPtr]
    ld l, a
    ld a, [wGb00FetchFailMsgPtr + 1]
    ld h, a
    ld de, ERROR_ADDR
    call PrintString
    pop af
    jp WaitForBackButton

.showFail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

; News Article's request/prefix strings (100.news.php, same host as
; News Config above -- gbdk/include/test_config.h's TEST_HTTP_NEWS_PATH).
sNewsArticleNoAuthReq:
    db "GET /cgb/download?name=/01/CGB-BXTJ/news/100.news.php HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Connection: close", $0D, $0A
    db $0D, $0A
sNewsArticleNoAuthReqEnd:

sNewsArticleAuthPrefix:
    db "GET /cgb/download?name=/01/CGB-BXTJ/news/100.news.php HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "Authorization: GB00 name=", $22
sNewsArticleAuthPrefixEnd:

sStageConfig:  db "STAGE: CONFIG", 0
sStageArticle: db "STAGE: ARTICLE", 0

; Prints "CFG <cfg_status> ART <art_status>" at HTTP_ADDR (row 5) --
; matches gbdk's sprintf(out->detail[0], "CFG %s ART %s", ...).
; Clobbers: everything (calls PrintString)
ShowNewsArticleStatusLine:
    ld hl, sNewsArticleCfgLabel
    ld de, wGb00StatusMsg
    ld b, 4 ; "CFG "
.copyCfgLabel
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyCfgLabel

    ld hl, wNewsArticleCfgStatus
    ld b, 3
.copyCfgVal
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyCfgVal

    ld hl, sNewsArticleArtLabel
    ld b, sNewsArticleArtLabelEnd - sNewsArticleArtLabel
.copyArtLabel
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyArtLabel

    ld hl, wGb00FetchStatusText
    ld b, 3
.copyArtVal
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyArtVal
    xor a, a
    ld [de], a

    ld hl, wGb00StatusMsg
    ld de, HTTP_ADDR
    jp PrintString

sNewsArticleCfgLabel: db "CFG "
sNewsArticleArtLabel: db " ART "
sNewsArticleArtLabelEnd:

; ---- News Article (two GB00-authenticated fetches, one ISP session) ----
;
; Matches gbdk's test_isp_news_article(): same Begin Session -> Read
; Identity -> Dial -> ISP Login -> one shared DNS Query as News Config,
; then TWO Gb00FetchOne calls in the same session (config.php, then
; 100.news.php) -- mirrors what a real game actually does for the
; Goldenrod Communication Center news feature (fetch the config, then
; the article itself). Neither fetch relies on REON's optional
; session-level auth cache (see gbdk's own comment on this) -- each
; gets its own real challenge/response.
; Clobbers: everything
RunNewsArticleTest:
    call ClearTextScreen
    ld hl, sSubNewsArticle
    ld de, $9801
    call PrintString

    ld a, [wIspPassword]
    or a, a
    jp z, .noPassword

    ld a, CMD_SESSION
    call SetCommand
    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jp nz, .showFail

    ld a, CMD_READ_ID
    call SetCommand
    call ReadIdentity
    or a, a
    jp nz, .showFail

    ld a, CMD_DIAL
    call SetCommand
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    ld hl, wIdentityPhone
    ld b, 0
.phoneLenLoop
    ld a, [hl+]
    or a, a
    jr z, .havePhoneLen
    inc b
    jr .phoneLenLoop
.havePhoneLen
    ld hl, wIdentityPhone
    call MagbDial
    or a, a
    jp nz, .showFail

    ld a, CMD_ISP_LOGIN
    call SetCommand
    call BuildIspLoginPayload
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

    ; Fetch 1: news config
    ld a, CMD_HTTP
    call SetCommand
    ld hl, sNewsConfigNoAuthReq
    ld a, l
    ld [wGb00FetchNoAuthPtr], a
    ld a, h
    ld [wGb00FetchNoAuthPtr + 1], a
    ld a, sNewsConfigNoAuthReqEnd - sNewsConfigNoAuthReq
    ld [wGb00FetchNoAuthLen], a
    ld hl, sNewsConfigAuthPrefix
    ld a, l
    ld [wGb00FetchAuthPrefixPtr], a
    ld a, h
    ld [wGb00FetchAuthPrefixPtr + 1], a
    ld a, sNewsConfigAuthPrefixEnd - sNewsConfigAuthPrefix
    ld [wGb00FetchAuthPrefixLen], a
    ld hl, wIdentityLogin
    ld a, l
    ld [wGb00FetchLoginPtr], a
    ld a, h
    ld [wGb00FetchLoginPtr + 1], a
    ld hl, wIspPassword
    ld a, l
    ld [wGb00FetchPasswordPtr], a
    ld a, h
    ld [wGb00FetchPasswordPtr + 1], a
    call Gb00FetchOne
    or a, a
    jp nz, .showConfigFail

    ; wGb00FetchStatusText gets overwritten by the article fetch below --
    ; stash the config fetch's status text before that happens.
    ld hl, wGb00FetchStatusText
    ld de, wNewsArticleCfgStatus
    ld b, 4
.copyCfgStatus
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyCfgStatus

    ; Fetch 2: news article (login/password pointers are unchanged from
    ; the config fetch above -- only the request text differs)
    ld hl, sNewsArticleNoAuthReq
    ld a, l
    ld [wGb00FetchNoAuthPtr], a
    ld a, h
    ld [wGb00FetchNoAuthPtr + 1], a
    ld a, sNewsArticleNoAuthReqEnd - sNewsArticleNoAuthReq
    ld [wGb00FetchNoAuthLen], a
    ld hl, sNewsArticleAuthPrefix
    ld a, l
    ld [wGb00FetchAuthPrefixPtr], a
    ld a, h
    ld [wGb00FetchAuthPrefixPtr + 1], a
    ld a, sNewsArticleAuthPrefixEnd - sNewsArticleAuthPrefix
    ld [wGb00FetchAuthPrefixLen], a
    call Gb00FetchOne
    or a, a
    jp nz, .showArticleFail

    call ShowNewsArticleStatusLine

    ld a, CMD_ISP_LOGOUT
    call SetCommand
    call MagbIspLogout

    ld a, CMD_HANGUP
    call SetCommand
    call MagbHangup

    ld a, CMD_END_SESSION
    call SetCommand
    call MagbEndSession

    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

.noPassword
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld hl, sSetIspPassword
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton

.showConfigFail
    ld hl, sStageConfig
    jr .showGb00OrProtoFail
.showArticleFail
    ld hl, sStageArticle
.showGb00OrProtoFail
    push hl ; stage label, printed at HTTP_ADDR below the FAIL/error line
    cp a, MAGB_ERR_ISP
    jr nz, .protoFail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld a, [wGb00FetchFailMsgPtr]
    ld l, a
    ld a, [wGb00FetchFailMsgPtr + 1]
    ld h, a
    ld de, ERROR_ADDR
    call PrintString
    pop af
    pop hl
    ld de, HTTP_ADDR
    call PrintString
    jp WaitForBackButton
.protoFail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    pop hl
    ld de, HTTP_ADDR
    call PrintString
    jp WaitForBackButton

.showFail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

; ---- Email Send (SMTP, port 25) -----------------------------------------
;
; Matches gbdk's test_isp_email_send(): neither SMTP nor POP3 is a
; Mobile Adapter command, both are ordinary line-based text protocols
; over a plain TCP connection (see net_extra.asm's own header comment
; for the multi-line-per-chunk rationale). SMTP accepts mail with no
; authentication at all here (a message only actually gets delivered if
; RCPT TO matches a real account's email -- confirmed against REON's
; own smtpConnection.js source, not guessed), so unlike News
; Config/Article/Email Recv, this one does NOT require the ISP PASSWORD
; to be set first. Email address and SMTP host are read from the
; adapter's own live config (ReadIdentity), never invented.
; Clobbers: everything
sMailFromPrefix: db "MAIL FROM:<"
sMailFromPrefixEnd:
sRcptToPrefix:   db "RCPT TO:<"
sRcptToPrefixEnd:
sEmailLineSuffix: db ">", $0D, $0A
sEmailLineSuffixEnd:

; Builds prefix + wIdentityEmail + ">\r\n" into wEmailCmdBuf -- shared by
; MAIL FROM/RCPT TO, the only two SMTP lines whose content depends on
; live config rather than being a fixed compile-time blob.
; Input: HL = prefix bytes, B = prefix length
; Output: wEmailCmdBuf holds the built line, wEmailCmdLen its length
; Clobbers: everything
BuildEmailCommandLine:
    ld de, wEmailCmdBuf
    xor a, a
    ld [wEmailCmdLen], a
.copyPrefix
    ld a, b
    or a, a
    jr z, .prefixDone
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [wEmailCmdLen]
    inc a
    ld [wEmailCmdLen], a
    dec b
    jr .copyPrefix
.prefixDone
    ld hl, wIdentityEmail
.copyEmail
    ld a, [hl+]
    or a, a
    jr z, .emailDone
    ld [de], a
    inc de
    ld a, [wEmailCmdLen]
    inc a
    ld [wEmailCmdLen], a
    jr .copyEmail
.emailDone
    ld hl, sEmailLineSuffix
    ld b, sEmailLineSuffixEnd - sEmailLineSuffix
.copySuffix
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [wEmailCmdLen]
    inc a
    ld [wEmailCmdLen], a
    dec b
    jr nz, .copySuffix
    ret

sSmtpHelo: db "HELO magbtestsuite", $0D, $0A
sSmtpHeloEnd:
sSmtpData: db "DATA", $0D, $0A
sSmtpDataEnd:
sSmtpQuit: db "QUIT", $0D, $0A
sSmtpQuitEnd:
; Same subject line gbdk's kTestEmailSubjectLine uses -- Email Recv's
; delete_matching_test_emails()-equivalent looks for this exact text to
; know which messages in the mailbox are safe to delete.
;
; The body line deliberately does NOT end in a literal "." right before
; its CRLF (confirmed against REON's real mail/smtpConnection.js:
; `_handleData()` decides "this is the lone
; end-of-DATA terminator line" via `data.endsWith(".\r\n")` on each
; line *individually*, not "is this line exactly '.'" -- so a message
; line that happens to end its own sentence with a period, like "...ROM."
; immediately followed by CRLF, satisfies that same check and gets
; treated as the real terminator one line early. The genuine terminator
; line right after it then arrives while the server already considers
; DATA finished, so it goes through `_onCommand()` as command name "."
; instead, producing a real `500 command not recognized` -- confirmed
; against a real libmobile-bgb run (2026-08-29/30): the combined
; "250 OK\r\n500 command not recognized\r\n" is REON's own response to
; that exact one-line-early split, not a symptom of a MAGB/transport bug
; on this ROM's side. Dropping the trailing period here is the fix --
; not a REON bug this ROM can (or should) work around any more cleverly
; than "don't trip their line-terminator check".
sSmtpBody:
    db "Subject: MAGB TestSuite", $0D, $0A, $0D, $0A
    db "Hello from the Mobile Adapter GB TestSuite ROM", $0D, $0A
    db ".", $0D, $0A
sSmtpBodyEnd:

sExpect220: db "220"
sExpect250: db "250"
sExpect354: db "354"

sNoEmailSmtpCfg:    db "NO EMAIL/SMTP CFG", 0
sNoSmtpGreeting:    db "NO SMTP GREETING", 0
sHeloRejected:      db "HELO REJECTED", 0
sMailFromRejected:  db "MAIL FROM REJECTED", 0
sRcptToRejected:    db "RCPT TO REJECTED", 0
sDataRejected:      db "DATA REJECTED", 0
sMessageRejected:   db "MESSAGE REJECTED", 0
sSentOk:            db "SENT OK", 0

RunEmailSendTest:
    call ClearTextScreen
    ld hl, sSubEmailSend
    ld de, $9801
    call PrintString

    ld a, CMD_SESSION
    call SetCommand
    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jp nz, .showFail

    ld a, CMD_READ_ID
    call SetCommand
    call ReadIdentity
    or a, a
    jp nz, .showFail

    ld a, [wIdentityEmail]
    or a, a
    jp z, .noEmailCfg
    ld a, [wIdentitySmtp]
    or a, a
    jp z, .noEmailCfg

    ld hl, wIdentityEmail
    ld de, HTTP_ADDR
    call PrintString

    ld a, CMD_DIAL
    call SetCommand
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    ld hl, wIdentityPhone
    ld b, 0
.phoneLenLoop
    ld a, [hl+]
    or a, a
    jr z, .havePhoneLen
    inc b
    jr .phoneLenLoop
.havePhoneLen
    ld hl, wIdentityPhone
    call MagbDial
    or a, a
    jp nz, .showFail

    ld a, CMD_ISP_LOGIN
    call SetCommand
    call BuildIspLoginPayload
    call MagbIspLogin
    or a, a
    jp nz, .showFail

    ld a, CMD_DNS
    call SetCommand
    ld hl, wIdentitySmtp
    call StrLen8
    ld hl, wIdentitySmtp
    call MagbDnsQuery
    or a, a
    jp nz, .showFail

    ld a, CMD_TCP_OPEN
    call SetCommand
    ld hl, wDnsResultIp
    ld bc, 25
    call MagbTcpOpen
    or a, a
    jp nz, .showFail
    call TcpLineReset

    ld a, CMD_EMAIL
    call SetCommand
    ld de, wEmailLineBuf
    ld b, EMAIL_RECV_BUF_SIZE
    call TcpRecvLine
    or a, a
    jp nz, .showTransportFailClosed
    ld hl, wEmailLineBuf
    ld de, sExpect220
    ld b, 3
    call StrPrefixMatch
    or a, a
    jp z, .showNoGreeting

    ; HELO
    ld hl, sSmtpHelo
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, sSmtpHeloEnd - sSmtpHelo
    ld [wEmailStepSendLen], a
    ld hl, wEmailLineBuf
    ld a, l
    ld [wEmailStepRecvPtr], a
    ld a, h
    ld [wEmailStepRecvPtr + 1], a
    ld a, EMAIL_RECV_BUF_SIZE
    ld [wEmailStepRecvCap], a
    ld hl, sExpect250
    ld a, l
    ld [wEmailStepExpectPtr], a
    ld a, h
    ld [wEmailStepExpectPtr + 1], a
    ld a, 3
    ld [wEmailStepExpectLen], a
    call EmailLineStep
    or a, a
    jp nz, .heloCheckFail

    ; MAIL FROM:<email>
    ld hl, sMailFromPrefix
    ld b, sMailFromPrefixEnd - sMailFromPrefix
    call BuildEmailCommandLine
    ld hl, wEmailCmdBuf
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, [wEmailCmdLen]
    ld [wEmailStepSendLen], a
    call EmailLineStep
    or a, a
    jp nz, .mailFromCheckFail

    ; RCPT TO:<email>
    ld hl, sRcptToPrefix
    ld b, sRcptToPrefixEnd - sRcptToPrefix
    call BuildEmailCommandLine
    ld hl, wEmailCmdBuf
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, [wEmailCmdLen]
    ld [wEmailStepSendLen], a
    call EmailLineStep
    or a, a
    jp nz, .rcptToCheckFail

    ; DATA
    ld hl, sSmtpData
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, sSmtpDataEnd - sSmtpData
    ld [wEmailStepSendLen], a
    ld hl, sExpect354
    ld a, l
    ld [wEmailStepExpectPtr], a
    ld a, h
    ld [wEmailStepExpectPtr + 1], a
    ld a, 3
    ld [wEmailStepExpectLen], a
    call EmailLineStep
    or a, a
    jp nz, .dataCheckFail

    ; message body, terminated by a lone "."
    ld hl, sSmtpBody
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, sSmtpBodyEnd - sSmtpBody
    ld [wEmailStepSendLen], a
    ld hl, sExpect250
    ld a, l
    ld [wEmailStepExpectPtr], a
    ld a, h
    ld [wEmailStepExpectPtr + 1], a
    ld a, 3
    ld [wEmailStepExpectLen], a
    call EmailLineStep
    or a, a
    jp nz, .messageCheckFail

    ; QUIT -- best-effort, result discarded, matches gbdk's
    ; (void)tcp_send_line(ctx, conn_id, "QUIT\r\n")
    ld hl, sSmtpQuit
    ld b, sSmtpQuitEnd - sSmtpQuit
    call TcpSendLine

    ld a, CMD_TCP_CLOSE
    call SetCommand
    call MagbTcpClose

    ld a, CMD_ISP_LOGOUT
    call SetCommand
    call MagbIspLogout

    ld a, CMD_HANGUP
    call SetCommand
    call MagbHangup

    ld a, CMD_END_SESSION
    call SetCommand
    call MagbEndSession

    ld hl, sSentOk
    ld de, ERROR_ADDR
    call PrintString
    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

.noEmailCfg
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld hl, sNoEmailSmtpCfg
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton

.showNoGreeting
    call MagbTcpClose
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld hl, sNoSmtpGreeting
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton

.heloCheckFail
    ld hl, sHeloRejected
    jr .showEmailStepFail
.mailFromCheckFail
    ld hl, sMailFromRejected
    jr .showEmailStepFail
.rcptToCheckFail
    ld hl, sRcptToRejected
    jr .showEmailStepFail
.dataCheckFail
    ld hl, sDataRejected
    jr .showEmailStepFail
.messageCheckFail
    ld hl, sMessageRejected
.showEmailStepFail
    push hl
    cp a, MAGB_ERR_ISP
    jr nz, .showEmailProtoFail
    call MagbTcpClose
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop hl
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton
.showEmailProtoFail
    push af
    call MagbTcpClose
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    pop hl ; the stage label -- a real protocol error already has its
           ; own specific PrintErrorCode text, no screen room for both
    jp WaitForBackButton

.showTransportFailClosed
    push af
    call MagbTcpClose
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

.showFail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

; ---- Email Recv (POP3, port 110) ----------------------------------------
;
; Matches gbdk's test_isp_email_recv(): POP3 authenticates with
; `USER <local-part-of-email>` / `PASS <ISP PASSWORD>` -- REON's real
; pop3Connection.js checks PASS against the identical log_in_password
; column the GB00/ISP-facing auth uses, so (unlike Email Send/SMTP)
; this one does require the ISP PASSWORD to be set first. After STAT,
; scans up to EMAIL_DELETE_MAX_SCAN messages via `TOP <n> 0` looking for
; this ROM's own test subject line, and DELEs only the ones that match
; -- never guesses, never touches anything else in what is a shared
; test mailbox. Every failure inside that scan loop (TOP unsupported,
; a message missing, a transport hiccup, the remote closing early) just
; stops or skips scanning; it does not fail the whole test, matching
; gbdk's delete_matching_test_emails() exactly (its own comment: "never
; deletes anything else in the mailbox").
; Clobbers: everything

DEF EMAIL_DELETE_MAX_SCAN EQU 20 ; gbdk's EMAIL_DELETE_MAX_SCAN

sPop3UserPrefix: db "USER "
sPop3UserPrefixEnd:
sPop3PassPrefix: db "PASS "
sPop3PassPrefixEnd:
sCrlf: db $0D, $0A
sCrlfEnd:
sPop3Stat: db "STAT", $0D, $0A
sPop3StatEnd:
sPop3TopPrefix: db "TOP "
sPop3TopPrefixEnd:
sPop3TopSuffix: db " 0", $0D, $0A
sPop3TopSuffixEnd:
sPop3DelePrefix: db "DELE "
sPop3DelePrefixEnd:
sPop3HeaderEnd1: db ".", $0D, $0A ; RFC 1939 multi-line terminator
sPop3HeaderEnd1End:
sPop3HeaderEnd2: db ".", $0A
sPop3HeaderEnd2End:
; Same text as (a substring of) sSmtpBody above -- a standalone copy is
; needed here since this one is compared against, not sent, and needs
; its own addressable start/end.
sSmtpSubjectLine: db "Subject: MAGB TestSuite"
sSmtpSubjectLineEnd:
sExpectOk: db "+OK"

sNoEmailPopCfg:  db "NO EMAIL/POP CFG", 0
sNoPopGreeting:  db "NO POP3 GREETING", 0
sUserRejected:   db "USER REJECTED", 0
sLoginFailed:    db "LOGIN FAILED", 0
sStatFailed:     db "STAT FAILED", 0

sPop3MsgsLabel: db "MSGS "
sPop3MsgsLabelEnd:
sPop3DelLabel: db " DEL "
sPop3DelLabelEnd:
sPop3MessagesLabel: db "MESSAGES: "
sPop3MessagesLabelEnd:

; Builds prefix + a NUL-terminated "middle" string + a fixed suffix into
; wEmailCmdBuf -- a more general version of RunEmailSendTest's own
; BuildEmailCommandLine (that one is hardcoded to wIdentityEmail + a
; fixed ">\r\n"; this one's middle/suffix are both caller-supplied,
; needed here for USER <user>/PASS <password> which share no fixed
; suffix character with MAIL FROM/RCPT TO). Takes its inputs from WRAM,
; not registers -- SM83 doesn't have enough register pairs left over
; for prefix+middle+suffix (each a pointer, two also needing a length)
; all at once.
;
; Input: wBuildLinePrefixPtr/Len, wBuildLineMiddlePtr (NUL-terminated),
;        wBuildLineSuffixPtr/Len -- all set by the caller first
; Output: wEmailCmdBuf holds the built line, wEmailCmdLen its length
; Clobbers: everything
BuildLineGeneric:
    ld de, wEmailCmdBuf
    xor a, a
    ld [wEmailCmdLen], a

    ld a, [wBuildLinePrefixPtr]
    ld l, a
    ld a, [wBuildLinePrefixPtr + 1]
    ld h, a
    ld a, [wBuildLinePrefixLen]
    ld b, a
.copyPrefix
    ld a, b
    or a, a
    jr z, .prefixDone
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [wEmailCmdLen]
    inc a
    ld [wEmailCmdLen], a
    dec b
    jr .copyPrefix
.prefixDone

    ld a, [wBuildLineMiddlePtr]
    ld l, a
    ld a, [wBuildLineMiddlePtr + 1]
    ld h, a
.copyMiddle
    ld a, [hl+]
    or a, a
    jr z, .middleDone
    ld [de], a
    inc de
    ld a, [wEmailCmdLen]
    inc a
    ld [wEmailCmdLen], a
    jr .copyMiddle
.middleDone

    ld a, [wBuildLineSuffixPtr]
    ld l, a
    ld a, [wBuildLineSuffixPtr + 1]
    ld h, a
    ld a, [wBuildLineSuffixLen]
    ld b, a
.copySuffix
    ld a, b
    or a, a
    ret z
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [wEmailCmdLen]
    inc a
    ld [wEmailCmdLen], a
    dec b
    jr .copySuffix

; Builds "TOP <wPop3CurMsg> 0\r\n" into wEmailCmdBuf/wEmailCmdLen.
; Clobbers: everything
BuildTopCommand:
    ld de, wEmailCmdBuf
    ld hl, sPop3TopPrefix
    ld b, sPop3TopPrefixEnd - sPop3TopPrefix
.copyPrefix
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyPrefix
    ld a, [wPop3CurMsg]
    call BuildDecimal
    ld hl, sPop3TopSuffix
    ld b, sPop3TopSuffixEnd - sPop3TopSuffix
.copySuffix
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copySuffix
    ; length = DE - wEmailCmdBuf -- safe as a plain 8-bit low-byte
    ; subtraction regardless of any page crossing in between: DE always
    ; equals wEmailCmdBuf + length here, and length < 256, so (DE mod
    ; 256) - (wEmailCmdBuf mod 256), mod 256, is exactly length mod 256
    ; by modular arithmetic -- not the pointer-subtraction pitfall this
    ; project's own BuildIspLoginPayload comment warns about elsewhere
    ; (that one was about an *explicit running counter* being safer than
    ; *not tracking length at all*; here BuildDecimal itself never
    ; reports how many digits it wrote, so this is the only way to know).
    ld hl, wEmailCmdBuf
    ld a, e
    sub a, l
    ld [wEmailCmdLen], a
    ret

; Builds "DELE <wPop3CurMsg>\r\n" into wEmailCmdBuf/wEmailCmdLen. Same
; length-computation note as BuildTopCommand above.
; Clobbers: everything
BuildDeleCommand:
    ld de, wEmailCmdBuf
    ld hl, sPop3DelePrefix
    ld b, sPop3DelePrefixEnd - sPop3DelePrefix
.copyPrefix
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyPrefix
    ld a, [wPop3CurMsg]
    call BuildDecimal
    ld hl, sCrlf
    ld b, sCrlfEnd - sCrlf
.copySuffix
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copySuffix
    ld hl, wEmailCmdBuf
    ld a, e
    sub a, l
    ld [wEmailCmdLen], a
    ret

; Parses leading ASCII decimal digits at [HL] into an 8-bit value,
; stopping at the first non-digit -- used on STAT's "+OK <count> <size>"
; reply (skipping the "+OK " prefix). Matches gbdk's
; parse_leading_uint(), except clamped to a byte: this ROM's decimal
; display (text.asm's BuildDecimal) only handles one byte, and a real
; test mailbox's message count is never remotely close to 256 in
; practice -- purely a display/scan-bound limitation, not a protocol
; correctness gap (EMAIL_DELETE_MAX_SCAN caps the scan at 20 regardless
; of how large the real count is).
; Input: HL = ASCII digits
; Output: A = parsed value (0-255)
; Clobbers: everything
ParseLeadingUint8:
    ld b, 0
.loop
    ld a, [hl]
    cp a, "0"
    jr c, .done
    cp a, "9" + 1
    jr nc, .done
    sub a, "0"
    push af
    ld a, b
    add a, a
    add a, a
    add a, b
    add a, a
    ld b, a
    pop af
    add a, b
    ld b, a
    inc hl
    jr .loop
.done
    ld a, b
    ret

; Prints "MSGS <count> DEL <deleted>" (if anything was deleted) or
; "MESSAGES: <count>" otherwise, at ERROR_ADDR (row 6 -- unused on a
; success path, same trick RunEmailSendTest's "SENT OK" uses). Matches
; gbdk's two-shapes sprintf in test_isp_email_recv()'s final block.
; Clobbers: everything (calls PrintString)
ShowPop3ResultLine:
    ld a, [wPop3Deleted]
    or a, a
    jr z, .noDeleted

    ld de, wPop3ResultMsg
    ld hl, sPop3MsgsLabel
    ld b, sPop3MsgsLabelEnd - sPop3MsgsLabel
.copyMsgsLabel
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyMsgsLabel
    ld a, [wPop3MsgCount]
    call BuildDecimal
    ld hl, sPop3DelLabel
    ld b, sPop3DelLabelEnd - sPop3DelLabel
.copyDelLabel
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyDelLabel
    ld a, [wPop3Deleted]
    call BuildDecimal
    xor a, a
    ld [de], a
    jr .printIt

.noDeleted
    ld de, wPop3ResultMsg
    ld hl, sPop3MessagesLabel
    ld b, sPop3MessagesLabelEnd - sPop3MessagesLabel
.copyMessagesLabel
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyMessagesLabel
    ld a, [wPop3MsgCount]
    call BuildDecimal
    xor a, a
    ld [de], a

.printIt
    ld hl, wPop3ResultMsg
    ld de, ERROR_ADDR
    jp PrintString

RunEmailRecvTest:
    call ClearTextScreen
    ld hl, sSubEmailRecv
    ld de, $9801
    call PrintString

    ld a, [wIspPassword]
    or a, a
    jp z, .noPassword

    ld a, CMD_SESSION
    call SetCommand
    ld a, STATUS_WAKE
    call SetStatus
    call MagbBeginSession
    or a, a
    jp nz, .showFail

    ld a, CMD_READ_ID
    call SetCommand
    call ReadIdentity
    or a, a
    jp nz, .showFail

    ld a, [wIdentityEmail]
    or a, a
    jp z, .noEmailCfg
    ld a, [wIdentityPop]
    or a, a
    jp z, .noEmailCfg

    ; user = local part of email, up to '@'
    ld hl, wIdentityEmail
    ld de, wPop3User
.copyUserLoop
    ld a, [hl+]
    or a, a
    jr z, .userDone
    cp a, "@"
    jr z, .userDone
    ld [de], a
    inc de
    jr .copyUserLoop
.userDone
    xor a, a
    ld [de], a

    ld hl, wIdentityEmail
    ld de, HTTP_ADDR
    call PrintString

    ld a, CMD_DIAL
    call SetCommand
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    ld hl, wIdentityPhone
    ld b, 0
.phoneLenLoop
    ld a, [hl+]
    or a, a
    jr z, .havePhoneLen
    inc b
    jr .phoneLenLoop
.havePhoneLen
    ld hl, wIdentityPhone
    call MagbDial
    or a, a
    jp nz, .showFail

    ld a, CMD_ISP_LOGIN
    call SetCommand
    call BuildIspLoginPayload
    call MagbIspLogin
    or a, a
    jp nz, .showFail

    ld a, CMD_DNS
    call SetCommand
    ld hl, wIdentityPop
    call StrLen8
    ld hl, wIdentityPop
    call MagbDnsQuery
    or a, a
    jp nz, .showFail

    ld a, CMD_TCP_OPEN
    call SetCommand
    ld hl, wDnsResultIp
    ld bc, 110
    call MagbTcpOpen
    or a, a
    jp nz, .showFail
    call TcpLineReset

    ld a, CMD_EMAIL
    call SetCommand
    ld de, wEmailLineBuf
    ld b, EMAIL_RECV_BUF_SIZE
    call TcpRecvLine
    or a, a
    jp nz, .showTransportFailClosed
    ld hl, wEmailLineBuf
    ld de, sExpectOk
    ld b, 3
    call StrPrefixMatch
    or a, a
    jp z, .showNoPopGreeting

    ; USER <user>
    ld hl, sPop3UserPrefix
    ld a, l
    ld [wBuildLinePrefixPtr], a
    ld a, h
    ld [wBuildLinePrefixPtr + 1], a
    ld a, sPop3UserPrefixEnd - sPop3UserPrefix
    ld [wBuildLinePrefixLen], a
    ld hl, wPop3User
    ld a, l
    ld [wBuildLineMiddlePtr], a
    ld a, h
    ld [wBuildLineMiddlePtr + 1], a
    ld hl, sCrlf
    ld a, l
    ld [wBuildLineSuffixPtr], a
    ld a, h
    ld [wBuildLineSuffixPtr + 1], a
    ld a, sCrlfEnd - sCrlf
    ld [wBuildLineSuffixLen], a
    call BuildLineGeneric
    ld hl, wEmailCmdBuf
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, [wEmailCmdLen]
    ld [wEmailStepSendLen], a
    ld hl, wEmailLineBuf
    ld a, l
    ld [wEmailStepRecvPtr], a
    ld a, h
    ld [wEmailStepRecvPtr + 1], a
    ld a, EMAIL_RECV_BUF_SIZE
    ld [wEmailStepRecvCap], a
    ld hl, sExpectOk
    ld a, l
    ld [wEmailStepExpectPtr], a
    ld a, h
    ld [wEmailStepExpectPtr + 1], a
    ld a, 3
    ld [wEmailStepExpectLen], a
    call EmailLineStep
    or a, a
    jp nz, .userCheckFail

    ; PASS <password>
    ld hl, sPop3PassPrefix
    ld a, l
    ld [wBuildLinePrefixPtr], a
    ld a, h
    ld [wBuildLinePrefixPtr + 1], a
    ld a, sPop3PassPrefixEnd - sPop3PassPrefix
    ld [wBuildLinePrefixLen], a
    ld hl, wIspPassword
    ld a, l
    ld [wBuildLineMiddlePtr], a
    ld a, h
    ld [wBuildLineMiddlePtr + 1], a
    ld hl, sCrlf
    ld a, l
    ld [wBuildLineSuffixPtr], a
    ld a, h
    ld [wBuildLineSuffixPtr + 1], a
    ld a, sCrlfEnd - sCrlf
    ld [wBuildLineSuffixLen], a
    call BuildLineGeneric
    ld hl, wEmailCmdBuf
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, [wEmailCmdLen]
    ld [wEmailStepSendLen], a
    call EmailLineStep
    or a, a
    jp nz, .passCheckFail

    ; STAT
    ld hl, sPop3Stat
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, sPop3StatEnd - sPop3Stat
    ld [wEmailStepSendLen], a
    call EmailLineStep
    or a, a
    jp nz, .statCheckFail

    ld hl, wEmailLineBuf + 4 ; skip "+OK " -- the count starts here
    call ParseLeadingUint8
    ld [wPop3MsgCount], a

    cp a, EMAIL_DELETE_MAX_SCAN
    jr c, .scanCountOk
    ld a, EMAIL_DELETE_MAX_SCAN
.scanCountOk
    ld [wPop3ScanCount], a

    xor a, a
    ld [wPop3Deleted], a
    ld a, 1
    ld [wPop3CurMsg], a

.scanMsgLoop
    ld a, [wPop3CurMsg]
    ld b, a
    ld a, [wPop3ScanCount]
    cp a, b
    jp c, .scanDone ; curMsg > scanCount

    call BuildTopCommand
    ld hl, wEmailCmdBuf
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, [wEmailCmdLen]
    ld [wEmailStepSendLen], a
    ld hl, wEmailLineBuf
    ld a, l
    ld [wEmailStepRecvPtr], a
    ld a, h
    ld [wEmailStepRecvPtr + 1], a
    ld a, EMAIL_RECV_BUF_SIZE
    ld [wEmailStepRecvCap], a
    ld hl, sExpectOk
    ld a, l
    ld [wEmailStepExpectPtr], a
    ld a, h
    ld [wEmailStepExpectPtr + 1], a
    ld a, 3
    ld [wEmailStepExpectLen], a
    call EmailLineStep
    or a, a
    jr z, .topOk
    ; gbdk distinguishes "stop scanning" (a real transport error) from
    ; "skip this one message" (TOP simply unsupported/message missing,
    ; transport still fine, MAGB_ERR_ISP) -- never fails the whole test
    ; from inside this loop either way.
    cp a, MAGB_ERR_ISP
    jp z, .skipThisMsg
    jp .scanDone

.topOk
    xor a, a
    ld [wPop3Matched], a
    ld [wPop3HeaderLines], a
.headerLoop
    ld a, [wPop3HeaderLines]
    cp a, 40
    jr nc, .headerScanDone
    inc a
    ld [wPop3HeaderLines], a

    ld de, wEmailLineBuf
    ld b, EMAIL_RECV_BUF_SIZE
    call TcpRecvLine
    or a, a
    jr nz, .scanDone ; real transport error -- stop scanning entirely
    ld a, [wLineRemoteClosed]
    or a, a
    jr nz, .scanDone ; remote closed mid-scan -- stop scanning entirely

    ld hl, wEmailLineBuf
    ld de, sPop3HeaderEnd1
    ld b, sPop3HeaderEnd1End - sPop3HeaderEnd1
    call StrPrefixMatch
    or a, a
    jr nz, .headerScanDone
    ld hl, wEmailLineBuf
    ld de, sPop3HeaderEnd2
    ld b, sPop3HeaderEnd2End - sPop3HeaderEnd2
    call StrPrefixMatch
    or a, a
    jr nz, .headerScanDone

    ld hl, wEmailLineBuf
    ld de, sSmtpSubjectLine
    ld b, sSmtpSubjectLineEnd - sSmtpSubjectLine
    call StrPrefixMatch
    or a, a
    jr z, .headerLoop
    ld a, 1
    ld [wPop3Matched], a
    jr .headerLoop

.headerScanDone
    ld a, [wPop3Matched]
    or a, a
    jr z, .skipThisMsg

    call BuildDeleCommand
    ld hl, wEmailCmdBuf
    ld a, l
    ld [wEmailStepSendPtr], a
    ld a, h
    ld [wEmailStepSendPtr + 1], a
    ld a, [wEmailCmdLen]
    ld [wEmailStepSendLen], a
    call EmailLineStep
    or a, a
    jr nz, .skipThisMsg ; DELE rejected -- just don't count it
    ld a, [wPop3Deleted]
    inc a
    ld [wPop3Deleted], a
    ld a, [wLineRemoteClosed]
    or a, a
    jr nz, .scanDone

.skipThisMsg
    ld a, [wPop3CurMsg]
    inc a
    ld [wPop3CurMsg], a
    jp .scanMsgLoop

.scanDone
    ld hl, sSmtpQuit ; "QUIT\r\n" -- reuses Email Send's string
    ld b, sSmtpQuitEnd - sSmtpQuit
    call TcpSendLine ; best-effort; commits any DELE marks

    ld a, CMD_TCP_CLOSE
    call SetCommand
    call MagbTcpClose

    ld a, CMD_ISP_LOGOUT
    call SetCommand
    call MagbIspLogout

    ld a, CMD_HANGUP
    call SetCommand
    call MagbHangup

    ld a, CMD_END_SESSION
    call SetCommand
    call MagbEndSession

    call ShowPop3ResultLine

    ld hl, sPass
    ld de, RESULT_ADDR
    call PrintString
    jp WaitForBackButton

.noPassword
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld hl, sSetIspPassword
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton

.noEmailCfg
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld hl, sNoEmailPopCfg
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton

.showNoPopGreeting
    call MagbTcpClose
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    ld hl, sNoPopGreeting
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton

.userCheckFail
    ld hl, sUserRejected
    jr .showEmailStepFail
.passCheckFail
    ld hl, sLoginFailed
    jr .showEmailStepFail
.statCheckFail
    ld hl, sStatFailed
.showEmailStepFail
    push hl
    cp a, MAGB_ERR_ISP
    jr nz, .showEmailProtoFail
    call MagbTcpClose
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop hl
    ld de, ERROR_ADDR
    call PrintString
    jp WaitForBackButton
.showEmailProtoFail
    push af
    call MagbTcpClose
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    pop hl
    jp WaitForBackButton

.showTransportFailClosed
    push af
    call MagbTcpClose
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

.showFail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

; ---- Raw TCP (interactive "netcat viewer") ------------------------------
;
; Matches gbdk's test_isp_raw_tcp(): dial the ISP, open a TCP socket to
; an arbitrary address (edited via the same 12-digit EditNumber the P2P
; screens use -- Raw TCP's target is IP-style dialing too, same shape as
; MagbDial's own libmobile phone-address parsing), and display whatever
; comes back live, one incoming Transfer Data poll at a time, until the
; remote closes the connection or B cancels. No fixed request/response
; to validate here -- deliberately the one ISP/HTTP entry that does NOT
; go through a PASS/FAIL screen, matching gbdk's own comment on why (no
; "correct" response exists to check against; the point is the live
; view itself).
;
; Text wraps back to the top of its display area once full rather than
; implementing true scrolling -- long output will eventually overwrite
; the header -- a known, accepted limitation matching gbdk's own stock
; console behavior here.
DEF TEST_ISP_RAW_PORT EQU 8080 ; gbdk/include/test_config.h's TEST_ISP_RAW_PORT
DEF RAW_TCP_POLL_BUF_SIZE EQU 32
DEF RAW_TCP_ROW_FIRST EQU 4
DEF RAW_TCP_ROW_LAST EQU 15 ; inclusive -- row 16/17 stay reserved for the stop hint/end reason
DEF RAW_TCP_END_ADDR  EQU $9A00 ; row 16
DEF RAW_TCP_HINT_ADDR EQU $9A20 ; row 17

sRawTcpTitle:        db "ISP RAW TCP", 0
sRawTcpIpTitle:      db "RAW TCP IP", 0
sRawTcpStopHint:     db "B: STOP", 0
sRawTcpEndedXfer:    db "XFER ERROR", 0
sRawTcpEndedClosed:  db "REMOTE CLOSED", 0
sRawTcpEndedStopped: db "STOPPED (B)", 0
sRawTcpMenuHint:     db "A/B: MENU", 0

; Converts 12 ASCII decimal digits (4 groups of 3, e.g. wRawTcpIp) into
; 4 raw IP bytes -- matches gbdk's parse_ip12(), same digit grouping
; MagbDial/libmobile's own mobile_parse_phoneaddr() uses for a P2P IP
; dial. The output pointer is tracked via WRAM rather than kept live in
; DE across the digit loop below, since DE is needed as scratch for the
; running accumulator's x10 multiply.
; Input: HL = 12 ASCII digits, DE = output 4-byte buffer
; Output: [DE..DE+3] = the 4 IP octets
; Clobbers: everything
ParseIp12:
    ld a, e
    ld [wIpParseOutPtr], a
    ld a, d
    ld [wIpParseOutPtr + 1], a
    ld b, 4
.octetLoop
    xor a, a
    ld [wIpParseAcc], a
    ld c, 3
.digitLoop
    ld a, [hl+]
    sub a, "0"
    ld e, a
    ld a, [wIpParseAcc]
    ld d, a
    add a, a
    add a, a
    add a, d
    add a, a
    add a, e
    ld [wIpParseAcc], a
    dec c
    jr nz, .digitLoop

    ld a, [wIpParseOutPtr]
    ld e, a
    ld a, [wIpParseOutPtr + 1]
    ld d, a
    ld a, [wIpParseAcc]
    ld [de], a
    inc de
    ld a, e
    ld [wIpParseOutPtr], a
    ld a, d
    ld [wIpParseOutPtr + 1], a
    dec b
    jr nz, .octetLoop
    ret

; Moves the Raw TCP display cursor to the start of the next row,
; wrapping RAW_TCP_ROW_LAST back to RAW_TCP_ROW_FIRST.
; Clobbers: A
RawTcpNewline:
    xor a, a
    ld [wRawTcpCol], a
    ld a, [wRawTcpRow]
    inc a
    cp a, RAW_TCP_ROW_LAST + 1
    jr c, .storeRow
    ld a, RAW_TCP_ROW_FIRST
.storeRow
    ld [wRawTcpRow], a
    ret

; Output: HL = $9800 + wRawTcpRow*32 + wRawTcpCol
; Clobbers: A, HL, DE
ComputeRawTcpAddr:
    ld a, [wRawTcpRow]
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld a, [wRawTcpCol]
    ld e, a
    ld d, 0
    add hl, de
    ld de, $9800
    add hl, de
    ret

; Advances the Raw TCP display cursor by one column, wrapping to the
; next row (via RawTcpNewline) once past column 19.
; Clobbers: A
RawTcpAdvance:
    ld a, [wRawTcpCol]
    inc a
    cp a, 20
    jr nc, RawTcpNewline
    ld [wRawTcpCol], a
    ret

; Displays one received byte at the current cursor position and
; advances it -- binary-safe: passes '\n' through as a real newline,
; ignores '\r' outright (a VRAM tile grid has no separate "carriage
; return" concept), and replaces any other control byte with '.',
; matching gbdk's own convention here (print_ascii_field() elsewhere in
; this project does the same for config fields).
; Input: A = raw byte
; Clobbers: everything
RawTcpPutChar:
    cp a, $0D
    ret z
    cp a, $0A
    jp z, RawTcpNewline
    cp a, $20
    jr nc, .haveChar
    ld a, "."
.haveChar
    push af
    call ComputeRawTcpAddr
    pop af
    sub a, $20 ; ASCII -> tile index, matches LoadFont's mapping (tile 0 = ' ')
    ; The tilemap write below must happen with the LCD off, same as every
    ; other VRAM write in this ROM (PrintString/ClearTextScreen/LoadFont
    ; all do this) -- Raw TCP is the one screen that writes live, one
    ; byte at a time, outside any of those functions' own LCD-off/on
    ; bracketing, so without this it was writing directly into VRAM
    ; whenever a byte happened to arrive, including while the PPU was
    ; actively fetching tiles (mode 3) -- a write that lands then is
    ; simply ignored, corrupting/losing exactly the character being
    ; written. Confirmed as the cause of a real report ("some letters,
    ; like O, don't show up") rather than a font-data bug: PrintString's
    ; own LCD-off writes never show this, and nothing about a specific
    ; character (as opposed to *whichever byte's write happened to race
    ; the PPU*) would explain it.
    push af
    push hl
    xor a, a
    ldh [rLCDC], a
    pop hl
    pop af
    ld [hl], a
    ld a, LCDC_ON | LCDC_BG_ON | LCDC_BG_TILEDATA
    ldh [rLCDC], a
    jp RawTcpAdvance

RunRawTcpTest:
    ld hl, wRawTcpIp
    ld de, sRawTcpIpTitle
    call EditNumber
    or a, a
    ret z ; cancelled -- back to the ISP/HTTP submenu, buffer unchanged

    call ClearTextScreen
    ld hl, sRawTcpTitle
    ld de, $9800
    call PrintString

    call MagbBeginSession
    or a, a
    jp nz, .showFail

    call ReadIdentity
    or a, a
    jp nz, .showFail

    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    ld hl, wIdentityPhone
    ld b, 0
.phoneLenLoop
    ld a, [hl+]
    or a, a
    jr z, .havePhoneLen
    inc b
    jr .phoneLenLoop
.havePhoneLen
    ld hl, wIdentityPhone
    call MagbDial
    or a, a
    jp nz, .showFail

    call BuildIspLoginPayloadNoPassword
    call MagbIspLogin
    or a, a
    jp nz, .showFail

    ld hl, wRawTcpIp
    ld de, wRawTcpIpBytes
    call ParseIp12

    ld hl, wRawTcpIpBytes
    ld bc, TEST_ISP_RAW_PORT
    call MagbTcpOpen
    or a, a
    jp nz, .showFail

    ld hl, sRawTcpStopHint
    ld de, $9820
    call PrintString

    ld a, RAW_TCP_ROW_FIRST
    ld [wRawTcpRow], a
    xor a, a
    ld [wRawTcpCol], a

.pollLoop
    call ReadJoypadPressed
    and a, PAD_B
    jr z, .noCancel
    ld hl, sRawTcpEndedStopped
    jp .endLoop
.noCancel

    ld a, MAGB_TIMEOUT_FRAMES_SHORT & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_SHORT >> 8
    ld [wExecTimeoutFrames + 1], a
    ld hl, wRawTcpPollBuf
    ld b, RAW_TCP_POLL_BUF_SIZE - 1
    ld c, 0
    call MagbTransferData
    or a, a
    jr z, .xferOk
    cp a, MAGB_ERR_TIMEOUT
    jr z, .pollLoop ; nothing arrived this poll window -- keep waiting
    ld hl, sRawTcpEndedXfer
    jp .endLoop

.xferOk
    ld a, [wXferGotLen]
    or a, a
    jr z, .checkClosed
    ld hl, wRawTcpPollBuf
    ld b, a
.putLoop
    ld a, [hl+]
    push hl
    push bc
    call RawTcpPutChar
    pop bc
    pop hl
    dec b
    jr nz, .putLoop

.checkClosed
    ld a, [wXferRemoteClosed]
    or a, a
    jr z, .checkEmptyPoll
    ld hl, sRawTcpEndedClosed
    jp .endLoop

.checkEmptyPoll
    ld a, [wXferGotLen]
    or a, a
    jr nz, .pollLoop
    call WaitVBlank
    jp .pollLoop

.endLoop
    ; hl = the end-reason string -- stash it across the cleanup calls
    ; below (all "Clobbers: everything").
    push hl
    call MagbTcpClose
    call MagbIspLogout
    call MagbHangup
    call MagbEndSession
    pop hl

    ld de, RAW_TCP_END_ADDR
    call PrintString
    ld hl, sRawTcpMenuHint
    ld de, RAW_TCP_HINT_ADDR
    call PrintString
    jp WaitForBackButton

.showFail
    push af
    ld hl, sFail
    ld de, RESULT_ADDR
    call PrintString
    pop af
    call PrintErrorCode
    jp WaitForBackButton

; Same two-call cursor-only update trick as DrawMenuCursor -- see that
; function's comment for why a full redraw per keypress isn't used.
; Input: B = item index (0..ISP_SUBMENU_COUNT-1), HL = cursor string
; Clobbers: everything (calls PrintString)
DrawIspSubMenuCursor:
    push hl
    ld a, b
    add a, a
    ld l, a
    ld h, 0
    ld de, IspSubMenuItemAddrs
    add hl, de
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a
    pop hl
    jp PrintString

; Clobbers: everything (calls PrintString repeatedly)
DrawIspSubMenu:
    call ClearTextScreen
    ld hl, sIspSubMenuTitle
    ld de, $9800
    call PrintString

    ld b, 0
.itemLoop
    ld hl, sCursorOff
    ld a, [wIspSubMenuSelected]
    cp a, b
    jr nz, .drawCursor
    ld hl, sCursorOn
.drawCursor
    call DrawIspSubMenuCursor

    ld a, b
    add a, a
    ld l, a
    ld h, 0
    ld de, IspSubMenuItemAddrs
    add hl, de
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a
    inc de ; label starts one column after the cursor
    push de
    ld a, b
    add a, a
    ld l, a
    ld h, 0
    ld de, IspSubMenuLabels
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    pop de
    call PrintString

    ld a, b
    inc a
    ld b, a
    cp a, ISP_SUBMENU_COUNT
    jr c, .itemLoop

    ld hl, sSubMenuFooter
    ld de, $9A00
    jp PrintString

; Runs the ISP/HTTP submenu loop. Returns A = chosen index
; (0..ISP_SUBMENU_COUNT-1) on A, or ISP_SUBMENU_COUNT if B was pressed
; (cancelled) -- matches ui_select_submenu()'s `return count;` sentinel.
; Clobbers: everything
ShowIspSubMenu:
    xor a, a
    ld [wIspSubMenuSelected], a
    call DrawIspSubMenu

.loop
    call WaitVBlank
    call ReadJoypadPressed
    ld b, a

    ld a, b
    and a, PAD_DOWN
    jr z, .checkUp
    ld a, [wIspSubMenuSelected]
    inc a
    cp a, ISP_SUBMENU_COUNT
    jr c, .storeSel
    xor a, a
    jr .storeSel

.checkUp
    ld a, b
    and a, PAD_UP
    jr z, .checkA
    ld a, [wIspSubMenuSelected]
    or a, a
    jr nz, .decSel
    ld a, ISP_SUBMENU_COUNT
.decSel
    dec a
    jr .storeSel

.checkA
    ld a, b
    and a, PAD_A
    jr z, .checkB
    ld a, [wIspSubMenuSelected]
    ret

.checkB
    ld a, b
    and a, PAD_B
    jr z, .loop
    ld a, ISP_SUBMENU_COUNT
    ret

.storeSel
    ld [wIspSubMenuNewSel], a

    ld a, [wIspSubMenuSelected]
    ld b, a
    ld hl, sCursorOff
    call DrawIspSubMenuCursor ; erase the cursor at the old position

    ld a, [wIspSubMenuNewSel]
    ld [wIspSubMenuSelected], a
    ld b, a
    ld hl, sCursorOn
    call DrawIspSubMenuCursor ; draw it at the new position

    jp .loop

; Top-level "ISP/HTTP" menu handler: shows the submenu, then dispatches
; to whichever entry was chosen (or does nothing on cancel -- ShowMenu's
; own CallHL/jp ShowMenu redraws the main menu either way once this
; returns). Every real handler ends the same way every other menu
; handler here does (eventually `jp WaitForBackButton` -> `ret`), so
; tail-jumping into one from CallHL's already-pushed return address
; works exactly like calling it directly, same idiom CallHL itself uses.
; Clobbers: everything
RunIspHttpMenu:
    call ShowIspSubMenu
    cp a, ISP_SUBMENU_COUNT
    ret z ; cancelled (B)

    ld l, a
    ld h, 0
    add hl, hl
    ld de, IspSubMenuHandlers
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    jp hl

; ---- Main menu data ---------------------------------------------------

DEF MENU_ITEM_COUNT EQU 6

MenuItemAddrs: ; rows 4-9, column 0 (cursor); matches gbdk's gotoxy(0, 4+i)
    dw $9880
    dw $98A0
    dw $98C0
    dw $98E0
    dw $9900
    dw $9920

; Exact wording/order matches gbdk/src/app/ui.c's kMenuLabels[] -- the
; outer menu shell is meant to look identical between the two
; implementations, even though several of these still just show
; "NOT IMPLEMENTED" on this side (see docs/status.md).
MenuLabels:
    dw sMenuAdapterSession
    dw sMenuReadConfig
    dw sMenuIspPassword
    dw sMenuIspHttp
    dw sMenuP2pCaller
    dw sMenuP2pListener

MenuHandlers:
    dw RunAdapterSessionTest
    dw RunReadConfigTest
    dw RunIspPasswordEdit
    dw RunIspHttpMenu
    dw RunP2pCaller
    dw RunP2pListener

sMenuTitle1: db "MOBILE ADAPTER GB", 0
sMenuTitle2: db "TESTSUITE", 0
sMenuFooter: db "A:RUN SEL:TRACE", 0

sCursorOn:  db ">", 0
sCursorOff: db " ", 0

sMenuAdapterSession: db "ADAPTER/SESSION", 0
sMenuReadConfig:     db "READ CONFIG", 0
sMenuIspPassword:    db "ISP PASSWORD", 0
sMenuIspHttp:        db "ISP/HTTP", 0
sMenuP2pCaller:      db "P2P CALLER", 0
sMenuP2pListener:    db "P2P LISTENER", 0

sNotImplemented: db "NOT IMPLEMENTED", 0
sAdapterIdLabel: db "ADAPTER ID: ", 0
sConfigChecksumOk:  db "CHECKSUM:OK", 0
sConfigChecksumBad: db "CHECKSUM:BAD", 0

sTraceTitle:    db "PROTOCOL TRACE", 0
sTraceEmpty:    db "(EMPTY)", 0
sTraceTxLabel:  db "TX ", 0
sTraceRxLabel:  db " RX ", 0
sTraceBackHint: db "B: MENU", 0
sNintendoEchoOk: db "NINTENDO ECHO OK", 0

; ---- Display bring-up (tiles/palette only -- text.asm owns the font) ----

; Turns the LCD off (safely, after waiting for VBlank), clears the
; tilemap, then sets a plain black-on-white BG palette 0 and turns the
; LCD back on. LoadFont/ClearTextScreen (text.asm) do their own
; LCD-off/on bracketing around their VRAM writes -- they don't rely on
; being called with the LCD already off, since this function doesn't
; leave it that way.
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
DEF CMD_READ_ID      EQU 10 ; appended, not inserted after CMD_SESSION, to avoid renumbering every other CMD_* constant
DEF CMD_EMAIL        EQU 11 ; Email Send/Recv's whole SMTP/POP3 conversation -- neither protocol maps to a single MAGB command the way the others here do, so this covers every line exchanged after TCP Open

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
    dw sCmdReadId
    dw sCmdEmail

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
sCmdReadId:     db "READ ID", 0
sCmdEmail:      db "EMAIL", 0

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

; Mobile Trainer's real home page -- gbdk/include/test_config.h's
; TEST_HTTP_TRAINER_HOME_PATH (Dan Docs' "Mobile Trainer" section, real
; observed URL, CGB-B9AJ being Mobile Trainer's own game code). Same
; host/port as Tamago Egg above; no GB00 auth needed here (it's outside
; REON's /cgb/download|upload front controller entirely).
sHttpRequestTrainerHome:
    db "GET /01/CGB-B9AJ/index.html HTTP/1.0", $0D, $0A
    db "Host: gameboy.datacenter.ne.jp", $0D, $0A
    db "User-Agent: MAGB-TestSuite/1.0", $0D, $0A
    db "Connection: close", $0D, $0A
    db $0D, $0A
sHttpRequestTrainerHomeEnd:

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
; Input: caller must set [wHttpRequestPtr]/[wHttpRequestLen] to the
;        full request text first -- Tamago Egg and Trainer Home share
;        this one function via RunIspHttpCore, differing only in which
;        request text (and title) they set before jumping in.
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

    ld a, [wHttpRequestPtr]
    ld e, a
    ld a, [wHttpRequestPtr + 1]
    ld d, a
    ld a, [wHttpRequestLen]
    ld c, a
    ld hl, wHttpRespBuf
    ld b, HTTP_RESP_BUF_SIZE
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
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
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
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

    jp .pollLoop

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
sTrainerHomeTitle: db "TRAINER HOME", 0
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
    dw sErrP2p                ; MAGB_ERR_P2P
    dw sErrCancelled          ; MAGB_ERR_CANCELLED

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
sErrP2p:                db "BAD P2P FRAME", 0
sErrCancelled:          db "CANCELLED", 0

SECTION "Config UI Scratch", WRAM0
wConfigPage: db     ; current page, 0..CONFIG_PAGE_COUNT-1
wPhoneScratch: ds 17 ; MagbConfigDecodePhone's output buffer (16 digits/symbols + NUL)

SECTION "Edit Text Scratch", WRAM0
wEditBufPtr: dw   ; the caller's real buffer, written back on A
wEditLabelPtr: dw
wEditMaxLen: db
wEditCursor: db
wEditWork: ds EDIT_TEXT_MAX_LEN + 1

SECTION "ISP Password State", WRAM0
; Starts empty (byte 0 = NUL) -- WRAM isn't guaranteed zeroed at boot on
; real hardware, but SerialHwInit's own xor-a/ld-[wSysTime] pattern
; doesn't extend to every WRAM byte in the ROM, so this needs its own
; explicit init. Zeroed once by EntryPoint alongside wMenuSelected.
wIspPassword: ds ISP_PASSWORD_MAX_LEN + 1

SECTION "Isp Identity Scratch", WRAM0
wIdentityLogin: ds MAGB_CONFIG_LOGIN_ID_LEN + 1
wIdentityPhone: ds 17 ; MagbConfigDecodePhone's own worst case: 16 digits/symbols + NUL
wIdentityEmail: ds MAGB_CONFIG_EMAIL_LEN + 1
wIdentitySmtp:  ds MAGB_CONFIG_SMTP_LEN + 1
wIdentityPop:   ds MAGB_CONFIG_POP_LEN + 1

SECTION "Isp Login Build Scratch", WRAM0
wIspLoginBuiltPayload: ds ISP_LOGIN_PAYLOAD_MAX
wIspLoginBuiltLen: db

SECTION "News Test Scratch", WRAM0
wGb00StatusMsg: ds 16 ; "HTTP nnn (AUTH)" or "CFG nnn ART nnn" + NUL
wNewsArticleCfgStatus: ds 4 ; News Article's config-fetch status, stashed
                             ; before the article fetch overwrites
                             ; wGb00FetchStatusText

DEF EMAIL_LINE_BUF_SIZE EQU 72 ; gbdk's MAGB_CONFIG_EMAIL_LEN(24) + 48 -- big
                                 ; enough for every command *this ROM sends*
                                 ; (wEmailCmdBuf only), never for a real
                                 ; server reply -- see EMAIL_RECV_BUF_SIZE
; A real single Transfer Data response can be up to PROTO_MAX_PAYLOAD_LEN-1
; bytes (the MAGB protocol's own per-packet ceiling) REGARDLESS of what
; capacity this ROM asks for -- confirmed the hard way against a real
; POP3 TOP reply (5 header lines + terminator, ~77 bytes) that arrived as
; one packet: MagbTransferData's own clamp-to-output-capacity silently
; drops whatever doesn't fit (its own comment's "caller re-polls" assumes
; the adapter's TCP buffer still has the rest, but a real adapter already
; delivered its *entire* single-packet reply in that one exchange, so the
; dropped tail -- here, the reply's own end-of-message terminator -- is
; gone for good). Every following poll for "the rest" then legitimately
; gets nothing, and Email Recv's header-scan loop spun through all 40
; iterations, each a real ~15s network round trip, before ever giving up
; -- the "trava"/infinite `>>> 15 Transfer data` loop a real libmobile-bgb
; run surfaced (2026-08-29/30). Fixed by giving wEmailLineBuf enough
; capacity that this clamp can never trigger for a real single-packet
; reply: PROTO_MAX_PAYLOAD_LEN itself, the same margin HTTP GET/GB00
; fetches already have relative to *their* single-poll capacity.
DEF EMAIL_RECV_BUF_SIZE EQU PROTO_MAX_PAYLOAD_LEN

SECTION "Email Test Scratch", WRAM0
wEmailLineBuf: ds EMAIL_RECV_BUF_SIZE ; reused for every SMTP/POP3 reply
wEmailCmdBuf:  ds EMAIL_LINE_BUF_SIZE ; MAIL FROM/RCPT TO/USER, built live
wEmailCmdLen:  db

wBuildLinePrefixPtr: dw
wBuildLinePrefixLen: db
wBuildLineMiddlePtr: dw
wBuildLineSuffixPtr: dw
wBuildLineSuffixLen: db

wPop3User: ds MAGB_CONFIG_EMAIL_LEN + 1
wPop3MsgCount: db
wPop3ScanCount: db
wPop3CurMsg: db
wPop3Deleted: db
wPop3HeaderLines: db
wPop3Matched: db
wPop3ResultMsg: ds 20 ; "MSGS nnn DEL nnn" or "MESSAGES: nnn" + NUL

wRawTcpIp: ds 13      ; 12-digit NUL-terminated, edited via EditNumber
wRawTcpIpBytes: ds 4  ; ParseIp12's output
wRawTcpRow: db
wRawTcpCol: db
wRawTcpPollBuf: ds RAW_TCP_POLL_BUF_SIZE
wIpParseOutPtr: dw
wIpParseAcc: db

SECTION "MATS Scratch", WRAM0
wMatsFrame: ds MATS_HEADER_LEN + MATS_MAX_PAYLOAD
wMatsSeqScratch: db
wMatsInLen: db
wMatsRecvSeq:: db
wMatsRecvLen:: db
wMatsRecvPayload:: ds MATS_MAX_PAYLOAD

SECTION "P2P State", WRAM0
wP2pDiscardByte: db ; P2pSendFrame's response-payload sink (0 capacity, never written)
wP2pPollBuf: ds MATS_HEADER_LEN + MATS_MAX_PAYLOAD ; P2pRecvFrame's raw Transfer Data receive buffer
; Default matches gbdk's TEST_P2P_PHONE (test_config.h) -- a loopback-
; style direct-IP P2P address, editable via the menu's P2P CALLER item.
; WRAM can't hold ROM initial-value data (`db` needs an image to load
; from) -- copied in from sP2pDefaultNumber by EntryPoint instead, once,
; alongside wMenuSelected/wIspPassword.
wP2pNumber: ds 13

SECTION "Edit Number Scratch", WRAM0
wNumBufPtr: dw
wNumLabelPtr: dw
wNumCursor: db
wNumWork: ds P2P_NUMBER_LEN + 1

SECTION "Trace UI Scratch", WRAM0
wTraceTotalPairs: db
wTraceRowIndex: db  ; current pair index i, start_pair..total_pairs-1
wTraceOldest: db    ; physical index of the oldest entry still in the buffer
wTraceIdxTx: db
wTraceIdxRx: db
wTraceRowAddr: dw   ; current tilemap row address

SECTION "Menu State", WRAM0
wMenuSelected: db  ; currently highlighted item, 0..MENU_ITEM_COUNT-1
wMenuNewSel: db    ; ShowMenu's .storeSel scratch: new index, survives the
                    ; DrawMenuCursor call that erases the old cursor first

SECTION "Isp Submenu State", WRAM0
wIspSubMenuSelected: db ; reset to 0 every ShowIspSubMenu entry, unlike
                         ; wMenuSelected -- see ShowIspSubMenu's comment
wIspSubMenuNewSel: db   ; same role as wMenuNewSel, for the submenu

SECTION "HTTP Scratch", WRAM0
wHttpRequestPtr: dw  ; set by RunIspHttpCore's caller before the jp -- the
                      ; full GET request text HttpFetch should send
wHttpRequestLen: db  ; byte count for wHttpRequestPtr
wHttpTestTitle: dw    ; set by RunIspHttpCore's caller before the jp -- the
                      ; title string printed at the top of the screen
wHttpRespBuf: ds HTTP_RESP_BUF_SIZE
wHttpRespLen: db   ; bytes currently held in wHttpRespBuf (0..HTTP_RESP_BUF_SIZE)
wHttpTotalRecv: dw ; total bytes received across every poll (for the 8192 cap)
wHttpEmptyPolls: db
wHttpLastCap: db   ; the capacity HttpFetch's poll loop passed on its most
                    ; recent MagbTransferData call -- MagbTransferData
                    ; clobbers everything, so this can't just live in a
                    ; register across that call
wHttpStatusMsg: ds 9 ; "HTTP " (5) + 3 status digits + null
