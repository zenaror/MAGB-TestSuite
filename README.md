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
   fetch against REON's real "Mystery Egg" test data; **Small Buffer**
   and **Big Buffer**, a GB00-authenticated pair carrying synthetic
   data of 128 bytes and 8 KiB — one arriving in a single Transfer
   Data, the other streamed and checksummed chunk by chunk, then
   uploaded back; Mobile Trainer's home page; SMTP send; POP3 receive
   (which deletes only the messages it sent itself); and an interactive
   raw-TCP ("netcat") viewer.
4. **P2P Caller / Listener** — two roles of the same test, run as two
   ROM instances dialing each other directly and exchanging a
   deterministic binary payload.

5. **Server conformance** — a separate section, deliberately not mixed
   in with the tests above. Those pass when the adapter, `libmobile` and
   the link behave; these pass when the *server* is correctly
   configured, and can fail while the adapter is perfect. One test so
   far: **Auth Prefix** sends a GB00 credential whose first 44
   characters are correct and whose remainder is not, and requires the
   server to refuse it — those 44 characters are only an echo of the
   challenge the server itself published, so a server that accepts them
   authenticates anyone who can read a `401`. That was a real defect,
   found through this suite; see
   [`gbdk/docs/protocol-notes.md`](gbdk/docs/protocol-notes.md).

The ISP account password is entered on-device and kept in
battery-backed cartridge SRAM, so it survives a power cycle. It is
never compiled in: a test that needs authentication refuses to run
while it is unset rather than sending a guess.

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

- P2P Caller/Listener works end-to-end on `gbdk/` against real
  hardware (PicoAdapterGB), which is also how a real disconnect-detection
  bug in `libmobile` was found and fixed — see
  [`gbdk/docs/journal.md`](gbdk/docs/journal.md). The `rgbds/` port of
  the same test is implemented but has not had its own two-instance run
  yet; that needs two linked setups at once, which is the only reason
  it is still open.

Implementation-specific gaps are listed in that implementation's own
README.

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
| [`gbdk/`](gbdk/) | C, GBDK-2020/SDCC | Full test coverage, every test confirmed against a real server. |
| [`rgbds/`](rgbds/) | Hand-written SM83 assembly, RGBDS | Same feature set, same tests, same results — see [`rgbds/docs/status.md`](rgbds/docs/status.md) for the per-routine detail. |

Neither is a subset of the other. They are kept behaviourally
identical on purpose: two independent implementations disagreeing about
the wire format is the cheapest way to find out that one of them is
wrong.

Want to use the protocol code in your own homebrew rather than run the
diagnostic ROM? Each side has an integration guide —
[`gbdk/docs/integration-guide.md`](gbdk/docs/integration-guide.md)
(start here even for assembly; the protocol reasoning lives there) and
[`rgbds/docs/integration-guide.md`](rgbds/docs/integration-guide.md).

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
├── server/             REON fixtures the buffer tests need — see server/README.md
├── gbdk/               C / GBDK-2020 implementation — see gbdk/README.md
└── rgbds/              SM83 assembly / RGBDS implementation — see rgbds/README.md
```

`emulador/` and `config.bin` are shared across implementations rather
than duplicated per directory — see
[`gbdk/docs/testing.md`](gbdk/docs/testing.md) for how each is used
and provisioned. Neither is part of this repository.

`server/` is: it holds the synthetic REON endpoints the SMALL BUFFER and
BIG BUFFER tests talk to. They are not needed to build either ROM, only
to pass those two tests, and they are checked in so the tests are
reproducible on any REON host rather than on one particular person's —
see [`server/README.md`](server/README.md).

## License

See [`LICENSE`](LICENSE). This repository contains original homebrew
code only — no Nintendo SDK, Pokémon, or other copyrighted ROM data.
