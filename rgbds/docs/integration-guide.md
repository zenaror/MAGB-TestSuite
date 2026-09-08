# Using this TestSuite's Mobile Adapter code in your own homebrew

The SM83 assembly counterpart of
[`gbdk/docs/integration-guide.md`](../../gbdk/docs/integration-guide.md).

**Read that one too, even if you write only assembly.** The two
implementations are deliberately kept behaviourally identical, and the
protocol reasoning — why one Transfer Data both sends and receives, the
three kinds of GB00 401, what a real Mobile Trainer's pacing looks like
— is written once, there. This guide covers what is different *here*:
the calling conventions, the global-state model, and the traps that
only exist in assembly.

Both sides now cover the same ground: session, dial, ISP, DNS, TCP,
Transfer Data, config readout, P2P, GB00 auth, SMTP/POP3, and a
battery-backed save. Neither is a subset of the other any more. See
[`docs/status.md`](status.md) for the exhaustive per-routine state.

---

## 1. What to copy

**Tier 1 — talk to the adapter at all:**

```text
include/hardware.inc
include/protocol.inc
src/hw/serial.asm
src/protocol/packet.asm
src/protocol/session.asm
```

`session.asm` carries the command wrappers too (Dial, ISP, DNS, TCP,
Transfer Data, Read Config), so unlike the C side there is no separate
"add networking" tier — it is one file, all of it, or a hand edit.

**Tier 2 — optional, take only what you need:**

```text
src/protocol/config.asm    config-blob decoding (BCD phone, checksum)
src/hw/joypad.asm          edge/repeat joypad reading, no protocol knowledge
include/gb00.inc
src/app/gb00_auth.asm      MD5 + base64 + REON's GB00 auth (NOT MAGB protocol)
src/app/net_extra.asm      line-based TCP engine for SMTP/POP3
src/app/save.asm           battery-backed SRAM record
```

`src/main.asm`, `src/app/text.asm`, `src/app/sound.asm` and
`src/app/big_buffer.asm` are this TestSuite's own program: menu, font,
result screens, and the two buffer tests. Read them, don't link them.
§9 says which patterns inside them are worth lifting.

### The `INCLUDE` rule that catches everyone once

RGBDS `DEF`/`EQU` constants are **assembler-time only and do not cross
`.asm` file boundaries.** Only `::`-exported labels do, resolved by the
linker. Every file that touches a `PROTO_*`/`MAGB_*` constant must
`INCLUDE "protocol.inc"` itself — `packet.asm` and `session.asm` both
include it for the same `PROTO_MAX_PAYLOAD_LEN`. If you re-split these
files, carry that with you.

---

## 2. Startup, and what `SerialHwInit` claims

```asm
INCLUDE "hardware.inc"
INCLUDE "protocol.inc"

EntryPoint:
    ; A must still hold the boot-time hardware ID ($11 CGB / $01 DMG).
    ; Nothing before this may touch A.
    ld sp, $FFFE          ; SP is not initialized for you; set it first
    call SerialHwInit
    call MagbProtocolInit
    ; ... your own init ...
```

`SerialHwInit` does four things, and two of them are claims on
resources your game may already own:

1. Verifies CGB and switches to double speed.
2. **Claims the VBlank interrupt vector** —
   `SECTION "VBlank Vector", ROM0[$0040]`.
3. **Writes `rIE` directly** (`ld a, IEF_VBLANK` / `ldh [rIE], a`), not
   OR'd into what was already there.
4. Zeroes `wSysTime` and enables interrupts.

`session.asm`'s response-wait timeout counts real VBlanks, so something
has to own that vector.

- **No VBlank handler of your own yet:** nothing to do.
- **You already have one:** you cannot link both — RGBDS refuses two
  `SECTION`s fixed at `$0040`. Merge `wSysTime`'s increment (see
  `VBlankISR` in `src/hw/serial.asm`) into your handler, delete this
  file's fixed-address `SECTION`, and make sure your own `rIE` write
  includes `IEF_VBLANK`.

### The non-CGB case is silent here, and that is worth fixing

