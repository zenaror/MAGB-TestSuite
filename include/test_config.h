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

/* ISP dial string. "#9677" is the real DION PDC ISP number: it is
 * hardcoded as a recognized special case in libmobile/commands.c
 * (isp_numbers[]) and is the exact same value REON's own
 * config.example.json uses for mobile_center_numb. libmobile's PPP
 * login handler (command_ppp_connect) does not check login/password
 * against any external account system -- it only echoes back an
 * assigned IP + DNS servers -- so "test"/"test" works against it
 * as-is. Against a real REON deployment's web-facing (HTTP/GB00)
 * auth, you would need a real account (see REON's own
 * `add_user.php`), but that is a separate, application-layer concern
 * from the Mobile-Adapter-level ISP login exercised by this test. */
#define TEST_ISP_PHONE        "#9677"
#define TEST_ISP_LOGIN        "test"
#define TEST_ISP_PASSWORD     "test"

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

/* Two more real, no-invented-URL targets on the same host, from the
 * same REON test dataset, covering Pokémon Crystal's other real
 * Mobile Adapter datacenter feature: the Goldenrod Communication
 * Center "News" service (`web/cgb/download/01/CGB-BXTJ/news/`).
 *
 * Both of these require REON's GB00 challenge/response HTTP auth --
 * confirmed by reading web/cgb/pokemon/news.php, not assumed: unlike
 * the tamago index.txt above, BOTH get_news_parameters_bin()
 * (config.php) and get_news_file() (100.news.php) unconditionally
 * call doAuth(2) ("Pokémon news + ranking endpoints require auth even
 * if free"). The numeric-cost-prefix exemption that lets tamago's
 * index.txt through only skips the *front controller's* cost check --
 * it does not stop the PHP script itself from demanding auth once
 * executed. This TestSuite implements that handshake (see
 * `include/gb00_auth.h`, `test_isp_http_gb00()` in test_runner.c, and
 * docs/protocol-notes.md's "GB00 HTTP authentication") using
 * TEST_ISP_LOGIN/TEST_ISP_PASSWORD as the account credentials. */
#define TEST_HTTP_NEWS_CONFIG_PATH "/cgb/download?name=/01/CGB-BXTJ/news/config.php"
#define TEST_HTTP_NEWS_PATH        "/cgb/download?name=/01/CGB-BXTJ/news/100.news.php"

/* Custom/extra HTTP target. Change the host to your own deployment
 * (e.g. a LAN IP) if you're not testing against the public REON
 * datacenter host used above. */
#define TEST_HTTP_CUSTOM_HOST "gameboy.datacenter.ne.jp"
#define TEST_HTTP_CUSTOM_PORT 80
#define TEST_HTTP_CUSTOM_PATH "/01/CGB-B9AJ/index.html"

/* 12-digit IP-style phone number: libmobile's own mobile_parse_phoneaddr()
 * (util.c) parses any 12-digit MAGB_CMD_DIAL payload as 4 groups of 3
 * decimal digits -> an IPv4 address, independent of libmobile-bgb.
 * "127000000001" -> 127.0.0.1 (loopback: two TestSuite ROMs talking
 * to the same local libmobile-bgb instance). Override for a REON
 * relay-assigned number or another host's IP. This can also be
 * changed at runtime from the P2P Caller menu (digit-entry screen). */
#define TEST_P2P_PHONE        "127000000001"

#endif /* TEST_CONFIG_H */
