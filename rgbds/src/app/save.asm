; ---- Battery-backed cartridge SRAM: the ISP password ------------------
;
; Port of gbdk's src/app/save.c, same on-cart format byte for byte, so a
; save written by either ROM is readable by the other. (They do not
; share a .sav in practice -- the two builds have different filenames --
; but keeping one format means one thing to reason about, and the
; checksum/magic/version rules below only have to be right once.)
;
; This ROM was mapperless (cart type $00, 32 KiB) until now, and the
; password lived in WRAM and was gone at power-off. Adding MBC5 with
; RAM+BATTERY (cart type $1B) is what makes it persist; the GBDK side
; got the mapper first, for code space, and picked up the battery on the
; way past.
;
; WHAT THIS STORES, AND WHERE IT ENDS UP: the password is written to
; cartridge SRAM verbatim. On an emulator that is a plain .sav file
; next to the ROM; on hardware it is the cart's battery-backed RAM. It is not
; encrypted or obscured -- there is nothing on a Game Boy to encrypt it
; with, and a cart's owner can always read its own save RAM. Treat the
; .sav as holding a real account credential: do not commit it, attach it
; to a bug report, or hand it to anyone you would not hand the password
; to. (The repo's .gitignore already excludes the whole emulator working
; directory, which is where BGB writes it.)

INCLUDE "hardware.inc"

; MBC5 control registers. Writes to these ROM addresses reach the
; mapper, not memory.
DEF MBC_RAMG EQU $0000 ; $0A enables cart RAM, anything else disables
DEF MBC_RAMB EQU $4000 ; cart RAM bank number
DEF SRAM_BASE EQU $A000

; Record layout, serialized explicitly. Same reasoning as the protocol
; layer (repo-root CLAUDE.md, "Do not rely on packed C structs"), and
; here it also pins the on-cart format so a toolchain change cannot
; silently invalidate everyone's save.
;
;   0   'M'
;   1   'A'
;   2   layout version
;   3   password length (0..SAVE_MAX_LEN)
;   4.. password bytes, not NUL-terminated
;   4+n additive checksum of bytes 0..4+n-1
DEF SAVE_OFF_MAGIC0  EQU 0
DEF SAVE_OFF_MAGIC1  EQU 1
DEF SAVE_OFF_VERSION EQU 2
DEF SAVE_OFF_LEN     EQU 3
DEF SAVE_OFF_DATA    EQU 4

DEF SAVE_MAGIC0  EQU $4D ; 'M'
DEF SAVE_MAGIC1  EQU $41 ; 'A'
; Bumping this is how to change the layout: an old record then fails
; validation and is treated as absent, rather than being read back
; through the wrong field offsets.
DEF SAVE_VERSION EQU 1

DEF SAVE_MAX_LEN EQU 8 ; matches ISP_PASSWORD_MAX_LEN / gbdk's TEST_ISP_PASSWORD_MAX_LEN

SECTION "Save Code", ROMX, BANK[1]

; Additive checksum over SRAM bytes 0 .. SAVE_OFF_DATA+len-1.
; Input: A = len
; Output: A = checksum
; Clobbers: A, B, C, HL
SaveChecksum:
    add a, SAVE_OFF_DATA
    ld b, a       ; bytes to sum
    ld hl, SRAM_BASE
    xor a, a
    ld c, a
.loop
    ld a, b
    or a, a
    jr z, .done
    ld a, c
    add a, [hl]
    ld c, a
    inc hl
    dec b
    jr .loop
.done
    ld a, c
    ret