On a DMG, `SerialHwInit` does `di` and halts forever, showing nothing.
That is a deliberate permanent stop, not an unbounded hardware wait —
but at that point in boot there is no font loaded and no screen set up,
so it cannot say why. The C side moved its equivalent into the app
layer specifically so it *could* say why (`ui_fatal_not_cgb()`).

If your game has a font by then, do the same: make `SerialHwInit`
return a flag instead of halting, and print your own message. A black
screen is indistinguishable from a dead cartridge.

---

## 3. Global state, not a context struct

gbdk's API takes `magb_context_t *ctx`, so a C program could in
principle run more than one. **This port has no such parameter.**
Session state (`wSessionActive`, `wRxPayload`, `wTcpConnId`,
`wXferPayload`, the trace ring) is fixed global WRAM, one instance per
ROM.

Fine for a single Mobile Adapter link, which is the only case that
exists in practice. If you needed two logical connections at once you
would have to duplicate the WRAM blocks and the routines that touch
them — nothing here is written to be instanced.

**WRAM budget:** the protocol layer's own sections total ~1.3 KiB in
`WRAM0` (Session State 276, Protocol Buffers 264, Transfer Scratch 260,
Trace State 258, Config Scratch 195, plus small per-command scratch).
The 258-byte trace ring is diagnostics; drop `Trace State` and
`RecordTraceByte`'s call sites if you don't want a debug overlay. The
buffers are sized for the protocol's real 254/255-byte maxima and
should not be shrunk — see §7.

### Calling convention

Every routine returns its result in `A`, `0` = OK, and clobbers
everything unless its own comment says otherwise. Codes are in
`protocol.inc` (`MAGB_ERR_*`), a subset of gbdk's enum with the same
names.

```asm
    call MagbBeginSession
    or a, a
    jr nz, .fail
```

---

## 4. Optional: live status notifications

`session.asm` can tell you which phase of a command is in flight —
useful for diagnosing a hang on real hardware with no debugger.

```asm
call MagbProtocolInit          ; zeroes the callback pointer; call once,
                               ; before any other Magb* routine
```

That alone is enough if you want no status display: every phase
transition checks the pointer, finds zero, and skips. It is an
**optional callback, not a link-time dependency** — `src/hw/` +
`src/protocol/` link on their own with no UI code at all.

To register one:

```asm
; Input: A = 0 about to wake/send, 1 waiting for the request ACK,
;            2 waiting for the response to start, 3 reading the response
; Clobbers: whatever you like; this is an ordinary `call`.
MyStatusFn:
    ret

    ld hl, MyStatusFn
    call MagbSetStatusCallback
```

`main.asm`'s `SetStatus::` is a complete working example.

### No cancel hook

gbdk's `ctx.cancel_check` function pointer has **no equivalent here.**
A long operation ends when its `MAGB_TIMEOUT_FRAMES_*` budget expires,
not when the player presses B. `main.asm`'s P2P loops check B
themselves, at the application level, between calls — that is the
pattern to copy if you need it. Worth knowing before shipping
something a player might want to back out of.

---

## 5. Recipe: fetch something over the internet

`RunIspHttpCore` in `src/main.asm` is the complete, error-checked
version of this, confirmed against a real server.

