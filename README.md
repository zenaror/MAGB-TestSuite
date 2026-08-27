# Mobile Adapter GB TestSuite

A standalone **Game Boy Color-only** homebrew ROM, written in C with
[GBDK-2020](https://github.com/gbdk-2020/gbdk-2020), that speaks the
real Nintendo **Mobile Adapter GB** (CGB-005 / Mobile System GB)
protocol over the GBC serial port (`SB`/`SC`). It exists to validate:

- physical or emulated Mobile Adapter GB hardware;
- [`libmobile`](https://github.com/REONTeam/libmobile);
- [`libmobile-bgb`](https://github.com/REONTeam/libmobile-bgb) (the
  BGB-to-libmobile bridge);
- [REON](https://github.com/REONTeam/reon)-compatible network services;
- any Game Boy/Game Boy Color emulator's serial-link implementation;
- future from-scratch hardware implementations of the protocol.

It contains no Pokémon (or any other) ROM code, game data, or
copyrighted assets. It is a clean-room diagnostic client built from
publicly documented protocol behavior and the reverse-engineered/open
implementations listed in `docs/protocol-notes.md`.

## Why GBC-only

This ROM intentionally targets **only** the SM83 CPU / GBC 8-bit serial
transport. It does not implement, and will never implement, any GBA
NORMAL8/NORMAL32/SIO32 transport, `REG_SIOCNT`, libgba APIs, or ARM
code. The Mobile Adapter's SIO32 command (`0x18`) is declared as a
protocol constant for completeness but is never sent. See
`docs/protocol-notes.md`, "GBC vs GBA differences," for why.

## Prerequisites

- [GBDK-2020](https://github.com/gbdk-2020/gbdk-2020) (developed and
  tested against the 4.5.0 release, SDCC 4.5.1).
- A native C compiler (`cc`/`gcc`) for the host-side unit tests —
  optional, but strongly recommended before touching protocol code.
- [BGB](https://bgb.bircd.org/) + `libmobile-bgb` + `libmobile` for the
  primary manual test environment (see `docs/testing.md`).

## Building

```sh
make GBDK_HOME=/path/to/gbdk-2020/gbdk
```

`GBDK_HOME` defaults to `/opt/gbdk`; override it however your GBDK-2020
is installed. Output: `build/mobile_adapter_testsuite.gbc`.

Every build also copies the ROM into `emulador/` at the project root
(a local emulator's working directory, e.g. a BGB install) if that
directory exists -- override the location via `EMU_DIR` in the
Makefile. Does nothing (with a message) if that directory is missing.

```sh
make clean      # remove build/
make test       # host-side protocol unit tests (native cc, no GBDK needed)
```

`make test`'s `test_config` binary partly validates against a real
captured Mobile Adapter GB configuration file, `config.bin`, expected
at the repo root. **This file is not part of the repository** (it's
real account data, and is `.gitignore`d) — provision your own by
capturing one from a real session (e.g. libmobile-bgb writes one out
after a successful Read Config / registration) and place it at
`config.bin`. Without it, those specific checks fail with a clear
message telling you to add the file; the rest of `make test` still
runs normally.

The build marks the ROM cartridge-header byte at `0x143` as `0xC0`
(CGB-only, via `-Wm-yC`) — verify with:

```sh
xxd -s 0x143 -l 1 build/mobile_adapter_testsuite.gbc   # expect: c0
```

## Compile-time configuration

`include/test_config.h` — ISP dial string/login/password, DNS
defaults, the HTTP host/port/path, and the default P2P phone/IP
number. Every default there is real, sourced data (not invented) —
see the comments in that file and `docs/protocol-notes.md` for exactly
where each one came from. Override on the command line, e.g.:

```sh
make GBDK_HOME=... CFLAGS_EXTRA='-DTEST_HTTP_HOST=\"myserver.example\"'
```

or edit the header directly for a local build. The P2P phone/IP number
can also be edited at runtime from the ROM's P2P Caller menu, so a
recompile isn't needed just to point it at a different address.

## Testing with BGB + libmobile

1. Start BGB, load `build/mobile_adapter_testsuite.gbc`.
2. Right-click the BGB window → **Link** → **Listen**.
3. Build and start `libmobile-bgb`'s `mobile` binary (see its own
   README).
4. In the ROM, run **Adapter / Session** first — this is the basic
   handshake test (wake, Begin Session, checksum/ACK validation,
   adapter ID capture, End Session).
5. Press SELECT from the main menu to inspect the raw protocol trace
   and compare it against libmobile's own debug log.

Full walkthrough, including the ISP/HTTP and two-instance P2P tests,
is in `docs/testing.md`.

## Test groups

1. **Adapter / Session** — wake-up, Begin Session (`0x10`,
   `"NINTENDO"`), full packet/checksum/ACK validation, adapter device
   ID capture, End Session.
2. **Read Config** — reads the documented 192-byte Mobile Adapter GB
   configuration blob (`0x19`, two 96-byte halves) and displays it
   across three pages: registration state/DNS/login ID/checksum
   validity; email/SMTP/POP; and Configuration Slot 1's decoded ISP
   dial-string (phone number + ID string) — similar to
   `gba-link-connection`'s `LinkMobile::readConfiguration()`.
3. **ISP Password** — no password field exists anywhere in the
   documented configuration layout (it's only ever kept in a game's
   own save data), so this can't be read from the adapter like the
   login ID/dial string/email/SMTP/POP below. This screen edits a
   session-wide RAM buffer, up to 8 characters (`TEST_ISP_PASSWORD_MAX_LEN`),
   starting **empty** — reset on power-off (this ROM has no cartridge
   save). Deliberately has no compile-time default: the tests that
   actually authenticate against a real account (News Config/Article,
   Email Recv) refuse to run with an explicit "SET ISP PASSWORD"
   failure while this is empty, rather than guessing a value.
4. **ISP / HTTP** — a submenu of seven sub-tests, all sharing the same
   Begin Session → Read Config → Telephone Status → Dial ISP → ISP
   Login → DNS Query → TCP Open → ... → TCP Close → ISP Logout → Hang
   Up → End Session shape. The dial string and login ID used are read
   live from the adapter's own configuration (Configuration Slot 1,
   BCD-decoded, and the login ID field), not compile-time constants —
   falling back to `TEST_ISP_PHONE`/`TEST_ISP_LOGIN` only for an
   unregistered (blank) config:
   - **Tamago Egg** — Pokémon Crystal's real "Mystery Egg" datacenter
     check (real REON test-dataset file, no auth needed).
   - **News Config** — fetches only `get_news_parameters_bin()`
     (`config.php`): a small binary descriptor (news size, the SRAM
     address to store it at, the ranking-submission SRAM layout), not
     the news content itself.
   - **News Article** — mirrors what a real game actually does:
     fetches News Config's `config.php` *and then* the real news
     content (`get_news_file()`, `100.news.php`) in the same ISP
     session, each with its own GB00 exchange. *Both* endpoints require
     REON's GB00 challenge/response HTTP auth (confirmed by reading
     REON's `news.php` source — the numeric-cost-prefix exemption that
     skips auth for Tamago's `index.txt` does not apply here; these
     were originally labeled "News Config"/"News (Auth)", which wrongly
     implied only one needed authentication). This TestSuite implements
     that handshake in full (MD5 + base64 + a custom bit-scramble — see
     `docs/protocol-notes.md`, "GB00 HTTP authentication"), using the
     live-config login ID and the ISP PASSWORD screen's password as the
     account credentials.
   - **Trainer Home** — Mobile Trainer's real home page
     (`TEST_HTTP_TRAINER_HOME_HOST`/`_PORT`/`_PATH`, Dan Docs' "Mobile
     Trainer" section), no auth needed. Repoint the constants at your
     own server if you want a genuinely custom target instead.
   - **Email Send** / **Email Recv** — a minimal SMTP send and POP3
     receive, using the email address and SMTP/POP server hostnames
     read live from the adapter's own configuration, confirmed against
     REON's real mail server source.
   - **Raw TCP (NC)** — the real, unscripted "ISP call (PPP)" test:
     dial, log in, open a TCP socket to an editable IP:port (no
     hostname/DNS — a 12-digit dotted-quad, same convention as the P2P
     phone/IP field), and just show whatever bytes come back, live, on
     screen, until the remote closes or B is pressed. No fixed request,
     no auth, no pass/fail — point it at a machine running
     `nc -l <port>` (port is compile-time, `TEST_ISP_RAW_PORT`) and
     whatever gets typed there streams to the Game Boy screen character
     by character. This is the one ISP test that doesn't validate a
     specific response, matching `gba-link-connection`'s own
     description of this Mobile Adapter mode: "the adapter can open up
     to 2 TCP/UDP sockets and transfer arbitrary data."
5. **P2P Caller** / **P2P Listener** — two roles of the same test,
   meant to be run as two ROM instances talking to each other (directly
   or via a REON relay). Exchanges a small deterministic binary
   framing (`"MATS"` + version + sequence + length + payload) over MAGB
   Transfer Data (`0x15`): a `PING`/`PONG` handshake, an 8-byte binary
   pattern (`0x00`/`0xFF` edge cases included), and finally a literal
   `"HELLO WORLD"` round-trip so the result screen shows an actual
   human-readable confirmation, not just byte counts.

Failures also show the official Nintendo Mobile Adapter GB error code
(e.g. `CODE: 24-000`) where one clearly applies — see
`docs/protocol-notes.md`, "Official Mobile Adapter GB error codes".

Every test reports `PASS`/`FAIL` plus a short diagnostic (expected vs.
actual command byte, the specific `magb_result_t` error, or
test-specific detail like an HTTP status code or received byte count)
— see `include/test_runner.h`. Every long-running step is cancellable
with B and bounded by a real timeout; nothing in this ROM can hang
forever waiting on external hardware.

A short chime plays on pass, a low buzz on fail, and a blip on every
menu move/selection (`src/app/sound.c` — raw GBC APU channel-1 square
wave, no tracker dependency).

## Architecture

Three strict layers (see `CLAUDE.md` for the full rationale):

```text
src/hw/serial_hw.c          Layer 1: SB/SC only, no protocol knowledge
src/protocol/magb_packet.c  Layer 2: checksum, framing, streaming parser (hardware-free, host-testable)
src/protocol/magb_session.c Layer 2: the ACK/idle-byte handshake, Begin/End Session, trace ring buffer
src/protocol/magb_network.c Layer 2: command wrappers (phone/dial/ISP/DNS/TCP/transfer/config)
src/app/test_runner.c       Layer 3: test sequencing, MATS P2P payload framing
src/app/ui.c                Layer 3: menu, joypad, result/trace/config screens
src/main.c                  entry point
```

Want to use the Mobile Adapter GB protocol code in your own homebrew,
not just run this diagnostic ROM? `docs/integration-guide.md` covers
exactly what to copy (the hardware/protocol layers, not the app layer)
and gives worked recipes for a session, an ISP/HTTP fetch, and a P2P
link.

## Known limitations

- The "sacrificial wake transfer" and ~100 ms post-wake delay
  (Section 8) are implemented per the public Mobile Adapter GB
  documentation, but are not exercised by libmobile itself (libmobile
  responds validly from its very first byte) — see
  `docs/protocol-notes.md` for why this code is intentionally kept
  anyway.
- The P2P Listener's "Wait For Call" screen does not animate while
  blocked (no live spinner) — it is still fully cancellable with B via
  `magb_context_t::cancel_check`, polled every protocol-level wait
  iteration.
- `ui_show_config()` decodes the documented header/DNS/login/email
  fields of the 192-byte configuration blob but does not attempt to
  parse the three 24-byte ISP dial-string "configuration slot"
  sub-structures, whose internal byte layout is not independently
  confirmed by any source consulted for this project.
- The ISP/HTTP test's actual reachability of `gameboy.datacenter.ne.jp`
  depends entirely on how the `libmobile`/`libmobile-bgb` instance
  under test is configured (relay, DNS, network access) — this ROM
  performs no shortcut and reports exactly which stage of the chain
  failed if it doesn't reach a real HTTP response.

## License

See `LICENSE`. This repository contains original homebrew code only —
no Nintendo SDK, Pokémon, or other copyrighted ROM data.
