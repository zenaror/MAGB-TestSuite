/** Compile-time TestSuite configuration.
 *
 * Override any of these on the `make` command line, e.g.:
 *   make CFLAGS_EXTRA='-DTEST_HTTP_HOST=\"myserver.example\"'
 * or by editing this file directly for a local build.
 *
 * Every default below is a REAL value taken from the reference
 * implementations this TestSuite validates against -- none of it is
 * invented. See docs/protocol-notes.md, "Test configuration sources"
 * for the exact file:line citations.
 */
#ifndef TEST_CONFIG_H
#define TEST_CONFIG_H

/* ISP dial string and login ID -- FALLBACK DEFAULTS ONLY. Every
 * ISP-touching test (test_isp_http(), test_isp_news_article(),
 * test_isp_email_send/recv() in test_runner.c, via the shared
 * read_isp_identity() helper) reads the real dial string
 * (Configuration Slot 1, BCD-decoded) and login ID
 * (MAGB_CONFIG_OFF_LOGIN_ID) live from the adapter's own Read
 * Configuration Data (0x19) response, exactly like the email tests
 * already read email/SMTP/POP -- per the project owner's own request
 * ("se algo exigir autenticacao, voce tem que ler todas as infos
 * necessarias da config do adaptador"). These two constants are only
 * used if the adapter has never been registered via Mobile Trainer
 * (a blank config), so this TestSuite still runs against libmobile's
 * default unregistered config exactly as before.
 *
 * "#9677" is the real DION PDC ISP number: it is hardcoded as a
 * recognized special case in libmobile/commands.c (isp_numbers[]) and
 * is the exact same value REON's own config.example.json uses for
 * mobile_center_numb. "test" as a login ID is not the shape of a real
 * registered account (Dan Docs documents the real format as
 * "gXXXXXXXXX", see docs/dandocs-magb.md) -- it only ever gets used as
 * this last-resort fallback. libmobile's PPP login handler
 * (command_ppp_connect) does not check login/password against any
 * external account system -- it only echoes back an assigned IP + DNS
 * servers -- so any login/password works against it at the
 * Mobile-Adapter level regardless. A real REON deployment's web-facing
 * (HTTP/GB00) auth, and its POP3/SMTP mail auth, both need a real
 * account's real login ID and password -- see TEST_ISP_PASSWORD_MAX_LEN
 * below for where the password itself comes from instead. */
#define TEST_ISP_PHONE        "#9677"
#define TEST_ISP_LOGIN        "test"

/* ISP account password -- unlike the dial string and login ID above,
 * there is deliberately NO compile-time default/fallback constant
 * here. No password field exists anywhere in the documented 192-byte
 * configuration layout (it is only ever kept in a game's own save
 * data), so it can never be read from Read Config either -- it has to
 * come from the user, via the "ISP PASSWORD" menu entry
 * (ui_edit_text() in main.c, kept only in RAM; this ROM has no
 * mapper/save). An earlier version of this file *did* define
 * TEST_ISP_PASSWORD "test" as a default, which silently masked a real
 * server-side 401/-ERR behind a misleading symptom for a full day of
 * debugging (see docs/protocol-notes.md's GB00 section) -- removed for
 * exactly that reason. `require_password()` in test_runner.c now fails
 * any test that actually authenticates (GB00 HTTP, POP3) with an
 * explicit "SET ISP PASSWORD" message while the password is still
 * empty, rather than guessing one.
 *
 * TEST_ISP_PASSWORD_MAX_LEN caps the ISP PASSWORD screen's editable
 * length at 8 characters (the project owner's own account password,
 * "pass157", is 7) -- well under the Mobile Adapter protocol's own
 * 0x20-byte ISP Login password field limit; this is purely this
 * TestSuite's own UI constraint. */
#define TEST_ISP_PASSWORD_MAX_LEN 8U

