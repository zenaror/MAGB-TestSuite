; MAGB packet framing: checksum computation and packet building.
;
; Mirrors the wire format documented in the repo-root CLAUDE.md exactly:
;   99 66 <command> <reserved=00> <length_hi> <length_lo> <payload...> <checksum_hi> <checksum_lo>
; Checksum is the 16-bit unsigned sum of command+reserved+length_hi+
; length_lo+payload (NOT the two magic bytes), transmitted big-endian.
;
; This module only builds bytes in RAM -- it knows nothing about the
; serial port. See src/hw/serial.asm for that, and src/protocol/session.asm
; for the ACK/wait-byte exchange that actually sends these bytes and
; validates a response.

INCLUDE "hardware.inc"
INCLUDE "protocol.inc"

SECTION "Protocol Buffers", WRAM0

; Holds one built request frame, or one received response frame's raw
; header+payload (see session.asm). Sized for PROTO_MAX_PAYLOAD_LEN.
wPacketBuffer:: ds PROTO_FRAME_OVERHEAD + PROTO_MAX_PAYLOAD_LEN

; BuildRequestFrame's scratch: command/payload_len must survive the
; payload-copy loop, which otherwise wants every register.
wBuildCommand:: db
wBuildPayloadLen:: db

SECTION "Protocol Code", ROM0

; Computes the MAGB checksum: a 16-bit unsigned sum of BC consecutive
; bytes starting at HL (unsigned overflow wraps, matching the documented
; "16-bit unsigned sum" spec -- this is intentional, not a bug).
;
; Input:  HL = pointer to the first byte to sum (the command byte, never
;              the magic bytes)
;         BC = number of bytes to sum
; Output: DE = 16-bit checksum, D = high byte, E = low byte (the same
;              order the checksum is transmitted on the wire)
; Clobbers: A, HL, BC
ComputeChecksum::
    ld de, 0
.loop
    ld a, b
    or a, c
    jr z, .done

    ld a, [hl+]
    call ChecksumAddByte
    dec bc
    jr .loop

.done
    ret

; Adds A into the running 16-bit checksum accumulator DE. Shared between
; ComputeChecksum's bulk loop (above) and session.asm's byte-at-a-time
; response checksum (there is no complete buffer to sum over while a
; response is still arriving one serial byte at a time).
;
; Input:  A = byte to add, DE = running sum
; Output: DE = updated sum
; Clobbers: none
ChecksumAddByte::
    add a, e
    ld e, a
    ret nc
    inc d
    ret

; Builds a request frame into wPacketBuffer: magic 99 66, command,
; reserved 00, length_hi 00, length_lo, payload, checksum. Cross-checked
; for Begin Session against CLAUDE.md's "Known Serialization Test"
; vector: command $10, payload "NINTENDO" must produce
; 99 66 10 00 00 08 4E 49 4E 54 45 4E 44 4F 02 77 (checksum 0x0277) --
; also gbdk/tests/host/test_packet.c's identical vector, so both
; implementations provably build the same bytes for the same command.
;
; Input:  A = command
;         DE = pointer to payload bytes (ignored if C == 0)
;         C = payload length (0..PROTO_MAX_PAYLOAD_LEN)
; Output: HL = wPacketBuffer, B = total frame length in bytes
;         carry SET if C > PROTO_MAX_PAYLOAD_LEN (nothing written, HL/B undefined)
; Clobbers: A, DE
BuildRequestFrame::
    ld [wBuildCommand], a
    ld a, c
    cp a, PROTO_MAX_PAYLOAD_LEN + 1
    jr nc, .tooLarge
    ld [wBuildPayloadLen], a

    ld hl, wPacketBuffer
    ld a, MAGB_MAGIC_1
    ld [hl+], a
    ld a, MAGB_MAGIC_2
    ld [hl+], a
    ld a, [wBuildCommand]
    ld [hl+], a
    xor a, a
    ld [hl+], a ; reserved
    ld [hl+], a ; length hi
    ld a, [wBuildPayloadLen]
    ld [hl+], a ; length lo

    or a, a
    jr z, .checksum
    ld b, a
.copyPayload
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .copyPayload

.checksum
    push hl ; remember where to write the checksum
    ld hl, wPacketBuffer + 2 ; first byte to sum: the command byte
    ld a, [wBuildPayloadLen]
    ld c, a
    ld b, 0 ; bc = payload_len, zero-extended
    ; bc += 4 (command+reserved+length_hi+length_lo) via inc, not
    ; `add a,4` on the 8-bit payload_len -- with PROTO_MAX_PAYLOAD_LEN
    ; up to 254, `254 + 4` overflows a uint8 (wraps to 2), silently
    ; corrupting the checksum for any payload over 251 bytes.
    inc bc
    inc bc
    inc bc
    inc bc
    call ComputeChecksum
    pop hl
    ld a, d
    ld [hl+], a
    ld a, e
    ld [hl+], a

    ; Total frame length (for the caller's transmit loop) likewise
    ; needs 16 bits: PROTO_FRAME_OVERHEAD(8) + a payload near
    ; PROTO_MAX_PAYLOAD_LEN's real 254-byte ceiling exceeds 255.
    ld a, [wBuildPayloadLen]
    ld c, a
    ld b, 0
    ld hl, PROTO_FRAME_OVERHEAD
    add hl, bc
    ld b, h
    ld c, l ; bc = total frame length
    ld hl, wPacketBuffer
    or a, a ; clear carry: success
    ret

.tooLarge
    scf
    ret
