# Using this TestSuite's Mobile Adapter code in your own homebrew

GBDK-2020 has no Mobile Adapter GB API. This TestSuite's hardware
(`src/hw/`) and protocol (`src/protocol/`) layers are one — written to
be lifted out of here and dropped into another ROM. This guide is how.

Everything below has been run against a real REON server and a real
adapter path; where something is only reasoned about, it says so.

Two rules govern the whole layout, and knowing them makes the rest
predictable:

- **A lower layer never depends on a higher one.** `src/protocol/`
  compiles with no UI, no menu, no `test_config.h`. `src/hw/` compiles
  with no protocol. That is a maintained property, not an aspiration —
  the palette call and the "wrong console" screen were pulled *out* of
  `serial_hw.c` for exactly this reason (see §2).
- **Nothing in the copyable layers reads a compile-time constant of
  yours.** ISP number, login, hostname, port, path: all arguments.
  There is nothing to strip.

---

## 1. What to copy

**Tier 1 — talk to the adapter at all** (session, no networking):

```text
include/serial_hw.h        src/hw/serial_hw.c
include/magb_protocol.h    src/protocol/magb_packet.c
include/magb_commands.h
include/magb_session.h     src/protocol/magb_session.c
```

**Tier 2 — add networking** (dial, ISP, DNS, TCP, Transfer Data, config
readout):

```text
include/magb_network.h     src/protocol/magb_network.c
```

**Tier 3 — optional extras, take only what you need:**

```text
include/magb_config.h      src/protocol/magb_config.c   config-blob decoding (BCD phone, checksum)
include/magb_fmt.h         src/protocol/magb_fmt.c      exact decimal/hex for wire strings (§8)
include/gb00_auth.h        src/app/gb00_auth.c          REON GB00 auth — NOT MAGB protocol (§9)
include/save.h             src/app/save.c               battery-backed SRAM record (§10)
```

Add the `.c` files to your build. Tier 1+2 is five files and needs no
special linker flags, no mapper, and no banking. Tier 3's `gb00_auth.c`
is the only piece with build requirements of its own — see §9.

`src/app/test_runner.c`, `src/app/ui.c` and `src/main.c` are this
TestSuite's diagnostic program. Read them; don't link them. §11 says
which parts of them are worth stealing as patterns rather than files.

---

## 2. Setup, and the one thing that changed

```c
#include "serial_hw.h"
#include "magb_session.h"

static magb_context_t g_magb;

void my_game_init(void) {
    if (!serial_hw_init()) {
        /* Not a Game Boy Color. The CGB-only high-speed serial mode
         * this code needs does not exist on DMG/MGB. Say so however
         * your game says things, and stop -- do not continue and talk
         * to the adapter anyway. */
        my_fatal_screen("REQUIRES GAME BOY COLOR");
    }
    magb_context_init(&g_magb);
}
```

`serial_hw_init()` checks `_cpu == CGB_TYPE`, calls `cpu_fast()`, and
returns `true`. On anything else it changes nothing and returns
`false`.

It used to *draw* that error itself, which dragged `<gbdk/console.h>`
and `<stdio.h>` into the hardware layer along with a
`set_default_palette()` call. Both moved to the app layer
(`ui_fatal_not_cgb()` and `ui_init()` in `src/app/ui.c`). So
`src/hw/serial_hw.c` now includes only `<gb/gb.h>`, `<gb/cgb.h>` and
`<gb/hardware.h>` — nothing about screens, and nothing for you to
delete.

**If your game does not already set a CGB background palette, you still
need one.** A CGB does not power on with a legible default the way a
DMG does; without an explicit palette your text renders on a blank
white screen with no error of any kind. That is a display concern, not
a serial one, which is why it now lives in `ui_init()`. Copy the one
line if you need it (`set_default_palette()`, `gb/cgb.h`).

### Letting the player abort

