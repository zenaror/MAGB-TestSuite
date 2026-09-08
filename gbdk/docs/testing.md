# Testing this TestSuite

There are two independent kinds of tests here: fast, deterministic
host-side unit tests for the hardware-independent packet layer, and
manual, real-hardware/real-emulator tests for everything that actually
needs a Mobile Adapter GB (or its emulation) to talk to.

## Host-side unit tests (automated)

```sh
make test
```

This builds `tests/host/test_packet.c` + `src/protocol/magb_packet.c`
with the host's native `cc` (no GBDK involved — this is why
`magb_packet.c` never includes any `gb/*.h` header) and runs it. It
covers:

- the exact Section 12 Begin Session vector (`99 66 10 00 00 08
  <"NINTENDO"> 02 77`, checksum `0x0277`);
- a zero-payload vector (End Session, checksum `0x0011`);
- oversized-payload rejection (`MAGB_ERR_PAYLOAD_TOO_LARGE`, and that
  it never touches the output buffer);
- `response_command()` (including that `0x95` is just `0x15|0x80`, not
  a magic success byte);
- the streaming parser: accepting a valid frame, rejecting a corrupted
  checksum, rejecting a corrupted second magic byte, and resynchronizing
  past a stray leading byte.

All of these must pass before touching anything downstream of the
packet layer. They're fast enough to run after every protocol change.

`make test` also builds and runs `tests/host/test_fmt.c` +
`src/protocol/magb_fmt.c` (the explicit decimal/hex formatters used to
build wire strings), which covers the zero-padding cases a `"%x"` gets
wrong -- a checksum of `0x0F00` must go out as `"0F00"`, and that only
shows up for one value in sixteen.

`make test` also builds and runs `tests/host/test_config.c` +
`src/protocol/magb_config.c` (the configuration-blob parser --
checksum validation, Configuration Slot BCD phone decode). Most of its
assertions are synthetic vectors, but the strongest ones cross-check
against a **real captured Mobile Adapter GB configuration file**,
`config.bin`, expected one level up from this `gbdk/` directory (the
actual repo root -- shared with any other implementation directory,
not copied per implementation).

**`config.bin` is not part of this repository.** It's real account
data (login ID, email, ISP dial string), so it's `.gitignore`d and
must be provisioned locally: capture one from a real session (e.g.
libmobile-bgb writes its own configuration file after a successful
Read Config / Mobile Trainer registration) and place it at the repo
root (one level up from `gbdk/`) as `config.bin`. Without it,
`test_config`'s real-capture checks are skipped with an explicit
message rather than failing; the synthetic checks (and all of
`test_packet`) still run and pass regardless.

## Manual tests against BGB + libmobile-bgb + libmobile

Everything below also applies to a real Game Boy Color with real
adapter hardware (a PicoAdapterGB, which is what most of this
project's later runtime verification actually used) — from the ROM's
side nothing differs, since it speaks ordinary MAGB traffic and takes
no emulator-specific shortcut. BGB is the easier environment to start
in, because it gives you a serial log to compare against the ROM's own
trace viewer.

1. Build the ROM (`make GBDK_HOME=/path/to/gbdk-2020/gbdk`, see the
   README for details) — `build/mobile_adapter_testsuite_gbdk.gbc`.
2. Start BGB, load the ROM.
3. In BGB: right-click → **Link** → **Listen**.
4. Start `libmobile-bgb`'s `mobile` binary (see its own README for
   build/run instructions; it needs a `config.json`/relay settings if
   you want the ISP/DNS/TCP path to reach REON or the public internet
   rather than failing DNS).