```asm
    call MagbBeginSession
    or a, a
    jr nz, .fail

    ; Dial: caller sets the timeout, because an ISP dial and a P2P dial
    ; need genuinely different budgets.
    ld a, LOW(MAGB_TIMEOUT_FRAMES_LONG)
    ld [wExecTimeoutFrames], a
    ld a, HIGH(MAGB_TIMEOUT_FRAMES_LONG)
    ld [wExecTimeoutFrames + 1], a
    ld hl, sMyPhoneNumber        ; ASCII digits, NOT NUL-terminated
    ld b, sMyPhoneNumberEnd - sMyPhoneNumber   ; length is explicit
    call MagbDial
    or a, a
    jr nz, .fail

    ; ISP Login: caller builds the whole payload --
    ; login_len, login, password_len, password, dns1[4], dns2[4]
    ld de, sMyIspLoginPayload
    ld c, sMyIspLoginPayloadEnd - sMyIspLoginPayload
    call MagbIspLogin            ; on OK: wIspAssignedIp[0:4]/[4:8]/[8:12]
    or a, a
    jr nz, .fail

    ld hl, sMyHostname
    ld b, sMyHostnameEnd - sMyHostname
    call MagbDnsQuery            ; on OK: wDnsResultIp[0:4]
    or a, a
    jr nz, .fail

    ld hl, wDnsResultIp
    ld bc, 80                    ; port, big-endian as transmitted
    call MagbTcpOpen             ; on OK: wTcpConnId
    or a, a
    jr nz, .fail

    ; Transfer Data: caller sets BOTH wTcpConnId (done by TcpOpen here)
    ; and wExecTimeoutFrames.
    ld de, sMyRequest
    ld c, sMyRequestEnd - sMyRequest
    ld hl, wMyRespBuf
    ld b, MY_RESP_BUF_SIZE
    call MagbTransferData
    ; [wXferGotLen] = bytes received this call
    ; [wXferRemoteClosed] = 1 once the adapter reports Transfer Data End
    ; Poll for the rest with C = 0 (send nothing) until remote_closed.

    call MagbTcpClose
    call MagbIspLogout
    call MagbHangup
    call MagbEndSession
```

Two things the register list does not make obvious:

- **`wExecTimeoutFrames` is an input**, for `MagbDial` and
  `MagbTransferData` only. Every other wrapper picks its own timeout
  internally. Forgetting it means the previous command's budget is
  still in effect.
- **`wTcpConnId` is an input to `MagbTransferData`**, despite the name.
  `MagbTcpOpen` fills it for a TCP session; a P2P session has no Open
  call, so a P2P caller sets it to `MAGB_P2P_CONNECTION_ID` itself.

### Reading the real ISP identity

`MagbReadConfig` fills `wConfigData` with the 192-byte blob in two
96-byte requests. `main.asm`'s `ReadIdentity` decodes login ID, email,
SMTP/POP hosts and Configuration Slot 1's BCD phone number
(`MagbConfigDecodePhone`, `config.asm`) out of it, and falls back to
constants only for an unregistered adapter. There is **no password
field anywhere in the blob** — that has to come from the user.

---

## 6. Recipe: bodies bigger than one payload, and line protocols

Both are in this repo already, and both exist because of the same rule:
**one Transfer Data both sends and receives**, so a "send-only" helper
that discards its output is throwing away whatever arrived with that
send. (Why that matters, and the two bugs it caused here, are in
`gbdk/docs/protocol-notes.md`.)

**Streaming a large request** — `BbStreamRequest`
(`src/app/big_buffer.asm`):

```asm
    ld hl, wBbReqBuf
    ld bc, request_length        ; 16-bit on purpose, see below
    call BbStreamRequest
```

It chunks at 253 bytes (the payload's first byte is the connection id),
sends every chunk but the last send-only, and routes **the final chunk
through a call that keeps the response** — that send completes the
request, so the reply can begin arriving on it.

The length is `BC`, not a byte, deliberately: the requests built here
run 96-261 bytes and a longer host or path would silently wrap an 8-bit
length instead of failing. The C side lost a day to exactly that.

**Line protocols** — `TcpSendLine` / `TcpRecvLine`
(`src/app/net_extra.asm`), for SMTP and POP3:

```asm
    ld hl, sMyCommand
    ld b, sMyCommandEnd - sMyCommand
    call TcpSendLine             ; keeps what comes back -- see below

    ld de, wMyLineBuf
    ld b, MY_LINE_BUF_SIZE
    call TcpRecvLine             ; accumulates to '\n', NUL-terminates
```

`TcpSendLine` deliberately passes a real destination buffer rather than
a zero-capacity one. A POP3 `+OK` frequently arrives bundled with the
ack for the send that asked for it; discarding it left every later poll
legitimately empty, waiting forever for a reply that had already
arrived. Don't "optimize" that buffer away.

---

## 7. Sizes: 254, 255, 253

- `PROTO_MAX_PAYLOAD_LEN` (254) — the conventional cap on what software
  *sends*.
- `PROTO_MAX_RX_PAYLOAD_LEN` (255) — what the adapter can legitimately
  *return*. Dan Docs: the real adapter discards packets larger than
  255, not 254. A real Transfer Data response carrying `payload_len =
  255` (conn_id + a full 254-byte chunk) was wrongly rejected as
  `MAGB_ERR_BAD_LENGTH` before this constant existed. Size receive
  buffers for 255.
- 253 — usable data per Transfer Data, after the connection-id byte.

---

## 8. Traps that only exist on this side

Everything in the C guide's "mistakes" list applies here too (two-step
`SC_REG` write, tolerating `$D2` at every ACK checkpoint, bounding every
external wait). These are the ones specific to RGBDS:

