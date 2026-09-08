# Mobile Adapter GB — protocol notes

This document records the wire-protocol decisions made in this
TestSuite and, for every non-obvious one, *where it came from*. It
exists so a future change can tell the difference between "this byte
is like this because three independent implementations agree" and
"this byte is a guess" (there should be none of the latter in this
codebase — see Section 53 of the project brief).

Primary references:

- Dan Docs, Mobile Adapter GB — <https://shonumi.github.io/dandocs.html#magb>
- pokecrystal-mobile-eng — <https://github.com/gb-mobile/pokecrystal-mobile-eng>
- libma — <https://github.com/mid-kid/libma>
- libmobile — <https://github.com/REONTeam/libmobile> (the actual test target)
- libmobile-bgb — <https://github.com/REONTeam/libmobile-bgb>
- REON — <https://github.com/REONTeam/reon>
- gba-link-connection — <https://github.com/afska/gba-link-connection>, `lib/LinkMobile.hpp`
- <https://gbdk.org/docs/api/> and the headers actually bundled with the installed GBDK-2020 4.5.0 release

Every hex value below was read out of one of these source trees, not
transcribed from a summary. File:line citations below refer to the
state of those projects at the time of this writing (no fixed commit
hash is pinned — re-check against the upstream project if a citation
looks stale).

## Serial clock: why 0x83, not 0x81

`SIOF_XFER_START | SIOF_CLOCK_INT | SIOF_SPEED_32X` = `0x80 | 0x01 | 0x02`
= `0x83` (GBDK-2020's own `include/gb/hardware.h` gives these exact bit
values). `0x81` is `SIOF_XFER_START | SIOF_CLOCK_INT` *without* the CGB
32x-speed bit — that configures the DMG-speed internal clock, not the
faster clock the Mobile Adapter GB expects on a Color unit. This
TestSuite always transmits `0x83` (see `serial_transfer_byte()` in
`src/hw/serial_hw.c`) and never falls back to `0x81`.

## CGB double speed

`serial_hw_init()` checks `_cpu == CGB_TYPE` (GBDK's own constant, from
`include/gb/cgb.h`) before doing anything else, and calls `cpu_fast()`
only once that passes. On anything else it changes nothing and returns
`false`; `main()` then shows a fatal message and halts forever
(`ui_fatal_not_cgb()`) rather than
continuing in DMG speed — mixing DMG CPU speed with the `SIOF_SPEED_32X`
serial bit does not correspond to any real Mobile Adapter GB
configuration, and the project brief explicitly requires refusing to
run rather than silently falling back. CGB double-speed mode roughly
doubles the *effective* serial bit rate for a given `SC` configuration,
which is what lets `SIOF_SPEED_32X` reach the ~64 KB/s rate real Mobile
Adapter GB traffic uses on hardware.

## The ACK phase must tolerate 0xD2, not just the response-wait phase

`request_ack_phase()` used to treat `MAGB_ADAPTER_WAIT` (`0xD2`)
arriving in place of ACK1 or ACK2 as an immediate, fatal error
(`MAGB_ERR_BAD_DEVICE_ID` / `MAGB_ERR_BAD_ACK`). This was wrong, and
was caught by comparing byte-level BGB link logs of this ROM against a
known-good ROM (a real, working Mobile Adapter title) talking to the
same BGB + libmobile-bgb setup: both logs show `0xD2` still being
returned on the transfer that would carry ACK1/ACK2, with the real
value only appearing some transfers later. `libmobile`'s own C source
computes ACK1/ACK2 synchronously with no delay (confirmed by feeding
the exact request byte-for-byte into the real library, off-hardware,
where it always answers immediately) -- so this delay is a real,
observed property of the BGB<->libmobile-bgb link path specifically,
not something to "fix" by changing timing, and not something the
protocol logic can assume away.

First fix: `0xD2` at the ACK1/ACK2 checkpoints is treated exactly like
`0xD2` everywhere else in this protocol -- "not ready yet," not an
error.

That alone was not sufficient. The relay delay turned out to be a
**consistent one-transfer-late delivery** of every meaningful byte,
not an occasional `0xD2`. Realigning two BGB link logs (this ROM's
failing one and a known-good ROM's working one, both captured against
the same BGB + libmobile-bgb setup) by shifting the RX column back by
exactly one row made both decode into a textbook-correct handshake.
Practical consequence: the byte landing at the "ACK2" checkpoint can
legitimately be a *delayed ACK1* (device-id-shaped, e.g. `0x88`)
instead of the real ACK2 (command-echo-shaped, e.g. `0x90`) --
requiring `ack2 == command|0x80` was itself a bug. Confirmed fixed by
simulating this exact one-transfer delay in a host-side harness
wrapped around the real libmobile C source and checking
`magb_begin_session()` still completes successfully under it.

The governing fix in `request_ack_phase()`: ACK1 is captured
opportunistically (only when it looks like a valid device id) and
never fails the exchange; ACK2 only fails the exchange on one of the
three explicit, unambiguous transport-error codes (`0xF0`/`0xF1`/
`0xF2`) -- any other value (`0xD2`, a delayed ACK1, or the real ACK2)
lets the handshake proceed. The fixed handshake byte sequence (device
ack `0x80`, filler, mandatory `0x4B`) is always sent regardless. The
real, authoritative signal that the whole exchange succeeded is the
response frame's own checksum, validated afterward in
`read_response_frame()` -- not any single intermediate ACK byte
landing exactly where a synchronous model predicts.

## SC_REG must be written in two steps, not one

`serial_transfer_byte()` writes `SC_REG` **twice**: first
`SIOF_CLOCK_INT | SIOF_SPEED_32X` (start bit clear), then
`SIOF_XFER_START | SIOF_CLOCK_INT | SIOF_SPEED_32X` (start bit set) as
a separate write. A single combined write of `0x83` compiles and looks
equivalent, but was confirmed (via BGB, with libmobile-bgb attached)
to leave the adapter emulation returning nothing but idle (`0xD2`)
bytes forever, never reaching the ACK phase -- even though the exact
same request bytes, fed directly into the real libmobile C source
off-hardware (bypassing SB/SC entirely), parse and ACK correctly. That
isolated the bug to this low-level register-write sequencing, not the
packet content or session logic.

The fix is confirmed against Pokémon Crystal's own real, working
Mobile Adapter driver: every single `rSC` write site in
pokecrystal-mobile-eng's `lib/mobile/main.asm` (both the CGB
high-speed case, `Function111b2e`, and the plain external-clock case
in `home/serial.asm`'s `Serial::` handler) writes the clock-source/
speed bits with the start bit clear first, then writes the start bit
separately -- never combined in one write. This TestSuite now follows
the same two-write convention unconditionally.

## CGB display bring-up: set_default_palette()

