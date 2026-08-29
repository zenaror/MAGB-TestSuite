# RGBDS implementation status

This is a **from-scratch, hand-written SM83 assembly** implementation of
the Mobile Adapter GB TestSuite, living alongside the working
[`gbdk/`](../../gbdk/) C implementation (see the repo root `README.md`).
It is not at feature parity yet -- treat anything not listed below as
not implemented.

## What exists so far

- **Toolchain / build**: `Makefile` (RGBDS `rgbasm`/`rgblink`/`rgbfix`,
  discovered on `PATH` or overridable, same pattern as `gbdk/Makefile`'s
  `GBDK_HOME`). Builds a CGB-only (`0x143 = 0xC0`), no-mapper (cartridge
  type `0x00`), 32 KiB ROM: `build/mobile_adapter_testsuite_rgbds.gbc`,
  copied to the shared `../emulador/` if present (deliberately a
  *different* filename than the GBDK build's, since both share that
  directory).
- **Hardware serial layer** (`src/hw/serial.asm`): `SerialTransferByte`
  (one byte over the link port, GBC high-speed internal-clock mode, with
  a bounded busy-wait timeout), `SerialHwInit` (refuses to continue on
  non-CGB hardware, switches to CGB double speed, enables the VBlank
  interrupt), and `SerialNow`/`SerialElapsedFrames` (a free-running
  ~59.7 Hz frame counter, incremented by a VBlank ISR -- the RGBDS
  equivalent of `gbdk`'s `sys_time`/`serial_now()`/
  `serial_elapsed_frames()`). A faithful port of
  `gbdk/src/hw/serial_hw.c`, including the hard-won two-step `SC`
  register write (see `include/hardware.inc`'s comment, and
  `gbdk/docs/journal.md`'s "Handshake / sessão inicial" for why that
  matters).
- **Packet framing layer** (`src/protocol/packet.asm`): `ComputeChecksum`
  (16-bit unsigned sum) and the generic `BuildRequestFrame` (command +
  payload pointer + payload length -> a full frame in `wPacketBuffer`,
  bounds-checked against `PROTO_MAX_PAYLOAD_LEN`). Building Begin
  Session's request through it produces the exact repo-root-`CLAUDE.md`
  "Known Serialization Test" vector -- hand-verified before trusting the
  routine.
- **Session/ACK protocol layer** (`src/protocol/session.asm`):
  `MagbExecute` -- the assembly equivalent of
  `gbdk/src/protocol/magb_session.c`'s `magb_execute()` (request ->
  request-ACK phase, tolerating the adapter's `0xD2`/relay-latency
  quirks the same way the C version does -> wait for response start ->
  read+checksum-validate the response -> response-ACK phase, with the
  same `MAGB_MAX_RETRANSMIT`-bounded retry loops in both directions,
  and the centralized Error Status `0x6E` recognition). Every other
  command wrapper below is built on top of this one function. Live
  status notifications (which phase of a command is in flight) go
  through an optional callback (`MagbProtocolInit`/
  `MagbSetStatusCallback`, defaulting to "no callback") rather than a
  direct call into this TestSuite's own UI code -- see
  `docs/integration-guide.md` for why: it's what lets `src/hw/`+
  `src/protocol/` be copied into someone else's homebrew without also
  forcing them to define a UI function just to satisfy the linker.
- **Text renderer** (`src/app/text.asm`): an 8x8 monospace font (ASCII
  `$20`-`$5F`; the bitmap is a 1bpp rasterization of a system monospace
  typeface, generated locally, not a copied font file), `LoadFont`, and
  `PrintString` (null-terminated string -> BG tilemap, no
  wrapping/scrolling). `main.asm`'s `SetCommand`/`SetStatus` call into
  this from `session.asm` at each protocol stage, so a hang shows
  exactly where it's stuck, as text.