```c
static bool my_cancel_check(void) { return (joypad() & J_B) != 0; }
...
g_magb.cancel_check = my_cancel_check;   /* optional; NULL = no cancel */
```

This function pointer is the *only* joypad-shaped thing anywhere in the
protocol layer, and it is opaque — nothing below `src/app/` ever calls
`joypad()`. It is polled during long waits (response wait, incoming
call); returning true aborts the command with `MAGB_ERR_CANCELLED`.

---

## 3. Every command follows one shape

```c
magb_result_t r = magb_begin_session(&g_magb);
if (r != MAGB_OK) { /* handle */ return; }

/* ... work ... */

magb_end_session(&g_magb);
```

`g_magb.session_active` becomes true only after Begin Session is fully
validated — the echoed `"NINTENDO"` payload and the frame checksum.
Never infer success from a single byte. (`0x95` in particular is just
`0x15|0x80`, the Transfer Data response. It is not a generic "OK".)

Every function returns `magb_result_t`. The error set is deliberately
wide — `MAGB_ERR_BAD_CHECKSUM`, `MAGB_ERR_DNS`, `MAGB_ERR_TCP`,
`MAGB_ERR_REMOTE_STATUS`, … — because "it failed" is useless when the
failure is somewhere in a chain of eleven commands. Surface which one.

On `MAGB_ERR_REMOTE_STATUS` the adapter sent an Error Status (`0x6E`)
packet; `ctx->remote_error_command` and `ctx->remote_error_code` say
which command it is complaining about and why. This can replace the
response to *any* command, so it is recognized once in `magb_execute()`
rather than in each wrapper.

---

## 4. Recipe: fetch something over the internet

```c
#include "magb_network.h"

magb_isp_login_result_t isp;
uint8_t dns0[4] = {0,0,0,0};   /* 0.0.0.0 = "use the adapter's own DNS" */
uint8_t ip[4];
uint8_t conn_id;
uint8_t resp[128];
uint8_t got;
bool closed;

magb_begin_session(&g_magb);
magb_dial(&g_magb, "#9677", MAGB_TIMEOUT_FRAMES_LONG);
magb_isp_login(&g_magb, "mylogin", "mypassword", dns0, dns0, &isp);
magb_dns_query(&g_magb, "my.server.example", ip);
magb_tcp_open(&g_magb, ip, 80, &conn_id);

static const char req[] =
    "GET /thing HTTP/1.0\r\nHost: my.server.example\r\n\r\n";
magb_transfer_data(&g_magb, conn_id, (const uint8_t *)req, sizeof(req) - 1,
                   resp, sizeof(resp), &got, &closed,
                   MAGB_TIMEOUT_FRAMES_LONG);

/* Poll for the rest: data = NULL, data_len = 0, until closed. */
while (!closed) {
    magb_transfer_data(&g_magb, conn_id, NULL, 0,
                       resp, sizeof(resp), &got, &closed,
                       MAGB_TIMEOUT_FRAMES_LONG);
    /* consume resp[0..got) */
}

magb_tcp_close(&g_magb, conn_id);
magb_isp_logout(&g_magb);
magb_hangup(&g_magb);
magb_end_session(&g_magb);
```

Check every return in real code. `test_isp_http()` in
`src/app/test_runner.c` is the error-checked version, including the
best-effort teardown chain a mid-sequence failure needs (close what you
opened, in reverse order, ignoring further errors).

### Reading the real ISP identity instead of hardcoding it

A registered adapter carries its own dial string and login ID.
`magb_read_config()` returns the 192-byte blob;
`MAGB_CONFIG_OFF_LOGIN_ID` and Configuration Slot 1's BCD phone number
(`magb_config_decode_phone()`, `magb_config.h`) are what a real client
uses. `read_isp_identity()` in `test_runner.c` is ~40 lines and does
exactly this, falling back to constants only for an unregistered
adapter.

There is **no password field anywhere in the configuration blob.** It
cannot be read from the adapter; it has to come from the user. See §10.

---

