# Using this TestSuite's protocol code in your own homebrew

This is the RGBDS/assembly counterpart of
[`gbdk/docs/integration-guide.md`](../../gbdk/docs/integration-guide.md).
Read that one first if you don't specifically need assembly -- the C
implementation is more mature (full Test 1/2 coverage, P2P, GB00 auth,
a config reader) and has a cleaner library boundary (see section 2
below for exactly how this one differs). This guide exists for people
who want the protocol in a hand-written SM83 ROM with no C runtime at
all, or who want to see the wire protocol at the instruction level.

As of this writing this port covers Begin/End Session, Dial/Hang Up,
ISP Login/Logout, DNS Query, TCP Open/Close, and Transfer Data (with a
working HTTP/1.0 GET built on top) -- see
[`rgbds/docs/status.md`](status.md) for exactly what's implemented and
what isn't (notably: no P2P, no config read, no GB00 auth yet).

Unlike gbdk's version, `src/hw/`+`src/protocol/` here have **no
compile-time dependency on this TestSuite's own UI code** -- you can
copy just those two directories plus `include/` and build them as-is;
nothing forces you to define anything UI-related first. See section 2.

## 1. What to copy

```
include/hardware.inc
include/protocol.inc

src/hw/serial.asm
src/protocol/packet.asm
src/protocol/session.asm
```

`src/app/*` (`main.asm`, `text.asm`) is this TestSuite's own menu/text
renderer/diagnostic display -- not meant to be copied, same as `gbdk`'s
`src/app/`.

Every `.asm` file that uses `protocol.inc`'s constants (`PROTO_*`,
`MAGB_*`) must `INCLUDE "protocol.inc"` itself -- unlike C headers,
RGBDS `DEF`/`EQU` constants don't cross `.asm` file boundaries on their
own (only `::`-exported labels do, resolved by the linker). If you
split these files differently in your own project, keep that in mind.

## 2. Optional: live-status notifications

This TestSuite's own text renderer (`text.asm`/`main.asm`) shows *which
stage* of a command is in flight (WAKE/SEND/WAIT/READ) -- useful for
diagnosing a hang on real hardware with no debugger attached.
`session.asm` supports this through an **optional callback pointer**,
not a hard link-time dependency -- `src/hw/`+`src/protocol/` build and
link completely on their own, with no UI code, if you never touch this.

```asm
call MagbProtocolInit ; zeroes the callback pointer -- call this once,
                       ; before any other Magb* function
```

That alone is enough if you don't want a status display at all -- every
`MagbExecute` phase transition checks the pointer, finds it zero, and
skips the notification. If you *do* want one, register a function
matching this contract:

```asm
; Input: A = 0 (about to wake the adapter/send a request)
;            1 (request sent, waiting for the adapter's ACK)
;            2 (ACK'd, waiting for the response to start arriving)
;            3 (response magic seen, reading the rest of it)
; Clobbers: whatever you want -- the caller treats this the same as any
; other `call`.
MyStatusFn:
    ret

    ...
    ld hl, MyStatusFn
    call MagbSetStatusCallback
```

`main.asm`'s own `SetStatus::` (prints one of four short strings to a
fixed screen row) is a complete working example -- see `EntryPoint`'s
`call MagbProtocolInit` / `call MagbSetStatusCallback` pair near the
top for exactly how this TestSuite wires itself up as just another
caller of this same optional mechanism.

Index `0` is never sent by `session.asm` itself, only by `main.asm`
before calling `MagbBeginSession` -- purely cosmetic, safe to ignore.

## 3. One-time setup

```asm
INCLUDE "hardware.inc"
INCLUDE "protocol.inc"

EntryPoint:
    ; A must still hold the boot-time hardware ID ($11 CGB / $01 DMG)
    ; here -- nothing before this may touch A.
    call SerialHwInit
    ; ... your own game's init ...
```

**Important, unlike gbdk's version:** `SerialHwInit` claims the fixed
VBlank interrupt vector (`SECTION "VBlank Vector", ROM0[$0040]`) and
writes `rIE` directly (`ld a, IEF_VBLANK` / `ldh [rIE], a`), not OR'd
into whatever was already there. `session.asm`'s response-wait timeout
needs its VBlank-driven frame counter (`wSysTime`) actually advancing,
so something has to own that vector.

