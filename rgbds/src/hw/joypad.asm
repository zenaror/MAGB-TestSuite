; Joypad polling. Pure hardware register access, same layering rule as
; serial.asm -- no menu/test knowledge here, just "what's held right
; now" and "what was newly pressed since the last call".

INCLUDE "hardware.inc"

SECTION "Joypad State", WRAM0
wJoypadHeld: db ; ReadJoypadPressed's own previous-frame snapshot

SECTION "Joypad Code", ROM0

; Reads the current state of all 8 buttons in one call.
;
; The GBC joypad only ever exposes 4 input lines at a time, multiplexed
; by which of P14/P15 (rP1 bits 4/5) is driven low, and those lines need
; a few read cycles to settle after switching which group is selected
; (universal real-hardware joypad quirk, not specific to this project).
; Both groups are read in turn and combined into one byte; rP1 is left
; fully deselected ($30) afterwards rather than latched on either group.
;
; Output: A = bitmask, PAD_* bits set for buttons currently held (1 = held)
; Clobbers: A
ReadJoypad::
    ld a, P1_SELECT_DPAD
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1] ; let the lines settle
    cpl
    and a, $0F ; bits 0-3 = right,left,up,down (now active-high)
    ld b, a

    ld a, P1_SELECT_BUTTONS
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    cpl
    and a, $0F ; bits 0-3 = a,b,select,start (now active-high)
    swap a ; -> bits 4-7, so it doesn't collide with the d-pad bits above
    or a, b

    ld b, a ; stash the result across the deselect write below
    ld a, P1_SELECT_NONE
    ldh [rP1], a
    ld a, b
    ret

; Same button state as ReadJoypad, but returns only buttons newly
; pressed since the last call (rising edge) -- one event per physical
; press instead of one every single frame a button is held down. Used
; by every screen that doesn't need held-direction auto-repeat (the
; main menu, the ISP/HTTP submenu, the Read Config pager, ...) --
; matches gbdk's wait_key_edge() convention: repeat is opt-in
; (ReadJoypadRepeat below), not the default everywhere.
;
; Output: A = bitmask, PAD_* bits set only for buttons newly pressed
;         this call
; Clobbers: A
ReadJoypadPressed::
    call ReadJoypad
    ld b, a
    ld a, [wJoypadHeld]
    cpl
    and a, b
    push af
    ld a, b
    ld [wJoypadHeld], a
    pop af
    ret

SECTION "Joypad Repeat State", WRAM0
wRepeatPrev:       db ; ReadJoypadRepeat's own previous-frame snapshot (A/B edge only)
wRepeatHeldUp:     db ; consecutive frames UP has been continuously held
wRepeatHeldDown:   db
wRepeatHeldLeft:   db
wRepeatHeldRight:  db

SECTION "Joypad Repeat Code", ROM0

; A D-pad direction held past REPEAT_DELAY frames fires a synthetic
; repeat event every REPEAT_INTERVAL frames after that (ReadJoypadRepeat
; below) -- the RGBDS-side equivalent of gbdk's REPEAT_DELAY/
; REPEAT_INTERVAL (ui.c), same values, same rationale: holding a
; direction should move the cursor/cycle a character faster than one
; press per step, matching what every other GBC text/number entry
; screen does.
DEF REPEAT_DELAY    EQU 18 ; ~0.3s held (at ~59.7Hz) before repeat starts
DEF REPEAT_INTERVAL EQU 6  ; then repeats roughly 10x/sec

; Must be called once right before an editor's input loop starts, so a
; key already held from selecting the menu entry that opened the editor
; isn't misread as a fresh A/B edge on the very first poll -- the
; RGBDS-side equivalent of gbdk's wait_key_repeat_reset().
; Clobbers: A
ReadJoypadRepeatReset::
    call ReadJoypad
    ld [wRepeatPrev], a
    xor a, a
    ld [wRepeatHeldUp], a
    ld [wRepeatHeldDown], a
    ld [wRepeatHeldLeft], a
    ld [wRepeatHeldRight], a
    ret