## 5. The rule that costs the most to learn: one Transfer Data does both

`magb_transfer_data()` sends *and* receives in a single command. There
is no send-only variant at the protocol level. A helper that passes a
throwaway output buffer to "just send" is silently discarding whatever
the remote had ready at that moment.

Whether that is safe depends entirely on the protocol you are speaking:

- **HTTP/1.0 request bodies: safe.** The server waits for the full
  `Content-Length` before replying. Nothing meaningful can arrive
  bundled with an intermediate chunk.
- **POP3, SMTP, anything line-at-a-time: not safe.** The reply to the
  line you just sent frequently arrives *with* that send. Discarding it
  costs you the whole response, and the symptom is a timeout waiting
  for something that already came and went.
- **The last chunk of any body: never safe.** That send completes the
  request, so the response can start arriving on it. Route the final
  chunk through a call that keeps its output.

This TestSuite gets it wrong twice in its own history and both are
written up in `docs/protocol-notes.md` ("The last send of a body must
also receive"). The shape that works:

```c
/* intermediate chunks: output discarded, fine for an HTTP body */
tcp_send_all(ctx, conn_id, body, body_len - last_chunk_len);
/* final chunk: keeps what comes back */
gb00_stream_request(ctx, conn_id, last_chunk, last_chunk_len, ...);
```

### Sizes: 254, 255, 253

- 254 (`MAGB_MAX_PAYLOAD`) is the conventional cap on what software
  *sends*.
- 255 (`MAGB_MAX_RX_PAYLOAD`) is what the adapter can legitimately
  *return*. Dan Docs says the real adapter discards packets larger than
  255, not 254. A real Transfer Data reply with `payload_len == 255`
  wrote one byte past a `payload[254]` array here and silently
  corrupted the field stored after it. Size receive buffers for 255.
- 253 is the usable data per Transfer Data: the payload's first byte is
  the connection id.

**Lengths are 8-bit in this API and that will bite you.**
`magb_transfer_data()` takes `uint8_t data_len`. An authenticated POST
header measuring 261 bytes truncated to `(uint8_t)261 == 5` and sent
the literal `"POST "` — no warning, no error, just a request the server
never saw. Anything whose length is not *provably* under 253 must go
through a chunking wrapper (`tcp_send_all()` is 15 lines; copy it).

---

## 6. Recipe: player-to-player link

```c
magb_dial(&g_magb, peer_number, MAGB_TIMEOUT_FRAMES_P2P_CALL);
/* or, on the receiving side: magb_wait_for_call(&g_magb, timeout) */

uint8_t discard[1];
uint8_t got;
bool closed;
magb_transfer_data(&g_magb, MAGB_P2P_CONNECTION_ID,
                   my_payload, sizeof(my_payload),
                   discard, 0, &got, &closed, MAGB_TIMEOUT_FRAMES_SHORT);

uint8_t incoming[16];
magb_transfer_data(&g_magb, MAGB_P2P_CONNECTION_ID, NULL, 0,
                   incoming, sizeof(incoming), &got, &closed,
                   MAGB_TIMEOUT_FRAMES_SHORT);

magb_hangup(&g_magb);
```

`MAGB_P2P_CONNECTION_ID` is `0xFF` — a telephone session, not a TCP
connection id from `magb_tcp_open()`.

**Define your own framing inside those payloads.** This TestSuite's
`MATS` header (magic + version + sequence + length, in
`test_runner.c`) is one example and is *not* part of the Mobile Adapter
protocol — do not copy it as if it were. Any self-describing header a
few bytes long works; the point is that the far end can tell your data
from garbage, since Transfer Data gives you no framing of its own.

Twelve-digit numbers like `127000000001` dial a direct IPv4 address —
that is libmobile's own `mobile_parse_phoneaddr()`, not a libmobile-bgb
special case. A REON relay deployment assigns real numbers instead, and
relay mode is configured on the `mobile` process, not in your ROM. The
two are different mechanisms; a relay-assigned number is not usable on
the direct-IP path. See `docs/protocol-notes.md`.

---

## 7. Pace yourself

A real Mobile Trainer does not pull as fast as the link allows. A
millisecond-stamped capture of one shows ~400 ms between data blocks of
a single transfer, and ~1 s between idle polls.

Running flat out exercises timing paths no real client takes, and stops
exercising the ones it does. That is not theoretical: REON's POP3 path
has a race a real Mobile Trainer never hits and a fast client hits
immediately. If your game talks to a service built for the original
hardware, match the original's rhythm. `TEST_PACING_RECV_FRAMES` (24
VBlanks) and `TEST_PACING_IDLE_FRAMES` (60) are this ROM's version.