; Reads a previously stored password into [HL], NUL-terminated, writing
; at most B-1 characters.
;
; Returns A=0 and an empty string whenever SRAM does not hold a record
; this build wrote and can still read: never written, a dead battery, an
; older layout, or a corrupted one. Uninitialized cart RAM is arbitrary
; bytes, so "looks like a password" is not good enough -- magic, layout
; version and checksum must all agree before a single byte is handed
; back. Silently loading garbage would resurrect exactly the bug that
; made a compiled-in default worth deleting: an authentication failure
; whose real cause is invisible.
;
; Input:  HL = destination buffer, B = capacity including the NUL
; Output: A = 1 if a password was loaded, 0 otherwise
; Clobbers: everything
SaveLoadPassword::
    ld a, l
    ld [wSaveDestPtr], a
    ld a, h
    ld [wSaveDestPtr + 1], a
    ld a, b
    ld [wSaveDestCap], a

    ; Empty the destination first, so every failure path below leaves
    ; the caller with an empty string rather than a partial one.
    xor a, a
    ld [hl], a

    ld a, $0A
    ld [MBC_RAMG], a
    xor a, a
    ld [MBC_RAMB], a

    ld a, [SRAM_BASE + SAVE_OFF_MAGIC0]
    cp a, SAVE_MAGIC0
    jr nz, .fail
    ld a, [SRAM_BASE + SAVE_OFF_MAGIC1]
    cp a, SAVE_MAGIC1
    jr nz, .fail
    ld a, [SRAM_BASE + SAVE_OFF_VERSION]
    cp a, SAVE_VERSION
    jr nz, .fail

    ; The length comes out of battery-backed RAM, which is as untrusted
    ; as any other external input -- validate it against BOTH the
    ; format's cap and the caller's buffer before using it to index.
    ld a, [SRAM_BASE + SAVE_OFF_LEN]
    cp a, SAVE_MAX_LEN + 1
    jr nc, .fail
    ld b, a
    ld a, [wSaveDestCap]
    dec a          ; usable characters, excluding the NUL
    cp a, b
    jr c, .fail    ; len > cap-1

    ld a, b
    call SaveChecksum
    ld c, a
    ld a, [SRAM_BASE + SAVE_OFF_LEN]
    ld e, a
    ld d, 0
    ld hl, SRAM_BASE + SAVE_OFF_DATA
    add hl, de
    ld a, [hl]
    cp a, c
    jr nz, .fail

    ; Copy len bytes out.
    ld a, [wSaveDestPtr]
    ld e, a
    ld a, [wSaveDestPtr + 1]
    ld d, a
    ld hl, SRAM_BASE + SAVE_OFF_DATA
    ld a, [SRAM_BASE + SAVE_OFF_LEN]
    ld b, a
    or a, a
    jr z, .empty
.copy
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copy
    xor a, a
    ld [de], a
    xor a, a
    ld [MBC_RAMG], a
    ld a, 1
    ret

.empty
    ; A valid record holding an empty password: the user cleared it.
    ; Report "nothing to load" so callers do not treat it as a set
    ; password.
    ld [de], a
.fail
    ld a, [wSaveDestPtr]
    ld l, a
    ld a, [wSaveDestPtr + 1]
    ld h, a
    xor a, a
    ld [hl], a
    ld [MBC_RAMG], a
    xor a, a
    ret

; Stores the NUL-terminated string at [HL] so a later SaveLoadPassword
; returns it. Storing an empty string clears the record, so a user who
; blanks the password field is not silently handed the old one back on
; the next boot.
;
; Input: HL = NUL-terminated password
; Clobbers: everything
SaveStorePassword::
    ; Measure, capped at SAVE_MAX_LEN.
    ld b, 0
    push hl
.measure
    ld a, [hl+]
    or a, a
    jr z, .haveLen
    ld a, b
    cp a, SAVE_MAX_LEN
    jr z, .haveLen
    inc b
    jr .measure
.haveLen
    pop hl

    ld a, $0A
    ld [MBC_RAMG], a
    xor a, a
    ld [MBC_RAMB], a

    ld a, SAVE_MAGIC0
    ld [SRAM_BASE + SAVE_OFF_MAGIC0], a
    ld a, SAVE_MAGIC1
    ld [SRAM_BASE + SAVE_OFF_MAGIC1], a
    ld a, SAVE_VERSION
    ld [SRAM_BASE + SAVE_OFF_VERSION], a
    ld a, b
    ld [SRAM_BASE + SAVE_OFF_LEN], a

    ld de, SRAM_BASE + SAVE_OFF_DATA
    ld a, b
    or a, a
    jr z, .noData
.copy
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copy
.noData

    ld a, [SRAM_BASE + SAVE_OFF_LEN]
    call SaveChecksum
    ld c, a
    ld a, [SRAM_BASE + SAVE_OFF_LEN]
    ld e, a
    ld d, 0
    ld hl, SRAM_BASE + SAVE_OFF_DATA
    add hl, de
    ld [hl], c

    ; Leaving cart RAM enabled across a power-off is the classic way to
    ; corrupt a save: the write-enable latch is what protects the RAM
    ; while the supply collapses. Disable it as soon as the write is
    ; done, every time.
    xor a, a
    ld [MBC_RAMG], a
    ret

SECTION "Save Scratch", WRAM0
wSaveDestPtr: dw
wSaveDestCap: db
