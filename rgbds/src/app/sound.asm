; Layer 3 -- tiny UI feedback sounds (menu move/select, test pass/fail).
; Pure GBC APU register writes (channel 1 square wave only, no
; tracker/soundfont dependency) -- a straight SM83 port of gbdk's
; sound.c/sound.h (see docs/status.md), same tone/envelope/duration
; values. Each call blocks for a handful of VBlanks (the same
; WaitVBlank-loop style already used for serial timeouts/pacing
; elsewhere in this project) and returns once the sound has finished
; playing -- short enough that this doesn't make the UI feel
; unresponsive.

INCLUDE "hardware.inc"

SECTION "Sound Code", ROM0

; Enables the APU and sets a sensible master volume/panning. Call once
; at startup.
; Clobbers: A
SoundInit::
    ld a, AUDENA_ON
    ldh [rNR52], a
    ld a, AUDTERM_1_LEFT | AUDTERM_1_RIGHT
    ldh [rNR51], a
    ld a, AUDVOL_MAX
    ldh [rNR50], a
    ret

; Blocks for B VBlanks (B may be 0, in which case this returns
; immediately).
; Clobbers: A, B
WaitFrames:
    ld a, b
    or a, a
    ret z
    call WaitVBlank
    dec b
    jr WaitFrames

; Plays one channel-1 square tone and blocks until it's done.
; Input: DE = 11-bit period (freq_hz = 131072 / (2048 - period)),
;        C  = duty (NR11 bits 7-6, e.g. DUTY_50),
;        H  = envelope (raw NR12 byte: bits 7-4 initial volume, bit 3
;             direction, bits 2-0 sweep pace),
;        B  = frames to hold (VBlanks) -- channel 1's own length timer
;             is left disabled, this controls duration instead, same as
;             gbdk's play_tone().
; Clobbers: everything
PlayTone:
    xor a, a
    ldh [rNR10], a ; no pitch sweep
    ld a, c
    ldh [rNR11], a
    ld a, h
    ldh [rNR12], a
    ld a, e
    ldh [rNR13], a
    ld a, d
    or a, AUDHIGH_RESTART
    ldh [rNR14], a
    jp WaitFrames

; Short high blip -- menu cursor move / item chosen.
; Clobbers: everything
SoundSelect::
    ld de, 1884 ; ~800 Hz
    ld c, DUTY_50
    ld h, $81 ; vol 8, decreasing, sweep pace 1
    ld b, 3
    jp PlayTone

; Short low buzz -- a test failed.
; Clobbers: everything
SoundError::
    ld de, 1393 ; ~200 Hz
    ld c, DUTY_50
    ld h, $84 ; vol 8, decreasing, sweep pace 4
    ld b, 10
    jp PlayTone

; Two short ascending tones -- a test passed.
; Clobbers: everything
SoundSuccess::
    ld de, 1797 ; C5
    ld c, DUTY_50
    ld h, $C2
    ld b, 4
    call PlayTone
    ld de, 1881 ; G5
    ld c, DUTY_50
    ld h, $C2
    ld b, 6
    jp PlayTone