---

## 8. Build wire strings explicitly, not with `sprintf`

`src/protocol/magb_fmt.c` is four small functions —
`magb_fmt_str`/`_u16`/`_hex8`/`_hex16` — that append at a cursor and
return the new one, so a header is built by chaining them.

They exist because a program whose job is putting exact bytes on a wire
should not derive those bytes from a formatter it cannot test. The
width matters in ways `%x` gets wrong: a checksum of `0x0F00` must go
out as `"0F00"`, never `"F00"`, and that only shows up for one value in
sixteen. `tests/host/test_fmt.c` covers the leading-zero cases on the
host.

Honest note: these were introduced while chasing a bug that turned out
to be a buffer overflow elsewhere, not an SDCC `sprintf` fault. `%u`
works. They are kept as a tested precaution, and the correction is
recorded in `docs/protocol-notes.md` rather than quietly edited away.

---

## 9. GB00 auth is REON's, not Nintendo's

`src/app/gb00_auth.c` implements REON's HTTP challenge/response for
Pokémon-Crystal-era downloads and uploads. It rides inside ordinary
HTTP over an ordinary TCP connection. It is **application-layer**, not
Mobile Adapter protocol — that is why it lives in `src/app/`.

`md5()`, `base64_encode()` and `base64_decode()` in it are generic and
reusable for anything. `gb00_build_authorization()` only means
something against REON or a service copying its scheme exactly.

**Three things to know before you use it:**

1. **Download and upload do not authenticate the same way.**
   `download.php` calls `doAuth(1)`; `upload.php` calls `doAuth(0)`,
   which `exit()`s after issuing a `Gb-Auth-ID` — so an upload is
   **three** requests, not two, and the body of the second is
   discarded. `doAuth(2)` ("utility") reuses a cached Authorization for
   15 minutes.

2. **There are three distinct kinds of 401** and they mean different
   things: `Gb-Status: 201` (credential rejected — wrong password),
   `WWW-Authenticate:` present (challenge expired, retry with the new
   one), and a bare 401 (the `Gb-Auth-ID` session is dead). Treating
   them as one error makes a wrong password indistinguishable from a
   stale session.

3. **Size the Authorization buffer from the constants.** The header is
   `"Authorization: GB00 name=\""` + `GB00_AUTHORIZATION_LEN` (92) +
   `"\"\r\n"`. Deriving that by hand cost this project a day: a buffer
   declared 112 bytes for 122 bytes of content overflowed into the
   adjacent `Gb-Auth-ID`, which then contained a stray NUL, which made
   `strlen()` report seven bytes short, which sent a truncated request.
   Compute it with `sizeof` on the literals and assert it at compile
   time — `bb_challenge_auth()` in `test_runner.c` shows how.

### Building it

`gb00_auth.c` is the one banked translation unit here (`#pragma bank
255`, MBC5, `-autobank`). If you are copying it into a mapperless ROM
that has room, drop the pragma and it is ordinary code. If you are
copying it into a banked ROM, three traps apply and they are all
documented in `docs/protocol-notes.md` ("ROM banking (MBC5)"):

- `BANKED` must appear on **both** the prototype and the definition. A
  mismatch compiles cleanly and jumps into the wrong bank at runtime.
