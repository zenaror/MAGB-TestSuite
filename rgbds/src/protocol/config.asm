; Pure, hardware-independent parsing of the 192-byte Mobile Adapter GB
; configuration blob (Read Configuration Data, 0x19 -- see session.asm's
; MagbReadConfig, which fills wConfigData). Checksum check and the
; Configuration Slot BCD phone decode; see gbdk/include/magb_config.h
; for the same two operations on the C side. Everything else (field
; offsets) is simple enough to read directly from main.asm's
; ShowConfigScreen without a wrapper function per field, matching how
; gbdk's own ui_show_config() indexes config[MAGB_CONFIG_OFF_*] directly
; too.

INCLUDE "hardware.inc"
INCLUDE "protocol.inc"

SECTION "Config Code", ROM0

; True (A=1) if wConfigData[190:192] (big-endian) equals the 16-bit
; unsigned additive sum of wConfigData[0:190] -- same algorithm as
; gbdk's magb_config_checksum_ok(), confirmed there against a real
; captured config blob (gbdk/tests/host/test_config.c).
;
; Output: A = 1 if the checksum matches, 0 otherwise
; Clobbers: everything
MagbConfigChecksumOk::
    ld hl, wConfigData
    ld bc, 0 ; running 16-bit sum, low byte in c, high byte in b
    ld de, MAGB_CONFIG_OFF_CHECKSUM
.sumLoop
    ld a, [hl+]
    add a, c
    ld c, a
    jr nc, .noCarry
    inc b
.noCarry
    dec de
    ld a, d
    or a, e
    jr nz, .sumLoop

    ; hl now points at wConfigData + MAGB_CONFIG_OFF_CHECKSUM
    ld a, [hl+]
    cp a, b
    jr nz, .mismatch
    ld a, [hl]
    cp a, c
    jr nz, .mismatch

    ld a, 1
    ret
.mismatch
    xor a, a
    ret

SECTION "Config Decode Scratch", WRAM0
wPhoneNibbleParity: db ; 0 = next nibble is a byte's high nibble, 1 = low

SECTION "Config Decode Code", ROM0

; Decodes an 8-byte BCD-packed Configuration Slot phone number (nibbles
; read high-then-low, byte by byte) into a NUL-terminated ASCII string.
; 0xA -> '#', 0xB -> '*', 0xF -> stop immediately (the documented
; end-of-number marker; any remaining nibbles are unused filler), 0-9 ->
; the matching ASCII digit. Same algorithm as gbdk's
; magb_config_decode_phone().
;
; Input:  HL = 8-byte BCD source (e.g. wConfigData + MAGB_CONFIG_OFF_SLOT1)
;         DE = dest buffer, at least 17 bytes (16 possible digits/symbols + NUL)
; Output: DE's buffer is NUL-terminated; A = characters written (0 if
;         the first nibble was already the end marker -- an empty slot)
; Clobbers: everything
MagbConfigDecodePhone::
    xor a, a
    ld [wPhoneNibbleParity], a
    ld c, 0 ; characters written so far
    ld b, 16 ; nibbles remaining (8 bytes * 2)
.nibbleLoop
    ld a, [wPhoneNibbleParity]
    or a, a
    jr nz, .lowNibble
    ld a, [hl]
    swap a
    jr .haveNibble
.lowNibble
    ld a, [hl]
.haveNibble
    and a, $0F

    cp a, MAGB_CONFIG_PHONE_NIBBLE_END
    jr z, .done
    cp a, MAGB_CONFIG_PHONE_NIBBLE_HASH
    jr z, .isHash
    cp a, MAGB_CONFIG_PHONE_NIBBLE_STAR
    jr z, .isStar
    add a, "0"
    jr .writeChar
.isHash
    ld a, "#"
    jr .writeChar
.isStar
    ld a, "*"
.writeChar
    ld [de], a
    inc de
    inc c

    ld a, [wPhoneNibbleParity]
    xor a, 1
    ld [wPhoneNibbleParity], a
    jr nz, .noAdvance ; parity just became 1 (low nibble next) -- same byte
    inc hl ; parity just became 0 (high nibble next) -- move to the next byte
.noAdvance
    dec b
    jr nz, .nibbleLoop

.done
    xor a, a
    ld [de], a
    ld a, c
    ret
