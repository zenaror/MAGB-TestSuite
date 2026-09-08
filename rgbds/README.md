# Mobile Adapter GB TestSuite -- RGBDS implementation

A from-scratch, hand-written **SM83 assembly** implementation of the
Mobile Adapter GB TestSuite, built with [RGBDS](https://rgbds.gbdev.io/),
living alongside the working [`gbdk/`](../gbdk/) C implementation. See
the repo root [`README.md`](../README.md) for what the TestSuite is and
what it tests in general, and
[`docs/status.md`](docs/status.md) in this directory for the
exhaustive, up-to-date list of what's implemented and confirmed working
so far.

## Prerequisites

- [RGBDS](https://rgbds.gbdev.io/) (`rgbasm`, `rgblink`, `rgbfix`).
- [BGB](https://bgb.bircd.org/) + `libmobile-bgb` + `libmobile`, or a
  real Mobile Adapter GB + flash cart, for manual testing (see
  [`gbdk/docs/testing.md`](../gbdk/docs/testing.md) — the same
  environment serves both implementations).
- [PyBoy](https://github.com/Baekalfen/PyBoy) (optional) — used during
  development to unit-test individual routines by redirecting the CPU's
  PC directly into them; not required to build or run the ROM.

## Building

```sh
make
```

Requires RGBDS (`rgbasm`, `rgblink`, `rgbfix`) on `PATH`, or point at a
specific install:

```sh
make RGBASM=/path/to/rgbasm RGBLINK=/path/to/rgblink RGBFIX=/path/to/rgbfix
```

Output: `build/mobile_adapter_testsuite_rgbds.gbc`, a CGB-only
(`0x143 = 0xC0`), 32 KiB ROM on MBC5 + RAM + BATTERY (`0x147 = 0x1B`).
The mapper is there for the battery, not for space — it persists the
ISP password across power cycles; nothing here ever switches a ROM
bank. Also copied to the shared
`../emulador/` if that directory exists (see
[`gbdk/docs/testing.md`](../gbdk/docs/testing.md)) -- deliberately a
*different* filename than the GBDK build's, since both share that
directory.

```sh
make clean
```

Validate the CGB-only header after a build:

```sh
xxd -s 0x143 -l 1 build/mobile_adapter_testsuite_rgbds.gbc   # expect: c0       (CGB only)
xxd -s 0x147 -l 3 build/mobile_adapter_testsuite_rgbds.gbc   # expect: 1b 00 02 (MBC5+RAM+BAT, 32 KiB ROM, 8 KiB RAM)
```

There is no host-side (`make test`) unit-test target on this side yet
-- routine-level verification during development is done via PyBoy
(see [`docs/status.md`](docs/status.md), which documents each routine's
test cases inline).

## Architecture

Same three-layer separation as `gbdk/` (see the repo root
[`CLAUDE.md`](../CLAUDE.md) for the full rationale), mapped to this
implementation's files:

```text
src/hw/serial.asm           Layer 1: SB/SC only, no protocol knowledge
src/hw/joypad.asm           Layer 1: input reading, no protocol knowledge
src/protocol/packet.asm     Layer 2: checksum, request-frame building (hardware-free)
src/protocol/config.asm     Layer 2: configuration blob decoding (BCD phone, checksum)
src/protocol/session.asm    Layer 2: MagbExecute (ACK/idle-byte handshake), command wrappers, trace ring buffer
src/app/gb00_auth.asm       Layer 3-ish: MD5 + base64 + GB00 challenge/response (ROMX BANK[1])
src/app/net_extra.asm       Layer 3-ish: line-based TCP protocol engine for SMTP/POP3 (ROMX BANK[1])
src/app/big_buffer.asm      Layer 3-ish: streaming GB00 request engine, Small/Big Buffer tests (ROMX BANK[1])
src/app/save.asm            Layer 3: battery-backed SRAM record (ISP password)
src/app/text.asm            Layer 3: font, PrintString, decimal/hex formatting
src/app/sound.asm           Layer 3: result beeps
src/main.asm                Layer 3 + entry point: menu, joypad, test sequencing, result/trace/config screens
```

`gb00_auth.asm`, `net_extra.asm` and `big_buffer.asm` live in `ROMX,
BANK[1]` rather than `ROM0`. Everything else did originally, which
meant the entire upper half of the physical 32 KiB ROM sat unused until
GB00/Email needed the room (see `docs/status.md`'s "GB00 authentication
primitives"). Bank 1 is the only ROMX bank and nothing here ever writes
a bank number, so it is simply the always-mapped upper 16 KiB — adding
a second bank would change that.

Want to use this protocol code in your own homebrew, not just run this
diagnostic ROM? [`docs/integration-guide.md`](docs/integration-guide.md)
covers what to copy (`src/hw/`, `src/protocol/`, not `src/app/`), the
calling conventions, the VBlank vector `SerialHwInit` claims, the
optional status callback, and the traps that only exist in assembly.
Read [`gbdk/docs/integration-guide.md`](../gbdk/docs/integration-guide.md)
alongside it — the protocol reasoning is written once, there.

## Known limitations

- No 16-bit-to-decimal formatting routine yet, so HTTP GET does not show
  the exact received byte count the way `gbdk/`'s equivalent screen does
  (`RX TOTAL %u B`) -- a display-only gap, not a protocol one.
- If an early ISP/HTTP command (Dial, ISP Login, DNS, TCP Open, HTTP
  GET itself) fails, this ROM stops immediately rather than attempting
  `gbdk/`'s full best-effort teardown chain (TCP Close → ISP Logout →
  Hang Up → End Session) the way a later-stage failure already does.
- On a non-CGB console `SerialHwInit` halts without showing anything,
  since no font is loaded that early. `gbdk/`'s equivalent prints an
  explanation. See the integration guide.

See [`docs/status.md`](docs/status.md)'s "Known simplifications" and
"What's explicitly NOT implemented yet" sections for the complete,
current list.

## License

See [`../LICENSE`](../LICENSE). This repository contains original
homebrew code only -- no Nintendo SDK, Pokémon, or other copyrighted
ROM data.
