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
  exactly where it's stuck, as text. Also `PrintHexByte` (a byte as two
  uppercase hex digits -- the RGBDS-side equivalent of gbdk's
  `printf("%hx", ...)`, used by the adapter-id readout below).
- **Joypad** (`src/hw/joypad.asm`): `ReadJoypad` (all 8 buttons in one
  call, standard GBC two-group-multiplexed read) and `ReadJoypadPressed`
  (edge-triggered -- only newly-pressed buttons, with its own small
  WRAM debounce state), the RGBDS-side equivalent of gbdk's
  `wait_key_edge()`.
- **Main menu** (`main.asm`'s `ShowMenu`/`DrawMenu`/`DrawMenuCursor`):
  a real joypad-driven menu matching `gbdk/src/app/ui.c`'s
  `ui_main_menu()` shell exactly -- same 6 items, same order, same
  wording ("ADAPTER/SESSION", "READ CONFIG", "ISP PASSWORD", "ISP/HTTP",
  "P2P CALLER", "P2P LISTENER"), same title/footer layout
  ("MOBILE ADAPTER GB" / "TESTSUITE", "A:RUN SEL:TRACE"). UP/DOWN moves
  the cursor (wrapping), A runs the selected item, B returns from a
  finished result screen, SELECT opens a real protocol trace viewer
  (`ShowTrace`, below). Selection persists across a round trip into a
  test and back, matching gbdk's `static uint8_t sel`. Every item on
  the menu is now real (no "NOT IMPLEMENTED" stubs left):
  - **ADAPTER/SESSION** (`RunAdapterSessionTest`, Test 1): Begin
    Session -> capture+show the adapter device id -> End Session
    (best-effort, result discarded). Mirrors gbdk's
    `test_adapter_session()` output text exactly: "ADAPTER ID: `<hex>`"
    / "NINTENDO ECHO OK" on success.
  - **ISP/HTTP** (`RunIspHttpMenu`/`ShowIspSubMenu`, Test 2): opens the
    same 7-item submenu gbdk's `ui_select_submenu()`/`kIspLabels[]` does
    (same wording/order: Tamago Egg, News Config, News Article, Trainer
    Home, Email Send, Email Recv, Raw TCP(NC)) -- title row 0, items
    starting row 2, "A:RUN B:BACK" footer, selection resets to item 0
    every time it's entered (unlike the main menu's persisted
    selection), B returns to the main menu. Tamago Egg and Trainer Home
    both run the real full Begin Session -> Read Identity -> Dial ->
    ISP Login -> DNS -> TCP Open -> HTTP GET -> TCP Close -> ISP Logout
    -> Hang Up -> End Session sequence via the shared `RunIspHttpCore`
    (see below); the other 5 entries show the same honest "NOT
    IMPLEMENTED" screen every other unimplemented item on this side
    uses.
  - **READ CONFIG** (`RunReadConfigTest`): Begin Session -> Read
    Configuration Data (both 96-byte halves, `MagbReadConfig`,
    `session.asm`) -> verify the blob's own trailing checksum -> End
    Session (best-effort). On success, opens a paged field-by-field
    viewer (`ShowConfigScreen`/`DrawConfigPage0`/`1`/`2`, `main.asm`)
    instead of a plain PASS line -- same 3 pages, same fields, same
    offsets as gbdk's `ui_show_config()` (session/network+DNS+login id+
    checksum, mail, ISP dial slot 1), LEFT/RIGHT to change page. Slot
    1's phone number is BCD-decoded (`MagbConfigDecodePhone`,
    `config.asm`, same algorithm as gbdk's
    `magb_config_decode_phone()`). Verified by injecting a synthetic
    config blob directly into `wConfigData` via PyBoy (redirecting the
    CPU's PC into `ShowConfigScreen` directly, bypassing the need for a
    real adapter response) and reading the rendered tilemap back -- all
    3 pages, the dotted-quad DNS addresses, the BCD phone decode, and
    the page-wrap all came out byte-correct. Login id/email/SMTP/POP
    are real free-text fields that commonly contain lowercase ASCII in
    practice -- this originally rendered as mostly dots (the font had
    no lowercase at all at the time); see "Hard-won bugs"' lowercase
    font entry for how that was found and fixed, and reran the same
    synthetic-blob PyBoy check afterward to confirm real lowercase text
    (e.g. `"test@example.com"`) renders correctly now instead of dots.