Not a wire-protocol detail, but a real bug hit and fixed during
hardware/BGB testing of this ROM, worth recording so it is never
"cleaned up" by accident: on a Game Boy Color, background palette 0
(the CGB equivalent of DMG's `BGP` register) is **not** initialized to
any legible default at power-on the way DMG's is. A CGB-only ROM
(header `0xC0`) does not benefit from the boot ROM's DMG-compatibility
auto-palette trick either (that mechanism is for `0x80`-flagged
backward-compatible carts, keyed off the title checksum, and does not
apply here). Without an explicit palette, this ROM's `cls()`/`printf()`
output was written correctly to VRAM (confirmed via BGB's debugger:
execution was alive and cycling normally through the standard GBDK
VBlank ISR trampoline at `0x0040`-`0x0047`, not crashed) but rendered
using an undefined palette that showed as a blank white screen on both
BGB and a real Everdrive GB X7 — identical symptom on both, since it is
a software bug, not an emulation or flash-cart quirk. Fixed by calling
GBDK's `set_default_palette()` (`gb/cgb.h`) — it sets CGB palette 0 to
the same white/light-gray/dark-gray/black scheme DMG uses by default.

The call lives in `ui_init()`, the app layer's display bring-up. It
was originally inside `serial_hw_init()`, which is how a serial-port
module came to depend on `<gbdk/console.h>` and `<stdio.h>`: a palette
call, then a fatal-error screen to go with it. Both moved out (the
screen is `ui_fatal_not_cgb()` now). Nothing about the fix changed —
only which layer owns it, so `src/hw/serial_hw.c` can be lifted into a
program that draws its own screens, or none. See
`docs/integration-guide.md`.

## Timeout strategy (Section 7)

Two independent bounds, deliberately not one:

1. **Per-byte hardware bound** (`serial_hw.c`, `SERIAL_HW_BYTE_TIMEOUT`,
   a plain decrementing loop counter, not a calibrated timer). A single
   SB/SC transfer completes in microseconds whenever anything is
   actually connected and clocking; this bound only exists to guarantee
   a completely disconnected/absent adapter can never hang the ROM
   inside one transfer. It is deliberately generous and imprecise —
   the exact iteration count that "means" some number of milliseconds
   depends on SDCC codegen and CGB speed mode, and none of that matters
   for a bound whose only job is "finite, not infinite".
2. **Real-time, multi-second bounds** (`magb_session.h`,
   `MAGB_TIMEOUT_FRAMES_SHORT` / `MAGB_TIMEOUT_FRAMES_LONG`), built on
   GBDK's `sys_time` — a real ~59.7 Hz VBlank counter incremented by the
   default VBlank ISR (`include/gb/gb.h`: "Global Time Counter in VBL
   periods (60Hz)"). This bounds how long the Game Boy will keep
   clocking `0x4B` while the adapter is off doing (possibly networked)
   work such as DNS resolution or a TCP handshake, which can legitimately
   take seconds — a fixed byte-level timeout would be the wrong tool for
   that job.

On top of both, `magb_context_t::cancel_check` (a function pointer the
UI layer sets to a joypad-B check) is polled once per RESPONSE_WAITING
iteration, so the user can always abort a long-running command with B
without the protocol layer needing to know anything about joypad
hardware (Section 20's "the application layer should remain
responsive" requirement, implemented without breaking the
hardware/protocol/UI layering).

## Packet format

```
99 66  CMD  00  LENH LENL  <payload, 0..254 bytes>  CKH CKL
```

- Magic `0x99 0x66` — confirmed identically in `libmobile/serial.c:29-30`
  (`if (c == 0x99) ... else if (c == 0x66 && ...)`), `libma`, and Dan
  Docs. **`0x02`/`0x03` (STX/ETX) are not used anywhere in this
  protocol** — those values belong to unrelated Game Boy Printer/Barcode
  Boy link accessories documented elsewhere on Dan Docs, and must never
  be introduced into the MAGB packet encoder.
- Header is exactly 4 bytes: `command`, `reserved` (always `0x00`),
  `length_high` (always `0x00`, this TestSuite never sends a payload
  >254 bytes), `length_low`. Confirmed byte-for-byte in
  `libmobile/mobile.c:59-69` (`packet_create()`): the header array is
  filled as `{command|0x80, 0, 0, length}` when the adapter builds a
  response, and the request-side parser (`serial.c:44-73`,
  `MOBILE_SERIAL_HEADER`) reads the same 4 positions with the same
  meaning, rejecting (dropping back to `WAITING`) if `header[2]`
  (length_high) is ever non-zero.
- Checksum: 16-bit unsigned sum of all 4 header bytes plus every
  payload byte, **not** including the `99 66` magic. Confirmed in
  `libmobile/mobile.c:70-72` (`packet_create()`, building an outgoing
  frame) and `serial.c:47-49`/`102-114` (`MOBILE_SERIAL_HEADER` /
  `MOBILE_SERIAL_CHECKSUM`, validating an incoming one) — both compute
  the same running sum over header+payload only. Transmitted big-endian
  (high byte first).
- Section 12's Begin Session vector (`99 66 10 00 00 08 <"NINTENDO"> 02
  77`) is reproduced exactly by `magb_build_frame()` and is a permanent
  host-side regression test (`tests/host/test_packet.c`).

## The ACK/idle-byte handshake, exactly

The commonly-quoted "2 ACK bytes" summary undersells what actually
happens; this section documents the literal transfer-by-transfer
sequence as implemented by `libmobile/serial.c`'s
`mobile_serial_transfer()` state machine — the sequence this TestSuite
actually reproduces in `magb_session.c`.

Recall that GBC serial is full-duplex: every `serial_transfer_byte(tx,
&rx)` call sends one byte *and* receives one byte simultaneously. In
the walkthrough below, "GBC" is what this TestSuite transmits on that
transfer, "adapter" is what libmobile returns on the *same* transfer.

**Request phase** (GBC is sending a command):

| GBC sends | adapter returns | libmobile state after |
|---|---|---|
| `0x99` | `0xD2` (idle) | `WAITING` |
| `0x66` | `0xD2` | `HEADER` |
| `cmd`, `0x00`, `0x00`, `len` (4 transfers) | `0xD2` each | `HEADER` → `DATA`/`CHECKSUM` |
| payload bytes | `0xD2` each | `DATA` |
| checksum high byte | `0xD2` | `CHECKSUM` |
| checksum low byte | **`adapter_device \| 0x80`** (ACK1, piggybacked on this exact transfer) | `ACKNOWLEDGE` |
| `MAGB_GBC_DEVICE_ACK` (`0x80`, i.e. `GAMEBOY\|0x80`) | **`cmd^0x80`, or `0xF0`/`0xF1`/`0xF2`** (ACK2) | `IDLE_CHECK` |
| filler (any byte) | `0xD2` | `IDLE_CHECK` |
| **must be exactly `0x4B`** | `0xD2` | `RESPONSE_WAITING` |

Source: `libmobile/serial.c:102-180` (`MOBILE_SERIAL_CHECKSUM` through
`MOBILE_SERIAL_IDLE_CHECK`). If the adapter reports `0xF0` (unknown
command) / `0xF1` (bad checksum) / `0xF2` (internal) in ACK2, this
TestSuite resends the *entire* request from `0x99` onward, up to
`MAGB_MAX_RETRANSMIT` (4) times (`magb_execute()` in `magb_session.c`)
— Dan Docs' public write-up asserts "up to 4 retries" for this case,
but that specific number is **not** hard-coded anywhere in libmobile's
own source (it retries this direction indefinitely on the adapter's
side, since the adapter isn't the one initiating resends here — the
*sender* is responsible for resending). Bounding our own resends to 4
is this TestSuite's own choice, per the project brief's explicit "never
retry forever" requirement, not a reproduction of adapter-internal
behavior.

**Response phase** (adapter has finished processing, is now sending):
once the adapter transitions out of `RESPONSE_WAITING` (internally,
whenever `command_handle()` finishes — this is where DNS/TCP/dial
network latency actually shows up as elapsed real time, not as any
special byte), the *next* transfer's rx byte is `0x99` and the response
frame streams out exactly like the request did, in reverse direction.
This TestSuite keeps transmitting `MAGB_GBC_WAIT` (`0x4B`) as filler
throughout — libmobile does not actually inspect the Game Boy's tx byte
during this phase, but real hardware/other adapters are documented to
expect `0x4B` specifically as the "I am still here, keep going" filler
value, so this TestSuite always sends it rather than an arbitrary byte.

**Response-ACK phase** (GBC now acknowledges the response it just
received):

| GBC sends | adapter returns |
|---|---|
| filler | `adapter_device \| 0x80` |
| filler | `0x00` (always; "nothing we can do with this", `serial.c:245-248`) |
| `0x00` (our checksum was fine) or `0xF1` (it wasn't) | `0xD2` |

Source: `libmobile/serial.c:230-269` (`MOBILE_SERIAL_RESPONSE_ACKNOWLEDGE`).
If this TestSuite reports `0xF1` here (its own `magb_parser_t` detected
a checksum mismatch on the incoming response), the adapter loops back
to `RESPONSE_START` and **resends the exact same response from
scratch** — this is the real, source-confirmed retry mechanism for a
receiver-side checksum failure, bounded on our side by the same
`MAGB_MAX_RETRANSMIT`. A non-checksum framing error (bad magic, bad
length) is *not* retried this way, because at that point this TestSuite
can no longer trust its own byte count enough to safely re-synchronize
mid-frame; it aborts the command immediately instead.

## Wait bytes

- `0xD2` (`MOBILE_SERIAL_IDLE_BYTE`, `libmobile/commands.h:27`; also
  `libma/ma_bios.c: MAPROT_IDLE_SLAVE`; also `LinkMobile.hpp:
  ADAPTER_WAITING`) — sent by the **adapter** during the entire request
  body and during `RESPONSE_WAITING`. Confirmed sent **only** during
  those idle/ack bookkeeping windows, not stuffed into the middle of an
  actual response frame's data bytes.
- `0x4B` (`libma/ma_bios.c: MAPROT_IDLE_MASTER`; `LinkMobile.hpp:
  GBA_WAITING`) — sent by the **Game Boy**, exactly once as the
  mandatory "go ahead and process" byte at the end of the request-ACK
  phase, and (by this TestSuite's convention, matching other
  implementations) as filler while clocking through a response.

## Request/response command bit, and why 0x95 is not special

`response_command = request_command | 0x80` (`magb_response_command()`
in `magb_packet.c`). This is a completely generic bit, applied to every
command uniformly — `0x10 → 0x90`, `0x17 → 0x97`, `0x15 → 0x95`. **`0x95`
is not a generic "handshake succeeded" byte**; it is simply what you get
from OR-ing `0x80` onto `0x15` (Transfer Data), and it only means "this
is a Transfer Data response." Treating it as a universal success
indicator would silently accept a `0x95` arriving in response to some
other command, which should instead fail as
`MAGB_ERR_UNEXPECTED_COMMAND`.

One documented exception: a Transfer Data (`0x15`) response can come
back as `0x1F | 0x80 = 0x9F` (`MOBILE_COMMAND_DATA_END`,
`libmobile/commands.c:635`) instead of `0x95`, specifically to signal
that the remote TCP peer closed the connection. `0x1F` never appears as
a request the Game Boy sends; it only appears in this one response
position. `magb_transfer_data()` in `magb_network.c` checks for it
explicitly (`*remote_closed`).

## Device IDs

`libmobile/commands.h`: `MOBILE_ADAPTER_GAMEBOY=0x00`,
`_GAMEBOY_ADVANCE=0x01`, `_BLUE=0x08`, `_YELLOW=0x09`, `_GREEN=0x0A`,
`_RED=0x0B`. `libmobile/config.c` defaults to `MOBILE_ADAPTER_BLUE`, so
a stock libmobile setup identifies itself as `0x08` during
Begin Session. `magb_commands.h`'s `MAGB_IS_KNOWN_ADAPTER_DEVICE()`
accepts the whole documented `0x08-0x0B` range rather than hardcoding
one model, per the project brief.

`Dial Telephone`'s first payload byte is a device-specific validation
value (`libmobile/commands.c` `command_tel_begin`): Blue requires
exactly `0x00`; Yellow doesn't check it; Green/Red accept `0x01` (also
`0x09`). `magb_dial()` in `magb_network.c` picks `0x00` only when the
captured adapter device is Blue, and `0x01` otherwise (correct for
Yellow/Green/Red, and Blue is the only one that actually enforces a
specific value).

## Begin Session

Payload is literally the 8 ASCII bytes `NINTENDO`, no trailing NUL —
confirmed in `libmobile/commands.c:29-31`
(`static const char nintendo[] PROGMEM = {'N','I','N','T','E','N','D','O'};`,
8 bytes) and independently in `libma/ma_bios.c` and
`LinkMobile.hpp:146-148`. The response echoes the same 8 bytes back
unmodified (`command_start()` returns the same packet it received,
only the command byte gains the `0x80` bit). `magb_begin_session()`
validates this echo byte-for-byte before marking the session active —
it never declares success merely because *some* byte in the exchange
happened to equal an expected constant.

(Not used by this TestSuite, but worth recording: `libmobile/commands.c:32-37`
also accepts a 32-byte alternate Begin Session payload,
`"EVERYONE HAPPY MOBILE CONNECTION"`, undocumented on Dan Docs. Not
implemented here since `"NINTENDO"` is the standard, universally
recognized payload.)

## Adapter wake-up and sleep

- **3-second inactivity timeout**: confirmed in `libmobile/mobile.c:172-184`
  (two related timeouts, both literally `3000` ms) and independently in
  `LinkMobile.hpp:307`'s comment ("the adapter will put itself in sleep
  mode after 3 seconds anyway"). This TestSuite never holds an active
  session idle for multiple seconds without either sending a command or
  ending the session.
- **Sacrificial first-transfer / ~100 ms wake delay**: this is
  documented in Dan Docs' public write-up, but **not modeled by
  libmobile** — `mobile_serial_init()` starts clean and responds validly
  from the very first byte. This TestSuite still performs the
  sacrificial wake transfer + ~7-VBlank delay (`magb_wake_adapter()`)
  because it costs nothing against libmobile (the discarded response
  byte is simply an extra `0xD2` observed and ignored) and is required
  for real hardware / other adapter implementations per the project
  brief. It is documented here specifically so nobody "cleans up" this
  code later believing it to be dead weight against libmobile.

## Test configuration sources (Section 24-29)

- `TEST_ISP_PHONE "#9677"` — real DION PDC ISP dial string, hardcoded as
  a recognized special case in `libmobile/commands.c`'s `isp_numbers[]`
  table, and the exact value REON's own `config.example.json` uses for
  `mobile_center_numb`.
- `TEST_ISP_LOGIN`/`TEST_ISP_PASSWORD "test"/"test"` — arbitrary but
  functional: `libmobile/commands.c`'s `command_ppp_connect()` never
  validates login/password against anything external, it only echoes
  back an assigned IP + DNS servers. These are not meant to be real
  DION-era credentials, and are not checked against REON's own
  (separate, HTTP/GB00-layer) user accounts.
- `TEST_DNS_PRIMARY_*` / `TEST_DNS_SECONDARY_* = 0.0.0.0` — confirmed
  libmobile behavior: a zeroed DNS entry in the ISP Login request is
  replaced with the locally configured DNS server in the response
  (`commands.c` `command_ppp_connect`, DNS substitution logic), rather
  than being rejected.
- `TEST_HTTP_HOST "gameboy.datacenter.ne.jp"` — REON's own
  `vhost.example.conf`/`docker-dns-entry.sh` `ServerName`/DNS entry for
  the Mobile System GB service.
- `TEST_HTTP_PATH "/cgb/download?name=/01/CGB-BXTJ/tamago/index.txt"` —
  **a real query Pokémon Crystal performs**: this is the exact request
  Crystal's "Mystery Egg" (tamago) feature sends to check for an
  available egg download from the Mobile Adapter datacenter.
  `CGB-BXTJ` is Pokémon Crystal (Japan)'s real cartridge code, and the
  requested file genuinely exists in REON's test dataset
  (REON's `web/cgb/download/01/CGB-BXTJ/tamago/index.txt`).
  It requires no authentication — REON's `doAuth()` (`web/cgb/auth.php`)
  only challenges a request whose filename has a numeric cost prefix
  (e.g. `10.foo.php`); `index.txt` has none — which makes it an ideal
  TestSuite HTTP target: real, deterministic, and free of REON's
  separate GB00 upload-auth scheme. Confirming this independently, the
  file's own 142-byte content *is* the literal URL template
  `http://gameboy.datacenter.ne.jp/cgb/download?name=/01/CGB-BXTJ/tamago/tamagoXX.pkm`.
- `TEST_HTTP_NEWS_CONFIG_PATH`/`TEST_HTTP_NEWS_PATH` — Pokémon
  Crystal's other real Mobile Adapter datacenter feature, the Goldenrod
  Communication Center "News" service
  (`web/cgb/download/01/CGB-BXTJ/news/`). `news/config.php` has no
  numeric cost prefix, so like the tamago `index.txt` it needs no
  auth. `news/100.news.php` (the actual news content) is documented in
  REON's own source as requiring its GB00 auth unconditionally, even
  though it's zero-cost (`web/cgb/pokemon/news.php`:
  `bxt_pokemon_news_require_authenticated_user_id()`, comment "Pokémon
  news + ranking endpoints require auth even if free"). This TestSuite
  does not implement that auth handshake, so this target is expected
  to come back HTTP 401 -- itself a real, correct, end-to-end
  ISP→DNS→TCP→HTTP result against a second real endpoint, just not a
  200. See `docs/integration-guide.md` if you want to add the GB00
  flow yourself.
- Email tests (SMTP send / POP3 receive) use **no compile-time
  host/address at all** -- they read the adapter's own email/SMTP-
  server/POP-server fields straight out of a live Read Configuration
  Data (0x19) response (`MAGB_CONFIG_OFF_EMAIL`/`_SMTP`/`_POP` in
  `magb_network.h`), exactly like a real game would. The dialogue
  itself (`test_isp_email_send`/`_recv` in `test_runner.c`) was
  confirmed against REON's real mail server source
  (REON's `mail/smtp.js`, `smtpConnection.js`,
  `pop3Connection.js`): SMTP takes mail with no authentication at all
  (delivery only actually happens if `RCPT TO` matches a real
  account's address); POP3 authenticates with `USER
  <local-part-of-email>` / `PASS <same password as ISP login>` --
  confirmed by reading `pop3Connection.js`'s `PASS` handler, which
  checks against the identical `log_in_password` database column the
  GB00/ISP-facing auth uses. The sent message itself carries
  `MIME-Version`/`From`/`To`/`Content-Type: text/plain;
  charset=iso-2022-jp` headers (both `From:` and `To:` set to the same
  live `id.email`, since this test always mails itself) -- the shape
  Mobile Trainer's real outgoing mail always uses (see "Mobile Trainer",
  "Email" in `dandocs-magb.md`). A bare `"Subject: ...\r\n\r\nbody"`
  message (this test's original shape) sends and round-trips fine over
  raw SMTP/POP3, and REON itself doesn't reject it, but Mobile Trainer's
  own inbox couldn't display a message received in that shape --
  confirmed by injecting a header-less test message directly into a
  real test mailbox and trying to open it in Mobile Trainer (failed),
  then retrying with these headers added (opened correctly).
  `charset=iso-2022-jp` is safe to declare even for this test's plain
  ASCII body, since plain ASCII is a valid subset of ISO-2022-JP's
  default/ASCII-mode state (no escape sequences needed).
- `TEST_P2P_PHONE "127000000001"` — libmobile's own
  `mobile_parse_phoneaddr()` (`util.c`) parses any 12-digit
  `MAGB_CMD_DIAL` payload as 4 groups of 3 decimal digits → an IPv4
  address (`"127000000001" → 127.0.0.1`), independent of
  libmobile-bgb (which only documents the behavior in its README, the
  actual parsing lives in libmobile core). This TestSuite's P2P Caller
  menu also lets the user edit this number/IP at runtime (12-digit
  editor, `ui_edit_number()`) rather than only via this compile-time
  default — similar in spirit to how `LinkMobile::callISP()` takes a
  runtime login/target rather than a hardcoded one.

## Read Configuration Data (0x19) payload/response, and the config layout

Request: `[offset, size]` (2 bytes); response: `[offset, data...]`
(`size+1` bytes), `size` capped at `0x80` and `offset+size` capped at
`libmobile`'s `MOBILE_CONFIG_SIZE_REAL` (`0x100`) —
`libmobile/commands.c:734-750` (`command_eeprom_read`).

The 192-byte documented configuration layout below is not this
TestSuite's invention — it is `gba-link-connection`'s
`LinkMobile::ConfigurationData` struct (`lib/LinkMobile.hpp:182-201`),
which a real GBA title parses out of the exact same EEPROM blob a GBC
Mobile Adapter exposes. `CONFIGURATION_DATA_SIZE = 192` there matches
this struct's `sizeof` exactly, and `LinkMobile` itself reads it in two
96-byte halves (`CONFIGURATION_DATA_CHUNK = 192/2`) for the same reason
this TestSuite does: a single `0x19` call is capped below 192 bytes.
`libmobile` itself treats this blob as opaque (it only exposes a
generic EEPROM read/write callback to host storage), so this layout
comes from LinkMobile/Dan Docs, not from libmobile's own source.

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | magic |
| 2 | 1 | registration state (`0x81` = complete, `0x01` = pending -- see below) |
| 3 | 1 | (unused) |
| 4 | 4 | primary DNS (IPv4) |
| 8 | 4 | secondary DNS (IPv4) |
| 12 | 10 | login ID |
| 22 | 22 | (unused) |
| 44 | 24 | email |
| 68 | 6 | (unused) |
| 74 | 20 | SMTP server |
| 94 | 19 | POP server |
| 113 | 5 | (unused) |
| 118 | 24 | configuration slot 1 (ISP dial-string entry) |
| 142 | 24 | configuration slot 2 |
| 166 | 24 | configuration slot 3 |
| 190 | 2 | checksum |

`ui_show_config()` (`src/app/ui.c`) displays this across three pages:
magic/registration-state/DNS/login ID/checksum validity; email/SMTP/
POP; and Configuration Slot 1's decoded phone number + ID string.

**Independently confirmed** by `docs/dandocs-magb.md` (Dan Docs'
"Configuration Data" section, converted to Markdown by the project
owner from https://shonumi.github.io/dandocs.html): every offset above
matches exactly (`0x0C`-`0x15` login ID, `0x2C`-`0x43` email,
`0x4A`-`0x5D` SMTP, `0x5E`-`0x70` POP, `0x76`-`0xBD` the three
configuration slots, `0xBE`-`0xBF` checksum) -- two independent
sources (a real GBA title's own parser, and Dan Docs' reverse
engineering) now agree byte-for-byte. Dan Docs additionally documents
the login ID's real format as `gXXXXXXXXX` (a literal `g` followed by
digits) and the checksum as a 16-bit additive sum of bytes `0x00`-`0xBD`.

**Registration state byte, corrected.** The original implementation
checked bit 0 (`config[2] & 0x01`) to decide "(REG)" vs "(NONE)". Both
of Dan Docs' documented values -- `0x01` ("registration in progress")
and `0x81` ("registration complete") -- have bit 0 set, so that check
could never actually tell them apart; it happened to always print
"(REG)" whenever *either* was present. Caught by comparing against a
real captured config file (`config.bin`, from libmobile-bgb) that had
byte 2 = `0x01`, not `0x81`. Fixed (`src/protocol/magb_config.c`'s
`MAGB_REG_STATE_COMPLETE`/`MAGB_REG_STATE_PENDING`) to compare the
whole byte against both documented values, showing "(PENDING)" as a
distinct third state.

**Configuration Slot decoding, implemented and verified.**
`src/protocol/magb_config.c` (`magb_config_decode_phone()`,
`magb_config_checksum_ok()`) decodes a slot's 8-byte BCD phone number
(`0xA`='#', `0xB`='*', `0xF`=end-of-number, read high-nibble-then-low,
byte by byte) and validates the trailing checksum. Both were verified
against `config.bin`, a real 512-byte configuration file the project
owner captured from an actual libmobile-bgb session (the first 192
bytes are byte-for-byte what a real `0x19` response contains; the rest
is libmobile-bgb's own on-disk container format, out of scope) --
`tests/host/test_config.c` reads that file directly and asserts:
Slot 1's phone decodes to `"#9677"` and its ID string is
`"DION PDC/CDMAONE"` (Dan Docs' exact documented PDC/CDMA default,
confirming Mobile Trainer really did write this slot for real), the
checksum at `0xBE`-`0xBF` (`0x353D` in this capture) matches the
additive sum of bytes `0x00`-`0xBD` exactly, and Slot 2/3 (untouched,
all-`0xFF` phone bytes) decode to an empty string rather than garbage.
This is the first host test in this project to validate against a
real captured artifact instead of a hand-built vector -- see
`tests/host/test_config.c`'s header comment.

**Every ISP-touching test now dials Slot 1's real phone number**, not
`TEST_ISP_PHONE`, via the same `read_isp_identity()` helper
(`test_runner.c`) that already read login ID/email/SMTP/POP live --
per the project owner's explicit request that anything needing
authentication read everything it can from the adapter's own config
rather than compile-time constants. `TEST_ISP_PHONE`/`TEST_ISP_LOGIN`
are now purely fallback defaults for an unregistered (blank) config.

## GB00 HTTP authentication

This is an HTTP-application-layer scheme REON uses for some
Pokémon-Crystal-era downloads/uploads (`web/cgb/auth.php`), riding
inside ordinary HTTP requests over an ordinary MAGB TCP connection --
not part of the Mobile Adapter protocol itself, which is why it lives
in `src/app/gb00_auth.c` (Layer 3) rather than `src/protocol/`. The
original algorithm was reverse-engineered by SimonTime (credited in
REON's own source) and is described in prose in
`web/htdocs/cgb/upload.php`'s header comment. That prose write-up gets
one detail wrong (see below); this implementation was derived
independently from, and round-trip-tested against, REON's actual PHP
*decode* function (`web/cgb/auth.php`: `decodeAuthorization()`,
`validateAuthData()`), not from the prose alone.

**Flow**: GET with no `Authorization` header -> server replies `401`
with `WWW-Authenticate: GB00 name="<48-char base64>"` (48 base64
characters exactly encode the 36 random bytes the server generated,
36 being divisible by 3 means no `=` padding) -> client computes an
`Authorization: GB00 name="<92-char base64>"` value and re-sends the
GET, now succeeding (or failing with a real, application-level reason)
in that same second response, no third round-trip needed.

**Building the 92-character Authorization value** (`gb00_build_authorization()`):

1. Base64-decode the 48-character challenge into 36 raw bytes.
2. Derive a 36-byte `bits_sorted` value from those 36 raw bytes:
   bytes 0-17 pack the *even*-numbered bits (0,2,4,6) of each
   challenge byte pair; bytes 18-35 pack the *odd*-numbered bits
   (1,3,5,7) of the *same* 18 byte pairs. (First byte of each pair
   fills the high nibble, second byte the low nibble.)
3. Compute `MD5(challenge_text_48chars + password)` -- note this
   hashes the **base64 challenge text itself** (48 ASCII characters),
   not the 36 decoded raw bytes, and the **password**, not the login.
   This 16-byte digest is the first 16 bytes of a 36-byte plaintext
   block.
4. The remaining 20 bytes of that plaintext block hold the login ID
   (dionId), **right-aligned, left-padded with `0xFF`** up to 20
   bytes. This is the one place upload.php's prose write-up is wrong
   -- it describes the login as left-aligned with the `0xFF` padding
   (and a trailing `0x00`) on the right. That ordering was tried and
   confirmed to *not* survive a round-trip through the server's real
   `trim($str, "\xFF")` call (a trailing non-`0xFF` byte, e.g. a short
   login followed by `0x00`, stops `trim()` from ever reaching the
   padding on that side, corrupting the recovered login). Left-padding
   was confirmed correct against dozens of random-challenge,
   varied-login-length round-trips through a from-scratch C port of
   REON's own `decodeAuthorization()`.
5. XOR the 36-byte plaintext block with `bits_sorted`, byte for byte.
6. Rotate 3 bits of each resulting byte: bit 0 moves to bit 3, bit 3
   moves to bit 6, bit 6 moves to bit 0; bits 1,2,4,5,7 are untouched
   (`0xB6` = `0b10110110` marks the untouched bits). This is the exact
   inverse of the server's own un-rotate step.
7. Base64-encode: `base64(raw_challenge_bytes[0:32])` (a *fresh,
   independently-padded* re-encoding of the first 32 raw challenge
   bytes -- **not** a slice of the original 48-character challenge
   text; 36 isn't a multiple of 32, so encoding boundaries don't line
   up, confirmed by direct test) gives the first 44 characters;
   `base64(scrambled_36_bytes)` (no padding, 36 % 3 == 0) gives the
   final 48 characters. 44 + 48 = 92.

**Why the first 32-byte re-encoding matters**: the server reconstructs
its own session ID from those first 44 characters
(`session_id(bin2hex(base64_decode(substr($authString,0,44))))`),
which must equal the session ID it created when it first issued the
401 challenge (`session_id(substr(bin2hex($randomBytes),0,64))` -- the
hex of the same first 32 bytes). Get this wrong and the server can't
even find the right session to validate against, regardless of
whether the password hash is correct.

**Re-verified 2026-08-26 directly against REON's `web/cgb/auth.php`**
(the project owner hit a real, persistent `32-401` even after the
login-source fix below): read the live `doAuth()` source line-by-line
again, not just this TestSuite's own prior summary of it. Confirms:
the deterministic-session-id mechanism above is exactly right (both
the challenge-issuing and validation code paths derive the identical
64-hex-char session id, no cookie needed); the header value format
(`GB00 name="<92 chars>"`) is exactly right (`substr($authString, 11)`
strips precisely `GB00 name="`, 11 characters). No bug was found in
this TestSuite's own crypto or request construction on this second
pass. At the time, two causes were suspected to be outside this ROM's
control (PHP dropping the `Authorization` header before it reaches
`doAuth()`; a wrong account password) -- **both ruled out** by the fix
below, found from a real BGB link-log capture.

**Actual root cause, found 2026-08-27: `GB00_RESP_BUF_SIZE` was too
small.** The project owner's own account credentials
(`g000000034`/`pass157`, confirmed correct) were being sent correctly
in the ISP Login packet the whole time -- the log proved the ROM never
even got as far as attempting the authenticated retry. A real 401
response from the actual nginx-fronted server is:

```
HTTP/1.1 401 Unauthorized
Server: nginx/1.27.0
Date: Thu, 27 Aug 2026 12:17:39 GMT
Content-Type: text/html; charset=UTF-8
Connection: close
WWW-Authenticate: GB00 name="<48-char challenge>"

```

227 bytes total -- but `gb00_http_get()`'s response buffer
(`GB00_RESP_BUF_SIZE`) was only `200`. The `WWW-Authenticate` line
starts at byte 145 and needs 82 more bytes to complete; only 55 fit
before the buffer's cap silently stopped accumulating. `gb00_find_challenge()`
correctly located the `WWW-Authenticate:` label (it's within the first
200 bytes) but then couldn't read a complete 48-character quoted
challenge past the truncation point, so it correctly reported
"NO WWW-AUTH HDR" -- every News test failed at that exact point, before
ever building an `Authorization` header, regardless of how correct the
crypto or credentials were. A minimal/synthetic test response (as used
during this feature's original host-side verification) never exercises
this, since it has no `Server`/`Date` lines pushing the challenge past
byte 200.

**Fix**: `GB00_RESP_BUF_SIZE` raised from `200` to `360` (real 401 is
227 bytes; a real 200 OK from `get_news_parameters_bin()`/
`get_news_file()` has a binary body instead of the `WWW-Authenticate`
line but no hard upper bound was derivable from the PHP source alone,
so 360 leaves comfortable margin). Since `360 > 255`, the per-call
capacity passed to `magb_transfer_data()` (a `uint8_t`) is now
explicitly clamped to `255` instead of just cast from
`GB00_RESP_BUF_SIZE`, which would otherwise silently wrap for a
"remaining space" value above 255 -- a latent bug that would have
resurfaced the moment the buffer grew past one byte's addressable
range, caught while making this fix rather than shipped separately.

**"NEWS ARTICLE" now performs the real game's full two-request flow**
(`test_isp_news_article()`, added per the project owner's request --
"no teste do article, ele deve fazer o fluxo completo, incluindo o
news config antes e depois o news article"): one Begin Session/Dial/
ISP Login/DNS Query, then `get_news_parameters_bin()`
(`config.php` -- news size, the SRAM address to store it at, and the
ranking-submission SRAM layout) followed by `get_news_file()`
(`100.news.php` -- the actual news content), each with its own GB00
challenge/response over its own TCP connection. A standalone
"NEWS CONFIG" test used to exist as an isolated single-request
diagnostic for just the config fetch (`test_isp_http_gb00()`) --
removed once "NEWS ARTICLE" already exercised that same fetch on its
way to the article, making it redundant.

This deliberately does **not** rely on REON's optional 15-minute
utility-auth session cache (`auth.php`'s
`$_SESSION['utility_authed_user_id']`/`_until`, checked at the top of
`doAuth()`'s `type==2` branch) to skip the second challenge --
REON's `web/cgb/pokemon/news.php`'s own comment on that path
says only that "the official client... may not perform an additional
401-challenge retry," not that it never does. Doing the full
challenge/response twice is still correct against the documented
protocol either way, and doesn't depend on a same-cookie-less PHP
session actually being resumable across this TestSuite's own
close-then-reopen TCP connections, which was never independently
verified.

A shared `gb00_fetch()` helper (`test_runner.c`) implements "GET, if
401 then challenge/respond, GET again" once; `test_isp_news_article()`
calls it per URL.

**Credentials**: `validateAuthData()` looks up the account by
`dion_ppp_id` and checks the password against the same
`log_in_password` column POP3 auth uses (see the email test notes
above). This TestSuite reads the login ID **live from the adapter's
own Read Configuration Data (0x19)** response
(`MAGB_CONFIG_OFF_LOGIN_ID`, 10 bytes) rather than from
`TEST_ISP_LOGIN`, falling back to `TEST_ISP_LOGIN` only if the config
field is blank (unregistered adapter). This was changed after the
project owner hit a real `32-401` (401-after-retry) against a live
server: `TEST_ISP_LOGIN="test"` is not the shape of a real registered
account, which Dan Docs' "Configuration Data" section documents as
`gXXXXXXXXX` (offset `0x0C-0x15`, a literal `g` followed by digits) --
REON's account records are almost certainly keyed by that real
registered ID, not an arbitrary compile-time string. `TEST_ISP_PASSWORD`
is still used for the password, since no password field exists
anywhere in the documented 192-byte configuration layout (it is only
ever kept in a game's own save data, per CLAUDE.md's Test
Configuration notes). If GB00 auth still fails with a 401-after-retry,
check the result screen's second line (`LOGIN <id>`, showing exactly
which login this run used) against whatever account actually exists on
the server under test.

**Verification performed before writing any C for the Game Boy**: the
full algorithm was prototyped in Python and round-tripped against a
line-for-line Python port of `decodeAuthorization()`/
`validateAuthData()` across dozens of random challenges and login
lengths (including empty and maximum-length logins); the actual
embedded C implementation (`md5()`, `base64_encode()`/`_decode()`,
`gb00_build_authorization()`) was then separately round-trip-tested
the same way from a native host build, *and* `md5()` was checked
against all 6 RFC 1321 test vectors independently (i.e. not merely
self-consistent with the round-trip test, which alone couldn't have
caught an MD5-specific bug shared by both sides).

**No mapper/save added for this -- a text-entry screen instead.** GB00
needs a login+password, and it's the same REON account already used
for ISP Login and the POP3 test. The login ID *is* stored in the
adapter's own configuration and is read from there live (see "Read
Configuration Data" above); the password is not (no password field
exists anywhere in the documented 192-byte layout), so it can't come
from Read Config no matter what. Originally this used a compile-time
`TEST_ISP_PASSWORD` constant; per the project owner's explicit request
("a senha deve ser perguntada para o usuario"), there is now an
"ISP PASSWORD" main-menu entry (`ui_edit_text()` in `src/app/ui.c`, a
character-cycling text editor modeled on the existing P2P-number
digit editor) that edits a session-wide RAM buffer
(`isp_password[]` in `main.c`) used by every ISP-touching test. It
starts EMPTY — there is deliberately no `TEST_ISP_PASSWORD` default,
because a guessed placeholder hid every real 401/`-ERR` behind a
confusing symptom for a full day; tests that actually authenticate now
refuse to run at all (`require_password()`) rather than send something
made up.

It no longer resets on power-off. The ROM grew a mapper for **code
space** (see "ROM banking" below), and once MBC5 was there,
battery-backed RAM was a header byte away — cartridge type is now
`0x1B` (MBC5+RAM+BATTERY) with one 8 KiB bank, and `src/app/save.c`
keeps the password across power cycles.

What did *not* change is the refusal to guess. There is still no
compile-time default: a cartridge that was never written, whose battery
died, or whose record fails its magic/version/checksum check loads as
empty, and the authenticating tests still refuse to run. The stored
record is validated before a single byte is handed back, because
uninitialized cart RAM is arbitrary bytes and "looks like a password"
is not good enough — silently loading garbage would recreate the exact
failure mode that made the old guessed default worth deleting.

The password is stored verbatim: on an emulator that means a plain
`.sav` next to the ROM. There is nothing on a Game Boy to encrypt it
with, and a cart's owner can always read its own save RAM, so the file
should be treated as holding a real account credential — not committed,
not attached to a bug report. The repo's `.gitignore` already excludes
the whole emulator working directory, which is where BGB writes it.

## P2P: direct-IP dialing and relay-based calls are different mechanisms

Confirmed by reading libmobile's `commands.c` directly, after
this ROM's own docs previously (incorrectly) implied a relay-based P2P
call was just "the same test with a different dialed number":

`command_tel()` (handling `12` Dial Telephone once the number isn't a
recognized ISP number) branches on `adapter->config.relay.type` *before*
ever looking at the dialed number as an address:

- **Relay disabled** (`MOBILE_ADDRTYPE_NONE`, the default, and what
  this TestSuite's P2P Caller/Listener test exercises): a 12-digit dial
  payload is parsed locally as a raw IPv4 address
  (`mobile_parse_phoneaddr()`), and the adapter opens a normal outbound
  TCP connection straight to `<that IP>:p2p_port` (default `1027` --
  `MOBILE_DEFAULT_P2P_PORT` in `mobile.h`). The Wait For Call (`14`)
  side opens a TCP *listening* socket on that same port
  (`command_wait_call_begin()`). This is genuinely peer-to-peer: two
  `mobile` processes talk directly to each other, and the only shared
  requirement is that port being mutually reachable (same LAN, no
  firewall blocking it, for a two-machine setup).

- **Relay enabled** (`mobile` process started with `--relay
  <server-addr>`, see libmobile-bgb's `source/main.c`): the
  *same* Dial command instead opens a TCP connection to the configured
  relay **server**, then hands the dialed number to that server's own
  call-matching protocol (`mobile_relay_proc_call()` in
  libmobile's `relay.c`) -- the number is never parsed as an
  IP in this mode. Both peers connect to the relay server, which
  brokers the match; this is a genuine REON-relay-style rendezvous
  connection, architecturally closer to the ISP/HTTP tests' plain TCP
  connections than to the direct-IP P2P path above.

These are mutually exclusive, and selected entirely by how the
`mobile` process itself was launched -- not by anything the Game Boy
dials. A "REON relay-assigned number" is only meaningful to a specific
relay server's own accounting and cannot be used as this TestSuite's
`TEST_P2P_PHONE`/P2P Caller dial value (which is always parsed as a
12-digit dotted-quad IP). This TestSuite's P2P test only exercises the
direct-IP path; it does not exercise relay-based calling.

## Error Status (0x6E) can replace the response to any command

Discovered from a real BGB + libmobile-bgb capture of the P2P test:
after the far end's connection dropped mid-exchange, a Transfer Data
(`15`) poll came back not as `95` (the normal response) but as
`6E|0x80 = EE`, with a 2-byte payload `[15, 00]`. Dan Docs' "6E - Error
Status" section documents this as a general mechanism, not specific to
Transfer Data: **any** request can get an Error Status response instead
of its own expected response command, with payload byte 0 naming which
command failed and byte 1 a command-specific error code (see the table
in the next section).

Every command wrapper in `magb_network.c`/`magb_session.c` used to only
check for its *own* expected response command and fall back to
`MAGB_ERR_UNEXPECTED_COMMAND` otherwise -- which is exactly what
happened here, misreporting a real, specific, documented failure
("Transfer Data: invalid connection / communication failed") as a
generic "unexpected command" with no useful detail. Rather than
duplicate an Error Status check in all thirteen wrappers, `magb_execute()`
now recognizes `0x6E|0x80` once, centrally, right after validating the
response frame: it captures the failed command/error code into
`ctx->remote_error_command`/`remote_error_code` and returns
`MAGB_ERR_REMOTE_STATUS` instead of `MAGB_OK`. Every wrapper already
does `if (r != MAGB_OK) return r;` immediately after calling
`magb_execute()`, so this required no changes to the wrappers
themselves. `test_p2p_caller()`/`test_p2p_listener()`'s receive-failure
path (`p2p_recv_fail()`) shows the decoded command/code on the result
screen instead of a misleading "TRANSFER TIMEOUT" when this is what
actually happened.

This does not conflict with `magb_execute()`'s documented policy of
leaving "is this the right response command for my request" to the
caller (Transfer Data's `15`-vs-`1F` distinction is the reason that
policy exists) -- `0x6E|0x80` is never a *valid success* shape for any
command, so recognizing it is a transport-level fact, not a
per-command judgment call.

## Official Mobile Adapter GB error codes

Real Nintendo software (Pokémon Crystal included) shows the player a
numeric `NN-NNN` code on a communication failure, e.g. `24-000` for a
failed TCP connection. This TestSuite surfaces the same codes
(`test_result_t::official_code`, shown as `CODE: NN-NNN` on the result
screen) wherever one clearly applies, so a failure here can be
compared directly against what a real cartridge would have shown.

| Code | Meaning |
|---|---|
| 10-000 | Adapter is not connected |
| 14-000 | Invalid checksum in configuration |
| 15-000 | Unexpected data (sent when the adapter couldn't connect to a server) |
| 20-000 | Wrong or invalid Mobile center was selected |
| 21-000 | Communication error |
| 24-000 | TCP connection fail |
| 25-000 | Mobile adapter not configured (use the Mobile Trainer to configure it) |
| 31-002 | Received error code from POP3 server |
| 32-000 | Unknown HTTP communication error |
| 32-XXX | HTTP communication error (XXX is the HTTP status code) |
| 33-000 | Communication error with mobile center |
| 33-XXX | HTTP error code related to the mobile center |
| 101-XXX | Socket communication error |

This TestSuite's own mapping from its internal `magb_result_t`/command
context onto these codes (`test_runner.c`,
`default_official_code()`/`result_fail_code()` call sites) is a
judgment call where the official table doesn't name this TestSuite's
exact internal error, not a re-derivation from Nintendo documentation:

- Any hardware/framing-level failure this TestSuite detects on its
  own (bad checksum, bad magic, timeout, ...) -> `21-000` (generic
  communication error), or `10-000` specifically for a timeout/no
  adapter response at all.
- Dial ISP failing -> `20-000` (wrong/invalid mobile center).
- ISP Login failing -> `25-000` (adapter not configured) -- a login
  rejection is the shape of failure the real Mobile Trainer / ISP
  configuration flow addresses.
- DNS Query failing -> `15-000` (couldn't reach a server), matching
  the table's own annotation.
- TCP Open failing -> `24-000` (exact, documented match).
- An HTTP-layer failure (send/receive error, or a successfully
  transported but non-`HTTP/`-prefixed response) -> `32-000`/`15-000`.
- A successfully parsed HTTP response -> `32-XXX` with XXX being the
  literal 3-digit status code this TestSuite received, matching the
  official convention exactly (not a guess).
- P2P failures and this TestSuite's own platform checks (not a CGB,
  user-cancelled) have no official code and are left uncoded --
  these aren't part of the ISP/HTTP-oriented error scheme above.

## GBC vs GBA differences, and why SIO32 is excluded

The GBA-targeted `libma`/`LinkMobile` sources describe an optional
32-bit SIO32 transfer mode (`MOBILE_COMMAND_CHANGE_CLOCK = 0x18`,
declared here as `MAGB_CMD_SIO32` purely for completeness) where four
8-bit transfers are packed into one 32-bit exchange and the ACK footer
handling changes shape (`libmobile/serial.c:275-306`,
`mobile_serial_transfer_32bit()` — note its own comment: *"the received
device byte can't be verified either"* in that mode). This is a GBA
`REG_SIOCNT`/`SIO32`-specific hardware feature with no Game Boy Color
equivalent; enabling it would also stop matching the byte-for-byte ACK
sequence this document describes above, which is the 8-bit sequence
real GBC hardware and libmobile's 8-bit path implement. This TestSuite
never sends `MAGB_CMD_SIO32` and never switches out of 8-bit
`SIOF_SPEED_32X` GBC serial mode.

## ROM banking (MBC5), and the two traps that come with it

Not protocol, but it constrains where protocol code may live, and both
failure modes below are silent at build time and fatal at runtime.

The GBDK ROM was mapperless (cartridge type `0x00`, 32 KiB) until the
BIG BUFFER test needed roughly 4 KiB more than the 826 bytes left. It
is now **MBC5, cartridge type `0x1B` (MBC5+RAM+BATTERY)** with one
8 KiB RAM bank. The mapper was added for code space alone; the RAM and
battery came afterwards, once it was there anyway, to persist the ISP
password (see the GB00 section above and `src/app/save.c`).

MBC1/MBC2/MBC3/MBC5 were all checked against the installed `bankpack`
before choosing (bank ceilings 127 excluding `0x20`/`0x40`/`0x60`, 15,
127 and 255 respectively). MBC5 is the one documented as guaranteed to
work in CGB double-speed mode, which this ROM runs in — that decided
it. MBC3 would also have fit and has Pokémon Crystal as precedent.

Exactly **one** translation unit is banked: `src/app/gb00_auth.c`
(`#pragma bank 255`, ~5 KiB of MD5/base64/GB00 code), chosen because it
is nearly self-contained and sits at the leaf of the call graph. Its
four exported functions carry `BANKED` on **both** prototype and
definition; a mismatch there compiles cleanly and jumps into the wrong
bank at runtime. An earlier, much wider `-autobank` attempt that let
bankpack scatter modules across banks without those annotations built
fine and hung on a blank screen; it was reverted.

The two traps, both of which bit this ROM and are now covered by
`make check-banking`:

1. **The non-banked code does not fit in bank 0.** It is ~30 KiB, so
   the linker lays `_CODE` out flat across banks 0 *and* 1. That works
   only because MBC5 maps bank 1 at reset and we normally never leave
   it — but it means everything above `0x3FFF` is displaced for as long
   as a banked module is mapped in. "Non-banked" here does **not** mean
   "always reachable".

2. **The bank trampoline was itself in the switchable window.** GBDK
   emits `_CODE` before `_HOME`, which placed `___sdcc_bcall_ehl` at
   `0x76E1`. The instant it wrote bank 2 to the MBC5 register it
   unmapped itself, and the CPU carried on executing whatever
   `gb00_auth` happened to have at that address. Fixed by pinning
   `-Wl-b_HOME=0x0200` and starting `-Wl-b_CODE=0x0C00` after it, which
   puts the trampoline at `0x097C`.

Consequently `gb00_auth.c` calls **nothing** outside its own bank — it
carries local copies of `memcpy`/`strlen` rather than `<string.h>`'s,
which the linker had placed at `0x6DF2` and `0x7732`. Interrupts are
fine as-is: the `0x40`/`0x48` vectors dispatch into crt0 code below
`0x1000`, and the serial IRQ is unused (this ROM polls `SC_REG`), so no
ISR path is ever unmapped.

`make check-banking` fails the build if the trampoline lands at or
above `0x4000`, or if `gb00_auth.c` gains any external reference other
than the trampoline. `bankpack` is pinned with `-Wb-min=2` so banked
modules never land in bank 1, where the flat `_CODE` already lives.

The RGBDS ROM needs none of this — it is hand-written assembly with
~12.6 KiB still free in ROMX bank 1 and no mapper change.

## GB00: download and upload do NOT authenticate the same way

Confirmed by reading REON's own `web/cgb/auth.php` and
`web/htdocs/cgb/{download,upload}.php`, after a real run where the
BIG BUFFER upload leg failed while its download leg passed.

`doAuth($type)` issues the same `WWW-Authenticate: GB00` challenge in
every case, but what it does *after* a valid `Authorization` depends on
the type, and the callers pass different ones:

| endpoint | call | on success |
|---|---|---|
| `download.php` | `doAuth(1)` | **returns** the session id; the script then serves the file, so the authenticated GET carries the content |
| `news/NN.news.php` | `doAuth(2)` | **returns** the user id; the script outputs content directly |
| `upload.php` | `doAuth()` (type 0) | sets `Gb-Auth-ID: <id>`, sends `200`, and **`exit()`s** — the request body is discarded |

So an upload is **three** requests, not two:

1. `POST` with no auth → `401` + `WWW-Authenticate: GB00 name="..."`
2. `POST` + `Authorization: GB00 name="..."`, **`Content-Length: 0`** →
   `200` + `Gb-Auth-ID: <id>`, empty body
3. `POST` + `Gb-Auth-ID: <id>` + the real `Content-Length` and body

`upload.php`'s own header comment states this outright: *"the server
responds with 200 OK and a `Gb-Auth-ID` header ... The game then sends
its POST request and includes the same `Gb-Auth-ID` header."*

Sending the body on step 2 is not merely wasteful — it is dropped, and
the server then answers step 2's headers rather than an upload verdict,
which looks exactly like a failed upload. Both ROMs originally did that.

Two smaller facts from the same source, worth not re-deriving:

- Auth is keyed off a **cost prefix** on the filename, not the
  directory: `getCost()` takes the leading dot-separated component and
  requires it to be numeric. `0.bigbuffer.cgb` therefore *does* require
  auth (cost 0, which `addCostToAccount()` then skips), which is why
  that name was chosen for the test fixture.
- `doAuth` runs **before** the file is looked up. A `401` from an
  endpoint is therefore no evidence that the requested file exists —
  a missing fixture and a present one challenge identically.

The session id is `bin2hex(random_bytes(16))`, 32 characters today.
Neither ROM assumes that width: both parse `Gb-Auth-ID` as an opaque
token up to a generous cap and refuse rather than truncate past it.

### The MAGBTEST fixture (server-side, confirmed)

REON has no shared git remote — the production server is the only place
these files exist, so a local checkout can never answer "does this
fixture exist?". Confirmed by the person running that server:

- `web/cgb/download/01/MAGBTEST/0.bigbuffer.php` serves 8192 bytes,
  `body[i] == i & 0xFF`, with `X-Test-Checksum: F000`. The `.cgb` in the
  requested path resolves to `.php` through `core.php`'s
  "file doesn't exist, try .php" fallback.
- `web/cgb/upload/01/MAGBTEST/0.bigbuffer.php` recomputes the same
  16-bit additive sum over the POSTed body, compares it against the
  request's `X-Test-Checksum`, and `echo`es `"\x01"` on a match or
  `"\x00"` otherwise. It also returns its own computed value in the
  response's `X-Test-Checksum`, so a rejection says what the server
  actually received rather than only that it disagreed. Both ROMs show
  that value beside their own on failure.

`F000` is independently derivable and worth keeping as a regression
constant: the body is 32 complete 0..255 ramps, and
`32 * (255*256/2) = 1044480`, which is `0xF000` mod 65536.

**Confirmed working end to end on 2026-09-07** against the real server:
`DL 8192 B OK` / `UPLOAD OK` / `CODE:32-200`. Both the streamed download
checksum and the server's re-derivation of the uploaded body agreed.

The earlier crash on this test (`PC=0x0038`, switchable window full of
filler) was the 32 KiB overflow, confirmed by the same run passing on
the 64 KiB MBC5 build. It presented as "only BIG BUFFER crashes" because
its code, being the most recently added, was the part that sat past the
boundary -- every older test's code was below it and intact. The
bank-trampoline problem found while investigating was real and worth
fixing, but it was not this crash: it would have taken NEWS ARTICLE down
with it, since that test calls the same banked functions.

### A 401 on the upload's third request is not a timing problem

Worth writing down because the obvious guess is wrong, and this project
has already spent days on a wrong guess about timing.

Requests 2 and 3 of an upload are coupled through a PHP session: request
2 writes the `Gb-Auth-ID`, request 3 reads it. That *looks* like it
could race — the ROM sends request 3 as fast as it can, with no pause —
and a real race of exactly that shape does exist elsewhere in REON (its
POP3 `+OK` for `PASS` is emitted outside the callback that populates the
maildrop, so a fast client can get `STAT 0 0` on a full mailbox).

It cannot happen here, structurally rather than by luck of timing. The
session file is written during PHP's shutdown, which runs even when the
script leaves via `exit()` — which is exactly how `doAuth` type 0
returns. PHP-FPM only reports end-of-request to nginx after that
shutdown completes, so by the time the `200` + `Gb-Auth-ID` reaches the
Game Boy, the session is already durable. The one function that would
break this is `fastcgi_finish_request()`, which ends the response early
and lets the script keep running; it appears nowhere in REON's web tree
(verified by grep on the local checkout, and by the person running the
production server, which is a separate tree — see the fixture note
above). Output buffering and the `files` session handler don't open a
window either, because the FPM decides when the request ends, not the
output flow.

So if an instrumented run ever shows a `401` on request 3, look at the
`Gb-Auth-ID` itself — missing, wrong, or a session already destroyed —
and not at how fast the ROM sent it.

One asymmetry to check first if session behaviour ever does get strange:
`serveFileOrExecScript()` calls `session_write_close()` only when it was
*not* given a session id, so the download path (type 1, which passes
one) leaves the close to shutdown while other paths close explicitly.
Safe for the same reason as above, but it is a real difference between
the two legs.

## Pacing: the TestSuite deliberately does not run flat out

Measured, not guessed. A millisecond-timestamped BGB capture of the
**real Mobile Trainer**, relayed by the person running the REON server:

| what | measured |
|---|---|
| between data blocks of one HTTP transfer | 389, 389, 391, 405, 418, 336 ms |
| idle polling after a transfer finished | 929–1067 ms, for 11 s |
| request split into three sends | +35 ms, +80 ms |

The first row is the important one: Mobile Trainer does **not** pull as
fast as the link allows. It takes a block, processes it, and only then
asks for the next. Both ROMs now wait ~400 ms between receive polls on
the HTTP paths (`TEST_PACING_RECV_FRAMES` / `MAGB_PACING_RECV_FRAMES`,
24 VBlanks), and both handle a zero setting as "no wait at all" so a
stress run can have the old behaviour back:

```sh
make CFLAGS_EXTRA='-DTEST_PACING_RECV_FRAMES=0'   # gbdk
```

Why a diagnostic ROM should care: running flat out exercises timing
paths no real client ever takes, and stops exercising the ones it does.

**Two places deliberately still run flat out**, and the reasons are
different:

- **SMTP/POP3 line receive.** The measurements above are of HTTP block
  transfers, and no comparable capture of a line-at-a-time protocol
  exists — pacing these would mean inventing a number, which is the
  opposite of what the HTTP pacing is. Running them flat out also has
  value of its own: REON had a race here (`+OK` for `PASS` emitted
  outside the callback that populates the maildrop, so a fast client got
  `STAT 0 0` on a full mailbox) that a paced client would never have
  reached. It has since been fixed upstream, but this TestSuite exists
  to validate any adapter or REON-compatible service rather than one
  server, and the fast regime is where that class of bug lives.
- **RAW TCP's live view.** It is an interactive window onto whatever
  someone types at `nc`, not a fidelity test; a one-second poll would
  make it feel broken. It stays at one frame.

Not reproduced here: Mobile Trainer's pre-connection ritual (short empty
sessions, EEPROM reads of varying length, multi-second gaps). That
changes what a test *is* rather than how fast it runs, and belongs in a
test of its own.

## What a real Mobile Trainer does before it dials (observed, not implemented)

The same timestamped BGB capture that gave the pacing numbers above also
shows **five** sessions before the connection, four of them throwaway:

```
22.019  Begin -> End                    (43 ms, empty session)
        ~2 s
24.115  Begin -> Read Config -> End     (249 ms)
        ~15 s
39.511  Begin -> End                    (21 ms, empty session)
        ~2 s
41.587  Begin -> Read Config -> End     (299 ms)
        ~2 s
43.991  Begin -> Read Config -> Status -> Call -> PPP -> DNS -> TCP -> HTTP
```

with the config read split differently each time — `0x80+0x40` in one
session, `0x60+0x60` in another, for the same 192 bytes.

This is recorded because it is a real observation about how a
commercial title drives the adapter, and the varying split in
particular is worth knowing: an adapter implementation that only ever
handles `0x60+0x60` would satisfy every request this TestSuite makes and
still be wrong.

**It is deliberately not implemented.** It was, briefly, and that was a
mistake worth writing down rather than quietly reverting. Reproducing
the sequence turned a timing reference into a behavioural feature: every
test grew a ~25 s prologue, and — worse — the primitives stopped being
primitives. A handshake test that performs four handshakes before the
one it measures is no longer a handshake test; when the handshake breaks
it fails inside the prologue and the result no longer says which one
broke. Diagnostic isolation is what those tests are for.

The capture was reference material for **rhythm**. What was actually
wanted from it is the pacing above: the TestSuite was running flat out
where a real client pauses. That is a property of how fast the tests
move, and it applies everywhere; the session sequence is a property of
one title's startup, and it belongs in this document rather than in the
ROMs.

## Wire-format numbers are built explicitly, not with sprintf

**Correction, recorded rather than quietly edited: the reasoning that
first justified this was wrong.**

The SMALL BUFFER POST went out seven bytes short, and the two numeric
conversions in `sprintf(..., "Content-Length: %u ... X-Test-Checksum:
%hx%hx ...")` happen to sum to exactly seven characters (`128` +
`1fc0`). That coincidence was taken as proof that SDCC had dropped both
conversions. It had not.

The seven bytes were the `s_bb_auth_header` overflow — the same one
that produced the corrupted `Authorization` header in "An
authentication bypass in REON's utility-auth cache" below. The intended
value is 121 characters and the buffer was 112, so the tail spilled into
`s_bb_auth_id`; writing `X-Test-User` ("34") there then put a NUL at
index 114, and `strlen` returned 114 instead of 121 — **seven short**.
Same number, entirely different cause.

`%u` and `%hx` work. The result screens prove it: `DL 8192 B OK` and
`MESSAGES: n` both print their numbers.

The explicit formatters in `magb_fmt.h` were kept anyway, because the
argument for them survives the correction being wrong:

- The wire format is now **tested** (`tests/host/test_fmt.c`), including
  the zero-padding cases (`0x0F00` must render `"0F00"`, never `"F00"`)
  that bite one checksum value in sixteen and would otherwise wait to
  fail confusingly much later.
- Both ROMs now emit uppercase hex, so they put identical bytes on the
  wire. They had disagreed, and only REON's `strtoupper()` hid it.

But they were a precaution, not the fix, and the note that said
otherwise would have sent the next reader hunting a compiler bug that
does not exist.
## The last send of a body must also receive

`test_isp_small_buffer()`'s upload failed with `NO HTTP/ PREFIX` for a
request the server had answered correctly. The BGB serial log shows why:

```
>>> 15 Transfer data (conn 0)     <- the 128-byte body
    00 01 02 ... 7F
<<< 15 Transfer data (conn 0)     <- the SAME exchange
    HTTP/1.1 200 OK ... X-Test-Checksum: 0000 ... 00
```

One Transfer Data both sends **and** receives. A server quick enough — a
small body to a server on the same machine — has its entire response
arrive bundled with the very send that completed the request. The send
discarded its output (`out_cap = 0`), so the response was lost, and the
poll that followed found only Transfer Data End.

This is the same bug `tcp_send_line()` had for the email tests, and the
general shape is worth remembering: **on this protocol every send is
also a receive, so any send that throws its output away can lose a whole
response** — and whether it does depends only on how fast the peer is.

The fix is narrow on purpose. `gb00_stream_request()` /
`BbStreamRequest` already send, receive and stream correctly, so the
*final* chunk of a body goes through them instead of through the
discarding raw send. Nothing else changed: intermediate chunks still
discard, which is safe because a server cannot answer before it has the
whole declared `Content-Length`.

An earlier attempt made *every* raw send accumulate into the shared
response buffer instead. That broke both ROMs and was reverted. It is
worth recording why, because the C and assembly versions failed
differently and only one was obvious: in the RGBDS version the new code
loaded `DE` with the accumulator offset to compute a receive cursor, and
`DE` **is** that routine's data-pointer argument — so it started sending
garbage. The lesson is not about that one register: widening a
low-level, register-constrained routine's responsibilities is a much
larger change than it looks, and the same fix expressed one layer up
(let the existing send-and-receive path handle the last chunk) carries
none of that risk.

## An authentication bypass in REON's utility-auth cache (found, then fixed)

Worth recording in full, because this TestSuite exists to validate
REON-compatible services and this is the first real defect it produced —
and because it was found *by accident*, through a bug of ours.

The GBDK ROM had a ten-byte buffer overflow that put a corrupted
`Authorization` header on the wire: the 92-character value truncated
mid-base64, its closing quote and CRLF overwritten. Plainly malformed.

`s_bb_auth_header` was `[16U + GB00_AUTHORIZATION_LEN + 4U]` = 112
bytes, and holds `Authorization: GB00 name="` (26) + 92 + `"` + CRLF +
NUL = 122. The `16` was a guess at the prefix length, which is 26. The
overflow ran into `s_bb_auth_id`, and `X-Test-User` ("34") written there
put a NUL at index 114 — which is also where the "seven missing bytes"
above came from (121 − 114). The size is now derived from the literals
with a compile-time assertion, verified by restoring the old 112 and
watching the build fail.

**The server answered `200` and reported the authenticated user.**

That is what made the client bug so hard to find — the failure surfaced
three layers later as a rejected upload — and it is also a defect in its
own right. `auth.php`'s type-2 (utility) path derived the session id
from `substr($authString, 0, 44)` and, on a cache hit inside the
15-minute window, returned the cached user id **before decoding or
validating the rest of the value**. Our truncation happened past
character 44, so the prefix still matched and the response half was
never checked.

The REON maintainer reproduced it directly: a legitimate handshake, then
the same request with everything after character 44 replaced by `A`.
`HTTP 200`.

The sharp edge is where those 44 characters come from. They are not the
client's secret — they are an echo of the challenge **the server itself
published in the 401**. Anyone who saw only the challenge response could
derive the session id without ever observing a client credential. The
protocol carries no encryption regardless, but this was a step *down*
from "replay a captured Authorization", which is what the code's own
comment implied.

Fixed upstream: the cache now stores a SHA-256 of the entire
`Authorization` value and compares it with `hash_equals`. A miss is not
a rejection — it falls through to full validation, so the legitimate
reuse the cache exists for still works. Verified end to end: challenge →
401, valid auth → 200, same auth repeated → 200, prefix-only → **401**
(was 200). Type 0 is unaffected and remains single-use.

**What this changes for the TestSuite.** A `401` on SMALL BUFFER's reuse
leg used to mean only "the 15-minute window expired". It can now also
mean "the Authorization we sent was wrong" — which is a gain, not an
ambiguity: the server's answer can finally detect client-side credential
corruption, which is precisely what it could not do while a truncated
header authenticated successfully.

### The regression test, and why it is not an adapter test

Both ROMs now carry **AUTH PREFIX**, which does deliberately what the
overflow did by accident: takes a valid `Authorization`, keeps the
44-character prefix, replaces everything after it, and requires the
server to refuse.

It lives under its own main-menu entry, **SERVER CONF**, not in the
ISP/HTTP submenu. That separation is the point. Every test in ISP/HTTP
passes when the adapter, libmobile and the link behave; this one passes
when the *server* is correctly configured, and it can fail while the
adapter is perfect. A red result whose meaning depends on which list it
came from is exactly the ambiguity this ROM exists to remove.

Three outcomes, deliberately distinguished:

| response | verdict |
| --- | --- |
| `200` | **FAIL, "BYPASS OPEN"** — this server lacks the fix |
| `401` + `Gb-Status` | **PASS** — full validation ran and rejected it |
| `401`, no `Gb-Status` | **FAIL, "CHALLENGE EXPIRED"** — inconclusive, nothing judged the credential |

`Gb-Status` is what is asserted on, not the bare `401`, because a 401
alone cannot tell a verdict from an expired challenge. Its value is
displayed rather than merely checked, so a server that someday answers a
different code shows up instead of being flattened into the same PASS.

Two implementation details that are easy to get wrong:

- The tail is destroyed by flipping each character between `A` and `B`,
  not by writing a fixed filler. A constant filler could in principle
  coincide with the real tail, and a negative test that silently sent a
  **valid** credential would pass while proving the opposite of what it
  claims. Both are base64 characters, so the value still decodes — to
  the wrong bytes. The length is unchanged, so the request is
  well-formed in every respect except the credential.
- "The server never challenged us" is reported as `NO CHALLENGE`, not as
  a bypass. An endpoint that serves without asking for authentication is
  a fixture problem; calling it a security finding would be a false
  alarm.

**Runtime-verified on both ROMs, 2026-09-08.** Both halves, on both
implementations. Each showed `PASS` / `GB-ST 201`, and the server log
for each of those requests recorded the prefix boolean as *matches —
corresponds to a challenge issued*:

```text
GBDK   14:58:18  GET  no Authorization                        -> 401
       14:58:19  GET  104 chars, 44-char prefix matches: YES  -> 401

RGBDS  15:00:59  GET  no Authorization                        -> 401
       15:01:00  GET  104 chars, 44-char prefix matches: YES  -> 401
```

That is case 1 of the table above — the only one in which the test
proves what it claims. Neither landed on the middle case, *no challenge
with that id*, which is the signature of an offset spilling into the
prefix. And that is the point of running both: the two compute the
offset independently (C indexes into the built header string, the
assembly overwrites `wGb00Authorization` in place), so agreement here is
two implementations confirming the same fact, not one confirming itself.

The contrapositive ran a minute earlier in each session: SMALL BUFFER
sent the *undamaged* value from the same builder — prefix matches AND
tail valid — and got `200` on both its GET and its POST, the cache-reuse
leg working on real traffic. Same builder, same session, differing only
in the tail. That is what closes the inference.

### Why the forged tail reads as almost all `A`

Both logs showed the tail ending `AAAAAAAAAAA"`, which looks like a
fixed filler — the very thing this deliberately avoids. It isn't, and
the distinction is worth writing down because the log will keep looking
like this.

The transform is `c = (c == 'A') ? 'B' : 'A'` per character. It does not
map everything to one symbol: every character that was not `A` becomes
`A`, and every character that *was* `A` becomes `B`. Since a base64
character is `A` about one time in 64, the result is mostly `A` **by
construction**, with a `B` wherever the original had one.

What matters is the property, and it holds: *every position differs from
its original*, so the tail as a whole cannot coincide with the valid
one — which a constant filler could, in principle. Checked on the host
against a realistic tail, an all-`A` tail (which becomes all-`B`) and an
alternating one: zero positions unchanged in every case. The all-`A`
decode is 36 zero bytes — structurally valid base64 of the right length,
so the server rejects it by comparison, not by failing to parse it.
That, too, is required: a rejection at a parse step would be the wrong
reason again.

#### The way this test could pass while proving nothing

Worth stating plainly, because it is not obvious and it is the only
thing that would make a PASS worthless.

The test is only meaningful if the 44-character prefix it sends is
**correct** and only the tail is wrong. If an offset were miscomputed
and the corruption spilled into the prefix, the server would reject the
request anyway — the damaged prefix misses the cache, full validation
runs, and the answer is the same `401 + Gb-Status: 201`. **The test
would report PASS without ever exercising the case the fix is about.**

Today the prefix is correct by construction (both ROMs build the whole
value with the real challenge, then overwrite from
`GB00_AUTH_PREFIX_LEN` onward) and, indirectly, by SMALL BUFFER passing
in the same period — SMALL BUFFER sends the *undamaged* value from the
same builder and gets a 200, which is what says the builder and the
offsets are right. Neither is an independent check inside this test.

Two ways to close it:

1. **Server-side — done, REON `224b47c`.** REON logs only the last 12
   characters of an `Authorization` deliberately, so the prefix never
   reaches the log. Instead it now logs a boolean per request: does the
   44-character prefix correspond to a challenge this server issued?
   `auth.php` already derives the PHP session id from exactly those 44
   characters, so the existence of that session file answers the
   question without storing or comparing any value. Three outcomes:
   matches; no challenge with that id; the 44 characters don't decode to
   32 bytes at all.
2. **Client-side, one extra request — not done.** Send the valid
   Authorization first and require 200, then the damaged one and require
   401, in the same session. Self-proving, needs no server help, and it
   is where this test should end up. It costs one more request and about
   60-80 bytes the GBDK build does not have (see the Makefile: 23 bytes
   free below `0x8000`). When that happens the server-side boolean
   becomes redundant, which is the right fate for instrumentation.

**The verification is the interesting part.** The maintainer ran all
three cases against the live server, and *all three answered an
identical `401`*:

| what was sent | HTTP | prefix boolean |
| --- | --- | --- |
| correct prefix, wrong tail | 401 | matches |
| prefix with one byte changed | 401 | no challenge with that id |
| prefix that doesn't decode to 32 bytes | 401 | doesn't decode |

The middle row is the realistic one, and the reason this mattered: a
wrong offset would produce still-valid base64 of the right length that
simply isn't the challenge. From the ROM's side those three are
indistinguishable — same status, same `Gb-Status`. **A negative test
cannot tell "rejected for the reason I intended" from "rejected for a
reason I caused" using only the response**, unless something outside the
response says which. That is the general lesson, not a REON detail:
when you assert that a server refuses something, make sure you can also
show it refused it for your reason.

Until the client-side version exists, read a PASS as "this server
rejected a credential whose tail was wrong" plus, from the server log,
"and the prefix was genuinely a challenge it issued".

### The three kinds of 401

They are not ambiguous on the wire, but there are **three**, not two —
and the third is easy to miss because it lives outside `doAuth`'s
authentication block:

| response | meaning |
|---|---|
| `401` + `Gb-Status: 201` | the challenge existed and the credential did **not** match — the verdict |
| `401` + `WWW-Authenticate:` | the challenge session is gone; not a verdict at all, but a fresh challenge inviting a new handshake |
| `401` + **neither header** | the request carried a `Gb-Auth-ID` and the session it names is dead |
| `200` | the window expired but the Authorization was intact — full revalidation passed and the request simply succeeded |

The third comes from the `Gb-Auth-ID` validation that runs *after* the
authentication block: `header_remove(); http_response_code(401);
exit();`. It is reachable only on a request that carries that header —
`doAuth` enters its authentication block **only when `Gb-Auth-ID` is
absent** — which makes the disambiguation free:

| what the ROM sent | `401` without `Gb-Status` means |
|---|---|
| `Authorization` | the challenge expired; redo the handshake |
| `Gb-Auth-ID` | that session died; the credential and challenge are not implicated |

So the ROM's own request state settles it, and only `Gb-Status` ever
needs reading — which matters, because `WWW-Authenticate`'s value is ~57
characters and both ROMs' token readers *refuse* an over-long value
rather than truncating it. Branching on that header would have
misclassified every time.

Both ROMs report `AUTH REJECTED (201)`, `CHALLENGE EXPIRED` (the
`Authorization` legs) or `AUTH ID REJECTED` (the upload's third
request). The last one matters most: without it a dead session on the
upload reads as `UPLOAD MISMATCH`, pointing at a payload the server
never read — and that is exactly the request where this project's own
bug lived.

A negative test — deliberately send a prefix-only Authorization and
require a 401 — would pin this as a regression test for any
REON-compatible server. Not implemented; it is a real change in what the
suite does and belongs to a deliberate decision, not a drive-by.

## REON stores mail subjects capped at 10 characters

Observed on the wire, not documented anywhere, and it silently broke the
EMAIL RECV test's cleanup for its entire life.

`TOP n 0` on a mailbox that had accumulated this test's own messages
returned:

```
Subject: MAGB Te...
```

for a message this TestSuite had sent as `Subject: MAGB TestSuite`. Every
other subject in that mailbox longer than ten characters was cut the same
way (`Este as...`, `Acentua...`, `Re: Hel...`), while shorter ones
(`Teste 01`, `Oi`, `Enviado A`) came back intact. So the rule is: ten
characters, with the last three replaced by `...` when the original was
longer.

`delete_matching_test_emails()` looked for the full 23-character
`Subject: MAGB TestSuite` and therefore never matched anything. It had
never deleted a single message — the mailbox reached twenty accumulated
test emails before anyone noticed, because "nothing to delete" and
"nothing matched" printed the same screen.

Two changes, and the split between them matters:

- **What is sent** is now `MAGB TEST`, nine characters, so it fits inside
  the cap and survives the round trip byte for byte. A test that cannot
  recognise its own output is not much of a test.
- **What is matched** is the shorter prefix `Subject: MAGB`, which also
  recognises the truncated `MAGB Te...` that earlier runs left behind.
  Without that the test could never clean up the mailbox it filled.

### Where it comes from

Confirmed by the REON maintainer: `mail/pop3Connection.js`,
`SUBJECT_MAX_CHARS = 10` with `SUBJECT_ELLIPSIS = "..."` counted *inside*
the ten. It is deliberate, and specified by the project owner.

Two details worth knowing:

- **It is not stored truncated.** `sys_inbox.message` keeps the whole
  message with the original subject; the cut is applied while building
  the view delivered over POP3 (`TOP` and `RETR`). The webmail still
  shows the full subject. So what a Game Boy sees through `TOP` is a
  *projection for the game*, not what is on disk — which matters if you
  ever compare the two and think one of them is corrupt.
- **The cut counts codepoints, not bytes** (`Array.from(text)` then
  `slice`). That is not fussiness: a JIS subject is multibyte, and
  cutting by byte would split a character and leave a dangling escape
  sequence — a malformed header that a 2001-era parser has no way to
  defend against. If you implement this yourself, cut on characters.

**There are two different limits, and confusing them cost a round trip
of questions.** Settled directly with the project owner:

| limit | whose | applies to |
|---|---|---|
| 10 characters | REON's, in `pop3Connection.js` | the **subject**, on delivery to the game. Mobile Trainer does receive the shortened title. |
| 12 characters per line | Mobile Trainer's own | how it wraps the message **body**. It handles this itself. |

The cap stays — it is the owner's own requirement, not an accident. An
earlier draft of this note said the truncation "does not affect Mobile
Trainer"; that was about the body wrap, not the subject.

### Only some headers reach the game at all

Volunteered by the maintainer, and it closes off an obvious alternative
design before anyone spends a day on it. The view built for the game
keeps exactly these headers and discards the rest:

```
MIME-Version, From, To, Subject, X-Game-title, X-Game-code
(+ Content-Type, which is generated)
```

So tagging a message with a custom header — `X-Test-Id:` or similar — to
recognise it later **does not work**: the header never arrives. Matching
on the subject is not a shortcut here, it is the only channel that
survives, which is why getting the truncation right matters as much as
it does.

`DELE` is also a soft delete: messages get `deleted_at` set and move to a
30-day trash rather than vanishing. Worth knowing before writing a test
that deletes: a matching rule that turns out too broad is recoverable.

### Message numbers are positions, so the listing's order is protocol

POP3 addresses messages by number — `TOP n`, `RETR n`, `DELE n` — and
those numbers are just positions in the maildrop listing. RFC 1939
requires them to stay fixed for the whole session, which is why `DELE`
only *marks* and renumbering happens at `QUIT`.

That makes the server's ordering a protocol-visible decision, and REON's
query had no `ORDER BY`: the numbering was whatever order the optimizer's
chosen index produced. It happened to give arrival order, so it looked
correct. Had the planner switched to the `(recipient, read_at)` index,
reading a message in the webmail could have renumbered the mailbox
between one sync and the next — and a client that had just scanned
headers would then delete a different message than the one it matched.

Fixed upstream with an explicit arrival-order sort. Nothing about the
observed behaviour changed; it stopped being luck. If you implement a
POP3 server for a Game Boy client, order the listing explicitly.

### The general lesson

**A test that recognises its own artifacts by an exact string is betting
that nothing between here and storage rewrites it.** Mail systems rewrite headers
routinely — folding, re-encoding, capping. Match a prefix you have
actually seen come back, and prefer sending something short enough that
there is nothing to rewrite.

## Outbound mail is gated by device-auth, and that gate is broken upstream

**Relayed 2026-09-08 by the session running the REON server, traced by
the session running mGBA. Not reproduced or verified from this
repository** — recorded here because it changes how to read an email
failure today, not because this ROM implements any part of it.

REON gates outbound mail (a message actually leaving REON for a real
external mailbox) behind a device-authorization endpoint: libmobile
tells REON `authorize` when a device starts using mail and
`deauthorize` when it is done, and Postfix refuses to relay for a
device sitting at `authorized=0`.

The reported defect is an ordering one inside libmobile. The
`authorize` event is *generated* mid-PPP-session, but the gate that
dispatches those events only opens when the session goes idle. The
`deauthorize` from the disconnect overwrites the still-pending
`authorize` before it is ever sent. The server-side signature is
unambiguous: 18 `deauthorize` and zero `authorize` in one day, every
device stuck at `authorized=0`, and Postfix rejecting with 554.

**What this means for this TestSuite's EMAIL SEND, precisely:** the
test passes, and that is not a contradiction. It sends to the address
in the adapter's own configuration — a REON-internal delivery, which
never reaches the Postfix relay path this gate protects. A test that
sent to an external address would fail today, and would fail for a
reason that is neither in this ROM nor in REON's mail server.

So: **do not treat a 554 on external mail as a TestSuite bug** while
this is open. Check whether `authorize` ever arrived server-side
before looking anywhere else.

Related but distinct, and already fixed: a pending device-auth event
could also starve behind a freshly started relay number-fetch, since
both share one socket buffer (libmobile `935aec7`, mutual-exclusion
gating in `mobile_actions_get()`). Same subsystem, different failure —
don't assume one fix covers the other.

A third, found server-side once the first was repaired (REON
`dd65168`): a `deauthorize` arriving with the **same** counter as the
last `authorize` was swallowed as an idempotent replay — 200 returned,
device left authorized. Revocation failing silently. Now a revocation is
honoured at an equal counter, while `authorize` still requires a
strictly greater one.

Three bugs in one subsystem, each exposed by fixing the one before it,
is itself the note worth keeping: anti-replay rules that treat every
message the same way get the asymmetry wrong. Granting access and
withdrawing it do not deserve equal suspicion — the failure modes are
not symmetric, and the safe default for a revocation is to honour it.