; Input: A = this direction's held-counter value (BEFORE this frame's
;        increment)
; Output: Z set if a repeat event is due this frame -- either this is
;         the very first frame the direction reads as held (A == 0,
;         the repeat-counter equivalent of a fresh edge), or A has
;         reached REPEAT_DELAY and is now sitting exactly on a
;         REPEAT_INTERVAL boundary past it
; Clobbers: A
IsRepeatDue:
    or a, a
    ret z
    cp a, REPEAT_DELAY
    ret c
    sub a, REPEAT_DELAY
.modLoop
    cp a, REPEAT_INTERVAL
    jr c, .modDone
    sub a, REPEAT_INTERVAL
    jr .modLoop
.modDone
    or a, a
    ret

; Like ReadJoypadPressed, but a D-pad direction held past REPEAT_DELAY
; frames also fires a synthetic repeat event every REPEAT_INTERVAL
; frames after that -- the RGBDS-side equivalent of gbdk's
; wait_key_repeat(). A/B still only fire on a fresh press (no repeat --
; nothing in this ROM holds A/B to mean "do it 10 times a second").
; Blocks internally on WaitVBlank and only returns once per meaningful
; event (a fresh press or a repeat tick), never once per raw frame --
; see gbdk's ui.c wait_key_repeat() comment for why that distinction
; matters (an earlier gbdk attempt that returned once per frame
; regardless of input looked exactly like a hang under PyBoy
; inspection, since the caller's loop just kept redrawing the screen at
; 60Hz instead of blocking for a real event).
;
; Callers must call ReadJoypadRepeatReset once before their first call
; to this in a given editor session (see above).
; Output: A = bitmask, PAD_* bits set for whichever event(s) fired
;         (always nonzero -- this never returns having fired nothing)
; Clobbers: everything
ReadJoypadRepeat::
.loop
    call WaitVBlank
    call ReadJoypad
    ld b, a ; b = cur, held for the rest of this iteration

    ld a, [wRepeatPrev]
    cpl
    and a, b
    and a, PAD_A | PAD_B
    ld c, a ; c = fired accumulator, starts with any fresh A/B press
    ld a, b
    ld [wRepeatPrev], a

    ; ---- UP ----
    ld a, b
    and a, PAD_UP
    jr z, .upReset
    ld a, [wRepeatHeldUp]
    call IsRepeatDue
    jr nz, .upNoFire
    ld a, c
    or a, PAD_UP
    ld c, a
.upNoFire
    ld a, [wRepeatHeldUp]
    cp a, $FF
    jr z, .checkDown
    inc a
    ld [wRepeatHeldUp], a
    jr .checkDown
.upReset
    xor a, a
    ld [wRepeatHeldUp], a

.checkDown
    ld a, b
    and a, PAD_DOWN
    jr z, .downReset
    ld a, [wRepeatHeldDown]
    call IsRepeatDue
    jr nz, .downNoFire
    ld a, c
    or a, PAD_DOWN
    ld c, a
.downNoFire
    ld a, [wRepeatHeldDown]
    cp a, $FF
    jr z, .checkLeft
    inc a
    ld [wRepeatHeldDown], a
    jr .checkLeft
.downReset
    xor a, a
    ld [wRepeatHeldDown], a

.checkLeft
    ld a, b
    and a, PAD_LEFT
    jr z, .leftReset
    ld a, [wRepeatHeldLeft]
    call IsRepeatDue
    jr nz, .leftNoFire
    ld a, c
    or a, PAD_LEFT
    ld c, a
.leftNoFire
    ld a, [wRepeatHeldLeft]
    cp a, $FF
    jr z, .checkRight
    inc a
    ld [wRepeatHeldLeft], a
    jr .checkRight
.leftReset
    xor a, a
    ld [wRepeatHeldLeft], a

.checkRight
    ld a, b
    and a, PAD_RIGHT
    jr z, .rightReset
    ld a, [wRepeatHeldRight]
    call IsRepeatDue
    jr nz, .rightNoFire
    ld a, c
    or a, PAD_RIGHT
    ld c, a
.rightNoFire
    ld a, [wRepeatHeldRight]
    cp a, $FF
    jr z, .done
    inc a
    ld [wRepeatHeldRight], a
    jr .done
.rightReset
    xor a, a
    ld [wRepeatHeldRight], a

.done
    ld a, c
    or a, a
    jp z, .loop
    ret