- If your game has **no VBlank handler of its own yet**, this is a
  non-issue -- just call `SerialHwInit` once at startup.
- If your game **already has its own VBlank handler**, you cannot link
  both as-is: RGBDS will refuse two `SECTION`s fixed at `$0040`. Merge
  `wSysTime`'s increment (see `src/hw/serial.asm`'s `VBlankISR`) into
  your own handler, drop this file's fixed-address `SECTION`, and make
  sure your own `rIE` write includes `IEF_VBLANK` alongside whatever
  else you already enable.

`SerialHwInit` halts permanently (deliberately, not a hardware-wait
timeout -- see its own comment) if the console isn't a CGB, since the
GBC high-speed serial mode this code depends on doesn't exist on
DMG/MGB.

There is **no cancel/abort hook** yet (gbdk's `g_magb.cancel_check`
function pointer has no RGBDS equivalent) -- a long operation
(dialing, DNS, TCP) can only be interrupted by its own
`MAGB_TIMEOUT_FRAMES_*` budget expiring, not by a button press. Worth
knowing before shipping something a player might want to cancel.

## 4. One real state, not a context struct

gbdk's API takes a `magb_context_t *ctx` parameter, so a C program can
in principle run more than one independently. **This RGBDS port has no
such parameter** -- session state (`wSessionActive`, `wRxPayload`,
`wTcpConnId`, `wXferPayload`, ...) is fixed global WRAM, one instance
per ROM build. This is fine for a single Mobile Adapter link (the
normal case), but if you need more than one logical connection at once
you'd need to duplicate these WRAM blocks and the functions that touch
them yourself -- nothing here is written to be instanced.

Also worth knowing before wiring this into an existing project's own
WRAM budget: this state currently adds up to a little over 1 KiB in
`WRAM0` (the payload buffers are sized for the protocol's real 254-byte
maximum) -- comfortably inside the CGB's 4 KiB fixed `WRAM0` bank on
its own, but worth checking against whatever your own game already
uses there.

## 5. Recipe: Begin a session, do something, end it

```asm
call MagbBeginSession
or a, a
jr nz, .fail ; A = a MAGB_ERR_* code, see protocol.inc

; ... do work, see the recipe below ...

call MagbEndSession
```

`[wSessionActive]` is `1` only once Begin Session has been fully
validated (echoed `"NINTENDO"` payload, correct checksum) -- never
assume success from a single byte.

## 6. Recipe: fetch something over the internet (ISP/HTTP)

This is a real, working, tested sequence -- `src/main.asm`'s
`RunIspHttpTest` (reachable from this TestSuite's own main menu's
"ISP/HTTP" item) is a complete, error-checked reference implementation
of exactly this (including the HTTP response-polling loop), the
assembly equivalent of gbdk's `test_isp_http()`:

```asm
    ld hl, sMyPhoneNumber   ; e.g. your ISP's dial string
    ld b, sMyPhoneNumberEnd - sMyPhoneNumber
    call MagbDial
    or a, a
    jr nz, .fail

    ld de, sMyIspLoginPayload ; pre-built: login_len,login,password_len,
    ld c, sMyIspLoginPayloadEnd - sMyIspLoginPayload ; password,dns1[4],dns2[4]
    call MagbIspLogin           ; on success: wIspAssignedIp (12 bytes)
    or a, a
    jr nz, .fail

    ld hl, sMyHostname
    ld b, sMyHostnameEnd - sMyHostname
    call MagbDnsQuery            ; on success: wDnsResultIp (4 bytes)
    or a, a
    jr nz, .fail

    ld hl, wDnsResultIp
    ld bc, 80                    ; port
    call MagbTcpOpen              ; on success: wTcpConnId (1 byte)
    or a, a
    jr nz, .fail

    ld de, sMyRequest
    ld c, sMyRequestEnd - sMyRequest
    ld hl, wMyRespBuf
    ld b, MY_RESP_BUF_SIZE
    call MagbTransferData
    or a, a
    jr nz, .fail
    ; [wXferGotLen] = bytes received this call, [wXferRemoteClosed] = 1
    ; once the adapter reports Transfer Data End. Keep calling
    ; MagbTransferData with C=0 (no new data) to poll for the rest,
    ; exactly like src/main.asm's HttpFetch does, until remote_closed.

    call MagbTcpClose
    call MagbIspLogout
    call MagbHangup
```