5. In the ROM: **Adapter / Session** first. Expect `PASS`, an adapter
   ID of `08` (libmobile's default, Blue/PDC) unless you reconfigured
   libmobile's `device`, and `NINTENDO ECHO OK`.
6. Press SELECT from the main menu to open the protocol trace and
   compare the raw `TX xx RX yy` byte sequence against libmobile's own
   debug log (`mobile_debug_print`/`mobile_debug_command`, if you built
   libmobile-bgb with debug logging enabled) — they should describe the
   exact same exchange documented in `docs/protocol-notes.md`.
7. **ISP / HTTP** next. This actually dials `#9677`, logs in with
   `test`/`test`, resolves `gameboy.datacenter.ne.jp` via DNS, opens a
   TCP connection to port 80, and issues a real HTTP/1.0 GET for
   Pokémon Crystal's real "Mystery Egg" metadata file. Whether this
   reaches the real REON server or just a local mock depends entirely
   on how `libmobile` is configured (relay/ISP settings) — this ROM
   performs no emulator-specific shortcut, it just
   speaks normal MAGB traffic and trusts whatever is on the other end
   of the adapter emulation. A `TRANSPORT PASS` with a non-200 HTTP
   status still proves the full Mobile Adapter → ISP → DNS → TCP →
   HTTP path works; only a `NO HTTP/ PREFIX` or an earlier-stage
   failure (`DIAL ISP FAILED`, `DNS QUERY FAILED`, ...) indicates an
   actual break in the chain, and the detail line says which stage.

### The tests that authenticate

**Tamago Egg**, **Trainer Home** and **Raw TCP** need no credentials.
Everything else does:

| test | needs |
| --- | --- |
| Small Buffer | ISP password + the `server/` fixture, REON `doAuth(2)` |
| Big Buffer | ISP password + the `server/` fixture, REON `doAuth(1)` + type-0 upload |
| Email Send / Email Recv | ISP password, a real SMTP/POP3 account |

Set it from the main menu's **ISP PASSWORD** entry before running any
of them. It starts **empty on a fresh cartridge and stays empty until
you type it** — there is no compiled-in default, and a test that needs
one fails with `SET ISP PASSWORD` rather than sending a guess. (An
earlier build did default it to `"test"`, and that masked a real
server-side 401 behind a misleading symptom for a full day.)

Once entered it is written to battery-backed cartridge SRAM and
restored at the next boot, so this is a once-per-cartridge step, not a
once-per-session one. **That means the `.sav` next to your ROM contains
a real account password in plain text** — the repo's `.gitignore`
excludes the whole `emulador/` directory for this reason. Don't commit
it and don't attach it to a bug report.

The two buffer tests also need REON to be serving the synthetic
MAGBTEST endpoints. They are checked in under [`server/`](../../server/)
precisely so the tests are reproducible on any REON host rather than on
one particular person's — see [`server/README.md`](../../server/README.md)
for installation, including the one change `download.php` needs.

**Email Send delivers inside REON, not to the outside world.** It sends
to the address in the adapter's own configuration. Mail actually
*leaving* REON for an external mailbox goes through a device-authorization
gate that is broken upstream in libmobile as of 2026-09-08 — see
`docs/protocol-notes.md`, "Outbound mail is gated by device-auth". If
you point this test at an external address and get a 554, that is not
this ROM.

**Email Recv deletes only its own messages.** It reads headers with
`TOP n 0` and issues `DELE` only for subjects matching its own, unlike
the real Mobile Trainer, which `RETR`s what it downloads and deletes
all of it. This runs against a real mailbox; a test that removed
everything it found would delete real mail. `DELE` only marks — the
`QUIT` commits — so a failure partway through leaves the mailbox alone.

### Server conformance (SERVER CONF)

Its own main-menu entry, on purpose. Every test above passes when the
adapter, libmobile and the link behave; this one passes when the
**server** is correctly configured, and can fail while the adapter is
perfect. Keeping it out of the ISP/HTTP list is what stops a red result
from being ambiguous about which side is broken.

One test today, **AUTH PREFIX**. It builds a valid GB00 `Authorization`,
keeps the 44-character prefix (which is only an echo of the challenge
the server itself published), replaces the rest, and requires a refusal:

| what you see | what it means |
| --- | --- |
| `PASS`, `GB-ST 201` | the server validated the whole credential and rejected it |
| `FAIL BYPASS OPEN` + `HTTP 200` | this server accepts a prefix-only credential — the bypass is open |
| `FAIL CHALLENGE EXPIRED` | inconclusive, not a pass: the challenge was gone, so nothing judged the credential. Just run it again |
| `FAIL NO CHALLENGE` | the endpoint served without asking for auth — a fixture problem, not a security finding |

Needs the ISP password set, like the other authenticating tests: a
*valid* Authorization has to exist before it can be damaged, or the
request would be refused for a reason unrelated to the prefix.

**A PASS on its own is half the claim — check the server log too.** It
says the server rejected a credential whose *tail* was wrong. That the
*prefix* was right is guaranteed by construction, not by anything this
ROM can observe: a wrong offset would be rejected identically, and the
test would still say PASS while never exercising the case the fix is
about. REON logs a per-request boolean for exactly this (does the
44-character prefix correspond to a challenge it issued); the run counts
when that says it matched. Running SMALL BUFFER in the same session
covers the same ground from this side, since it sends the undamaged
value from the same builder and needs a 200. See
`docs/protocol-notes.md`, "The way this test could pass while proving
nothing".

**Not yet runtime-verified on either ROM.** It compiles clean and
mirrors the reproduction the REON maintainer ran by hand, but neither
build has executed it against the live server yet.

### Read Configuration

Run **Read Config** from the main menu. Against a freshly-initialized
`libmobile-bgb` config file, expect mostly zeroed/blank fields (no
login ID, `0.0.0.0` DNS, `(NONE)` registration state) — that is a
correct result, not a bug: it reflects whatever
`mobile_cb_config_read()` actually returns on the libmobile side, which
this TestSuite does not fabricate. It still proves the `0x19` command,
its 2-byte request / N+1-byte response framing, and the two-chunk
96+96 byte read both work end-to-end.

## Manual tests: P2P (two ROM instances)

Test 3 needs two running copies of this same ROM — either two BGB
instances each with their own `libmobile-bgb`, or an equivalent
physical/emulated setup.

```
Instance A: main menu -> P2P Listener
Instance B: main menu -> P2P Caller
```

On the Caller side, pressing A on "P2P Caller" first opens a 12-digit
number/IP editor (default `127000000001`) — confirm or edit it, then A
again to dial. `127000000001` decodes (inside libmobile core, not this
ROM — see `docs/protocol-notes.md`) as `127.0.0.1`, i.e. "the same
machine, if both `libmobile-bgb` instances are reachable on it."

This exercises libmobile's **direct-IP P2P** path specifically
(libmobile's `commands.c`: the 12-digit dial payload is parsed
locally as a raw IPv4 address, then the adapter opens a normal outbound
TCP connection straight to `<that IP>:p2p_port`, default port 1027 --
`MOBILE_DEFAULT_P2P_PORT` in `mobile.h` -- while the Listener side's
"Wait For Call" opens a TCP *listening* socket on that same port). Both
machines need that port mutually reachable (same LAN, no firewall
blocking it) for this to work across two physical machines.

A **relay-based** P2P call (a real REON-style rendezvous relay server)
is a *different, adapter-level* mechanism, not a variant of this same
test reachable by dialing a different number: it only activates when
the `mobile` process itself is started with `--relay <server-addr>`
(see libmobile-bgb's `source/main.c`), and once active, the
dialed number is sent to *that relay server's own* call-matching
protocol (`mobile_relay_proc_call()` in libmobile's
`commands.c`) instead of ever being parsed as an IP -- an entirely
different TCP connection (to the relay server, not to the peer) and
handshake. This ROM's P2P test does not exercise that path, and there
is no dialed-number value that would select it; it is exclusively
controlled by how the `mobile` process was launched.

Bring up the Listener first (it blocks on Wait For Call, cancellable
with B), then trigger the Caller. On success both sides show `PASS`,
`TX 12 RX 12` (4-byte `"PING"`/`"PONG"` handshake + the 8-byte `00 01
55 AA FE FF 10 EF` pattern, echoed back exactly), and `DATA OK`.
Distinguishable failure states: `NO CALL` (dial failed), `CANCELLED`
(listener aborted with B), `TRANSFER TIMEOUT`, `BAD TEST FRAME` (MATS
magic/version mismatch), `BAD PAYLOAD` (payload bytes didn't match),
`P2P ERROR` (remote disconnected mid-exchange).

## What is *not* covered by this ROM alone

Runtime verification against a real physical Mobile Adapter GB, a real
REON deployment's actual ISP/DNS/HTTP backend, or another emulator's
serial implementation is outside what a single compile-and-run of this
ROM can prove by itself — those require the project owner (or whoever
is running the test) to actually set up that environment and observe
the result, per this repository's `CLAUDE.md` "Responsibility
Boundary". This ROM's job is to emit and validate real, correct MAGB
protocol traffic and report exactly where in the chain a failure
occurred; it does not simulate any of the other side.