- **`SRAM` is a reserved keyword.** `save.asm` uses `SRAM_BASE` for the
  `$A000` window because of it. A sweeping rename to fix this will also
  rewrite the word inside prose comments; check the diff.
- **Local labels scope to the preceding *global* label.** A `.loop`
  under a routine you later split, or under a stray label added above
  it, silently belongs to a different parent. It bit
  `MagbReadConfig`'s `.halfLoop` here, when the wrapper that used to
  sit above it was removed.
- **`JR` range is only checked at link time.** A branch that assembles
  fine can fail to link once the section grows. Reach for `JP` in
  branches that span a long routine; the two extra cycles are not the
  problem you are solving.
- **8-bit length arithmetic wraps** where payloads get interesting.
  `packet.asm`'s `BuildRequestFrame` summed an 8-bit payload length
  with a small constant in two places; both wrapped silently near the
  254-byte max. It computes in 16-bit `BC` now. Default to 16-bit for
  any new length or offset arithmetic unless you have checked the value
  can never exceed 255.
- **A "fill with a constant" loop must test the counter *before*
  writing**, if the constant and the loop counter share a register —
  easy with `A` doing double duty. It bit `FillMemory` and
  `ClearTextScreen` here.
- **`LCDC` bit 4** (`LCDC_BG_TILEDATA`) must be set when your tile data
  lives at `$8000`. Left at its power-on default it reads tiles from
  `$9000` with *signed* addressing instead: blank screen, no error.
- **Writing VRAM outside an LCD-off window loses writes.** A tile write
  landing in PPU mode 3 is simply ignored on real hardware. This showed
  up as "some letters don't appear" in the live Raw TCP viewer, the one
  place writing tiles one byte at a time outside `PrintString`'s own
  LCD-off bracketing.
- **This cart is MBC5 now** (type `$1B`, for the battery — the build
  still fits in 32 KiB). On a mapperless ROM a stray write into
  `$0000-$7FFF` was harmless; now it reaches the mapper, and a write to
  `$2000-$3FFF` switches ROM banks mid-execution. Bank 1 is the only
  ROMX bank and nothing here ever writes a bank number, so `BANK[1]`
  still just means "the always-mapped upper 16 KiB" — anything that
  adds a second ROMX bank has to revisit that assumption.

---

## 9. What not to copy — and what to steal instead

| Don't link | Do steal the pattern |
| --- | --- |
| `src/main.asm` | `RunIspHttpCore`'s sequence and teardown; `ReadIdentity`; the P2P B-check loops (§4); `SetStatus::`'s callback shape |
| `src/app/text.asm` | its LCD-off bracketing around every VRAM write (§8) |
| `src/app/big_buffer.asm` | `BbStreamRequest`'s chunking and final-chunk rule (§6) |
| MATS framing (in `main.asm`) | the *idea* of a self-describing header inside Transfer Data payloads — it is this TestSuite's own invention, not part of the protocol |

The test constants baked into `main.asm` — `sIspPhoneNumber` `"#9677"`,
the `"test"`/`"test"` ISP login payload, `sDnsHostname`
`"gameboy.datacenter.ne.jp"`, the MAGBTEST paths — are this project's
diagnostic targets. Point your own game at your own server.

`gb00_auth.asm` is REON's HTTP auth scheme, not Mobile Adapter
protocol. `Md5`, `Base64Encode` and `Base64Decode` inside it are
generic and reusable; `Gb00BuildAuthorization` only means something
against REON. Read §9 of the C guide before using any of it — the
download/upload asymmetry and the three kinds of 401 are the parts that
cost real debugging time.
