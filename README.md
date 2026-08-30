![Logo](logo.png)

---

A **Game Boy Color homebrew diagnostic ROM** that speaks the real
Nintendo **Mobile Adapter GB** (CGB-005 / Mobile System GB) protocol
over the GBC serial port. It exists to validate implementations of
that protocol, not to play a game:

- physical or emulated Mobile Adapter GB hardware;
- [`libmobile`](https://github.com/REONTeam/libmobile);
- [`libmobile-bgb`](https://github.com/REONTeam/libmobile-bgb) (the
  BGB-to-libmobile bridge);
- [REON](https://github.com/REONTeam/reon)-compatible network services;
- any Game Boy/Game Boy Color emulator's serial-link implementation;
- future from-scratch hardware implementations of the protocol.

It contains no Pokémon (or any other) ROM code, game data, or
copyrighted assets — a clean-room diagnostic client built from publicly
documented protocol behavior and reverse-engineered/open references
(see [`CLAUDE.md`](CLAUDE.md)).

## What it tests

Both implementations below expose the same set of checks, from a
simple text menu on the Game Boy screen:

1. **Adapter / Session** — wake-up, Begin Session, packet/checksum/ACK
   validation, adapter device ID capture, End Session.
2. **Read Config** — reads and decodes the adapter's real 192-byte
   configuration blob (registration state, DNS, login ID, email/SMTP/
   POP, ISP dial string).
3. **ISP / HTTP** — a real ISP dial-up session (Dial → ISP Login → DNS
   → TCP → data transfer → teardown) driving seven targets: an HTTP
   fetch against REON's real "Mystery Egg" test data, GB00-authenticated
   news config/article fetches, Mobile Trainer's home page, SMTP send,
   POP3 receive, and an interactive raw-TCP ("netcat") viewer.
4. **P2P Caller / Listener (only GBDK, for now)** — two roles of the same test,
   run as two ROM instances dialing each other directly and exchanging a
   deterministic binary payload.

Every test reports `PASS`/`FAIL` plus a specific diagnostic (which
command, which stage, which error code) — never a fake success. See
each implementation's own README for the exact test list and current
status.

## Known limitations

These apply to both implementations, since they're protocol/environment
facts rather than a bug in either one:

- The configuration reader decodes the documented header/DNS/login/
  email fields of the 192-byte configuration blob, but not the three
  24-byte ISP dial-string "configuration slot" sub-structures beyond
  slot 1 — their internal byte layout isn't independently confirmed by
  any source consulted for this project. See
  [`gbdk/docs/protocol-notes.md`](gbdk/docs/protocol-notes.md),
  "Configuration Slot decoding."
- The ISP/HTTP tests' actual reachability of
  `gameboy.datacenter.ne.jp` depends entirely on how the `libmobile`
  instance under test is configured (relay, DNS, network access) — the
  TestSuite reports exactly which stage of the chain failed rather than
  shortcutting.

Implementation-specific gaps (e.g. what's not yet confirmed on real
hardware for `rgbds/`) are listed in that implementation's own README.

## Why GBC-only

Both implementations target **only** the SM83 CPU / GBC 8-bit serial
transport (`SIOF_SPEED_32X`, i.e. `SC = 0x83`, not `0x81`). Neither
implements, or will ever implement, any GBA NORMAL8/NORMAL32/SIO32
transport, `REG_SIOCNT`, libgba APIs, or ARM code — the Mobile
Adapter's SIO32 command (`0x18`) is declared as a protocol constant for
completeness but is never sent. See
[`gbdk/docs/protocol-notes.md`](gbdk/docs/protocol-notes.md), "GBC vs
GBA differences," for why.

## Implementations

This repository holds more than one implementation of the same
TestSuite, each self-contained in its own top-level directory:

| Directory | Language / toolchain | Status |
| --- | --- | --- |
| [`gbdk/`](gbdk/) | C, GBDK-2020/SDCC | **Current, working implementation.** Full test coverage, confirmed on real hardware. |
| [`rgbds/`](rgbds/) | Hand-written SM83 assembly, RGBDS | In progress — feature set now close to `gbdk/`'s; see [`rgbds/docs/status.md`](rgbds/docs/status.md) for exactly what's confirmed. |

Each implementation is independently self-contained: its own build,
its own tests, its own docs. [`CLAUDE.md`](CLAUDE.md) at the repo root
covers both — the project brief and protocol references apply to
either, and it states explicitly which parts are GBDK-specific.

## Repository layout

```text
.
├── CLAUDE.md          project brief and protocol references (both implementations)
├── LICENSE
├── config.bin         real captured Mobile Adapter config, provisioned locally (see gbdk/docs/testing.md)
├── emulador/           shared local emulator working dir, e.g. a BGB install
├── gbdk/               C / GBDK-2020 implementation — see gbdk/README.md
└── rgbds/              SM83 assembly / RGBDS implementation — see rgbds/README.md
```

`emulador/` and `config.bin` are shared across implementations rather
than duplicated per directory — see
[`gbdk/docs/testing.md`](gbdk/docs/testing.md) for how each is used
and provisioned. Neither is part of this repository.

## License

See [`LICENSE`](LICENSE). This repository contains original homebrew
code only — no Nintendo SDK, Pokémon, or other copyrighted ROM data.