/* 0.0.0.0 tells the adapter "use your own configured DNS" -- confirmed
 * libmobile behavior (commands.c command_ppp_connect): a zeroed DNS
 * entry in the request is replaced with the locally configured
 * server in the response, rather than being rejected. */
#define TEST_DNS_PRIMARY_A    0
#define TEST_DNS_PRIMARY_B    0
#define TEST_DNS_PRIMARY_C    0
#define TEST_DNS_PRIMARY_D    0
#define TEST_DNS_SECONDARY_A  0
#define TEST_DNS_SECONDARY_B  0
#define TEST_DNS_SECONDARY_C  0
#define TEST_DNS_SECONDARY_D  0

/* gameboy.datacenter.ne.jp is the real historical Mobile System GB /
 * DION datacenter hostname: it is REON's own ServerName/DNS entry
 * (vhost.example.conf, docker-dns-entry.sh) AND is literally the host
 * embedded in Pokémon Crystal's real "Mystery Egg" metadata file that
 * ships in REON's test dataset (see TEST_HTTP_PATH below).
 *
 * TEST_HTTP_PATH is not a guess: it is the exact request Pokémon
 * Crystal's "Mystery Egg" (tamago) feature performs against the
 * Mobile Adapter datacenter to check for an available egg download.
 * The requested file genuinely exists in REON's test dataset
 * (web/cgb/download/01/CGB-BXTJ/tamago/index.txt) and requires no
 * authentication (REON's doAuth() only challenges requests whose
 * filename has a numeric cost prefix, e.g. "10.foo.php" --
 * "index.txt" has none). This makes it an ideal TestSuite HTTP
 * target: a small, deterministic, real Pokémon Crystal download with
 * no extra protocol (like REON's custom GB00 upload auth) to
 * implement. Its content is itself the literal URL template
 * "http://gameboy.datacenter.ne.jp/cgb/download?name=/01/CGB-BXTJ/tamago/tamagoXX.pkm",
 * confirming both this host and this path convention independently. */
#define TEST_HTTP_HOST        "gameboy.datacenter.ne.jp"
#define TEST_HTTP_PORT        80
#define TEST_HTTP_PATH        "/cgb/download?name=/01/CGB-BXTJ/tamago/index.txt"

/* REON's synthetic MAGBTEST fixtures. Neither is a real licensed
 * title's endpoint -- deliberately not a "CGB-XXXX-NN"-shaped folder,
 * since that format belongs to real cartridges (see repo-root
 * CLAUDE.md: "This is NOT a Pokemon Crystal clone and must not contain
 * Pokemon-specific game code").
 *
 * These replaced a "NEWS ARTICLE" test that fetched Pokemon Crystal's
 * own news endpoints (/01/CGB-BXTJ/news/config.php and 100.news.php).
 * It worked, but it validated the GB00 handshake against real game
 * data; the project owner asked for synthetic data instead, which is
 * what these are.
 *
 * The two differ only in size, and that difference is the point:
 *
 *   BIG   (TEST_BIGBUFFER_SIZE) is far larger than one Transfer Data
 *         (0x15) response and than any buffer this ROM could hold, so
 *         it exercises the streaming path -- a running 16-bit additive
 *         checksum computed chunk by chunk, never buffered in full --
 *         plus a full upload round trip.
 *   SMALL (TEST_SMALLBUFFER_SIZE) fits in a SINGLE Transfer Data
 *         response, so it exercises the opposite regime: no streaming,
 *         no chunking, header and body arriving together.
 *
 * They also reach different halves of REON's auth. download.php calls
 * doAuth(1) and upload.php calls doAuth() (type 0), which is what BIG
 * uses. doAuth(2) -- "utility" auth -- is reached only by a script that
 * authenticates itself, the way news.php does, with download.php's
 * $skipCostAuth letting it through. SMALL mirrors that mechanism, so
 * removing the news test does not take doAuth(2) coverage with it.
 * See docs/protocol-notes.md, "GB00: download and upload do NOT
 * authenticate the same way". */