- **Command wrappers** (`src/protocol/session.asm`, each a thin
  `MagbExecute` wrapper matching its `gbdk/src/protocol/magb_network.c`
  counterpart's payload shape and response validation):
  - `MagbBeginSession` / `MagbEndSession` (`0x10`/`0x11`)
  - `MagbDial` / `MagbHangup` (`0x12`/`0x13`) -- Dial builds
    [validation_byte, ...digits], the validation byte per-adapter-type
    (Blue `0x00`, else `0x01`) via `ctx->adapter_device`
  - `MagbIspLogin` / `MagbIspLogout` (`0x21`/`0x22`) -- Login takes a
    pre-built payload (caller assembles login_len+login+password_len+
    password+dns1[4]+dns2[4]); on success fills `wIspAssignedIp` (12
    bytes: assigned IP / DNS1 / DNS2)
  - `MagbDnsQuery` (`0x28`) -- hostname is the raw payload, no
    length-prefix (matches libmobile's `command_dns_request_begin()`);
    fills `wDnsResultIp` (4 bytes) on success
  - `MagbTcpOpen` / `MagbTcpClose` (`0x23`/`0x24`) -- Open takes an
    IP pointer + port, fills `wTcpConnId` on success; Close reads
    `wTcpConnId` directly (this ROM only ever has one connection open
    at a time so far, so no connection-id parameter yet)
  - `MagbTransferData` (`0x15`) -- sends up to `PROTO_MAX_PAYLOAD_LEN - 1`
    bytes over the connection `MagbTcpOpen` opened (reads `wTcpConnId`
    directly, same simplification as `MagbTcpClose`) and copies whatever
    the adapter sends back into the caller's output buffer, clamped to
    its capacity; a zero-length send is how a caller polls for more
    incoming data. Recognizes Transfer Data End (`0x1F | 0x80`) and
    reports it via `[wXferRemoteClosed]`, matching
    `gbdk/src/protocol/magb_network.c`'s `magb_transfer_data()` --
    including that a received response is *not* necessarily an echo of
    what was just sent.

`src/main.asm` runs the full sequence: Begin Session -> Dial (`#9677`,
the real DION PDC ISP number) -> ISP Login (`test`/`test`, `0.0.0.0`/
`0.0.0.0` DNS -- same fallback values as `gbdk/include/test_config.h`;
libmobile's PPP login handler doesn't check credentials against a real
account, so this is valid regardless) -> DNS Query
(`gameboy.datacenter.ne.jp`, the real historical Mobile System GB
datacenter host) -> TCP Open (port 80) -> **HTTP GET** (see below) ->
TCP Close -> ISP Logout -> Hang Up -> End Session, printing which
command is running, which stage within it, and on failure which
`MAGB_ERR_*` -- all as readable text. Stops at the first failing
command rather than attempting best-effort cleanup (see "Known
simplifications" below).

### HTTP GET (`src/main.asm`'s `HttpFetch`/`HttpShowResult`)

The last piece needed for a genuine RGBDS equivalent of the GBDK side's
Test 2, ported from `gbdk/src/app/test_runner.c`'s `test_isp_http()`:

- Sends the same real HTTP/1.0 GET request gbdk sends (`TEST_HTTP_PATH`
  against `TEST_HTTP_HOST` -- the real "Mystery Egg" metadata file, 148
  bytes including headers, built as `db` literals with explicit
  `$0D,$0A` bytes rather than a `"\r\n"` string escape, since RGBDS
  string literals don't uniformly support `\r`).
- Polls `MagbTransferData` with zero-length sends until Transfer Data
  End arrives, a 240-byte response buffer (`HTTP_RESP_BUF_SIZE`, same
  as gbdk's) fills, a 8192-byte total-received safety cap is hit
  (`HTTP_MAX_TOTAL_BYTES`), or 5 consecutive empty polls suggest the
  peer stalled (`HTTP_MAX_EMPTY_POLLS`) -- same bounds as gbdk's.
- A transport-level failure (any `MagbTransferData` call returning
  non-OK) is a normal `MAGB_ERR_*` failure, shown through
  `PrintErrorCode` like every other command.
- A response that doesn't start with `"HTTP/"` is explicitly **not**
  a failure -- exactly matching gbdk's `out->result = MAGB_OK` in that
  case -- since the transport worked; this ROM shows `"NO HTTP PREFIX"`
  on row 5 and continues on to TCP Close/cleanup regardless.
- On a recognizable HTTP response, extracts the 3-digit status code at
  response offset 9 (same offset gbdk uses, e.g. the `"200"` in
  `"HTTP/1.0 200 OK"`) and shows `"HTTP 200"` (or similar) on row 5.
- Does **not** yet show the exact received byte count on screen (gbdk's
  `"RX TOTAL %u B"`) -- would need a 16-bit-to-decimal routine this ROM
  doesn't have yet; deferred as a display-only simplification, not a
  protocol gap.

## Confirmed working

- **Begin Session / End Session** (2026-08-28): a full PASS reproduced
  in mGBA (built-in Mobile Adapter GB responder, `config.ini`'s
  `mobileAdapterEnabled=1`) and independently verified byte-for-byte
  correct by reading WRAM directly. `mobileAdapterEnabled=0` (bare key,
  no `sio.` prefix) confirmed to flip the same build to a correct FAIL,
  matching PyBoy and BGB with nothing linked -- both directions
  verified.
- **Dial / ISP Login / DNS / TCP Open+Close / ISP Logout / Transfer
  Data+HTTP GET**: reviewed function-by-function with the same
  manual-trace rigor that caught real register-clobbering bugs in the
  session layer (see "Hard-won bugs"); no bugs found on review.
  Confirmed to still fail cleanly (readable text, no display corruption,
  no regression -- verified via a PyBoy screen capture showing the exact
  same "SESSION / WAKE / RESULT: FAIL / TIMEOUT" text as before this
  milestone) against PyBoy and BGB with nothing linked -- these commands
  are never reached in that environment since Begin Session itself fails
  first there. **Not yet confirmed to PASS against any real responder**
  -- the local same-machine peer session that ran the earlier mGBA
  PASS confirmation is no longer available this session (not listed by
  `ListAgents`, and no local `mgba`/`mgba-qt` binary is installed on
  this machine either), so that confirmation is deferred to the project
  owner's own manual testing (see repo-root `CLAUDE.md`'s Responsibility
  Boundary) -- `~/.config/mgba/config.ini` still has
  `mobileAdapterEnabled=1` left over from the earlier session, so a
  local mGBA run (once installed) or the project owner's own
  environment should work without extra setup.

## Hard-won bugs (worth reading before touching this code again)

- **LCDC tile-data-select bit.** The text renderer's very first attempt
  built and ran but showed a totally blank white screen. `LoadFont`
  copies tiles to `$8000` (unsigned addressing), but nothing set LCDC
  bit 4 (`LCDC_BG_TILEDATA` in `hardware.inc`) -- without it the PPU
  reads BG tiles from `$9000` with *signed* addressing instead, so
  every tile index the tilemap referenced pointed at the wrong,
  never-written VRAM. Every LCDC-enabling write in this codebase must
  include this bit whenever the BG is on.
- **"Fill with a constant" loops that check-after-write instead of
  check-before-write.** `FillMemory` (main.asm) and `ClearTextScreen`
  (text.asm) both originally wrote `A` to `[hl+]`, then reused `A` as
  scratch for the `BC == 0` test *after* the write, before looping back
  to write `A` again -- so only the very first byte was ever actually
  the intended constant (0); every byte after that was leftover bits of
  the countdown counter. This silently broke clearing the screen
  entirely, and looked exactly like a string printed without a null
  terminator (confirmed innocent by instrumenting `PrintString` with an
  iteration counter; the real culprit was found by reading a tilemap
  row neither function should have touched at all and finding it
  non-zero too). Both loops now check `BC == 0` *before* each write and
  set `A` fresh every iteration.

- **8-bit overflow in `BuildRequestFrame`'s length arithmetic.** Raising
  `PROTO_MAX_PAYLOAD_LEN` from 80 towards the protocol's real 254-byte
  max (needed for the HTTP GET request/response) exposed two places
  where `packet.asm`'s `BuildRequestFrame` summed an 8-bit payload
  length with a small constant using an 8-bit `add`: the checksum range
  (`payload_len + 4`, wraps to 2 once `payload_len > 251`, silently
  corrupting the checksum) and the total frame length returned to the
  caller (`PROTO_FRAME_OVERHEAD(8) + payload_len`, doesn't fit in 8 bits
  once `payload_len > 247`). Neither had ever been exercised above
  ISP Login's ~74-byte worst case before, so both went unnoticed until
  this milestone. Fixed by doing both sums in 16-bit `BC` instead, and
  updating `SendRequestFrame`'s transmit-loop counter (`session.asm`) to
  match `BuildRequestFrame`'s new `BC`-length output.

## Known simplifications

- On a failing command, this ROM stops immediately rather than
  attempting best-effort Hang Up/End Session cleanup (e.g. a failed
  Dial doesn't get an End Session sent afterward). `gbdk`'s test runner
  does attempt that cleanup; this port doesn't yet. Real hardware's own
  session should still self-recover via its own idle-session timeout
  either way (see `gbdk/docs/journal.md`'s MOBILE_TIMER_SERIAL note) --
  not a resource leak, just a slower recovery.
- `MagbDial`/`MagbTcpOpen` don't bounds-check their digit-count/length
  inputs against `MAGB_MAX_PHONE_NUMBER_LEN` -- safe today since every
  call site in `main.asm` passes a fixed, known-safe compile-time
  length, but worth adding an explicit check before any caller passes a
  runtime-computed length.

## What's explicitly NOT implemented yet

- Best-effort cleanup (Hang Up/End Session, or here also TCP Close/ISP
  Logout) after an earlier command in the sequence fails -- see "Known
  simplifications" below; gbdk's `isp_http_cleanup()` has no RGBDS
  equivalent yet.
- Showing the exact received HTTP byte count on screen (gbdk's
  `"RX TOTAL %u B"`) -- would need a 16-bit-to-decimal display routine;
  purely cosmetic, not a protocol gap.
- A protocol trace ring buffer (the GBDK side's SELECT-button TX/RX
  history).
- P2P, menu, config screen, GB00 auth, email -- the rest of
  `gbdk/src/app/`'s test surface.
- Lowercase letters and most punctuation beyond what's in the font
  (`$20`-`$5F` only).

## Suggested next milestone

With Test 2's full command sequence now ported (Begin Session -> Dial
-> ISP Login -> DNS -> TCP Open -> HTTP GET -> TCP Close -> ISP Logout
-> Hang Up -> End Session), reasonable next steps are: (1) best-effort
cleanup on a mid-sequence failure, for closer parity with gbdk's
`isp_http_cleanup()`; (2) the protocol trace ring buffer; or (3)
starting on Test 3 (P2P Caller/Listener). Whichever is picked, get a
real PASS confirmation for the current HTTP GET milestone first (see
"Confirmed working" above) before building further on top of it.

## Manual verification status

Built (`make`), header validated (`0x143 = 0xC0`, `0x147 = 0x00`, 32768
bytes). Per this repo's `CLAUDE.md` Responsibility Boundary (the
project owner's step):

- Confirm it shows **RESULT: PASS** through the full sequence against
  PicoAdapterGB / real hardware, and/or BGB + `libmobile-bgb`.
- If it shows **RESULT: FAIL** unexpectedly, report exactly which
  command line and which stage/error text are showing -- that's the
  whole point of the text-renderer milestone, and should make
  root-causing a real failure much faster than a color-only build
  could. A link-level trace from the adapter side for that exchange
  remains the most useful thing to pair it with, the same way earlier
  GBDK bugs got root-caused (see `gbdk/docs/journal.md`).