Check every call's `A` result in real code -- the example above omits
some of that for brevity. `rgbds/src/main.asm`'s `HttpFetch`/
`HttpShowResult` show the complete version, including the
total-bytes/empty-poll safety bounds and response parsing.

## 7. Recipe: direct player-to-player link (P2P)

**Not implemented in this RGBDS port yet** -- see `docs/status.md`.
`gbdk/docs/integration-guide.md`'s own P2P recipe (`magb_dial()` /
`magb_wait_for_call()` + `magb_transfer_data()` with your own tiny
framing on top) is the reference; porting it to RGBDS should follow
the exact same `MagbTransferData` shape already established here (see
recipe 6 above) once `MagbWaitForCall` exists.

## 8. Things this TestSuite already got wrong once -- don't reintroduce them

- **`SC_REG` must be written in two steps**, not combined into one
  write -- see `include/hardware.inc`'s `SC_CLOCK_SPEED` comment and
  `gbdk/docs/journal.md`'s "Handshake / sessão inicial" for the real
  hardware/BGB behavior this was confirmed against.
- **Don't validate ACK1/ACK2 by exact expected value.** The
  BGB<->libmobile-bgb relay path can deliver a meaningful byte one
  transfer later than a synchronous read predicts --
  `session.asm`'s `RequestAckPhase` tolerates `MAGB_ADAPTER_WAIT`
  (`0xD2`) at every checkpoint for exactly this reason, not just in a
  single dedicated wait loop. Only the explicit transport-error codes
  (`0xF0`/`0xF1`/`0xF2`) and the response frame's own checksum are safe
  to treat as authoritative.
- **CGB display bring-up has no `set_default_palette()` equivalent
  here** -- `main.asm`'s `InitDisplayBlank` sets BG palette 0 manually
  via `rBCPS`/`rBCPD`. If you build your own text/tile display on CGB,
  remember `LCDC` bit 4 (`LCDC_BG_TILEDATA` in `hardware.inc`) must be
  set whenever your tile data lives at `$8000` (unsigned addressing) --
  leaving it at its power-on default silently reads tiles from `$9000`
  with *signed* addressing instead, producing a blank screen with no
  error of any kind (see `docs/status.md`'s "Hard-won bugs").
- **8-bit length arithmetic breaks once payloads approach the real
  254-byte max.** `packet.asm`'s `BuildRequestFrame` originally summed
  an 8-bit payload length with a small constant using an 8-bit `add`
  in two places; both silently wrapped once the payload got large
  enough (see `docs/status.md`). Now computed in 16-bit `BC`. If you
  extend this code further, any new length/offset arithmetic should
  default to 16-bit unless you've specifically checked the value can
  never exceed 255.
- **A "fill with a constant" loop must check the loop counter *before*
  writing, not after**, if the constant being written and the
  loop-counter scratch share the same register -- an easy mistake with
  `A` doing double duty. Not protocol code (it bit `main.asm`'s
  `FillMemory` and `text.asm`'s `ClearTextScreen`), but a real,
  hard-to-spot bug worth remembering if you adapt any of this project's
  own loops elsewhere.

## 9. What NOT to copy as-is

- `src/main.asm` and `src/app/text.asm` are this TestSuite's own
  fixed-layout menu/status display -- not library code. The `SetStatus`
  contract (section 2) is the only thing from them worth treating as
  an API.
- The test constants baked into `src/main.asm` (`sIspPhoneNumber`
  `"#9677"`, `sIspLoginPayload`'s `"test"`/`"test"`, `sDnsHostname`
  `"gameboy.datacenter.ne.jp"`, `sHttpRequest`'s exact GET path) are
  this TestSuite's own diagnostic target (the same real, documented
  targets `gbdk`'s `test_config.h` uses) -- point your own game at your
  own ISP/server.
- P2P, config read (`0x19`/`0x1A`), GB00 auth, and email are not
  ported here at all -- if you need any of those today, work from
  `gbdk`'s C implementation (`gbdk/src/protocol/magb_config.c`,
  `gbdk/src/app/gb00_auth.c`) and `gbdk/docs/integration-guide.md`
  instead.