/* REON's dedicated "BIG BUFFER" stress-test fixture -- unlike every
 * other path above, this is NOT a real licensed title's endpoint
 * (deliberately not a "CGB-XXXX-NN"-shaped folder, since that format
 * is reserved for real cartridges; see repo-root CLAUDE.md's "This is
 * NOT a Pokémon Crystal clone and must not contain Pokémon-specific
 * game code"). Added specifically to exercise a body (TEST_BIGBUFFER_
 * SIZE bytes) far larger than any single Transfer Data (0x15)
 * response and any buffer this mapperless, no-SRAM ROM could hold at
 * once -- see gb00_stream_request()/test_isp_big_buffer() in
 * test_runner.c for how that's verified (a running 16-bit additive
 * checksum computed while streaming, never buffered in full). Same
 * GB00 challenge/response auth (REON's doAuth()) and host as News/
 * Tamago above, relayed cross-session while implementing this test,
 * not independently confirmed against REON's PHP source the way the
 * paths above were. */
#define TEST_HTTP_BIGBUFFER_DOWNLOAD_PATH "/cgb/download?name=/01/MAGBTEST/0.bigbuffer.cgb"
#define TEST_HTTP_BIGBUFFER_UPLOAD_PATH   "/cgb/upload?name=/01/MAGBTEST/0.bigbuffer.cgb"
#define TEST_BIGBUFFER_SIZE 8192U

/* The small half of the pair. 128 bytes fits inside one Transfer Data
 * payload, so the whole response lands in a single read -- the regime
 * BIG BUFFER never touches. Same body contract as BIG (body[i] ==
 * i & 0xFF) and the same X-Test-Checksum header, so there is only one
 * format to reason about; the expected checksum is 127*128/2 = 8128
 * (0x1FC0). Reached through REON's doAuth(2) rather than doAuth(1),
 * which requires a self-authenticating script server-side plus a
 * download.php $skipCostAuth entry -- see this file's block comment
 * above and the note in docs/protocol-notes.md. */
#define TEST_HTTP_SMALLBUFFER_PATH "/cgb/download?name=/01/MAGBTEST/0.smallbuffer.cgb"
#define TEST_SMALLBUFFER_SIZE 128U

/* ---- Pacing -----------------------------------------------------------
 *
 * How long to wait between successive receive polls on one connection,
 * in VBlanks (~59.7 Hz, so ~17 ms each).
 *
 * These are not invented. They come from a millisecond-timestamped BGB
 * capture of the REAL Mobile Trainer, relayed by the person running the
 * REON server, and the numbers were consistent across the whole
 * transfer:
 *
 *   between data blocks in one HTTP transfer: 389, 389, 391, 405, 418,
 *     336 ms -- call it ~400 ms. Mobile Trainer does NOT pull as fast
 *     as the link allows; it takes a block, processes it, and only then
 *     asks for the next.
 *   idle after a transfer finished: 929..1067 ms, ~1 s, for 11 s before
 *     it disconnected.
 *
 * Why a TestSuite should care, beyond faithfulness: running flat out
 * exercises timing paths no real client ever takes, and stops
 * exercising the ones it does. That is not hypothetical here -- REON's
 * own POP3 path has a race (its `+OK` for PASS is emitted outside the
 * callback that populates the maildrop) that the real Mobile Trainer
 * never hits and a fast test client hits immediately. Both regimes are
 * worth being able to run, which is why these are constants rather than
 * hardcoded delays:
 *
 *   make CFLAGS_EXTRA='-DTEST_PACING_RECV_FRAMES=0 -DTEST_PACING_IDLE_FRAMES=0'
 *
 * gives back the old flat-out behaviour for stress runs. Zero is
 * handled explicitly (no wait at all), not as a one-frame wait.
 *
 * Pacing is ALL that was taken from that capture. It also shows Mobile
 * Trainer opening several short sessions before it dials, with varying
 * EEPROM read lengths and multi-second gaps -- that is recorded in
 * docs/protocol-notes.md as an observation and deliberately not
 * implemented. It was, briefly, and it was a mistake: it changed what
 * the tests *are* rather than how fast they run, and a handshake test
 * that performs four prior handshakes is no longer a handshake test.
 * The capture was reference material for rhythm, not a feature. */
