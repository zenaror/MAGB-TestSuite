# Using this TestSuite's protocol code in your own homebrew

This TestSuite's hardware (`src/hw/`) and protocol (`src/protocol/`)
layers were written to be a self-contained, reusable Mobile Adapter GB
client -- GBDK-2020 has no such API of its own (see
`docs/protocol-notes.md` for why every byte of this is hand-rolled).
The application layer (`src/app/`, `src/main.c`) is TestSuite-specific
and not meant to be copied; the layers below it are.

## 1. What to copy

```
include/serial_hw.h
include/magb_protocol.h
include/magb_commands.h
include/magb_session.h
include/magb_network.h

src/hw/serial_hw.c
src/protocol/magb_packet.c
src/protocol/magb_session.c
src/protocol/magb_network.c
```

Drop these into your own project's `include/`/`src/` (or a
subdirectory of your choosing) and add the four `.c` files to your
build. Nothing here depends on `src/app/*` or `test_config.h` --
`magb_network.c`'s functions all take their parameters (ISP number,
login, hostname, IP, port, ...) as arguments rather than reading
compile-time constants, so there is nothing TestSuite-specific to
strip out.

Do **not** copy `src/app/test_runner.c`'s `MATS` framing
(`mats_build`/`mats_parse`) verbatim -- that is this TestSuite's own
diagnostic payload-inside-Transfer-Data format, invented for this
project's P2P test, not part of the Mobile Adapter protocol. Use it
only as a *pattern* for defining your own application-level framing
inside `magb_transfer_data()` payloads (see step 5).

## 2. One-time setup

```c
#include "serial_hw.h"
#include "magb_session.h"

static magb_context_t g_magb;

void my_game_init(void) {
    serial_hw_init();          /* CGB check + cpu_fast(); halts with a
                                 * fatal message if not a CGB */
    magb_context_init(&g_magb);
}
```

`serial_hw_init()` also calls GBDK's `set_default_palette()` (see
`docs/protocol-notes.md`, "CGB display bring-up") because this
TestSuite has no other palette of its own. If your game already
manages CGB background palettes, drop that one call from your copy of
`serial_hw_init()` -- it exists only because the TestSuite would
otherwise render invisible white-on-white text, and calling it twice
with different palette data would just make your own palette 0 get
overwritten.

If you want the player able to abort a long operation (dialing, DNS,
TCP, waiting for a P2P call) with a button press, wire up the same
hook the TestSuite's UI uses:

```c
static bool my_cancel_check(void) {
    return (joypad() & J_B) != 0;
}
...
g_magb.cancel_check = my_cancel_check; /* optional; NULL = no cancel */
```

This is the *only* place `magb_session.h`'s API touches anything
joypad-related, and only as an opaque function pointer -- the protocol
code itself never calls `joypad()`.

## 3. Recipe: Begin a session, do something, end it

Every real interaction with the adapter follows this shape:

```c
magb_result_t r = magb_begin_session(&g_magb);
if (r != MAGB_OK) {
    /* handle failure -- see magb_protocol.h's magb_result_t and
     * docs/protocol-notes.md's "Official Mobile Adapter GB error
     * codes" if you want to show the player a real NN-NNN code */
    return;
}

/* ... do work, see recipes below ... */

magb_end_session(&g_magb);
```

`g_magb.session_active` is `true` only once Begin Session has been
fully validated (echoed `"NINTENDO"` payload, correct checksum) --
never assume success from a single byte.

## 4. Recipe: fetch something over the internet (ISP/HTTP)

```c
#include "magb_network.h"

magb_phone_status_t phone;
magb_isp_login_result_t isp;
uint8_t dns1[4] = {0,0,0,0}; /* 0.0.0.0 = "use the adapter's own DNS" */
uint8_t dns2[4] = {0,0,0,0};
uint8_t host_ip[4];
uint8_t conn_id;
uint8_t response[128];
uint8_t got_len;
bool remote_closed;

magb_telephone_status(&g_magb, &phone);           /* optional sanity check */
magb_dial(&g_magb, "#9677");                      /* your ISP's dial string */
magb_isp_login(&g_magb, "mylogin", "mypassword", dns1, dns2, &isp);
magb_dns_query(&g_magb, "my.server.example", host_ip);
magb_tcp_open(&g_magb, host_ip, 80, &conn_id);

static const char req[] = "GET /my-endpoint HTTP/1.0\r\nHost: my.server.example\r\n\r\n";
magb_transfer_data(&g_magb, conn_id, (const uint8_t *)req, sizeof(req) - 1,
                    response, sizeof(response), &got_len, &remote_closed,
                    MAGB_TIMEOUT_FRAMES_LONG);
/* keep calling magb_transfer_data() with data=NULL, data_len=0 to poll
 * for more of the response, exactly like test_isp_http() does in
 * src/app/test_runner.c, until remote_closed is true */

magb_tcp_close(&g_magb, conn_id);
magb_isp_logout(&g_magb);
magb_hangup(&g_magb);
```