- **ISP PASSWORD** (`RunIspPasswordEdit`/`EditText`, `main.asm`): a
  real in-place text editor for the ISP account password
  (`wIspPassword`, starts empty, capped at `ISP_PASSWORD_MAX_LEN`(8) --
  matches gbdk's `TEST_ISP_PASSWORD_MAX_LEN`), the RGBDS-side
  equivalent of gbdk's `ui_edit_text()`. LEFT/RIGHT moves the cursor,
  UP/DOWN cycles the character under it, A saves (trailing spaces
  trimmed), B cancels without saving. Charset is gbdk's exact
  space+lowercase+uppercase+digits (`sTextCharset`) -- initially shipped
  as space+uppercase+digits only, before the font had lowercase; see
  "Hard-won bugs". Only remaining real difference from gbdk: no
  held-direction auto-repeat (gbdk's `wait_key_repeat()`) -- one press
  moves/cycles one step. Verified by editing a value, saving, and
  reading `wIspPassword`
  back from WRAM directly (`"B"`, trailing spaces correctly trimmed),
  and separately that a cancelled edit leaves the previously-saved
  value untouched. Nothing on this side reads the password yet -- no
  GB00-authenticated test (News/Email/Trainer Home) has been ported
  here -- so this is a real, functional editor without a consumer yet,
  the same shape gbdk's own UI_MENU_ISP_PASSWORD case has before any
  GB00 test runs.
- **P2P CALLER / P2P LISTENER** (Test 3 -- `RunP2pCaller`/
  `RunP2pListener`, `main.asm`): a real, working port of gbdk's
  `test_p2p_caller()`/`test_p2p_listener()`, including the MATS payload
  framing ("magic 'MATS' + version + sequence + length", carried inside
  Transfer Data payloads on the P2P connection id `0xFF`
  (`MAGB_P2P_CONNECTION_ID`) -- this TestSuite's own convention, not
  part of the Mobile Adapter protocol, but byte-identical to gbdk's own
  `mats_build()`/`mats_parse()` so a gbdk-built ROM and this one can
  talk P2P to each other) and the exact same test sequence: Begin
  Session -> Dial (Caller) or Wait For Telephone Call, `0x14`
  (Listener) -> PING/PONG -> an 8-byte binary pattern
  (`00 01 55 AA FE FF 10 EF`, covering all-zero/all-one-bit and
  alternating-bit edge cases) -> a "HELLO WORLD" round trip (adds no
  new protocol coverage, just a human-readable on-screen confirmation)
  -> Hang Up -> End Session (best-effort, matching gbdk's
  `p2p_cleanup()`).
  - **P2P CALLER** first opens a real number editor (`EditNumber`,
    below) pre-filled with gbdk's `TEST_P2P_PHONE` default
    (`127000000001`, a loopback-style direct-IP address); B here
    cancels back to the menu without dialing at all.
  - Three real, hard-won protocol lessons ported faithfully from gbdk
    rather than re-derived, each backed by that file's own comment
    citing a real two-machine BGB session: (1) Dial for P2P needs a
    longer timeout than an ISP dial (`MAGB_TIMEOUT_FRAMES_P2P_CALL`,
    ~25s, vs `_LONG`'s ~15s); (2) Wait For Call only waits ~1s
    internally before an Error Status meaning "no call yet", so the
    Listener retries it itself, up to `P2P_WAIT_CALL_MAX_ATTEMPTS`(20)
    times; (3) once a P2P link is established, `P2pRecvFrame`'s poll
    loop is deliberately **unbounded** except for a B-to-cancel check
    -- two independently-run peer instances do not reach each protocol
    step in lockstep, and gbdk's own history shows that giving up too
    early on one side tears the connection down under whichever side
    is still waiting, surfacing as a real adapter Error Status on the
    *other* side instead of a clean timeout on this one. `MagbDial` and
    `MagbTransferData` (`session.asm`) both changed from a hardcoded
    internal timeout to reading `[wExecTimeoutFrames]` (caller-set) to
    make this possible -- matching gbdk's own `magb_dial()`/
    `magb_transfer_data()`, whose `timeout_frames` is a real parameter
    for the same reason; the one existing ISP/HTTP call site of each
    was updated to set it explicitly instead of relying on the old
    default.
  - `MagbWaitForCall` (`0x14`, `session.asm`) is new; every other
    command Test 1/2 already needed existed before this milestone.
  - Verified: menu wiring, the number editor (edit/cancel/re-open all
    behave correctly, checked by reading `wP2pNumber` back from WRAM),
    and both tests failing cleanly (WAKE -> TIMEOUT, matching every
    other command with nothing linked) in PyBoy and BGB. **Not yet
    confirmed to PASS** -- this needs two real linked instances (two
    Game Boys + two Mobile Adapters, or two BGB+libmobile-bgb
    instances), which the project owner's own environment can exercise
    but this one cannot.
- **Protocol trace ring buffer** (SELECT from the main menu,
  `ShowTrace` in `main.asm` + `session.asm`'s `RecordTraceByte`/
  `TracedTransferByte`/`wTraceHead`/`wTraceCount`/`wTraceBuf`): every
  byte `TracedTransferByte` moves over the wire (TX then RX, on success
  only) is appended to a 128-entry ring buffer -- `TracedTransferByte`
  is a drop-in replacement for `SerialTransferByte` with the exact same
  contract, and all ~17 of `session.asm`'s own call sites now go
  through it instead, mirroring how gbdk's `magb_session.c` routes
  every transfer through its own internal `xfer()` helper rather than
  calling `serial_transfer_byte()` directly. `ShowTrace` displays the
  most recent 14 TX/RX pairs, one "TX xx RX xx" line per pair, or
  "(EMPTY)" if nothing has been recorded yet -- same shape and page
  size as gbdk's `ui_show_trace()`. `MAGB_TRACE_LEN` (128) being a power
  of two turns the ring buffer's wraparound into a plain `AND` instead
  of a modulo; verified correct (including the wraparound case) by
  injecting synthetic entries directly into WRAM via PyBoy and reading
  the rendered tilemap back, since nothing in this environment
  currently answers real Mobile Adapter traffic long enough to fill the
  buffer with real bytes (see "Manual verification status").
- **Command wrappers** (`src/protocol/session.asm`, each a thin
  `MagbExecute` wrapper matching its `gbdk/src/protocol/magb_network.c`
  counterpart's payload shape and response validation):
  - `MagbBeginSession` / `MagbEndSession` (`0x10`/`0x11`)
  - `MagbDial` / `MagbHangup` (`0x12`/`0x13`) -- Dial builds
    [validation_byte, ...digits], the validation byte per-adapter-type
    (Blue `0x00`, else `0x01`) via `ctx->adapter_device`; caller must
    set `[wExecTimeoutFrames]` first (ISP vs P2P dials need different
    budgets -- see "Main menu"'s P2P entry)
  - `MagbWaitForCall` (`0x14`) -- the P2P Listener's counterpart to
    Dial; always uses `MAGB_TIMEOUT_FRAMES_SHORT` internally (gbdk's
    own `magb_wait_for_call()` always does too), so unlike Dial this
    one doesn't need the caller to set a timeout
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
    bytes over whichever connection `[wTcpConnId]` names (despite the
    name, this is really "which connection id" -- `MagbTcpOpen` fills
    it for TCP, but a P2P caller must set it to
    `MAGB_P2P_CONNECTION_ID` directly, since P2P has no Open call) and
    copies whatever the adapter sends back into the caller's output
    buffer, clamped to its capacity; a zero-length send is how a caller
    polls for more incoming data. Caller must also set
    `[wExecTimeoutFrames]` first (an HTTP poll and a P2P send/poll need
    different budgets -- see "Main menu"'s P2P entry). Recognizes
    Transfer Data End (`0x1F | 0x80`) and reports it via
    `[wXferRemoteClosed]`, matching
    `gbdk/src/protocol/magb_network.c`'s `magb_transfer_data()` --
    including that a received response is *not* necessarily an echo of
    what was just sent.

`src/main.asm`'s `RunIspHttpCore` runs the full sequence: Begin Session
-> Read Identity (see below) -> Dial (the adapter's own live Slot 1
phone number, falling back to `#9677`, the real DION PDC ISP number) ->
ISP Login (the adapter's own live login id + the ISP PASSWORD menu's
password, falling back to `test`/empty; `0.0.0.0`/`0.0.0.0` DNS -- same
fallback values as `gbdk/include/test_config.h`; libmobile's PPP login
handler doesn't check credentials against a real account, so an empty
password is valid regardless) -> DNS Query (`gameboy.datacenter.ne.jp`,
the real historical Mobile System GB datacenter host) -> TCP Open (port
80) -> **HTTP GET** (see below) -> TCP Close -> ISP Logout -> Hang Up
-> End Session, printing which command is running, which stage within
it, and on failure which `MAGB_ERR_*` -- all as readable text. Stops at
the first failing command through HTTP GET; TCP Close/ISP Logout/Hang
Up/End Session after that are best-effort and never fail the test
themselves (see "Hard-won bugs"' "TCP Close after Transfer Data End"
entry for why), matching gbdk's `isp_http_cleanup()` calling all four
as `(void)`. Only gap left from full parity with gbdk's cleanup: if an
*earlier* command (Dial, ISP Login, DNS, TCP Open, HTTP GET itself)
fails, this ROM still stops immediately rather than attempting the same
best-effort teardown gbdk's `isp_http_cleanup()` would (see "Known
simplifications" below).

Two thin entry points stage which request/title `RunIspHttpCore` uses
before jumping in, so the ~80-line Begin-Session..End-Session sequence
above isn't duplicated per target: `RunTamagoEggTest` (the ISP/HTTP
submenu's "TAMAGO EGG" entry -- the request described above) and
`RunTrainerHomeTest` (the submenu's "TRAINER HOME" entry -- a plain
unauthenticated GET against `/01/CGB-B9AJ/index.html` on the same
host/port, gbdk's `TEST_HTTP_TRAINER_HOME_PATH` -- Mobile Trainer's
real, Dan-Docs-documented home page; no GB00 auth needed since it's
outside REON's `/cgb/download|upload` front controller entirely). Both
set `wHttpRequestPtr`/`wHttpRequestLen` (read by `HttpFetch`) and
`wHttpTestTitle` (read by `RunIspHttpCore`'s title line) before jumping
to the shared core. Both are reachable from the menu now via the
ISP/HTTP submenu (`RunIspHttpMenu`/`ShowIspSubMenu`, see "What exists
so far" above).

### Read Identity (`src/main.asm`'s `ReadIdentity`)

Matches gbdk's `read_isp_identity()`: calls `MagbReadConfig` (`0x19`),
then copies the live login id (`ConfigFieldToCstr`, NUL-terminates on
the field's own embedded `0x00`/max length/destination capacity,
whichever comes first) and decodes the live Slot 1 phone number
(`MagbConfigDecodePhone`) out of the adapter's real configuration --
falling back to the same compile-time `test`/`#9677` defaults this ROM
already used only when the corresponding live field is genuinely blank,
never a guessed value. Used by every `RunIspHttpCore` target (Tamago
Egg included) via `BuildIspLoginPayload`, which assembles the real ISP
Login payload (`login_len, login, password_len, password, dns1[4]=0,
dns2[4]=0`) from `wIdentityLogin` and the ISP PASSWORD menu's live
`wIspPassword` using an explicit running-counter length (`wIspLoginBuiltLen`),
not pointer subtraction. Verified via PyBoy (both helpers independently,
each with real-value/blank-field/max-length/dest-capacity-clamping test
cases) -- not yet re-verified end-to-end against a real adapter, since
this changes the already-libmobile-bgb-confirmed Tamago Egg PASS to use
a new `MagbReadConfig` dependency (see "Manual verification status").

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

### GB00 authentication primitives (`src/app/gb00_auth.asm`)

A from-scratch SM83 port of gbdk's `gb00_auth.c` (MD5 + base64 + REON's
GB00 challenge/response bit-scramble) -- the crypto/encoding engine
News Config/Article need, and now do use (see "GB00 HTTP fetch engine
and News Config/Article" below). Not re-derived independently -- ported
directly from gbdk's already-round-trip-tested-against-REON's-real-PHP
implementation, so this only needed to be a *faithful transcription*,
verified against known-good outputs rather than against a live server:

- **MD5** (`Md5::`): textbook RFC 1321, all 32-bit values as 4
  little-endian bytes at fixed WRAM addresses (SM83 has no spare
  register pairs to thread 3-4 simultaneous 32-bit pointers through
  the round function). Verified against the standard RFC 1321 test
  vectors (`md5("")`, `md5("abc")`, `md5("The quick brown fox...")`)
  plus two synthetic multi-block inputs (80 bytes, and exactly 56 bytes
  -- the edge case that forces a full second block) by injecting each
  message into WRAM via PyBoy (redirecting the CPU's PC directly into
  `Md5`, bypassing the need for any menu path that reaches it) and
  reading the digest back byte-for-byte. All correct.
- **base64** (`Base64Encode::`/`Base64Decode::`, RFC 4648): verified
  round-trip against Python's `base64` module for 8 inputs (empty
  string through "foobar", covering all 3 padding cases, plus a
  36-byte binary buffer) in both directions.
- **GB00 challenge/response** (`Gb00BuildAuthorization::`,
  `Gb00BitsSorted`, `Gb00RotateEncode`): verified against a from-scratch
  Python re-implementation of gbdk's exact algorithm (not against a
  live REON server -- gbdk's own version was already round-trip-tested
  there; this only needed to confirm the SM83 port matches that same,
  already-verified algorithm bit-for-bit) across 4 cases including
  edge cases (empty login+password, and the maximum 19-char login +
  8-char password this ROM's own `ISP_PASSWORD_MAX_LEN` allows).

Two real bugs were found and fixed by this verification process, not
by inspection -- both are written up in "Hard-won bugs" below:
`Base64Decode` clobbering its own input-scan pointer, and
`Gb00BuildAuthorization`/`Gb00BitsSorted` colliding on a reused WRAM
variable name.

This file's code (not its WRAM state) lives in `ROMX, BANK[1]` rather
than `ROM0` -- see the file's own header comment. Worth calling out
here too: every other file in this ROM used plain `ROM0` (RGBDS packs
that into the fixed lower 16 KiB only), so before this, the *entire
upper half* of the physical 32 KiB ROM was unused `$FF` padding --
confirmed by inspecting the built ROM directly and by `rgblink -m`'s
own map output (`ROM0: 10466/16384 used`, no `ROMX` section at all,
literal `$FF` bytes from `$4000` through `$7FFF`). For a mapperless
cart (cartridge type `$00`), that upper half is just the ROM chip's
second 16 KiB, always mapped, nothing to bank-switch -- `ROMX BANK[1]`
is the correct, standard way to tell RGBDS to actually use it. After
moving this file's code there: `ROM0: 7856/16384 used` (8528 free),
`ROMX: 2610/16384 used in 1 bank` (13774 free) -- roughly **4x** the
previously-visible free space. This matters a lot for what's next:
News/Email/Raw TCP would likely not have fit in the ~5.9 KiB that was
left in `ROM0` alone.

### GB00 HTTP fetch engine and News Config/Article (`src/app/gb00_auth.asm`, `src/main.asm`)

`Gb00FetchOne::` (gb00_auth.asm) wraps one GB00-authenticated HTTP GET,
mirroring gbdk's `gb00_http_get()`/`gb00_status_code()`/
`gb00_find_challenge()`/`gb00_fetch()` step-for-step: sends a caller-
supplied no-auth GET; if the status isn't `401`, done; otherwise finds
the `WWW-Authenticate` challenge, closes and reopens the TCP connection
(REON's PHP closes after a 401), builds the Authorization value via
`Gb00BuildAuthorization`, and retries with a caller-supplied
Authorization-header prefix + that value + a shared suffix. Every
request text this engine sends is a compile-time ROM blob or
prefix+value+suffix copied byte-by-byte into WRAM -- no `sprintf`, no
packed structs, matching this project's serialization convention.
`GB00_RESP_BUF_SIZE` is 300, the same number gbdk's own hard-won 401
capture forced it to (a real nginx 401 challenge response measured 227
bytes; 200 silently truncated the `WWW-Authenticate` line and broke
every News test before ever attempting the authenticated retry).

Verified via PyBoy (fresh instances per case -- see "Hard-won bugs"
below for why): `Gb00StatusCode` and `Gb00FindChallenge` against a
real-shaped synthetic 401 response (full match), a `200 OK` with no
challenge header at all, a truncated challenge too short to hold the
full 48 characters, and a response too short to have a status line at
all -- all five cases correct, including both "not found" edge cases.
The TCP-dependent parts of `Gb00FetchOne` itself (the actual open/
close/reopen and the second GET) are **not** independently unit-tested
-- they're straightforward compositions of already-verified pieces
(`MagbTcpOpen`/`MagbTcpClose`/`MagbTransferData`, all already
hardware-confirmed elsewhere, plus the two now-verified parsers), and
only a real adapter can meaningfully exercise the actual 401-then-retry
round trip.

`RunNewsConfigTest`/`RunNewsArticleTest` (main.asm) wire this into the
ISP/HTTP submenu's NEWS CONFIG/NEWS ARTICLE entries: both refuse to run
at all with an empty ISP PASSWORD (matches gbdk's `require_password()`
-- GB00 auth validates this against a real account, unlike Dial/ISP
Login), then Begin Session -> Read Identity -> Dial -> ISP Login -> one
shared DNS Query (`gameboy.datacenter.ne.jp`, same host Tamago Egg/
Trainer Home use) -> News Config does one `Gb00FetchOne`
(`/cgb/download?name=/01/CGB-BXTJ/news/config.php`); News Article does
that same fetch *and* the article fetch
(`/cgb/download?name=/01/CGB-BXTJ/news/100.news.php`) in the same ISP
session, neither relying on REON's optional session-auth cache (each
gets its own real challenge/response) -- matching gbdk's
`test_isp_http_gb00()`/`test_isp_news_article()` exactly. PyBoy
confirms both reach `Begin Session -> WAKE -> TIMEOUT -> FAIL` cleanly
with no adapter attached (the same baseline every other ISP/HTTP test
shows), and that the empty-password guard fires correctly before ever
attempting a session.

### Email Send / Email Recv (`src/app/net_extra.asm`, `src/main.asm`)

Neither SMTP nor POP3 is a Mobile Adapter command -- both are ordinary
line-based text protocols run over a plain TCP connection, exactly like
the HTTP tests' TCP connection (port 25 / 110 instead of 80). Read
Identity (`ReadIdentity`, main.asm) now also reads the adapter's live
email/SMTP-host/POP-host config fields (`wIdentityEmail`/
`wIdentitySmtp`/`wIdentityPop`, offsets already defined in
`protocol.inc`) -- no compile-time fallback for these three, unlike
login/phone: an unregistered adapter genuinely has no email account, and
both tests detect and report that explicitly ("NO EMAIL/SMTP CFG"/"NO
EMAIL/POP CFG") rather than inventing one.

`net_extra.asm` (`ROMX BANK[1]`, alongside `gb00_auth.asm`) provides the
shared line-protocol engine, ported from gbdk's
`tcp_send_line()`/`tcp_recv_line()`/`line_step()`:

- **`TcpRecvLine::`** carries a one-call "pending" byte buffer
  (`LINE_PENDING_MAX` = `PROTO_MAX_PAYLOAD_LEN`, 254 bytes) because a
  single TCP receive can carry more than one protocol line -- a real
  BGB/libmobile-bgb capture gbdk's own comment cites showed an SMTP
  `"250 OK\r\n"` reply and a second, unrelated line arriving together in
  one Transfer Data response. Matches gbdk's own simplification
  exactly: leftover bytes past a `'\n'` are always re-derived by
  re-scanning what was just written into the caller's destination
  buffer, regardless of whether that batch came from the pending buffer
  or a fresh network read, rather than tracking the two sources
  separately.
- **`EmailLineStep::`** composes `TcpSendLine`/`TcpRecvLine`/
  `StrPrefixMatch` into one send-then-check-the-reply-prefix step
  (gbdk's `line_step()`), returning `0` on a match or a `MAGB_ERR_*`
  code otherwise -- a real transport error propagated as-is, or the new
  `MAGB_ERR_ISP` (`protocol.inc`) if the transport worked but the reply
  didn't start with the expected prefix (a real SMTP/POP3 rejection).
  Takes its parameters from a WRAM descriptor, not registers -- SM83
  doesn't have enough register pairs left over for
  send+recv+expect (each a pointer, two also needing a length) all at
  once, especially once `TcpSendLine`'s own "clobbers everything"
  would otherwise destroy them first.

Verified via PyBoy: `TcpRecvLine` against a synthetic two-line pending
buffer (`"250 OK\r\n500 unexpected\r\n"`, the exact real-world scenario
the header comment describes) split correctly across two calls, with
the leftover-restash logic landing the second line's full text and
leaving the pending buffer empty afterward; `StrPrefixMatch` against
three cases (match, mismatch, a `"+OK"` reply). All fresh-PyBoy-
instance-per-case (see "Hard-won bugs").

`RunEmailSendTest` (SMTP, no ISP PASSWORD required -- REON's SMTP
accepts mail unauthenticated, a message only actually gets delivered if
`RCPT TO` matches a real account) matches gbdk's `test_isp_email_send()`:
greeting `220` -> `HELO` -> `MAIL FROM:<email>` -> `RCPT TO:<email>` ->
`DATA` -> body+`.` -> best-effort `QUIT`. `BuildEmailCommandLine`
(prefix + live `wIdentityEmail` + `">\r\n"`) verified via PyBoy for a
real address and an empty one, both exactly matching the expected byte
sequence.

`RunEmailRecvTest` (POP3, ISP PASSWORD *is* required -- REON's real
`pop3Connection.js` checks `PASS` against the same `log_in_password`
column GB00 auth uses) matches gbdk's `test_isp_email_recv()`: greeting
`+OK` -> `USER <local-part-of-email>` -> `PASS <password>` -> `STAT`
(parsed via `ParseLeadingUint8`, clamped to a byte -- this ROM's decimal
display, `text.asm`'s `BuildDecimal`, only handles one byte, and a real
test mailbox's count is never remotely close to 256 in practice) -> up
to `EMAIL_DELETE_MAX_SCAN` (20) messages scanned via `TOP <n> 0` for
this ROM's own test subject line, `DELE`d only on a match, never
guessed at. Every failure inside that scan loop (`TOP` unsupported, a
message missing, a transport hiccup, the remote closing early) only
stops or skips scanning -- it does not fail the whole test, matching
gbdk's `delete_matching_test_emails()` and its own comment ("never
deletes anything else in the mailbox") exactly. `ParseLeadingUint8`,
`BuildTopCommand`, `BuildDeleCommand` verified via PyBoy (decimal
parsing across 4 cases including a non-digit string; command-building
for single- and double-digit message numbers) -- all correct.

Both tests confirmed via PyBoy to reach `Begin Session -> WAKE ->
TIMEOUT -> FAIL` cleanly with no adapter attached, and Email Recv's
empty-password guard fires correctly before attempting a session (Email
Send has no such guard, matching gbdk).

### Raw TCP (`src/main.asm`)

Matches gbdk's `test_isp_raw_tcp()`: an interactive "netcat viewer" --
edit a 12-digit IP (reuses the same `EditNumber` the P2P screens use,
same digit grouping as `MagbDial`'s IP-style dialing), dial the ISP with
an **explicit empty password** regardless of the live ISP PASSWORD menu
value (`BuildIspLoginPayloadNoPassword`, a separate function from
`BuildIspLoginPayload` rather than parameterizing that
hardware-confirmed one -- Raw TCP has no auth step of its own, and a
password set for News/Email testing should never leak into an unrelated
Raw TCP session by accident), open a TCP socket to the entered address
(`ParseIp12`, gbdk's `parse_ip12()`), then poll and display whatever
comes back live -- binary-safe (`RawTcpPutChar`: `'\n'` is a real
newline, `'\r'` is a no-op, any other control byte becomes `.`), until
the remote closes or B cancels. Text wraps back to
`RAW_TCP_ROW_FIRST` once past `RAW_TCP_ROW_LAST`, a known, accepted
limitation matching gbdk's own stock-console wraparound. The one
deliberate deviation from gbdk here: early-stage failures (Begin
Session/Read Identity/Dial/ISP Login/TCP Open) show this ROM's own
`RESULT: FAIL` + `PrintErrorCode` shape instead of gbdk's fixed
per-stage printf strings, for consistency with every other test on this
side rather than exactly mirroring gbdk's raw-tcp screen.

Verified via PyBoy: the IP-edit screen renders and confirms correctly
with the default `127.0.0.1` (reuses `sP2pDefaultNumber`'s text, since
it's the exact same value as gbdk's `TEST_ISP_RAW_IP`); the whole flow
reaches `Begin Session -> TIMEOUT -> FAIL` with no adapter attached; B
from the IP-edit screen and B from the end screen both correctly return
to the menu. `ParseIp12` verified against 4 cases (the default loopback
address, an arbitrary LAN-shaped address, all-255s, and all-zeros) --
all correct. `RawTcpPutChar`/`ComputeRawTcpAddr`/`RawTcpAdvance`/
`RawTcpNewline` verified by feeding a string containing an embedded
newline, two control bytes, and a trailing `\r\n` through them and
reading the resulting tilemap back -- text landed on the correct rows,
control bytes became `.`, `\r` was silently absorbed, and the cursor
ended exactly where expected.

### ISP/HTTP submenu (`src/main.asm`)

`RunIspHttpMenu`/`ShowIspSubMenu` -- the 7-item submenu gbdk's
`ui_select_submenu()`/`kIspLabels[]` opens (same wording/order: TAMAGO
EGG, NEWS CONFIG, NEWS ARTICLE, TRAINER HOME, EMAIL SEND, EMAIL RECV,
RAW TCP(NC)) -- now exists and is what the main menu's "ISP/HTTP" item
opens, replacing the earlier milestone's "runs Tamago Egg directly"
behavior. Title row 0, items starting row 2, `"A:RUN B:BACK"` footer,
selection resets to item 0 every entry (a plain WRAM byte, not
persisted like the main menu's), B returns to the main menu. All 7
entries are now backed by a real implementation (Tamago Egg, Trainer
Home, News Config, News Article, Email Send, Email Recv, Raw TCP) --
none of this submenu's entries show "NOT IMPLEMENTED" anymore. Verified
via PyBoy: all 7 labels render correctly, up/down/A/B navigation works,
B returns to the main menu, and each entry reaches its own real test
flow.

## Confirmed working

- **Begin Session / End Session** (2026-08-28): a full PASS reproduced
  in mGBA (built-in Mobile Adapter GB responder, `config.ini`'s
  `mobileAdapterEnabled=1`) and independently verified byte-for-byte
  correct by reading WRAM directly. `mobileAdapterEnabled=0` (bare key,
  no `sio.` prefix) confirmed to flip the same build to a correct FAIL,
  matching PyBoy and BGB with nothing linked -- both directions
  verified.
- **Main menu + Adapter/Session (Test 1), full PASS against real
  libmobile-bgb** (project owner, 2026-08-29, real BGB + libmobile-bgb,
  not PyBoy/BGB-with-nothing-linked): menu navigation and Test 1
  confirmed working end to end after the `LoadFont` glyph-corruption
  fix and the menu-redraw LCD/`LY` fix below. This is the first
  real-responder PASS confirmation for anything past Begin Session/End
  Session on this side.
- **Dial / ISP Login / DNS / TCP Open+Close / ISP Logout / Hang Up /
  End Session**: full PASS against real libmobile-bgb (see the
  Transfer Data/HTTP GET entry below) -- every one of these is
  exercised in that same passing run.
- **Transfer Data (0x15) / HTTP GET**: two real libmobile-bgb runs
  (project owner). First run (2026-08-29) reached the real Tamago Egg
  backend and correctly built/sent the GET request, but the *second*
  Transfer Data poll's response (a legitimate 255-byte payload) was
  wrongly rejected as `MAGB_ERR_BAD_LENGTH` -- see "Hard-won bugs" for
  the root-cause writeup and fix. Second run (2026-08-30), after that
  fix: the real HTTP response ("HTTP/1.1 200 OK...") now arrives in
  full -- the 255-byte-response fix is **confirmed working**. That same
  run then surfaced the *next* bug (TCP Close after Transfer Data End
  wrongly treated as fatal -- see "Hard-won bugs"). Third run
  (2026-08-30): **full PASS end to end** against real libmobile-bgb --
  Begin Session -> Dial -> ISP Login -> DNS -> TCP Open -> HTTP GET
  (real "HTTP 200") -> TCP Close -> ISP Logout -> Hang Up -> End
  Session, `RESULT: PASS` on screen. This is the first complete,
  real-responder PASS confirmation for the entire ISP/HTTP chain.
- **Email Send (SMTP) / Email Recv (POP3), full PASS against real
  libmobile-bgb** (project owner, 2026-08-30). First real run of each
  surfaced one real bug apiece -- both root-caused against real traces
  and REON's own reference source, fixed, and confirmed by a second
  real run right after: Email Send's `250 OK`/`500 command not
  recognized` split (REON's own SMTP simulator ending DATA one line
  early on a body line that happened to end in a literal `.` before
  its CRLF) and Email Recv's post-authentication hang (`TOP`'s real
  multi-line reply exceeding `wEmailLineBuf`'s old 72-byte capacity,
  silently losing its own end terminator to `MagbTransferData`'s
  output-capacity clamp) -- see "Hard-won bugs" for both write-ups.
  Confirms the GB00-adjacent line-based SMTP/POP3 engine
  (`net_extra.asm`) end to end against a real server for the first
  time, not just PyBoy's no-adapter-attached baseline.
- **Raw TCP, confirmed working against real libmobile-bgb** (project
  owner, 2026-08-30): the interactive netcat-style viewer -- IP entry,
  dial, ISP Login with an explicit empty password, TCP Open, and live
  binary-safe display of whatever comes back -- works as designed. This
  makes every ISP/HTTP submenu target now real-responder-confirmed. That
  same first real run also surfaced a real display bug (some letters
  not showing up, e.g. "O") -- root-caused and fixed (a missing LCD-off
  guard around Raw TCP's live tile writes, see "Hard-won bugs"), and a
  second real run right after confirmed the display is now correct too.
- **Read Configuration Data (0x19)** (`MagbReadConfig`,
  `MagbConfigChecksumOk`): reviewed function-by-function, no bugs found;
  confirmed to fail cleanly (WAKE -> TIMEOUT, matching every other
  command with nothing linked) in PyBoy. **Not yet confirmed to PASS**
  against a real responder -- unlike the commands above, this one
  hasn't been through a real libmobile-bgb/hardware session yet. Also
  note: this only reads the raw 192-byte blob and checks its checksum
  -- it does not yet decode/display individual fields (login ID, phone
  slots, ...) the way gbdk's `ui_show_config()` does; see "What's
  explicitly NOT implemented yet".

## Hard-won bugs (worth reading before touching this code again)

- **Lowercase 'm' rendered as three disconnected vertical strokes.**
  Reported (2026-08-30) via a real screenshot of the ISP PASSWORD
  editor: typing "mae" showed an unrecognizable glyph (looked like
  three bars, or a stray Cyrillic-ish shape) followed by "ae". The
  original lowercase 'm' used the exact same row pattern (`$A8`, i.e.
  three isolated 1px legs at columns 0/2/4) for *every* row of its
  x-height, including the top one -- with nothing connecting the three
  legs into a recognizable "wide letter with a closed top" shape the
  way 'm' needs (compare 'n', which reads fine specifically because its
  top row *does* connect its two legs: `$E0` = a solid arch across the
  first two legs, only the bottom rows are isolated). Fixed by giving
  'm' the same treatment -- a solid connecting bar (`$F8`, spanning all
  three legs) on its own top row, legs (`$A8`) below it. Verified via
  PyBoy (rendered "mae" through the actual font tiles and read the
  pixels back) -- not yet re-confirmed on a real screen.
- **A-Z/0-9 were almost illegible -- and the bitmap data itself showed
  why.** Reported (2026-08-30) after extended real-hardware use across
  every ISP/HTTP target. The original set was an algorithmically
  thresholded downscale of a system typeface, using only 5 columns x 6
  rows of actual ink inside each 8x8 cell -- and inspecting the raw
  bitmap bytes turned up real, asymmetric defects consistent with that
  report, not just a matter of taste: `'O'`'s two side-strokes sat at
  different columns on different rows (not a symmetric curve at all),
  for one. Before touching the bitmap data, the project owner also
  asked whether `gbdk/references/pokecrystal-mobile-eng`'s `font.png`
  could be used as a basis -- refused: that file is the font extracted
  from the real Pokemon Crystal ROM (the reference repo's own README
  says so), with no license, which is exactly the "copyrighted
  graphics" the repo-root `CLAUDE.md`'s Copyright / Clean-Room
  Considerations section rules out, "inspired by" or not. Redrawn A-Z
  and 0-9 from scratch instead -- each glyph hand-designed as its own
  pixel grid (`rgbds/src/app/text.asm`'s `gen_font.py`-style generation,
  not traced from any font file), using the full cap-height (rows 0-6,
  one row taller than the old set) with the baseline on row 6 --
  deliberately the same row the existing lowercase's x-height baseline
  already sits on, so a redrawn capital and the existing lowercase
  letters line up visually without touching the lowercase set at all.
  `M`/`W` use a 6th column (still one 8px tile each, just less trailing
  blank space) since they're the widest letters in the set. Verified by
  rendering the full new A-Z/0-9 set into VRAM via PyBoy and reading
  each tile's bitmap back out as ASCII art for visual review -- every
  glyph came back clean and symmetric, matching the intended design
  exactly (same technique this project already used to verify the
  original lowercase glyphs when *they* were added). Punctuation,
  symbols, and lowercase are unchanged. **Confirmed on a real screen**
  (project owner, 2026-08-30): "MUITO melhor" -- substantially more
  legible than the old set.
- **`RawTcpPutChar` wrote to VRAM without turning the LCD off first.**
  Reported (2026-08-30) as some letters (e.g. "O") not showing up
  during a real Raw TCP session. Every other screen in this ROM
  (`PrintString`/`ClearTextScreen`/`LoadFont`) turns the LCD off before
  touching VRAM, specifically so a write can never land while the PPU
  is mid-fetch (mode 3), when it would simply be ignored. `RawTcpPutChar`
  is the one place that writes live, one incoming byte at a time,
  outside any of those functions' bracketing -- whichever character's
  write happened to race the PPU got silently dropped, which reads
  exactly like "random letters missing" rather than a font-data bug
  (nothing about one glyph's bitmap would explain an *intermittent*
  failure). Root-caused from the symptom description alone (Raw TCP
  only, intermittent, not every screen) without needing a serial trace
  -- this one was a display-timing bug, not a protocol bug, so the wire
  bytes were never the issue. Fixed by wrapping just the one tile write
  with the same LCD-off/on bracketing every other screen already uses.
- **`MagbTransferData`'s output-capacity clamp silently drops bytes a
  real adapter will never resend.** Found from a real libmobile-bgb
  Email Recv run (2026-08-29/30) that hung: `>>> 15 Transfer data` /
  `<<< 15 Transfer data` repeating forever after POP3 authentication,
  never timing out into a result screen. Root cause: `session.asm`'s
  `MagbTransferData` clamps what it copies into the caller's output
  buffer to that buffer's stated capacity, and its own comment assumed
  the untaken remainder stays available in the adapter's TCP buffer for
  a later poll ("clamp: copy only cap bytes, drop the rest (**caller
  re-polls**)"). That assumption is wrong for a single real adapter
  response: a live POP3 `TOP 1 0` reply (5 header lines + the RFC 1939
  terminator, ~77 bytes) arrived from the real server as *one* MAGB
  packet, but Email Recv's `wEmailLineBuf` (`EMAIL_LINE_BUF_SIZE`, 72
  bytes at the time) only asked for ~71 bytes of it -- the adapter had
  already handed over its *entire* buffered chunk in that one exchange,
  so the ~6 bytes past this ROM's requested capacity (including the
  reply's own end terminator) were gone the moment the next Transfer
  Data command overwrote `wRxPayload`, not retrievable by a later poll
  the way the comment assumed. Every following poll legitimately
  returned nothing, and the header-scan loop spun through all 40
  iterations, each a real ~15s round trip, before giving up -- the
  observed hang. Confirmed as a receive-capacity issue, not a parsing
  bug, by checking the exact reply length in the real trace (`lenLo` =
  `0x4E` = 78 bytes total) against `EMAIL_LINE_BUF_SIZE`. Fixed by
  giving `wEmailLineBuf` its own `EMAIL_RECV_BUF_SIZE` = `PROTO_MAX_PAYLOAD_LEN`
  (254) -- large enough that a single real Transfer Data response, up
  to the protocol's own per-packet ceiling, can never be clamped.
  `HttpFetch`/`Gb00HttpGetOnce`'s own buffers (240/300 bytes) happen to
  be comfortably above `PROTO_MAX_PAYLOAD_LEN-1` (253) already, so they
  aren't exposed to this specific failure mode, but the underlying
  `MagbTransferData` clamp behavior itself is worth remembering before
  sizing *any* new receive buffer this way: a caller-specified output
  capacity below 253 bytes is a real, not just theoretical, data-loss
  risk against a real adapter, regardless of how the calling code polls
  afterward.
- **REON's real SMTP test server treats "a message line that just ends
  in a period" as the end of DATA one line early.** Found from the same
  real-hardware session's Email Send run: libmobile-bgb showed a real
  `500 command not recognized` after an otherwise-successful `250 OK`.
  Traced to `references/reon/mail/smtpConnection.js`'s `_handleData()`:
  it decides a line is the lone SMTP end-of-DATA terminator via
  `data.endsWith(".\r\n")` on *each line individually*, not "is this
  line exactly `.`". This ROM's test message's own body line, `"Hello
  from the Mobile Adapter GB TestSuite ROM."`, ends in a literal `.`
  immediately before its `\r\n` -- satisfying that same (non-standard;
  real SMTP dot-stuffing only cares about a line's *first* character)
  check a line early. The server exits DATA mode there, sends the real
  `250 OK` for a message missing its actual last line, and then
  processes what was genuinely meant to be *the* terminator line (".")
  as an ordinary command instead -- command name `"."`, unrecognized,
  hence `500 command not recognized`. Not a MAGB/transport bug on this
  ROM's side at all -- REON's own real server, not this ROM, decided
  DATA was over. Fixed by dropping the trailing period from the test
  message's body line (`sSmtpBody`, main.asm) so no line but the
  genuine terminator ends in `.\r\n`.

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

- **`LoadFont` racing the PPU instead of the LCD actually being off.**
  Reported by the project owner from a real BGB run: the screen showed
  recognizable but corrupted/partial-looking glyphs (right tile
  *numbers*, garbled tile *pixel data*) instead of clean text -- compare
  against the gbdk build's equivalent screen, which rendered fine.
  `LoadFont` (`text.asm`) copies 1024 bytes straight into VRAM tile
  block 0 with no LCD-off/on bracketing of its own; its comment assumed
  `InitDisplayBlank` (`main.asm`) left the LCD off before calling it,
  but `InitDisplayBlank` actually turns the LCD back *on* before
  returning. So the whole 1024-byte copy ran against a live PPU: writes
  landing in HBlank/VBlank got through, everything else (the bulk of
  Mode 3) was silently dropped by the hardware, leaving stale VRAM
  content mixed in with the real font data. `ClearTextScreen` and
  `PrintString` already bracket their own VRAM writes with LCD off/on
  and were unaffected -- `LoadFont` was the only one relying on caller
  state. Fixed by giving `LoadFont` the same self-contained LCD off/on
  bracketing. Confirmed in PyBoy: same ROM, same screen, glyphs now
  clean.

- **Turning the LCD off outside VBlank resets `LY`, so back-to-back
  `PrintString` calls can silently eat a real button press.** Found
  while building the main menu: `DrawMenu`'s original version redrew
  the whole screen (title + 6 items + footer, ~14 `PrintString` calls)
  on *every* keypress, and pressing an arrow key a few times fast in
  PyBoy intermittently landed on a blank white frame -- despite VRAM
  and `LCDC` both checking out completely normal moments later.
  Root cause: `PrintString`/`ClearTextScreen` turn the LCD off
  unconditionally (no VBlank wait), and turning `LCDC` off resets `LY`
  to 0; turning it back on then makes the *next* call's LCD-off legal
  only once `LY` climbs back to 144 again -- i.e. after waiting out
  nearly a full new frame, every single time, once more than one such
  call happens back to back. A ~14-call redraw therefore took roughly
  14 frames (~230ms) end to end, and `ShowMenu`'s input loop doesn't
  poll the joypad again until the redraw it triggered has returned --
  long enough for a transient press to start and end entirely inside
  that window and never be sampled. (This also explains why the
  "blank screen" was never reproducible by inspecting memory after
  the fact: nothing was actually corrupted, `PrintString` was just
  mid-multi-frame-stall when a screenshot landed.) Fixed two ways:
  `PrintString`/`ClearTextScreen`/`LoadFont` all now `call WaitVBlank`
  before turning the LCD off (cheap correctness fix, matches
  `InitDisplayBlank`'s existing pattern); and, more importantly,
  `DrawMenu` no longer redraws the whole screen on a plain cursor move
  -- a new `DrawMenuCursor` helper prints just the one changed
  character (old position erased, new position drawn), cutting a
  selection-change redraw from ~14 `PrintString` calls to 2. Confirmed
  with a PyBoy stress test (multiple rapid arrow presses in a row,
  several repeated runs) and in real BGB.

- **A real, valid 255-byte response was rejected as `MAGB_ERR_BAD_LENGTH`.**
  Reported by the project owner from a real BGB + libmobile-bgb run of
  ISP/HTTP (Tamago Egg): fails partway through the HTTP GET with
  "BAD LENGTH", confirmed from their serial trace log -- the second
  Transfer Data poll's response frame arrives as
  `99 66 95 00 00 FF ...` (magic, `TRANSFER|0x80`, reserved, length_hi
  00, length_lo **FF**), i.e. a real, correctly-framed response
  legitimately carrying `payload_len = 255` (a 1-byte conn_id echo plus
  a full 254-byte HTTP response chunk -- a perfectly ordinary way for a
  real adapter to hand back a maximum-size chunk).
  `ReadResponseFrame` (`session.asm`) rejected any length_low
  `> PROTO_MAX_PAYLOAD_LEN(254)` as `MAGB_ERR_BAD_LENGTH`, and
  `wRxPayload` was only sized for 254 bytes anyway. But 254 is not the
  adapter's actual receive limit -- it is only what "supported
  software" conventionally chooses to *send*
  (`gbdk/docs/dandocs-magb.md`, "Packet length limits": "On GBC,
  supported software limits Packet Data to 254 bytes." -- immediately
  followed by "the real Mobile Adapter discards packets larger than
  **255** bytes"). gbdk's own receive-side parser
  (`magb_packet.c`'s `magb_parser_feed()`) has no upper-bound check on
  `payload_len` at all, matching that -- though its 254-byte
  `packet.payload[MAGB_MAX_PAYLOAD]` buffer would silently overrun by
  one byte in this exact scenario, a latent bug of its own this port
  doesn't want to copy. Fixed by adding a separate
  `PROTO_MAX_RX_PAYLOAD_LEN = 255` (protocol.inc) for the receive path
  only -- `wRxPayload` is now sized for it, and the length-low ceiling
  check in `ReadResponseFrame` is gone entirely (once the ceiling
  equals 255, every possible byte value is already legal, so there is
  nothing left to reject; the length_hi-must-be-0 check right before it
  stays, since that one is still real). `PROTO_MAX_PAYLOAD_LEN` itself
  stays 254 and untouched -- it only governs what this ROM *builds and
  sends* (`BuildRequestFrame`/`MagbTransferData`'s own outgoing cap),
  which this bug never implicated. **Re-confirmed fixed** by the
  project owner against real libmobile-bgb (2026-08-30): the same
  255-byte response now parses correctly and the real HTTP response
  ("HTTP/1.1 200 OK...") was received in full.

- **TCP Close after Transfer Data End treated as a fatal test failure.**
  Reported by the project owner from the same real libmobile-bgb run
  right after the 255-byte fix above: the HTTP GET now genuinely
  succeeded end to end (a real "HTTP 200" was on screen), but the whole
  test still ended in `RESULT: FAIL` / `ADAPTER ERR STATUS`. Their
  serial trace showed why: this ROM's own explicit TCP Close (`0x24`,
  sent right after Transfer Data End already told it the remote peer
  had closed its side) got back an Error Status response
  (`0x6E|0x80 = 0xEE`, payload `[0x24, 0x00]` -- "the command that
  errored" + an error code) instead of the expected TCP Close response
  (`0xA4`) -- the adapter's own way of saying "that connection is
  already gone," a real and legitimate outcome, not a transport
  failure. `RunIspHttpTest` (`main.asm`) treated any non-zero result
  from TCP Close/ISP Logout/Hang Up/End Session as fatal
  (`or a,a` / `jp nz, .showFail` after each), so a cleanup-step hiccup
  failed a test whose actual data exchange had already fully succeeded.
  gbdk's own `isp_http_cleanup()` (`test_runner.c`) never had this
  problem: it calls all four of `magb_tcp_close()`/`magb_isp_logout()`/
  `magb_hangup()`/`magb_end_session()` as `(void)`, discarding their
  result unconditionally, every time -- not just on an earlier failure.
  Fixed by matching that exactly: those four calls in `RunIspHttpTest`
  no longer check their result at all. The command/status lines still
  update for each (diagnostic visibility unchanged); only whether a
  teardown hiccup can fail the *test* changed. **Confirmed fixed** by
  the project owner against real libmobile-bgb (2026-08-30, third run):
  full `RESULT: PASS`.

- **Font had no lowercase at all.** Reported by the project owner:
  once the config screen (READ CONFIG) and ISP PASSWORD editor
  actually needed to show/type realistic text, the gap this ROM
  already knew about (font is ASCII `$20`-`$5F` only -- ends at `_`,
  right before lowercase starts at `` ` ``/`a`) stopped being
  theoretical -- login id/email/SMTP/POP config fields commonly contain
  lowercase ASCII in real captured data, and `PrintAsciiField` showed
  every one of those bytes as `.` (out of its printable range), so a
  realistic value rendered as almost nothing but dots. Fixed by adding
  27 more tiles to `FontTiles` (text.asm) -- `` ` `` (`$60`, filler, so
  the font's own ASCII range stays one contiguous block) plus `a`-`z`
  (`$61`-`$7A`) -- extending the loaded font from 64 to 91 tiles, still
  comfortably inside the 256-tile unsigned-addressing block ($8000-
  $8FFF) `LCDC_BG_TILEDATA` selects (nothing else uses tiles past this
  font's own range, so there was no collision to worry about). Lowercase
  glyphs use the same 5-column-wide cell (bits 7-3 of each row byte) as
  the uppercase set: x-height letters occupy rows 2-6, ascenders
  (`b`,`d`,`f`,`h`,`k`,`l`,`t`) extend into rows 0-1, descenders
  (`g`,`j`,`p`,`q`,`y`) extend into row 7. `PrintAsciiField`'s printable
  range widened from `$20`-`$5F` to `$20`-`$7A` to match, and the ISP
  PASSWORD editor's charset (`sTextCharset`) now matches gbdk's exactly
  (space+lowercase+uppercase+digits) instead of omitting lowercase.
  First attempt at transcribing the row data for several letters
  (`a`,`c`,`e`,`g`,`m`,`n`,`o`,`p`,`q`,`r`,`s`,`u`,`v`,`w`,`x`,`y`,`z`,
  and `` ` ``) came out shifted down by one tile row from the intended
  design -- an extra `$00,$00` pair typed at the start of those specific
  lines (every glyph that happened to start with two *intentionally*
  blank rows; glyphs with a nonzero first row, like `b`/`d`/`h`/`i`,
  didn't have the bug) -- caught before shipping by mechanically
  recomputing every row from the intended bitmap and comparing, not by
  eye. Verified legible by rendering the full lowercase and uppercase
  alphabets plus digits directly into VRAM via PyBoy (writing a tiny
  hand-assembled machine-code snippet into WRAM and pointing the CPU's
  PC at it, to call `PrintString` several times with arbitrary strings
  without needing a menu path that reaches it) and reading back the
  rendered screenshot, then re-running the config-screen synthetic-blob
  check from the READ CONFIG entry above to confirm a realistic
  lowercase-heavy value (`"test@example.com"`) now renders as real text
  instead of dots.

- **PyBoy PC-hijack testing: a HALTed CPU doesn't un-halt just because
  the harness sets a new PC.** Not a ROM bug -- a testing-methodology
  trap worth recording since it silently produced a *plausible-looking
  wrong result* rather than an obvious crash. The PC-hijack trampoline
  technique this project uses (write a tiny stub into WRAM ending in
  `HALT`, point the CPU's `PC`/`SP` at it, tick, read results back) works
  perfectly for a single call per `PyBoy` instance. Reusing the *same*
  instance for a second trampoline call (new stub, new `PC`/`SP`, same
  running CPU) does not reliably work: PyBoy's CPU stays internally
  halted from the *first* call's `HALT`, so the second call's ticks
  either do nothing (the sentinel byte the harness watches for never
  changes, silently reported as "didn't finish" if checked) or, worse,
  execute unpredictably (this is what happened testing
  `Gb00FindChallenge` right after `Gb00StatusCode` in one session: it
  returned `A = 255`, a value neither function ever legitimately
  produces, which briefly looked like a real bug in the challenge-search
  loop until an isolated fresh-instance retest returned the correct
  `A = 1`). Two safe patterns: (1) one fresh `PyBoy(...)` instance per
  trampoline call (simplest, used for most of this session's isolated
  primitive tests), or (2) chain multiple calls inside *one* stub with
  no intermediate `HALT` (used to test `TcpRecvLine` across two
  sequential calls sharing pending-buffer state, where a fresh instance
  per call would have reset that state and defeated the point of the
  test).

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

- **`Base64Decode` clobbering its own input-scan pointer.** Found while
  cross-checking `gb00_auth.asm` against known base64 test vectors, not
  by inspection: decoding anything past the first 4 input characters
  produced garbage, and even the *first* output byte was sometimes
  wrong depending on what came after it in memory. Root cause:
  `Base64Value` (looks up a character's 6-bit value by linearly
  scanning `Base64Alphabet`) uses `HL` to walk the alphabet table and
  is documented as clobbering it -- but `Base64Decode`'s own main loop
  *also* uses `HL` as the input-text scan pointer (`ld a, [hl+]` to
  read each of the 4 base64 characters in a group), relying on it
  surviving across the very `call Base64Value` that clobbers it. Every
  character after the first one in a group was read from wherever
  `Base64Value` happened to leave `HL` inside the alphabet table, not
  from the actual input. Fixed with `push hl` / `pop hl` around each of
  the three `call Base64Value` sites inside the decode loop -- `HL`
  needed saving there specifically because, unlike most of this
  codebase's helpers, `Base64Value`'s *entire* job is incompatible with
  a caller that also wants to keep using `HL` as a walking pointer
  across the call.

- **`Gb00BuildAuthorization`/`Gb00BitsSorted` colliding on a reused
  WRAM variable name.** Found the same way, cross-checking the full
  authorization-builder output against a from-scratch Python
  re-implementation of gbdk's algorithm: the output's first 44
  characters (the base64 of the raw challenge's first 32 bytes) were
  always correct, but the remaining 48 (the scrambled plaintext) were
  consistently wrong. Root cause: `Gb00BitsSorted` used
  `wGb00ChallengePtr`/`wGb00OutPtr` as its own private input/output
  scratch -- but `Gb00BuildAuthorization` *also* uses
  `wGb00ChallengePtr` to remember the original base64 challenge text's
  address across several later steps (building the MD5 input, building
  the final output). The `call Gb00BitsSorted` in between silently
  overwrote it with `Gb00BitsSorted`'s own input pointer (the raw,
  decoded 36-byte challenge, a completely different buffer), so every
  later step that reloaded "the challenge pointer" actually read from
  the wrong address -- reading 48 bytes from there for the MD5 input
  ran past the raw-challenge/bits-sorted buffers into whatever
  followed them in WRAM, corrupting the password hash. Fixed by giving
  `Gb00BitsSorted` its own distinctly-named
  `wGb00BitsSrcPtr`/`wGb00BitsOutPtr`, never touched by the outer
  function. (A related false lead during this same debugging session,
  worth remembering for next time: test data placed at hand-picked
  "should be free" WRAM scratch addresses like `$C760` can silently
  collide with this ROM's *real* internal state -- `$C760` turned out
  to be `wMd5OldB`, live scratch MD5 itself uses on every call, which
  overwrote the test's login string mid-computation and looked exactly
  like a second bug until traced back to the test harness's own
  address choice, not the ROM.)

- **RGBDS v1.0.3 toolchain drift (build broke, no code-level cause).**
  The installed `rgbasm` jumped from the v0.6.1 this project was
  written against straight to v1.0.3, and `make` started failing with
  `error: Unrecognized option '-H'` before even reaching a single
  source file. Two unrelated syntax/flag removals landed between those
  versions: (1) v0.7.0 made rgbasm's old auto-insert/auto-strip-`nop`-
  after-`halt` behavior opt-in via `-H`/`--nop-after-halt`, then v0.8.0
  removed that behavior (and the `-H`/`-h` flags) *entirely* -- rgbasm
  now always keeps whatever `nop` is literally written in source, no
  flag needed, so the Makefile's `-H` was simply deleted rather than
  replaced; (2) that same v0.8.0 release also dropped lowercase `-i`
  for `--include` in favor of `-I`, which the Makefile already used
  inconsistently (`-i` for the flag, capital-letter conventions
  elsewhere) -- fixed by switching to `-I`. Separately, `include/hardware.inc`
  used bare `NAME EQU value` declarations (valid through v0.9.x); v1.0
  requires `DEF NAME EQU value` for a new constant (matches the style
  every other file in this ROM already used) -- rgbasm's error message
  for this is actually helpful (`did you mean "DEF X EQU ..."?`), so
  this one was a quick, safe, mechanical fix once the flag errors above
  stopped masking it. None of this is a wire-protocol or code-generation
  change -- purely assembler-syntax/flag compatibility -- and the
  resulting ROM was re-run in PyBoy afterward with the same WAKE ->
  TIMEOUT -> FAIL sequence (no adapter attached) this session's every
  other ISP/HTTP run has shown.

## What's explicitly NOT implemented yet

- Best-effort cleanup after an *earlier* command in the ISP/HTTP
  sequence fails (Dial, ISP Login, DNS, TCP Open, HTTP GET itself) --
  this ROM still stops immediately in that case rather than attempting
  TCP Close/ISP Logout/Hang Up/End Session the way gbdk's
  `isp_http_cleanup()` would. Cleanup *after a success* (or after
  Transfer Data End) is implemented now -- see "Hard-won bugs"' "TCP
  Close after Transfer Data End" entry -- this is only the
  earlier-failure case.
- Showing the exact received HTTP byte count on screen (gbdk's
  `"RX TOTAL %u B"`) -- text.asm's `BuildDecimal` (added for the config
  screen's DNS addresses) only handles one byte (0-255); this needs a
  16-bit value, still purely cosmetic, not a protocol gap.
- Write Configuration (`0x1A`) -- Read Configuration (`0x19`) is now
  implemented (see "Main menu" above); nothing on this side writes
  configuration data back yet.
- Punctuation/symbols beyond what's in the font (`$20`-`$7A`, i.e.
  through lowercase `z` -- no `{|}~` or anything past it). Lowercase
  itself is now covered (see "Hard-won bugs").
- The 16-bit-safe overflow case for `ParseLeadingUint8` (Email Recv's
  `STAT` parsing) and for `text.asm`'s `BuildDecimal` display more
  generally -- both are 8-bit only. A real test mailbox's message count
  is never remotely close to 256 in practice, and `EMAIL_DELETE_MAX_SCAN`
  (20) already bounds the scan regardless of the true count, so this is
  a display-only ceiling, not a protocol correctness gap.

Everything the repo-root `CLAUDE.md` explicitly names as this ROM's job
now has a real, working implementation on this side, including every
ISP/HTTP submenu target -- what's left below is either cosmetic, or
requires the real hardware/network environment this side of the project
cannot provide for itself (per `CLAUDE.md`'s Responsibility Boundary).

## Suggested next milestone

All three of the repo-root `CLAUDE.md`'s named tests (Adapter/Session,
ISP/HTTP, P2P Caller/Listener) exist as real, working implementations,
and -- new since the previous milestone -- so does every one of the
ISP/HTTP submenu's 7 targets (Tamago Egg, Trainer Home, News Config,
News Article, Email Send, Email Recv, Raw TCP), plus Read Configuration
Data, a protocol trace viewer, the ISP PASSWORD editor, live ISP
identity reading, and a verified MD5/base64/GB00 authentication +
GB00 HTTP fetch engine + line-based SMTP/POP3 engine. Test 2's Tamago
Egg target has a full, real, libmobile-bgb-confirmed PASS; every other
ISP/HTTP submenu target is new since that PASS and has only been
verified as far as PyBoy (no real adapter) allows -- see "Manual
verification status" for exactly what still needs a real
PicoAdapterGB/BGB+libmobile-bgb run. **Test 3 (P2P) is the one piece of
this ROM's own named scope that has not been confirmed to PASS at
all** -- not because anything is missing on this side, but because it
needs two real linked instances (two Game Boys + two Mobile Adapters,
or two BGB+libmobile-bgb sessions) to actually prove out, which no
single manual test session can provide alone. Reasonable next steps,
roughly in order of value: (1) get a real two-instance P2P Caller/
Listener PASS -- the one remaining unconfirmed piece of this ROM's core
scope; (2) work through "Manual verification status"'s backlog of new
ISP/HTTP submenu targets against a real adapter, one at a time,
starting with whichever the project owner can test soonest; (3)
best-effort cleanup on a mid-sequence ISP/HTTP failure, for full parity
with gbdk's `isp_http_cleanup()`; (4) Write Configuration (`0x1A`); (5)
showing the exact received HTTP/email byte counts on screen (would need
a 16-bit-safe `BuildDecimal`, purely cosmetic).

## Manual verification status

Built (`make`), header validated (`0x143 = 0xC0`, `0x147 = 0x00`, 32768
bytes). Per this repo's `CLAUDE.md` Responsibility Boundary (the
project owner's step):

- **Confirmed PASS against real libmobile-bgb (project owner,
  2026-08-30): Tamago Egg, Trainer Home, News Config, News Article,
  Email Send, Email Recv, Raw TCP** -- every ISP/HTTP submenu target
  now has a real-responder PASS on record. This also covers, as a side
  effect of those PASSes: live Read Identity
  (`ReadIdentity`/`BuildIspLoginPayload`, exercised by all of them) and
  the GB00 401-then-retry round trip (News Config/Article) against a
  real REON server, not just PyBoy's synthetic-response tests. Email
  Send/Recv's first real runs each surfaced one real bug (a REON SMTP
  simulator quirk, and an `EMAIL_LINE_BUF_SIZE`-vs-real-reply-size gap)
  -- both fixed and reconfirmed by a second real run; see "Hard-won
  bugs" and the "Confirmed working" entry above for the full writeup.
- **P2P Caller/Listener** is the one piece of this ROM's own named
  scope (repo-root `CLAUDE.md`) not yet run against a real adapter --
  needs two real linked instances (two Game Boys + two Mobile Adapters,
  or two BGB+libmobile-bgb sessions) -- see "Suggested next milestone";
  the two-simultaneous-setups requirement is why this is still open,
  not anything known to be wrong on this side.
- **Font rendering issue reported during Raw TCP (2026-08-30): some
  letters (e.g. "O") didn't show up.** Root-caused from the report
  alone (specific enough -- Raw TCP only, intermittent characters, not
  every screen) without needing the BGB log the project owner offered
  to send: `RawTcpPutChar` was the *only* VRAM-writing code in this ROM
  that didn't turn the LCD off before writing a tile, unlike
  `PrintString`/`ClearTextScreen`/`LoadFont` (all of which do, precisely
  to avoid this). Raw TCP writes live, one incoming byte at a time,
  outside any of those functions' own LCD-off/on bracketing -- a write
  landing while the PPU is actively fetching tiles (mode 3) is simply
  ignored on real hardware, corrupting/losing whichever character's
  write happened to race it. Not a font-data bug (nothing about a
  specific glyph's bitmap would explain intermittent, not-every-occurrence
  failures) and not the same issue as the already-fixed `LoadFont`
  glyph-row bug below. Fixed by wrapping just the one tile write in
  `RawTcpPutChar` with the same LCD-off/on pattern every other screen
  uses; verified via PyBoy (writing "HELLO WORLD\n" through it landed
  every character correctly, LCDC restored to its correct on-state
  afterward). **Confirmed fixed against real hardware/BGB** (project
  owner, 2026-08-30, retest immediately after the fix) -- Raw TCP now
  displays correctly.
- If it shows **RESULT: FAIL** unexpectedly, report exactly which
  command line and which stage/error text are showing -- that's the
  whole point of the text-renderer milestone, and should make
  root-causing a real failure much faster than a color-only build
  could. A link-level trace from the adapter side for that exchange
  remains the most useful thing to pair it with, the same way earlier
  GBDK bugs got root-caused (see `gbdk/docs/journal.md`).