- The bank trampoline (`___sdcc_bcall_ehl`) must live below `0x4000`,
  or it unmaps itself on every banked call. Pin `_HOME` low
  (`-Wl-b_HOME=0x0200`).
- A banked module must not call anything outside itself unless that
  target is also below `0x4000`. `gb00_auth.c` carries its own
  `memcpy`/`strlen` for this reason.

`make check-banking` in this repo enforces all three mechanically,
including a ROM scan for direct `CALL`s into banked functions. It is
~150 lines of Makefile and Python (`tools/check_far_calls.py`) and is
worth porting if you bank anything.

---

## 10. Persisting a password (and what that means)

`src/app/save.c` writes one record to cartridge SRAM:

```text
0  'M'    2  layout version    4..  password bytes
1  'A'    3  length (0..cap)   4+n  additive checksum of bytes 0..4+n-1
```

Magic, version and checksum must *all* agree before a single byte is
handed back. Uninitialized cart RAM is arbitrary bytes; "looks like a
password" is not good enough. The stored length is validated against
both the format's cap and the caller's buffer before it indexes
anything — it comes out of battery-backed RAM, which is as untrusted as
any other external input.

Needs a cart type with RAM+BATTERY (`0x1B` for MBC5 here) and one RAM
bank. `ENABLE_RAM` / `SWITCH_RAM(0)` / `DISABLE_RAM` around every
access — leaving RAM enabled across a power-off is the classic way to
corrupt a save, since the write-enable latch is what protects it while
the supply collapses.

**The `.sav` holds the credential in plain text.** There is nothing on
a Game Boy to encrypt it with, and a cart's owner can always read its
own save RAM. Don't commit it, don't attach it to a bug report.

And keep the distinction this project had to learn the hard way:
**persisted is not defaulted.** An absent or corrupt record loads as
empty, and the code that needs a password refuses to run rather than
sending a guess. A compiled-in default `"test"` once masked a real
server-side 401 behind a misleading symptom for a full day.

---

## 11. What not to copy — and what to steal instead

| Don't link | Do steal the pattern |
| --- | --- |
| `src/app/test_runner.c` | `tcp_send_all()` chunking (§5); `read_isp_identity()`; the line-based `tcp_send_line()`/`tcp_recv_line()` pair if you speak SMTP/POP3 |
| `src/app/ui.c` | the trace ring buffer (`magb_trace_record()`, already in `magb_session.h`) makes a good in-game debug overlay |
| `include/test_config.h` | its structure: one header, every environment-dependent value, overridable from the build |
| `MATS` framing | the *idea* of a self-describing header inside Transfer Data (§6) |

---

## 12. Mistakes this project already made, in one list

Full write-ups in `docs/protocol-notes.md`. Don't reintroduce these:

- **`SC_REG` must be written twice**, not as one combined `0x83`. Prime
  the clock/speed bits with the start bit clear, then set the start bit
  separately — Pokémon Crystal's real driver never combines them, and
  the combined version left the adapter seeing idle bytes forever.
- **Don't validate ACK bytes by exact expected value.** The relay path
  can deliver a meaningful byte one transfer later than a synchronous
  reading of libmobile predicts. Tolerate `0xD2` at every checkpoint,
  not just in the dedicated wait loop. Only `0xF0`/`0xF1`/`0xF2` are
  safe to treat as fatal there; the response frame's own checksum is
  the authoritative signal.
- **Bound every external wait.** Two independent bounds: a byte-level
  loop counter in `serial_hw.c` (finite, uncalibrated — it only has to
  not be infinite) and a real VBlank-counted budget in the protocol
  layer for multi-second waits. A missing adapter must never hang the
  ROM.
- **8-bit length arithmetic wraps** exactly where payloads get
  interesting (§5).
- **A discarded Transfer Data response is a lost response** (§5).
- **Derive buffer sizes from constants, assert them** (§9).