Check every call's `magb_result_t` return in real code -- the example
above omits that for brevity. `src/app/test_runner.c`'s
`test_isp_http()` is a complete, error-checked reference
implementation of this exact flow, including the response-buffer
accumulation loop.

## 5. Recipe: direct player-to-player link (P2P)

```c
magb_dial(&g_magb, peer_number);   /* or magb_wait_for_call() on the
                                     * receiving side */

/* Define your OWN tiny framing for whatever you're sending -- MATS in
 * test_runner.c is one example, not a protocol requirement. At
 * minimum, send something self-describing enough that the other side
 * can tell real data from garbage; a magic+length header a few bytes
 * long is plenty. */
uint8_t my_payload[16] = { /* ... */ };
uint8_t discard[1];
uint8_t got_len;
bool remote_closed;
magb_transfer_data(&g_magb, MAGB_P2P_CONNECTION_ID, my_payload, sizeof(my_payload),
                    discard, 0, &got_len, &remote_closed, MAGB_TIMEOUT_FRAMES_SHORT);

/* receiving: data_len=0, poll until got_len>0 or remote_closed */
uint8_t incoming[16];
magb_transfer_data(&g_magb, MAGB_P2P_CONNECTION_ID, NULL, 0,
                    incoming, sizeof(incoming), &got_len, &remote_closed,
                    MAGB_TIMEOUT_FRAMES_SHORT);

magb_hangup(&g_magb);
```

`127000000001`-style 12-digit numbers dial directly to an IPv4 address
under libmobile-bgb (see `docs/protocol-notes.md`); a real REON relay
deployment assigns your game an actual phone number instead, which you
dial the same way.

## 6. Things this TestSuite already got wrong once -- don't reintroduce them

If you're tempted to "simplify" while adapting this code, these are
documented, hard-won fixes (full writeups in `docs/protocol-notes.md`):

- **`SC_REG` must be written in two steps**, not combined into one
  `SC_REG = 0x83`-style write -- confirmed against Pokémon Crystal's
  own real serial driver, and against a real BGB + libmobile-bgb link
  where the single-write version left the adapter emulation seeing
  nothing but idle bytes forever.
- **Don't validate ACK1/ACK2 by exact expected value.** The
  BGB<->libmobile-bgb relay path can deliver every meaningful byte one
  transfer later than a synchronous reading of libmobile's source
  predicts. Only the three explicit transport-error codes
  (`0xF0`/`0xF1`/`0xF2`) are safe to treat as fatal at that point; the
  response frame's own checksum is the real, authoritative success
  signal.
- **CGB needs `set_default_palette()`** (or your own palette setup) --
  it does not power on with DMG's legible default.

## 7. What NOT to copy as-is

- `test_config.h`'s ISP/DNS/HTTP defaults are this TestSuite's own
  diagnostic target (a real, working, unauthenticated Pokémon Crystal
  download on REON's test dataset) -- point your own game at your own
  server.
- `src/app/ui.c` and `test_runner.c` are diagnostic-menu code, not
  library code. Use them for *inspiration* (e.g. the trace ring buffer
  in `magb_session.h`/`magb_trace_record()` is genuinely reusable for
  your own in-game debug overlay), not as something to link into a
  shipping game unmodified.
- `src/app/gb00_auth.c`/`gb00_auth.h` (MD5, base64, and REON's GB00
  challenge/response scheme) is **not** Mobile Adapter protocol code
  at all -- it's REON-specific HTTP-application-layer auth for one
  particular recreated service. The `md5()`/`base64_encode()`/
  `base64_decode()` helpers in it are genuinely generic and reusable
  for anything that needs them; `gb00_build_authorization()` itself
  only makes sense if you're talking to REON (or a service that
  copies its exact scheme).
