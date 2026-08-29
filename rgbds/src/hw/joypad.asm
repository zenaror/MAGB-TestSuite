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
; press instead of one every single frame a button is held down. The
; menu (main.asm) is the only caller so far.
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