#define TEST_PACING_RECV_FRAMES 24U /* ~400 ms between blocks of one transfer */
#define TEST_PACING_IDLE_FRAMES 60U /* ~1 s between idle polls */


/* Mobile Trainer's real home page -- Dan Docs' "Mobile Trainer"
 * section documents this exact observed URL
 * (http://gameboy.datacenter.ne.jp/01/CGB-B9AJ/index.html,
 * CGB-B9AJ being Mobile Trainer's own game code). No auth needed (it's
 * outside REON's /cgb/download|upload front controller entirely, so
 * doAuth()'s cost-prefix check never even applies). Was originally
 * labeled "Custom" as a generic user-overridable target; renamed to
 * "Trainer Home" once it became clear it always held this one real,
 * specific URL rather than an actually-custom one. Still fine to
 * repoint at your own deployment (e.g. a LAN IP) if you want a genuine
 * custom target instead. */
#define TEST_HTTP_TRAINER_HOME_HOST "gameboy.datacenter.ne.jp"
#define TEST_HTTP_TRAINER_HOME_PORT 80
#define TEST_HTTP_TRAINER_HOME_PATH "/01/CGB-B9AJ/index.html"

/* 12-digit IP-style phone number: libmobile's own mobile_parse_phoneaddr()
 * (util.c) parses any 12-digit MAGB_CMD_DIAL payload as 4 groups of 3
 * decimal digits -> an IPv4 address, independent of libmobile-bgb.
 * "127000000001" -> 127.0.0.1 (loopback: two TestSuite ROMs talking to
 * the same local libmobile-bgb instance). Override with another host's
 * IP in this same 12-digit form for a two-machine test -- the adapter
 * then opens a direct outbound TCP connection to <that IP>:p2p_port
 * (default 1027, MOBILE_DEFAULT_P2P_PORT), so that port needs to be
 * mutually reachable between the two machines. This value only means
 * anything on that direct-IP path: a real REON relay-assigned number
 * is not usable here at all -- relay mode is a separate mechanism,
 * enabled on the `mobile` process itself (`--relay <addr>`, not this
 * ROM), and once active the dialed number goes to the relay server's
 * own call-matching protocol instead of ever being parsed as an IP
 * (see libmobile's commands.c: command_tel() branches on
 * adapter->config.relay.type before this parsing is ever reached).
 * Editable at runtime from the P2P Caller menu (digit-entry screen). */
#define TEST_P2P_PHONE        "127000000001"

/* "RAW TCP" test target -- mirrors gba-link-connection's own
 * description of a real "ISP call (PPP)" test: dial the ISP, open a
 * TCP socket to an arbitrary address, and transfer arbitrary data.
 * Point this at a machine running `nc -l <port>` (or `ncat`/`socat`
 * equivalents) and whatever you type there is transferred to the ROM
 * and shown on screen live, character by character -- see
 * test_isp_raw_tcp() in test_runner.c. No auth, no fixed request/
 * response shape: this is the one ISP test that's genuinely
 * open-ended/interactive rather than scripted.
 *
 * Defaults to the loopback address (127.0.0.1) -- point it at your own
 * dev machine's actual LAN IP at runtime from the ISP/HTTP submenu
 * (digit-entry screen) before running the test, since the adapter/
 * network backend generally can't reach the Game Boy's own loopback.
 * The port is compile-time only -- override via CFLAGS_EXTRA if 8080
 * collides with something. */
#define TEST_ISP_RAW_IP   "127000000001"
#define TEST_ISP_RAW_PORT 8080

#endif /* TEST_CONFIG_H */
