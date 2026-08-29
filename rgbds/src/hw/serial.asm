; Hardware serial layer for the Mobile Adapter GB link.
;
; Mirrors gbdk/src/hw/serial_hw.c exactly at the register-write level --
; this project's GBDK implementation already hit and fixed real hardware
; issues here (see gbdk/docs/journal.md, "Handshake / sessao inicial"), so
; this is a faithful port of already-validated behavior, not a fresh
; design. Knows nothing about MAGB packet framing or protocol semantics --
; see src/protocol/packet.asm for that.

INCLUDE "hardware.inc"

; Loop-iteration budget for a single byte transfer's busy-wait. Not a
; calibrated real-time duration (unlike the GBDK version's frame-based
; timeouts) -- a single serial byte at CGB double-speed clock completes in
; microseconds, so this is generous headroom against a genuinely stuck/
; disconnected link, not a tuned value. Revisit once this is exercised
; against real hardware.
DEF SERIAL_BYTE_TIMEOUT EQU 8192

SECTION "Serial Timer", WRAM0

; Free-running ~59.7 Hz VBlank counter, incremented by the VBlank ISR
; below. Mirrors gbdk/src/hw/serial_hw.c's sys_time -- used by
; session.asm's wait-for-response timeout the same way
; serial_elapsed_frames()/MAGB_TIMEOUT_FRAMES_* are used there.
wSysTime:: dw

SECTION "VBlank Vector", ROM0[$0040]
    jp VBlankISR

SECTION "VBlank Interrupt Handler", ROM0

VBlankISR:
    push af
    push hl
    ld hl, wSysTime
    inc [hl]
    jr nz, .noCarry
    inc hl
    inc [hl]
.noCarry
    pop hl
    pop af
    reti

SECTION "Serial HW Code", ROM0

; Returns the current value of wSysTime.
; Output: DE = wSysTime
; Clobbers: A, HL
SerialNow::
    ld hl, wSysTime
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a
    ret

; Frames elapsed since a previous SerialNow snapshot. Unsigned
; wraparound-safe (a plain 16-bit subtraction), matching
; gbdk/include/serial_hw.h's serial_elapsed_frames() exactly.
;
; Input:  BC = snapshot from a previous SerialNow call
; Output: DE = elapsed frames (wSysTime - BC)
; Clobbers: A, HL
SerialElapsedFrames::
    call SerialNow
    ld a, e
    sub a, c
    ld e, a
    ld a, d
    sbc a, b
    ld d, a
    ret

; Aborts any in-progress serial transfer immediately.
; Clobbers: A
SerialAbort::
    xor a
    ldh [rSC], a
    ret

; Transfers one byte over the serial port in GBC high-speed
; internal-clock mode (the Mobile Adapter GB requires this; see
; hardware.inc's SC_CLOCK_SPEED comment for why SC is written in two
; separate steps rather than one combined write).
;
; Input:   A = byte to transmit
; Output:  A = byte received (only meaningful if carry is clear)
;          carry SET   = timed out, transfer aborted, no byte received
;          carry CLEAR = success
; Clobbers: HL
SerialTransferByte::
    ldh [rSB], a

    ld a, SC_CLOCK_INT | SC_CLOCK_SPEED
    ldh [rSC], a
    ld a, SC_XFER_START | SC_CLOCK_INT | SC_CLOCK_SPEED
    ldh [rSC], a

    ld hl, SERIAL_BYTE_TIMEOUT
.wait
    ldh a, [rSC]
    and a, SC_XFER_START
    jr z, .done

    dec hl
    ld a, h
    or a, l
    jr nz, .wait

    ; Timed out: a missing/unresponsive adapter must not hang the ROM.
    call SerialAbort
    scf
    ret

.done
    ldh a, [rSB]
    or a, a ; clear carry: success
    ret

; One-time hardware bring-up: refuses to continue on non-CGB hardware
; (the GBC high-speed serial mode this ROM depends on doesn't exist on
; DMG/MGB), switches the CPU to CGB double speed, zeroes wSysTime, and
; enables+unmasks the VBlank interrupt (session.asm's response-wait
; timeout needs wSysTime actually advancing).
;
; Input: none. Register A must still hold the boot-time hardware
;        identification byte (the CGB boot ROM leaves $11 in A; DMG
;        leaves $01) -- callers must invoke this before clobbering A
;        with anything else after the jp EntryPoint in the header.
; Never returns if the console is not a CGB.
SerialHwInit::
    cp a, $11
    jr z, .isCgb

    ; Not a CGB: halt permanently rather than run with an invalid serial
    ; configuration. This is a deliberate, permanent stop -- not a wait
    ; on external (Mobile Adapter) hardware -- so an unbounded loop here
    ; is correct, not a violation of this project's "always bound
    ; hardware waits" rule.
    di
.haltForever
    halt
    nop
    jr .haltForever

.isCgb
    ld a, KEY1_PREPARE_SWITCH
    ldh [rKEY1], a
    stop

    call SerialAbort

    ; WRAM contents are not guaranteed zero at boot on real hardware.
    xor a, a
    ld [wSysTime], a
    ld [wSysTime + 1], a

    ld a, IEF_VBLANK
    ldh [rIE], a
    ei

    ret
