; GB00 authentication -- REON's custom HTTP challenge/response scheme
; for Pokemon-Crystal-era Mobile Adapter GB downloads/uploads.
;
; This is an APPLICATION-layer (HTTP-level) scheme, not part of the
; Mobile Adapter protocol itself -- it rides inside ordinary HTTP
; request/response bodies sent over an ordinary MAGB TCP connection,
; exactly like the rest of this TestSuite's HTTP tests. Belongs here in
; src/app/, not src/protocol/, matching gbdk/src/app/gb00_auth.c's own
; placement and its own header comment about why.
;
; The algorithm (MD5 + base64 + a bit-scramble) was reverse-engineered
; by SimonTime (credited in REONTeam/reon's own source) and is ported
; here directly from gbdk/src/app/gb00_auth.c, which was itself
; round-trip-tested on the host against REON's real PHP decode function
; -- see that file's own header comment and gbdk/docs/protocol-notes.md
; ("GB00 HTTP authentication") for the full derivation. Not re-derived
; independently here; this is a faithful port of already-verified logic.
;
; The actual code (not the WRAM state) lives in ROMX BANK[1], not ROM0
; -- this is a mapperless 32KB cart (cartridge type $00, rgbfix -m 0x00),
; so "BANK[1]" here just means the ROM's fixed upper 16KB ($4000-$7FFF),
; always mapped, never bank-switched (there's no MBC to switch it, and
; nothing here ever needs to). This was worth doing at all because
; every other file in this ROM declares its code as plain ROM0, which
; RGBDS packs into the lower 16KB ($0000-$3FFF) only -- before this,
; the entire upper half of the physical ROM sat unused (all $FF
; padding), and this file's own MD5/base64/GB00 code alone would not
; have fit in what was left there.

INCLUDE "hardware.inc"
INCLUDE "protocol.inc"

; ---- MD5 (RFC 1321) ---------------------------------------------------
;
; Deliberately simple/textbook (rotate-left-by-N implemented as N
; rotate-left-by-1 steps, no unrolled/table-driven cleverness) --
; matches gbdk's own md5() comment: this runs a handful of times per
; test, never in a hot loop, and correctness/clarity matter far more
; than cycles for an SM83 port of a from-scratch crypto primitive.
;
; All 32-bit values are stored as 4 bytes, little-endian, at fixed WRAM
; addresses (not roamed via pointers) -- SM83 has no spare register
; pairs to thread 3-4 simultaneous 32-bit pointers through the round
; function, and fixed addresses make every step trivially re-checkable
; against the reference C.
;
; Verified against the standard RFC 1321 test vectors
; (md5("")=d41d8cd98f00b204e9800998ecf8427e,
; md5("abc")=900150983cd24fb0d6963f7d28e17f72) by injecting each
; message into wMd5Block via PyBoy (redirecting the CPU's PC into Md5
; directly) and reading the resulting digest back out of WRAM -- see
; docs/status.md.

SECTION "Md5 State", WRAM0
; Persistent chaining state, carried from one 64-byte block to the
; next. Starts at MD5's fixed magic constants (Md5:: below) and is
; updated by ADDING each block's round result into it -- not replaced
; by it; that add-back step is easy to miss porting this by hand, so
; it's called out here explicitly.
wMd5StateA: ds 4
wMd5StateB: ds 4
wMd5StateC: ds 4
wMd5StateD: ds 4

; Per-block working variables -- copied from wMd5State* at the start of
; each block, mutated through all 64 rounds, then added back into
; wMd5State* at the end of the block.
wMd5A: ds 4
wMd5B: ds 4
wMd5C: ds 4
wMd5D: ds 4
wMd5OldB: ds 4 ; staging for B/C/D so the round's simultaneous
wMd5OldC: ds 4 ; (a,b,c,d) = (d,a,b,b+rotl(f,s)) update can read every
wMd5OldD: ds 4 ; old value it needs before any of them are overwritten
wMd5F: ds 4
wMd5Temp: ds 4 ; Rol32TempBy1's own working value

wMd5RoundIdx: db ; 0..63
wMd5G: db        ; this round's message-word index (0..15), from Md5G_Table
wMd5BlockPtr: dw ; the 64-byte block Md5ProcessBlock is currently working on

; Padded-message scratch. 128 bytes covers every call site in this ROM
; (GB00's challenge+password is the largest input, up to 48+32=80
; bytes; 80+1+padding+8 never exceeds two 64-byte blocks) -- matches
; gbdk's own static block[128]. wMd5PadPos is a plain counter (0..128),
; deliberately NOT a pointer/address -- using `AND $3F` to compute
; "position mod 64" only works unconditionally on a counter that starts
; at 0; doing the same arithmetic on wMd5Block's actual runtime address
; would silently break if the linker ever placed it somewhere that
; makes the block straddle a 256-byte page.
wMd5Block: ds 128
wMd5PadPos: db
wMd5MsgLen: db   ; original message length before padding
wMd5DigestPtr: dw ; caller's 16-byte output buffer

SECTION "Md5 Code", ROMX, BANK[1]

; Copies 4 bytes from [HL] to [DE]. Both advanced by 4.
; Clobbers: A, HL, DE
Md5Copy4:
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [hl+]
    ld [de], a
    inc de
    ret

; Adds the 4-byte little-endian word at [DE] into the 4-byte
; little-endian word at [HL], in place: [HL] += [DE].
; Input: HL = dest (4 bytes), DE = addend (4 bytes)
; Clobbers: A, B
Add32:
    or a, a ; clear carry for the first byte
    ld a, [hl]
    ld b, a
    ld a, [de]
    adc a, b
    ld [hl], a
    inc hl
    inc de

    ld a, [hl]
    ld b, a
    ld a, [de]
    adc a, b
    ld [hl], a
    inc hl
    inc de

    ld a, [hl]
    ld b, a
    ld a, [de]
    adc a, b
    ld [hl], a
    inc hl
    inc de

    ld a, [hl]
    ld b, a
    ld a, [de]
    adc a, b
    ld [hl], a
    ret

; Rotates the 4-byte little-endian word at wMd5Temp left by 1 bit, in
; place. `sla a` on the top byte primes the carry with the word's own
; top bit (bit 31); the chain of `rl a` from the bottom byte up then
; carries that bit into position 0 and each byte's own top bit into the
; next byte up, which is exactly a left rotate of the full 32-bit value.
; Clobbers: A
Rol32TempBy1:
    ld a, [wMd5Temp + 3]
    sla a
    ld a, [wMd5Temp + 0]
    rl a
    ld [wMd5Temp + 0], a
    ld a, [wMd5Temp + 1]
    rl a
    ld [wMd5Temp + 1], a
    ld a, [wMd5Temp + 2]
    rl a
    ld [wMd5Temp + 2], a
    ld a, [wMd5Temp + 3]
    rl a
    ld [wMd5Temp + 3], a
    ret

; Rotates wMd5Temp left by Md5S[wMd5RoundIdx] bits.
; Clobbers: A, B, HL, DE
Md5RotateBySRoundIdx:
    ld a, [wMd5RoundIdx]
    ld hl, Md5S
    ld e, a
    ld d, 0
    add hl, de
    ld b, [hl]
.loop
    call Rol32TempBy1
    dec b
    jr nz, .loop
    ret

; ---- Per-round F function + message-word index (see RFC 1321 s3.4) ----
; Each writes the round's F value into wMd5F and copies this round's
; Md5G_Table entry into wMd5G. Every byte of every 32-bit XOR/AND/OR/NOT
; here is independent, so these are written as a 1-byte macro invoked 4
; times (offsets 0-3) rather than by hand 4 times over -- the assembler
; substituting \1 guarantees the 4 byte-lanes are byte-for-byte
; identical in structure, the same guarantee unrolling by hand well
; would only get from very careful copy-pasting.

MACRO md5_f0_byte ; \1 = byte offset 0-3 -- F = (B&C)|(~B&D)
    ld a, [wMd5B + \1]
    ld b, a
    ld a, [wMd5C + \1]
    and a, b
    ld c, a
    ld a, [wMd5B + \1]
    cpl
    ld b, a
    ld a, [wMd5D + \1]
    and a, b
    or a, c
    ld [wMd5F + \1], a
ENDM

Md5RoundF0:
    md5_f0_byte 0
    md5_f0_byte 1
    md5_f0_byte 2
    md5_f0_byte 3
    ret

MACRO md5_f1_byte ; \1 = byte offset 0-3 -- F = (D&B)|(~D&C)
    ld a, [wMd5D + \1]
    ld b, a
    ld a, [wMd5B + \1]
    and a, b
    ld c, a
    ld a, [wMd5D + \1]
    cpl
    ld b, a
    ld a, [wMd5C + \1]
    and a, b
    or a, c
    ld [wMd5F + \1], a
ENDM

Md5RoundF1:
    md5_f1_byte 0
    md5_f1_byte 1
    md5_f1_byte 2
    md5_f1_byte 3
    ret

MACRO md5_f2_byte ; \1 = byte offset 0-3 -- F = B^C^D
    ld a, [wMd5B + \1]
    ld b, a
    ld a, [wMd5C + \1]
    xor a, b
    ld b, a
    ld a, [wMd5D + \1]
    xor a, b
    ld [wMd5F + \1], a
ENDM

Md5RoundF2:
    md5_f2_byte 0
    md5_f2_byte 1
    md5_f2_byte 2
    md5_f2_byte 3
    ret

MACRO md5_f3_byte ; \1 = byte offset 0-3 -- F = C^(B|~D)
    ld a, [wMd5D + \1]
    cpl
    ld b, a
    ld a, [wMd5B + \1]
    or a, b
    ld b, a
    ld a, [wMd5C + \1]
    xor a, b
    ld [wMd5F + \1], a
ENDM

Md5RoundF3:
    md5_f3_byte 0
    md5_f3_byte 1
    md5_f3_byte 2
    md5_f3_byte 3
    ret

; Processes one 64-byte block at [HL], folding it into wMd5State*.
; Input: HL = pointer to a 64-byte block
; Clobbers: everything
Md5ProcessBlock:
    ld a, l
    ld [wMd5BlockPtr], a
    ld a, h
    ld [wMd5BlockPtr + 1], a

    ld hl, wMd5StateA
    ld de, wMd5A
    call Md5Copy4
    ld hl, wMd5StateB
    ld de, wMd5B
    call Md5Copy4
    ld hl, wMd5StateC
    ld de, wMd5C
    call Md5Copy4
    ld hl, wMd5StateD
    ld de, wMd5D
    call Md5Copy4

    xor a, a
    ld [wMd5RoundIdx], a
.roundLoop
    ld a, [wMd5RoundIdx]
    cp a, 16
    jr nc, .notF0
    call Md5RoundF0
    jr .haveF
.notF0
    cp a, 32
    jr nc, .notF1
    call Md5RoundF1
    jr .haveF
.notF1
    cp a, 48
    jr nc, .notF2
    call Md5RoundF2
    jr .haveF
.notF2
    call Md5RoundF3
.haveF
    ld a, [wMd5RoundIdx]
    ld hl, Md5G_Table
    ld e, a
    ld d, 0
    add hl, de
    ld a, [hl]
    ld [wMd5G], a

    ld hl, wMd5F
    ld de, wMd5A
    call Add32 ; F += A

    ld a, [wMd5RoundIdx]
    add a, a
    add a, a ; a = i*4
    ld hl, Md5K
    ld e, a
    ld d, 0
    add hl, de
    ld d, h
    ld e, l
    ld hl, wMd5F
    call Add32 ; F += K[i]

    ld a, [wMd5G]
    add a, a
    add a, a ; a = G*4
    ld l, a
    ld h, 0
    ld a, [wMd5BlockPtr]
    add a, l
    ld l, a
    ld a, [wMd5BlockPtr + 1]
    adc a, 0
    ld h, a ; hl = wMd5BlockPtr + G*4 = &M[G]
    ld d, h
    ld e, l
    ld hl, wMd5F
    call Add32 ; F += M[G]

    ld hl, wMd5F
    ld de, wMd5Temp
    call Md5Copy4
    call Md5RotateBySRoundIdx
    ld hl, wMd5Temp
    ld de, wMd5F
    call Md5Copy4 ; F = rotl(F, S[i])

    ld hl, wMd5B
    ld de, wMd5OldB
    call Md5Copy4
    ld hl, wMd5C
    ld de, wMd5OldC
    call Md5Copy4
    ld hl, wMd5D
    ld de, wMd5OldD
    call Md5Copy4

    ld hl, wMd5OldD
    ld de, wMd5A
    call Md5Copy4 ; new A = old D

    ld hl, wMd5OldC
    ld de, wMd5D
    call Md5Copy4 ; new D = old C

    ld hl, wMd5OldB
    ld de, wMd5C
    call Md5Copy4 ; new C = old B

    ld hl, wMd5OldB
    ld de, wMd5B
    call Md5Copy4 ; B = old B (about to add F onto it)
    ld hl, wMd5B
    ld de, wMd5F
    call Add32 ; new B = old B + rotl(F, S[i])

    ld a, [wMd5RoundIdx]
    inc a
    ld [wMd5RoundIdx], a
    cp a, 64
    jp nz, .roundLoop

    ld hl, wMd5StateA
    ld de, wMd5A
    call Add32
    ld hl, wMd5StateB
    ld de, wMd5B
    call Add32
    ld hl, wMd5StateC
    ld de, wMd5C
    call Add32
    ld hl, wMd5StateD
    ld de, wMd5D
    jp Add32 ; tail call -- Add32's own ret returns to our caller too

; Computes the MD5 digest of an arbitrary message into a 16-byte
; digest. Single-shot (no streaming API) -- every call site in this
; TestSuite hashes well under 128 bytes at once (see wMd5Block's own
; comment).
;
; Input: HL = message pointer, C = message length (0..119), DE = 16-byte
;        output buffer
; Output: [DE buffer] filled with the digest
; Clobbers: everything
Md5::
    push hl
    ld a, c
    ld [wMd5MsgLen], a
    ld a, e
    ld [wMd5DigestPtr], a
    ld a, d
    ld [wMd5DigestPtr + 1], a
    pop hl

    ld de, wMd5Block
    ld a, c
    or a, a
    jr z, .noMsgBytes
    ld b, a
.copyMsg
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyMsg
.noMsgBytes
    ld a, [wMd5MsgLen]
    ld [wMd5PadPos], a

    ; append the 0x80 terminator byte
    ld a, [wMd5PadPos]
    ld l, a
    ld h, 0
    ld de, wMd5Block
    add hl, de
    ld [hl], $80
    ld a, [wMd5PadPos]
    inc a
    ld [wMd5PadPos], a

    ; zero-pad until position mod 64 == 56
.padLoop
    ld a, [wMd5PadPos]
    and a, $3F
    cp a, 56
    jr z, .padDone
    ld a, [wMd5PadPos]
    ld l, a
    ld h, 0
    ld de, wMd5Block
    add hl, de
    ld [hl], 0
    ld a, [wMd5PadPos]
    inc a
    ld [wMd5PadPos], a
    jr .padLoop
.padDone

    ; append the 8-byte little-endian bit length; every input this ROM
    ; ever hashes is under 120 bytes (960 bits), so only the first two
    ; length bytes are ever nonzero
    ld a, [wMd5PadPos]
    ld l, a
    ld h, 0
    ld de, wMd5Block
    add hl, de ; hl = &block[PadPos]

    ld a, [wMd5MsgLen]
    ld b, a
    ld a, b
    add a, a
    add a, a
    add a, a ; a = (msg_len * 8) low byte
    ld [hl+], a
    ld a, b
    srl a
    srl a
    srl a
    srl a
    srl a ; a = top 3 bits of msg_len, i.e. bits 8-10 of (msg_len*8)
    ld [hl+], a
    xor a, a
    REPT 6
    ld [hl+], a
    ENDR

    ld a, [wMd5PadPos]
    add a, 8
    ld [wMd5PadPos], a ; total padded length

    ld a, $01
    ld [wMd5StateA], a
    ld a, $23
    ld [wMd5StateA + 1], a
    ld a, $45
    ld [wMd5StateA + 2], a
    ld a, $67
    ld [wMd5StateA + 3], a

    ld a, $89
    ld [wMd5StateB], a
    ld a, $AB
    ld [wMd5StateB + 1], a
    ld a, $CD
    ld [wMd5StateB + 2], a
    ld a, $EF
    ld [wMd5StateB + 3], a

    ld a, $FE
    ld [wMd5StateC], a
    ld a, $DC
    ld [wMd5StateC + 1], a
    ld a, $BA
    ld [wMd5StateC + 2], a
    ld a, $98
    ld [wMd5StateC + 3], a

    ld a, $76
    ld [wMd5StateD], a
    ld a, $54
    ld [wMd5StateD + 1], a
    ld a, $32
    ld [wMd5StateD + 2], a
    ld a, $10
    ld [wMd5StateD + 3], a

    xor a, a
    ld [wMd5BlockOffset], a
.blockLoop
    ld a, [wMd5BlockOffset]
    ld l, a
    ld h, 0
    ld de, wMd5Block
    add hl, de
    call Md5ProcessBlock

    ld a, [wMd5BlockOffset]
    add a, 64
    ld [wMd5BlockOffset], a
    ld b, a
    ld a, [wMd5PadPos]
    cp a, b
    jr nz, .blockLoop

    ld a, [wMd5DigestPtr]
    ld e, a
    ld a, [wMd5DigestPtr + 1]
    ld d, a
    ld hl, wMd5StateA
    call Md5Copy4
    ld hl, wMd5StateB
    call Md5Copy4
    ld hl, wMd5StateC
    call Md5Copy4
    ld hl, wMd5StateD
    jp Md5Copy4

SECTION "Md5 Block Offset", WRAM0
wMd5BlockOffset: db

SECTION "Md5 Tables", ROMX, BANK[1]
; K[i] = floor(abs(sin(i+1)) * 2^32), little-endian 32-bit words.
Md5K:
    db $78,$A4,$6A,$D7,$56,$B7,$C7,$E8,$DB,$70,$20,$24,$EE,$CE,$BD,$C1 ; K[0..3]
    db $AF,$0F,$7C,$F5,$2A,$C6,$87,$47,$13,$46,$30,$A8,$01,$95,$46,$FD ; K[4..7]
    db $D8,$98,$80,$69,$AF,$F7,$44,$8B,$B1,$5B,$FF,$FF,$BE,$D7,$5C,$89 ; K[8..11]
    db $22,$11,$90,$6B,$93,$71,$98,$FD,$8E,$43,$79,$A6,$21,$08,$B4,$49 ; K[12..15]
    db $62,$25,$1E,$F6,$40,$B3,$40,$C0,$51,$5A,$5E,$26,$AA,$C7,$B6,$E9 ; K[16..19]
    db $5D,$10,$2F,$D6,$53,$14,$44,$02,$81,$E6,$A1,$D8,$C8,$FB,$D3,$E7 ; K[20..23]
    db $E6,$CD,$E1,$21,$D6,$07,$37,$C3,$87,$0D,$D5,$F4,$ED,$14,$5A,$45 ; K[24..27]
    db $05,$E9,$E3,$A9,$F8,$A3,$EF,$FC,$D9,$02,$6F,$67,$8A,$4C,$2A,$8D ; K[28..31]
    db $42,$39,$FA,$FF,$81,$F6,$71,$87,$22,$61,$9D,$6D,$0C,$38,$E5,$FD ; K[32..35]
    db $44,$EA,$BE,$A4,$A9,$CF,$DE,$4B,$60,$4B,$BB,$F6,$70,$BC,$BF,$BE ; K[36..39]
    db $C6,$7E,$9B,$28,$FA,$27,$A1,$EA,$85,$30,$EF,$D4,$05,$1D,$88,$04 ; K[40..43]
    db $39,$D0,$D4,$D9,$E5,$99,$DB,$E6,$F8,$7C,$A2,$1F,$65,$56,$AC,$C4 ; K[44..47]
    db $44,$22,$29,$F4,$97,$FF,$2A,$43,$A7,$23,$94,$AB,$39,$A0,$93,$FC ; K[48..51]
    db $C3,$59,$5B,$65,$92,$CC,$0C,$8F,$7D,$F4,$EF,$FF,$D1,$5D,$84,$85 ; K[52..55]
    db $4F,$7E,$A8,$6F,$E0,$E6,$2C,$FE,$14,$43,$01,$A3,$A1,$11,$08,$4E ; K[56..59]
    db $82,$7E,$53,$F7,$35,$F2,$3A,$BD,$BB,$D2,$D7,$2A,$91,$D3,$86,$EB ; K[60..63]

Md5S:
    db 7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22 ; S[0..15]
    db 5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20 ; S[16..31]
    db 4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23 ; S[32..47]
    db 6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21 ; S[48..63]

Md5G_Table:
    db 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 ; G[0..15]
    db 1,6,11,0,5,10,15,4,9,14,3,8,13,2,7,12 ; G[16..31]
    db 5,8,11,14,1,4,7,10,13,0,3,6,9,12,15,2 ; G[32..47]
    db 0,7,14,5,12,3,10,1,8,15,6,13,4,11,2,9 ; G[48..63]

; ---- base64 (RFC 4648, '+'/'/' alphabet, '=' padding) ------------------

SECTION "Base64 Scratch", WRAM0
wB64InPtr: dw
wB64OutPtr: dw
wB64Len: db
wB64Byte0: db
wB64Byte1: db
wB64Byte2: db
wB64Byte3: db
wB64Pad2: db
wB64Pad3: db
wB64OutCount: db

SECTION "Base64 Code", ROMX, BANK[1]

; Writes exactly 4*ceil(len/3) characters plus a NUL terminator to [DE].
; Input: HL = data ptr, C = data length (0..255), DE = output buffer
; Clobbers: everything
Base64Encode::
    ld a, l
    ld [wB64InPtr], a
    ld a, h
    ld [wB64InPtr + 1], a
    ld a, e
    ld [wB64OutPtr], a
    ld a, d
    ld [wB64OutPtr + 1], a
    ld a, c
    ld [wB64Len], a

.groupLoop
    ld a, [wB64Len]
    cp a, 3
    jr c, .remainder

    ld a, [wB64InPtr]
    ld l, a
    ld a, [wB64InPtr + 1]
    ld h, a
    ld a, [hl+]
    ld [wB64Byte0], a
    ld a, [hl+]
    ld [wB64Byte1], a
    ld a, [hl+]
    ld [wB64Byte2], a
    ld a, l
    ld [wB64InPtr], a
    ld a, h
    ld [wB64InPtr + 1], a

    ld a, [wB64Byte0]
    srl a
    srl a
    call Base64EmitChar

    ld a, [wB64Byte0]
    and a, $03
    swap a ; (byte0&3)<<4
    ld b, a
    ld a, [wB64Byte1]
    swap a
    and a, $0F ; byte1>>4
    or a, b
    call Base64EmitChar

    ld a, [wB64Byte1]
    and a, $0F
    add a, a
    add a, a ; (byte1&0xF)<<2
    ld b, a
    ld a, [wB64Byte2]
    srl a
    srl a
    srl a
    srl a
    srl a
    srl a ; byte2>>6
    or a, b
    call Base64EmitChar

    ld a, [wB64Byte2]
    and a, $3F
    call Base64EmitChar

    ld a, [wB64Len]
    sub a, 3
    ld [wB64Len], a
    jr .groupLoop

.remainder
    ld a, [wB64Len]
    or a, a
    jr z, .terminate
    cp a, 1
    jr z, .oneLeft

    ld a, [wB64InPtr]
    ld l, a
    ld a, [wB64InPtr + 1]
    ld h, a
    ld a, [hl+]
    ld [wB64Byte0], a
    ld a, [hl+]
    ld [wB64Byte1], a

    ld a, [wB64Byte0]
    srl a
    srl a
    call Base64EmitChar

    ld a, [wB64Byte0]
    and a, $03
    swap a
    ld b, a
    ld a, [wB64Byte1]
    swap a
    and a, $0F
    or a, b
    call Base64EmitChar

    ld a, [wB64Byte1]
    and a, $0F
    add a, a
    add a, a
    call Base64EmitChar

    ld a, "="
    call Base64EmitCharRaw
    jr .terminate

.oneLeft
    ld a, [wB64InPtr]
    ld l, a
    ld a, [wB64InPtr + 1]
    ld h, a
    ld a, [hl+]
    ld [wB64Byte0], a

    ld a, [wB64Byte0]
    srl a
    srl a
    call Base64EmitChar

    ld a, [wB64Byte0]
    and a, $03
    swap a
    call Base64EmitChar

    ld a, "="
    call Base64EmitCharRaw
    ld a, "="
    call Base64EmitCharRaw

.terminate
    ld a, [wB64OutPtr]
    ld l, a
    ld a, [wB64OutPtr + 1]
    ld h, a
    xor a, a
    ld [hl], a
    ret

; Looks up the base64 alphabet character for the 6-bit value in A, then
; falls through to Base64EmitCharRaw to write it out.
; Input: A = 6-bit value (0-63)
; Clobbers: everything
Base64EmitChar:
    push de
    ld hl, Base64Alphabet
    ld e, a
    ld d, 0
    add hl, de
    ld a, [hl]
    pop de
    ; fall through
; Writes the character in A at the current output position, advancing it.
; Clobbers: A, HL (indirectly via the address recompute)
Base64EmitCharRaw:
    push af
    ld a, [wB64OutPtr]
    ld l, a
    ld a, [wB64OutPtr + 1]
    ld h, a
    pop af
    ld [hl+], a
    ld a, l
    ld [wB64OutPtr], a
    ld a, h
    ld [wB64OutPtr + 1], a
    ret

; Standard base64 decode. Input length must be a multiple of 4 (always
; true for GB00's fixed 48-character challenge, this ROM's only
; caller). Malformed-character input is not detected (returns garbage
; instead of an error) -- every call site in this ROM only ever feeds
; this a real base64 string already produced by the adapter's own HTTP
; response, so that error path was not worth the extra ROM bytes; see
; Base64Value's own doc comment.
;
; Input: HL = base64 text ptr, C = input length (multiple of 4), DE = output buffer
; Output: A = number of bytes decoded
; Clobbers: everything
Base64Decode::
    ld a, l
    ld [wB64InPtr], a
    ld a, h
    ld [wB64InPtr + 1], a
    ld a, e
    ld [wB64OutPtr], a
    ld a, d
    ld [wB64OutPtr + 1], a
    ld a, c
    ld [wB64Len], a
    xor a, a
    ld [wB64OutCount], a

.groupLoop
    ld a, [wB64Len]
    or a, a
    jp z, .done

    ld a, [wB64InPtr]
    ld l, a
    ld a, [wB64InPtr + 1]
    ld h, a

    ld a, [hl+]
    push hl ; Base64Value clobbers HL (it walks Base64Alphabet with it) --
    call Base64Value ; this loop also uses HL as the input-scan pointer,
    pop hl ; so it must be saved/restored around every single call here.
    ld [wB64Byte0], a

    ld a, [hl+]
    push hl
    call Base64Value
    pop hl
    ld [wB64Byte1], a

    ld a, [hl]
    cp a, "="
    jr nz, .char2Real
    ld a, 1
    ld [wB64Pad2], a
    xor a, a
    ld [wB64Byte2], a
    jr .char2Done
.char2Real
    xor a, a
    ld [wB64Pad2], a
    ld a, [hl]
    push hl
    call Base64Value
    pop hl
    ld [wB64Byte2], a
.char2Done
    inc hl

    ld a, [hl]
    cp a, "="
    jr nz, .char3Real
    ld a, 1
    ld [wB64Pad3], a
    xor a, a
    ld [wB64Byte3], a
    jr .char3Done
.char3Real
    xor a, a
    ld [wB64Pad3], a
    ld a, [hl]
    push hl
    call Base64Value
    pop hl
    ld [wB64Byte3], a
.char3Done
    inc hl

    ld a, l
    ld [wB64InPtr], a
    ld a, h
    ld [wB64InPtr + 1], a

    ld a, [wB64Byte0]
    add a, a
    add a, a ; b0<<2
    ld b, a
    ld a, [wB64Byte1]
    swap a
    and a, $0F ; b1>>4
    or a, b
    call Base64WriteByte

    ld a, [wB64Pad2]
    or a, a
    jr nz, .skipOut1
    ld a, [wB64Byte1]
    and a, $0F
    swap a ; (b1&0xF)<<4
    ld b, a
    ld a, [wB64Byte2]
    srl a
    srl a ; b2>>2
    or a, b
    call Base64WriteByte
.skipOut1

    ld a, [wB64Pad3]
    or a, a
    jr nz, .skipOut2
    ld a, [wB64Byte2]
    and a, $03
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a ; (b2&3)<<6
    ld b, a
    ld a, [wB64Byte3]
    or a, b
    call Base64WriteByte
.skipOut2

    ld a, [wB64Len]
    sub a, 4
    ld [wB64Len], a
    jp .groupLoop

.done
    ld a, [wB64OutCount]
    ret

; Writes A to the output buffer, advances the pointer, increments
; wB64OutCount.
; Clobbers: everything
Base64WriteByte:
    push af
    ld a, [wB64OutPtr]
    ld l, a
    ld a, [wB64OutPtr + 1]
    ld h, a
    pop af
    ld [hl+], a
    ld a, l
    ld [wB64OutPtr], a
    ld a, h
    ld [wB64OutPtr + 1], a
    ld a, [wB64OutCount]
    inc a
    ld [wB64OutCount], a
    ret

; Input: A = a base64 alphabet character
; Output: A = its 6-bit value (0-63); returns 0 for a character not in
;         the alphabet -- see Base64Decode's own doc comment for why
;         this isn't treated as an error here.
; Clobbers: BC, HL
Base64Value:
    ld c, a
    ld hl, Base64Alphabet
    ld b, 0
.loop
    ld a, [hl+]
    cp a, c
    jr z, .found
    inc b
    ld a, b
    cp a, 64
    jr nz, .loop
    ld b, 0
.found
    ld a, b
    ret

Base64Alphabet:
    db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

; ---- GB00 challenge/response -------------------------------------------
; See this file's header comment and gbdk/docs/protocol-notes.md for the
; full derivation. Byte-for-byte ported from gbdk's gb00_bits_sorted()/
; gb00_rotate_encode()/gb00_build_authorization(), which were themselves
; round-trip-tested against REON's real PHP decode function.

DEF GB00_CHALLENGE_LEN EQU 48
DEF GB00_AUTHORIZATION_LEN EQU 92

SECTION "Gb00 Scratch", WRAM0
wGb00ChallengePtr: dw
wGb00LoginPtr: dw
wGb00PasswordPtr: dw
; Gb00BitsSorted's OWN input/output pointers -- deliberately separate
; from wGb00ChallengePtr/wGb00LoginPtr/wGb00PasswordPtr above: an
; earlier version had Gb00BitsSorted reuse wGb00ChallengePtr as its own
; scratch, which silently clobbered Gb00BuildAuthorization's copy of
; the original base64 challenge pointer the moment it called
; Gb00BitsSorted (found by cross-checking the whole authorization
; builder's output against a from-scratch Python re-implementation of
; gbdk's algorithm -- see docs/status.md).
wGb00BitsSrcPtr: dw
wGb00BitsOutPtr: dw
wGb00Idx: db
wGb00B1: db
wGb00B2: db
wGb00Result: db
wGb00ChallengeRaw: ds 36
wGb00BitsSorted: ds 36
wGb00Md5Input: ds GB00_CHALLENGE_LEN + 32 ; challenge + password, generous bound (real password cap is 8)
wGb00PwHash: ds 16
wGb00Plaintext: ds 36
wGb00Scrambled: ds 36
wGb00LoginLen: db
wGb00PasswordLen: db
wGb00Authorization:: ds GB00_AUTHORIZATION_LEN + 1

SECTION "Gb00 Code", ROMX, BANK[1]

; Rebuilds the same 36-byte "bitsSorted" value REON's server derives
; from the challenge: bytes 0-17 pack the even-numbered bits of each
; challenge byte pair, bytes 18-35 pack the odd-numbered bits of the
; same pairs.
; Input: HL = 36-byte raw challenge, DE = 36-byte output
; Clobbers: everything
Gb00BitsSorted:
    ld a, l
    ld [wGb00BitsSrcPtr], a
    ld a, h
    ld [wGb00BitsSrcPtr + 1], a
    ld a, e
    ld [wGb00BitsOutPtr], a
    ld a, d
    ld [wGb00BitsOutPtr + 1], a

    xor a, a
    ld [wGb00Idx], a
.loop
    ld a, [wGb00Idx]
    cp a, 36
    jp z, .doneGb00Bits

    ld a, [wGb00Idx]
    cp a, 18
    jr c, .pairIsIdx
    sub a, 18
.pairIsIdx
    add a, a
    ld l, a
    ld h, 0
    ld a, [wGb00BitsSrcPtr]
    add a, l
    ld l, a
    ld a, [wGb00BitsSrcPtr + 1]
    adc a, 0
    ld h, a
    ld a, [hl+]
    ld [wGb00B1], a
    ld a, [hl]
    ld [wGb00B2], a

    xor a, a
    ld [wGb00Result], a

    ld a, [wGb00Idx]
    cp a, 18
    jr nc, .packOdd

    ld a, [wGb00B1]
    bit 6, a
    jr z, .e1
    ld a, [wGb00Result]
    set 7, a
    ld [wGb00Result], a
.e1
    ld a, [wGb00B1]
    bit 4, a
    jr z, .e2
    ld a, [wGb00Result]
    set 6, a
    ld [wGb00Result], a
.e2
    ld a, [wGb00B1]
    bit 2, a
    jr z, .e3
    ld a, [wGb00Result]
    set 5, a
    ld [wGb00Result], a
.e3
    ld a, [wGb00B1]
    bit 0, a
    jr z, .e4
    ld a, [wGb00Result]
    set 4, a
    ld [wGb00Result], a
.e4
    ld a, [wGb00B2]
    bit 6, a
    jr z, .e5
    ld a, [wGb00Result]
    set 3, a
    ld [wGb00Result], a
.e5
    ld a, [wGb00B2]
    bit 4, a
    jr z, .e6
    ld a, [wGb00Result]
    set 2, a
    ld [wGb00Result], a
.e6
    ld a, [wGb00B2]
    bit 2, a
    jr z, .e7
    ld a, [wGb00Result]
    set 1, a
    ld [wGb00Result], a
.e7
    ld a, [wGb00B2]
    bit 0, a
    jr z, .e8
    ld a, [wGb00Result]
    set 0, a
    ld [wGb00Result], a
.e8
    jr .storeResult

.packOdd
    ld a, [wGb00B1]
    bit 7, a
    jr z, .o1
    ld a, [wGb00Result]
    set 7, a
    ld [wGb00Result], a
.o1
    ld a, [wGb00B1]
    bit 5, a
    jr z, .o2
    ld a, [wGb00Result]
    set 6, a
    ld [wGb00Result], a
.o2
    ld a, [wGb00B1]
    bit 3, a
    jr z, .o3
    ld a, [wGb00Result]
    set 5, a
    ld [wGb00Result], a
.o3
    ld a, [wGb00B1]
    bit 1, a
    jr z, .o4
    ld a, [wGb00Result]
    set 4, a
    ld [wGb00Result], a
.o4
    ld a, [wGb00B2]
    bit 7, a
    jr z, .o5
    ld a, [wGb00Result]
    set 3, a
    ld [wGb00Result], a
.o5
    ld a, [wGb00B2]
    bit 5, a
    jr z, .o6
    ld a, [wGb00Result]
    set 2, a
    ld [wGb00Result], a
.o6
    ld a, [wGb00B2]
    bit 3, a
    jr z, .o7
    ld a, [wGb00Result]
    set 1, a
    ld [wGb00Result], a
.o7
    ld a, [wGb00B2]
    bit 1, a
    jr z, .o8
    ld a, [wGb00Result]
    set 0, a
    ld [wGb00Result], a
.o8

.storeResult
    ld a, [wGb00Idx]
    ld l, a
    ld h, 0
    ld a, [wGb00BitsOutPtr]
    add a, l
    ld l, a
    ld a, [wGb00BitsOutPtr + 1]
    adc a, 0
    ld h, a
    ld a, [wGb00Result]
    ld [hl], a

    ld a, [wGb00Idx]
    inc a
    ld [wGb00Idx], a
    jp .loop

.doneGb00Bits
    ret

; Client-side bit rotation: bit0->bit3, bit3->bit6, bit6->bit0 of A (the
; exact inverse of the server's un-rotate step); bits 7,5,4,2,1 pass
; through unchanged.
; Input: A = byte
; Output: A = rotated byte
; Clobbers: BC
Gb00RotateEncode:
    ld b, a
    and a, $B6
    ld c, a
    ld a, b
    bit 0, a
    jr z, .skip1
    ld a, c
    set 3, a
    ld c, a
.skip1
    ld a, b
    bit 3, a
    jr z, .skip2
    ld a, c
    set 6, a
    ld c, a
.skip2
    ld a, b
    bit 6, a
    jr z, .skip3
    ld a, c
    set 0, a
    ld c, a
.skip3
    ld a, c
    ret

; Builds the Authorization header's "name" value (92 characters + NUL,
; wGb00Authorization) for the given challenge (exactly 48 base64
; characters, verbatim from the WWW-Authenticate header), login
; (adapter's own live config login id) and password (ISP PASSWORD menu).
;
; Input: HL = challenge (48 base64 chars, NOT NUL-terminated),
;        DE = login (NUL-terminated, <=19 bytes),
;        BC = password (NUL-terminated)
; Output: wGb00Authorization holds the built value, NUL-terminated
; Clobbers: everything
Gb00BuildAuthorization::
    ld a, l
    ld [wGb00ChallengePtr], a
    ld a, h
    ld [wGb00ChallengePtr + 1], a
    ld a, e
    ld [wGb00LoginPtr], a
    ld a, d
    ld [wGb00LoginPtr + 1], a
    ld a, c
    ld [wGb00PasswordPtr], a
    ld a, b
    ld [wGb00PasswordPtr + 1], a

    ld a, [wGb00ChallengePtr]
    ld l, a
    ld a, [wGb00ChallengePtr + 1]
    ld h, a
    ld c, GB00_CHALLENGE_LEN
    ld de, wGb00ChallengeRaw
    call Base64Decode

    ld hl, wGb00ChallengeRaw
    ld de, wGb00BitsSorted
    call Gb00BitsSorted

    ld a, [wGb00ChallengePtr]
    ld l, a
    ld a, [wGb00ChallengePtr + 1]
    ld h, a
    ld de, wGb00Md5Input
    ld b, GB00_CHALLENGE_LEN
.copyChallengeToMd5
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyChallengeToMd5

    ld a, [wGb00PasswordPtr]
    ld l, a
    ld a, [wGb00PasswordPtr + 1]
    ld h, a
    xor a, a
    ld [wGb00PasswordLen], a
.copyPassword
    ld a, [hl+]
    or a, a
    jr z, .passwordDone
    ld [de], a
    inc de
    ld a, [wGb00PasswordLen]
    inc a
    ld [wGb00PasswordLen], a
    jr .copyPassword
.passwordDone

    ld hl, wGb00Md5Input
    ld a, [wGb00PasswordLen]
    add a, GB00_CHALLENGE_LEN
    ld c, a
    ld de, wGb00PwHash
    call Md5

    ld hl, wGb00PwHash
    ld de, wGb00Plaintext
    ld b, 16
.copyHash
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyHash

    ld a, [wGb00LoginPtr]
    ld l, a
    ld a, [wGb00LoginPtr + 1]
    ld h, a
    xor a, a
    ld [wGb00LoginLen], a
.loginLenLoop
    ld a, [hl+]
    or a, a
    jr z, .haveLoginLen
    ld a, [wGb00LoginLen]
    inc a
    ld [wGb00LoginLen], a
    jr .loginLenLoop
.haveLoginLen

    ld a, 20
    ld b, a
    ld a, [wGb00LoginLen]
    ld c, a
    ld a, b
    sub a, c
    ld b, a ; b = fill count = 20 - loginLen
    ld hl, wGb00Plaintext + 16
.fillLoop
    ld a, b
    or a, a
    jr z, .fillDone
    ld a, $FF
    ld [hl+], a
    dec b
    jr .fillLoop
.fillDone
    ld a, [wGb00LoginPtr]
    ld e, a
    ld a, [wGb00LoginPtr + 1]
    ld d, a
    ld a, [wGb00LoginLen]
    ld b, a
    or a, a
    jr z, .noLogin
.copyLogin
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .copyLogin
.noLogin

    xor a, a
    ld [wGb00Idx], a
.scrambleLoop
    ld a, [wGb00Idx]
    cp a, 36
    jr z, .scrambleDone
    ld l, a
    ld h, 0
    ld de, wGb00Plaintext
    add hl, de
    ld a, [hl]
    ld b, a

    ld a, [wGb00Idx]
    ld l, a
    ld h, 0
    ld de, wGb00BitsSorted
    add hl, de
    ld a, [hl]
    xor a, b

    call Gb00RotateEncode
    ld c, a

    ld a, [wGb00Idx]
    ld l, a
    ld h, 0
    ld de, wGb00Scrambled
    add hl, de
    ld a, c
    ld [hl], a

    ld a, [wGb00Idx]
    inc a
    ld [wGb00Idx], a
    jr .scrambleLoop
.scrambleDone

    ; First component: a fresh, independently-padded base64 encoding of
    ; the challenge's first 32 raw bytes -- NOT a slice of the original
    ; 48-character challenge text (36 bytes has no base64 padding, so a
    ; naive slice at character 44 does not correspond to a clean
    ; 32-byte prefix; confirmed by gbdk's own round-trip test).
    ld hl, wGb00ChallengeRaw
    ld c, 32
    ld de, wGb00Authorization
    call Base64Encode

    ld hl, wGb00Scrambled
    ld c, 36
    ld de, wGb00Authorization + 44
    jp Base64Encode

; ---- GB00 HTTP fetch engine --------------------------------------------
;
; Wraps a plain (no-auth) HTTP GET, detects a REON 401 challenge, and
; retries with the computed Authorization header -- mirrors gbdk's
; gb00_http_get()/gb00_status_code()/gb00_find_challenge()/gb00_fetch()
; (test_runner.c) step-for-step, but with no sprintf: every request this
; engine sends is either a fixed, compile-time ROM byte blob (the
; no-auth attempt, built by main.asm per target) or a compile-time-known
; prefix + the computed 92-char Authorization value + a shared
; compile-time suffix (the authenticated retry), copied byte-by-byte
; into a WRAM scratch buffer here -- matches this project's existing
; "no packed structs, explicit serialization" convention (repo-root
; CLAUDE.md).
;
; 300 bytes, matching gbdk's own GB00_RESP_BUF_SIZE exactly: gbdk
; measured a real nginx 401 challenge response (headers + the ~81-byte
; WWW-Authenticate line) at 227 bytes from a real BGB link-log capture
; -- 200 silently truncated it there, so this port starts from gbdk's
; already-hard-won number instead of re-deriving a smaller one and
; risking the same bug.
DEF GB00_RESP_BUF_SIZE EQU 300
DEF GB00_MAX_EMPTY_POLLS EQU 5
; Comfortably covers the largest real request this ROM builds (News
; Article's authenticated retry measures 238 bytes: prefix 122 + the
; 92-char Authorization value + a 24-byte suffix -- confirmed by
; counting the exact strings main.asm builds these from).
DEF GB00_AUTH_REQ_BUF_SIZE EQU 250

SECTION "Gb00 Fetch Scratch", WRAM0
; Caller-set request descriptor -- see Gb00FetchOne's own doc comment.
wGb00FetchNoAuthPtr:: dw
wGb00FetchNoAuthLen:: db
wGb00FetchAuthPrefixPtr:: dw
wGb00FetchAuthPrefixLen:: db
wGb00FetchLoginPtr:: dw
wGb00FetchPasswordPtr:: dw

; Results
wGb00FetchStatusText:: ds 4 ; 3 digits + NUL, e.g. "200"
wGb00FetchDidAuth:: db
wGb00FetchFailMsgPtr:: dw   ; valid only when Gb00FetchOne returns MAGB_ERR_ISP

wGb00RespBuf: ds GB00_RESP_BUF_SIZE
wGb00RespLen: dw ; 16-bit: GB00_RESP_BUF_SIZE(300) exceeds a byte's range
wGb00EmptyPolls: db
wGb00FetchChallenge: ds GB00_CHALLENGE_LEN ; NOT NUL-terminated, matches
                                            ; Gb00BuildAuthorization's HL input
wGb00AuthReqBuf: ds GB00_AUTH_REQ_BUF_SIZE
wGb00AuthReqLen: db

SECTION "Gb00 Fetch Code", ROMX, BANK[1]

; Sends [DE]/[C] as one MagbTransferData, then polls with zero-length
; reads (same shape as main.asm's HttpFetch) until Transfer Data End,
; the response buffer fills, or GB00_MAX_EMPTY_POLLS consecutive empty
; polls suggest the peer stalled. Requires [wTcpConnId] already set --
; Gb00FetchOne's job, not this helper's.
;
; Input: DE = request bytes, C = request length (a byte -- every
;        request this engine builds is well under 255)
; Output: A = result (0=OK, transport-level only); wGb00RespLen holds
;         the total bytes accumulated in wGb00RespBuf
; Clobbers: everything
Gb00HttpGetOnce:
    xor a, a
    ld [wGb00RespLen], a
    ld [wGb00RespLen + 1], a
    ld [wGb00EmptyPolls], a

    ld hl, wGb00RespBuf
    ld b, 255 ; GB00_RESP_BUF_SIZE(300) > 255 -- the first call is always capped at 255
    ld a, MAGB_TIMEOUT_FRAMES_LONG & $FF
    ld [wExecTimeoutFrames], a
    ld a, MAGB_TIMEOUT_FRAMES_LONG >> 8
    ld [wExecTimeoutFrames + 1], a
    call MagbTransferData
    or a, a
    ret nz

    ld a, [wXferGotLen]
    ld [wGb00RespLen], a
    xor a, a
    ld [wGb00RespLen + 1], a

.pollLoop
    ld a, [wXferRemoteClosed]
    or a, a
    jr nz, .done

    ld a, [wGb00EmptyPolls]
    cp a, GB00_MAX_EMPTY_POLLS
    jr nc, .done

    ; remaining (16-bit) = GB00_RESP_BUF_SIZE - wGb00RespLen
    ld a, [wGb00RespLen]
    ld e, a
    ld a, [wGb00RespLen + 1]
    ld d, a
    ld hl, GB00_RESP_BUF_SIZE
    ld a, l
    sub a, e
    ld l, a
    ld a, h
    sbc a, d
    ld h, a
    jr nc, .haveRemaining
    ld hl, 0
.haveRemaining
    ; cap = min(remaining, 255)
    ld a, h
    or a, a
    jr z, .remainderFits
    ld a, 255
    jr .haveCap
.remainderFits
    ld a, l
.haveCap
    or a, a
    jr z, .done ; buffer full
    ld b, a ; MagbTransferData's output-capacity input

    ld hl, wGb00RespBuf
    ld a, [wGb00RespLen]
    ld e, a
    ld a, [wGb00RespLen + 1]
    ld d, a
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
    ld a, [wGb00EmptyPolls]
    inc a
    ld [wGb00EmptyPolls], a
    jr .skipEmptyCount
.gotSomething
    xor a, a
    ld [wGb00EmptyPolls], a
.skipEmptyCount

    ld a, [wXferGotLen]
    ld e, a
    ld d, 0
    ld hl, wGb00RespLen
    ld a, [hl]
    add a, e
    ld [hl+], a
    ld a, [hl]
    adc a, d
    ld [hl], a

    jr .pollLoop

.done
    xor a, a
    ret

sGb00HttpMagic: db "HTTP/" ; compared by fixed 5-byte count, no NUL needed

; Extracts the 3-digit HTTP status from wGb00RespBuf (offset 9, e.g. the
; "200" in "HTTP/1.0 200 OK") if the response is long enough and starts
; with "HTTP/". Matches gbdk's gb00_status_code() exactly (same offset,
; same 12-byte minimum).
;
; Output: A = 1 on success (wGb00FetchStatusText holds the 3 digits,
;         NUL-terminated), 0 on failure
; Clobbers: everything
Gb00StatusCode:
    ld a, [wGb00RespLen + 1]
    or a, a
    jr nz, .longEnough ; high byte set -> definitely >= 256 > 12
    ld a, [wGb00RespLen]
    cp a, 12
    jr c, .fail
.longEnough
    ld hl, wGb00RespBuf
    ld de, sGb00HttpMagic
    ld b, 5
.magicCmp
    ld a, [de]
    inc de
    cp a, [hl]
    jr nz, .fail
    inc hl
    dec b
    jr nz, .magicCmp

    ld hl, wGb00RespBuf + 9
    ld de, wGb00FetchStatusText
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [hl+]
    ld [de], a
    inc de
    ld a, [hl]
    ld [de], a
    inc de
    xor a, a
    ld [de], a
    ld a, 1
    ret
.fail
    xor a, a
    ret

DEF GB00_NEEDLE_LEN EQU 17 ; "WWW-Authenticate:"
sGb00Needle: db "WWW-Authenticate:"

; Searches wGb00RespBuf (length wGb00RespLen) for "WWW-Authenticate:",
; then copies the GB00_CHALLENGE_LEN characters following the next '"'
; into wGb00FetchChallenge. Matches gbdk's gb00_find_challenge().
;
; Output: A = 1 on success, 0 if not found (or found too close to the
;         end of the buffer to hold a full challenge)
; Clobbers: everything
Gb00FindChallenge:
    ld hl, wGb00RespBuf
    ld a, [wGb00RespLen]
    ld e, a
    ld a, [wGb00RespLen + 1]
    ld d, a
.scanLoop
    ld a, d
    or a, a
    jr nz, .doCompare ; remaining >= 256, definitely enough room
    ld a, e
    cp a, GB00_NEEDLE_LEN + 1
    jr c, .notFound ; remaining <= NEEDLE_LEN -- can't possibly match
.doCompare
    push hl
    push de
    ld de, sGb00Needle
    ld b, GB00_NEEDLE_LEN
.cmpLoop
    ld a, [de]
    cp a, [hl]
    jr nz, .cmpFail
    inc hl
    inc de
    dec b
    jr nz, .cmpLoop
    pop de
    pop hl
    jr .matched
.cmpFail
    pop de
    pop hl
    inc hl
    ld a, e ; remaining--
    sub a, 1
    ld e, a
    ld a, d
    sbc a, 0
    ld d, a
    jr .scanLoop

.matched
    ld bc, GB00_NEEDLE_LEN
    add hl, bc
    ld a, e ; remaining -= NEEDLE_LEN
    sub a, GB00_NEEDLE_LEN
    ld e, a
    ld a, d
    sbc a, 0
    ld d, a

.quoteLoop
    ld a, d
    or a, a
    jr nz, .haveByte
    ld a, e
    or a, a
    jr z, .notFound ; ran out of buffer before finding a closing quote
.haveByte
    ld a, [hl+]
    ld c, a
    ld a, e ; remaining--
    sub a, 1
    ld e, a
    ld a, d
    sbc a, 0
    ld d, a
    ld a, c
    cp a, $22 ; '"'
    jr nz, .quoteLoop
    ; hl now points right after the opening quote (auto-incremented by
    ; the ld a,[hl+] that just read it); remaining = bytes left from there

    ld a, d
    or a, a
    jr nz, .haveChallenge ; remaining >= 256 > GB00_CHALLENGE_LEN(48)
    ld a, e
    cp a, GB00_CHALLENGE_LEN
    jr c, .notFound
.haveChallenge
    ld de, wGb00FetchChallenge
    ld b, GB00_CHALLENGE_LEN
.copyChallenge
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copyChallenge
    ld a, 1
    ret
.notFound
    xor a, a
    ret

sGb00Status401: db "401" ; compared by fixed 3-byte count, no NUL needed
sGb00AuthSuffix:
    db $22, $0D, $0A ; closing quote for the Authorization header value
    db "Connection: close", $0D, $0A
    db $0D, $0A
sGb00AuthSuffixEnd:

; Fetches one URL with REON's GB00 challenge/response auth, matching
; gbdk's gb00_fetch(): GET with no Authorization; if the response isn't
; a 401, done (no auth was required for this path). Otherwise finds the
; WWW-Authenticate challenge, computes the Authorization value, and
; re-sends the GET with it. Opens its own TCP connection (port 80,
; hardcoded -- every GB00 target in this ROM is on the same
; gameboy.datacenter.ne.jp:80) and always closes it before returning, on
; every exit path -- the caller only owns Begin Session/Dial/ISP
; Login/DNS Query around one or more calls to this (News Article calls
; this twice in the same ISP session, one DNS Query shared between
; them).
;
; Input: caller must set, before calling:
;   wGb00FetchNoAuthPtr/Len     -- the fixed no-auth GET request bytes
;   wGb00FetchAuthPrefixPtr/Len -- "GET <path> HTTP/1.0\r\nHost: ...\r\n
;                                  Authorization: GB00 name=\"" (no
;                                  closing quote/blank line -- this
;                                  routine appends the computed 92-char
;                                  value and the shared suffix itself)
;   wGb00FetchLoginPtr/PasswordPtr -- NUL-terminated strings
; Output: A = result (0=OK; else a MAGB_ERR_* code from the underlying
;         TCP/transfer call, or MAGB_ERR_ISP for an app-level parse
;         failure -- see wGb00FetchFailMsgPtr, valid only in that case).
;         On success: wGb00FetchStatusText holds the final 3-digit
;         status, wGb00FetchDidAuth records whether the auth retry
;         happened.
; Clobbers: everything
Gb00FetchOne::
    xor a, a
    ld [wGb00FetchDidAuth], a

    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    ret nz

    ld a, [wGb00FetchNoAuthPtr]
    ld e, a
    ld a, [wGb00FetchNoAuthPtr + 1]
    ld d, a
    ld a, [wGb00FetchNoAuthLen]
    ld c, a
    call Gb00HttpGetOnce
    or a, a
    jr z, .checkStatus
    push af
    call MagbTcpClose
    pop af
    ret

.checkStatus
    call Gb00StatusCode
    or a, a
    jr nz, .haveStatus
    call MagbTcpClose
    ld hl, sGb00NoHttpPrefix
    ld a, l
    ld [wGb00FetchFailMsgPtr], a
    ld a, h
    ld [wGb00FetchFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret

.haveStatus
    ld hl, wGb00FetchStatusText
    ld de, sGb00Status401
    ld b, 3
.cmp401Loop
    ld a, [de]
    inc de
    cp a, [hl]
    jr nz, .noAuthNeeded
    inc hl
    dec b
    jr nz, .cmp401Loop
    ; all 3 bytes matched -- status is "401"
    call Gb00FindChallenge
    or a, a
    jr nz, .haveChallenge
    call MagbTcpClose
    ld hl, sGb00NoAuthHeader
    ld a, l
    ld [wGb00FetchFailMsgPtr], a
    ld a, h
    ld [wGb00FetchFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret

.noAuthNeeded
    call MagbTcpClose
    xor a, a
    ret

.haveChallenge
    call MagbTcpClose

    ld hl, wGb00FetchChallenge
    ld a, [wGb00FetchLoginPtr]
    ld e, a
    ld a, [wGb00FetchLoginPtr + 1]
    ld d, a
    ld a, [wGb00FetchPasswordPtr]
    ld c, a
    ld a, [wGb00FetchPasswordPtr + 1]
    ld b, a
    call Gb00BuildAuthorization

    ld hl, wDnsResultIp
    ld bc, 80
    call MagbTcpOpen
    or a, a
    ret nz ; TCP reopen failed -- a real MAGB_ERR_*, PrintErrorCode covers it

    ld hl, wGb00AuthReqBuf
    ld a, [wGb00FetchAuthPrefixPtr]
    ld e, a
    ld a, [wGb00FetchAuthPrefixPtr + 1]
    ld d, a
    ld a, [wGb00FetchAuthPrefixLen]
    ld b, a
    call .appendReqBytes

    ld de, wGb00Authorization
    ld b, GB00_AUTHORIZATION_LEN
    call .appendReqBytes

    ld de, sGb00AuthSuffix
    ld b, sGb00AuthSuffixEnd - sGb00AuthSuffix
    call .appendReqBytes

    ld a, [wGb00FetchAuthPrefixLen]
    add a, GB00_AUTHORIZATION_LEN
    add a, sGb00AuthSuffixEnd - sGb00AuthSuffix
    ld [wGb00AuthReqLen], a

    ld de, wGb00AuthReqBuf
    ld a, [wGb00AuthReqLen]
    ld c, a
    call Gb00HttpGetOnce
    or a, a
    jr z, .checkAuthStatus
    push af
    call MagbTcpClose
    pop af
    ret

.checkAuthStatus
    call MagbTcpClose
    call Gb00StatusCode
    or a, a
    jr nz, .authStatusOk
    ld hl, sGb00NoHttpPrefixAfterAuth
    ld a, l
    ld [wGb00FetchFailMsgPtr], a
    ld a, h
    ld [wGb00FetchFailMsgPtr + 1], a
    ld a, MAGB_ERR_ISP
    ret
.authStatusOk
    ld a, 1
    ld [wGb00FetchDidAuth], a
    xor a, a
    ret

; Appends B bytes from [DE] to the write cursor in HL (advancing both),
; local to Gb00FetchOne's request-building step above -- not exported,
; not meant for reuse elsewhere.
; Input: DE = source, B = length, HL = write cursor (persists across
;        calls -- the three call sites above build one request in place)
; Output: HL advanced past the copied bytes
; Clobbers: A, DE, HL, B
.appendReqBytes:
    ld a, b
    or a, a
    ret z
.appendReqLoop
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .appendReqLoop
    ret

sGb00NoHttpPrefix:          db "NO HTTP/ PREFIX", 0
sGb00NoAuthHeader:          db "NO WWW-AUTH HDR", 0
sGb00NoHttpPrefixAfterAuth: db "NO HTTP AFTER AUTH", 0
