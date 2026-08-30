# Mobile Adapter GB TestSuite -- GBDK implementation

TestSuite: a Game Boy Color-only homebrew ROM written in C with
[GBDK-2020](https://github.com/gbdk-2020/gbdk-2020). See the repo root
[`README.md`](../README.md) for what the TestSuite is, what it tests,
and how this implementation relates to the sibling
[`rgbds/`](../rgbds/) one.

## Prerequisites

- [GBDK-2020](https://github.com/gbdk-2020/gbdk-2020) (developed and
  tested against the 4.5.0 release, SDCC 4.5.1).
- A native C compiler (`cc`/`gcc`) for the host-side unit tests --
  optional, but strongly recommended before touching protocol code.
- [BGB](https://bgb.bircd.org/) + `libmobile-bgb` + `libmobile` for the
  primary manual test environment (see [`docs/testing.md`](docs/testing.md)).

## Building

```sh
make GBDK_HOME=/path/to/gbdk-2020/gbdk   # GBDK_HOME defaults to /opt/gbdk
make clean                                # remove build/
make test                                 # host-side protocol unit tests (native cc, no GBDK needed)
```

Output: `build/mobile_adapter_testsuite_gbdk.gbc`, also copied to the
shared `../emulador/` if that directory exists (override via `EMU_DIR`
in the Makefile). Validate the CGB-only header after a build:

```sh
xxd -s 0x143 -l 1 build/mobile_adapter_testsuite_gbdk.gbc   # expect: c0
```

`make test`'s `test_config` binary partly validates against a real
captured Mobile Adapter GB configuration file, expected at
`../config.bin` (repo root, shared -- not part of this repository, see
the root [`README.md`](../README.md)) -- skipped with a clear message,
not a failure, if that file is missing.

Compile-time defaults (ISP dial string/login, DNS, HTTP host/port/path,
default P2P phone/IP) live in `include/test_config.h`, overridable via
`CFLAGS_EXTRA` on the `make` command line -- see the comments in that
file and [`docs/protocol-notes.md`](docs/protocol-notes.md) for where
each default came from.

## Testing

See [`docs/testing.md`](docs/testing.md) for the full walkthrough
(BGB + libmobile setup, what each manual test needs, the two-instance
P2P setup). Quick start: start BGB, load the built ROM, right-click →
**Link** → **Listen**, start `libmobile-bgb`, then run **Adapter /
Session** from the ROM's menu first -- it's the basic handshake test.
SELECT from the main menu opens a live protocol trace to compare
against libmobile's own log. Full protocol rationale for every test
(why GB00 needs MD5+base64, the P2P direct-IP framing, error codes,
...) is in [`docs/protocol-notes.md`](docs/protocol-notes.md).

## Architecture

Three strict layers (see the repo root [`CLAUDE.md`](../CLAUDE.md) for
the full rationale):

```text
src/hw/serial_hw.c          Layer 1: SB/SC only, no protocol knowledge
src/protocol/magb_packet.c  Layer 2: checksum, framing, streaming parser (hardware-free, host-testable)
src/protocol/magb_session.c Layer 2: the ACK/idle-byte handshake, Begin/End Session, trace ring buffer
src/protocol/magb_network.c Layer 2: command wrappers (phone/dial/ISP/DNS/TCP/transfer/config)
src/app/test_runner.c       Layer 3: test sequencing, MATS P2P payload framing
src/app/ui.c                Layer 3: menu, joypad, result/trace/config screens
src/main.c                  entry point
```

Want to use this protocol code in your own homebrew, not just run this
diagnostic ROM? [`docs/integration-guide.md`](docs/integration-guide.md)
covers exactly what to copy (the hardware/protocol layers, not the app
layer) and gives worked recipes for a session, an ISP/HTTP fetch, and a
P2P link.

## License

See [`../LICENSE`](../LICENSE). This repository contains original
homebrew code only -- no Nintendo SDK, Pokémon, or other copyrighted
ROM data.
