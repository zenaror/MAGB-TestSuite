# Mobile Adapter GB — Dan Docs Technical Reference

> Source: [Dan Docs — shonumi.github.io/dandocs.html](https://shonumi.github.io/dandocs.html)  
> Scope: the complete **Mobile Adapter GB** hardware section plus the requested **Game and Server Documentation** sections.  
> Dan Docs states that the information in the document is **Public Domain**.  
> This Markdown reorganizes the material as an implementation-oriented reference while preserving known constants, layouts, protocol behavior, unknown fields, edge cases, and documented quirks.

## Contents

### Hardware Documentation

- [Mobile Adapter GB](#mobile-adapter-gb)
  - [General Hardware Information](#general-hardware-information)
  - [Compatible Games](#compatible-games)
  - [Protocol — Packet Format](#protocol--packet-format)
  - [Protocol — Flow of Communication](#protocol--flow-of-communication)
  - [Protocol — Commands](#protocol--commands)
  - [Configuration Data](#configuration-data)

### Game and Server Documentation

- [EX Monopoly (GBA)](#ex-monopoly-gba)
- [Game Boy Wars 3 (GBC)](#game-boy-wars-3-gbc)
- [Hello Kitty no Happy House (GBC)](#hello-kitty-no-happy-house-gbc)
- [Mario Kart Advance (GBA)](#mario-kart-advance-gba)
- [Mobile Pro Yakyuu (GBA)](#mobile-pro-yakyuu-gba)
- [Mobile Trainer (GBC)](#mobile-trainer-gbc)
- [Net de Get: Mini Game @ 100 (GBC)](#net-de-get-mini-game--100-gbc)
- [Zen Nihon GT Senshuken (GBA)](#zen-nihon-gt-senshuken-gba)

---

# Mobile Adapter GB

## General Hardware Information

The Mobile Adapter GB is a Japanese cellular-network accessory for Game Boy Color and Game Boy Advance.

- Release date: **January 27, 2001**.
- Model: **CGB-005**.
- Official service shutdown: **December 14, 2002**.
- Connects a compatible Japanese mobile phone to the Game Boy link port.
- Every adapter was bundled with **Mobile Trainer**, used to configure the service.
- Nintendo's service was hosted under `gameboy.datacenter.ne.jp`.
- Supported use cases included email, downloadable content, direct player communication, rankings, tournaments, and other network services.
- It was Nintendo's first official handheld online-gaming platform.

### Adapter variants

| Color | Network / phone type | Status |
|---|---|---|
| Blue | PDC | Released |
| Yellow | cdmaOne | Released |
| Red | DDI | Released |
| Green | PHS | Planned, never released |

## Compatible Games

### Game Boy Color — 6

- Game Boy Wars 3
- Hello Kitty: Happy House
- Mobile Golf
- Mobile Trainer
- Net de Get Minigames @ 100
- Pocket Monsters Crystal Version

### Game Boy Advance — 16

- All-Japan GT Championship
- Daisenryaku For Game Boy Advance
- Doraemon: Midori no Wakusei Doki Doki Daikyuushuutsu!
- Exciting Bass
- EX Monopoly
- JGTO Licensed: Golfmaster Mobile
- Kinniku Banzuke ~Kongou-kun no Daibouken!~
- Mail de Cute
- Mario Kart Advance
- Mobile Pro Baseball: Control Baton
- Monster Guardians
- Morita Shougi Advance
- Napoleon
- Play Novel: Silent Hill
- Starcom: Star Communicator
- Zero-Tours

Cancelled Mobile Adapter projects:

- `beatmaniaGB Net Jam` — GBC
- `Horse Racing Creating Derby` — GBA

`Yu-Gi-Oh! Duel Monsters 5 Expert 1` contains Mobile Adapter library/code, but the released GBA game does not appear to expose the functionality.

## Protocol — Packet Format

### Serial mode

#### Game Boy Color

- Uses the fastest GBC serial mode documented by Dan Docs, approximately **64 Kbit/s**.
- Bits 0 and 1 of `SC` (`0xFF02`) are set.
- Uses the Game Boy's internal serial clock.

#### Game Boy Advance

- Uses `NORMAL8`.
- Shift clock: **256 KHz**.

### Packet layout

```text
Magic bytes             2 bytes
Packet header            4 bytes
Packet data              0-254 bytes on GBC
Packet checksum          2 bytes
Acknowledgement signal   2 bytes
```

Magic:

```text
99 66
```

Header:

```text
Byte 0   Command ID
Byte 1   Unknown / unused; normally 00
Byte 2   Packet Data length high byte
Byte 3   Packet Data length low byte
```

Packet Data is arbitrary command-specific data.

### Packet length limits

On GBC, supported software limits Packet Data to **254 bytes**. Dan Docs attributes this to a 256-byte area shared by Packet Data and its two-byte checksum.

Although GBA software can represent a larger 16-bit Packet Data length, the real Mobile Adapter discards packets larger than 255 bytes. In practical terms, the high byte of the length remains zero.

Larger application-level transfers are split across multiple Mobile Adapter packets.

### Checksum

The packet checksum is the unsigned 16-bit additive sum of:

- all four Packet Header bytes; and
- all Packet Data bytes.

The two magic bytes are **not** included.

Checksum byte order is **big-endian**.

### Acknowledgement signal

After the checksum, both devices exchange two acknowledgement bytes.

```text
Byte 0   Device ID OR 80h
Byte 1   Role / command acknowledgement / error
```

Normal values:

- Sender byte 1: `00`.
- Receiver byte 1: `Command ID XOR 80h`.

Examples:

- `19` — the Game Boy requests configuration data from the adapter.
- `1A` — the Game Boy sends configuration data to the adapter.

Packet-level acknowledgement errors:

| Value | Meaning |
|---|---|
| `F0` | Command unsupported / not implemented |
| `F1` | Checksum failed |
| `F2` | Internal error, e.g. TCP/telephone transfer buffer full |

When `F1` is returned, the sender retries immediately, up to four attempts.

### Device IDs

| Device ID | ID OR `80h` | Device |
|---:|---:|---|
| `00` | `80` | Game Boy Color |
| `01` | `81` | Game Boy Advance |
| `08` | `88` | PDC adapter — Blue |
| `09` | `89` | cdmaOne adapter — Yellow |
| `0A` | `8A` | PHS adapter — Green |
| `0B` | `8B` | DDI adapter — Red |

## Protocol — Flow of Communication

The Game Boy remains responsible for clocking the serial interface. Even when data is arriving from a remote server, the handheld must continue initiating serial transfers to pull additional bytes from the adapter.

HTTP, POP3, SMTP and other application protocols are implemented by the **game software**, not by the adapter. The adapter provides telephone/network connectivity and TCP/UDP transport.

### Wait bytes

When the Game Boy is transmitting a packet, the Mobile Adapter returns `D2` while waiting for the outgoing packet to finish.

When the adapter is transmitting a packet, the Game Boy sends `4B` while clocking in the response.

Conceptually:

| Device | Role | Magic / wait bytes | Ack byte 1 |
|---|---|---|---|
| Game Boy | Sender | `99 66` | `00` |
| Mobile Adapter | Receiver | `D2 D2 ...` | `Command XOR 80h` |
| Game Boy | Receiver | `4B 4B ...` | `Command XOR 80h` |
| Mobile Adapter | Sender | `99 66` | `00` |

> **Source inconsistency:** the Dan Docs flow table prints `96 66` for the sender magic bytes, while the packet-format section specifies `99 66`. The latter is the documented Mobile Adapter packet magic and is used throughout this Markdown; the `96` entry appears to be a typo in the original table.

### Common startup sequence

A frequently observed library-style sequence is:

```text
10  Begin Session
11  End Session
10  Begin Session

19  Read Configuration Data — first 96 bytes
19  Read Configuration Data — second 96 bytes
11  End Session

10  Begin Session
19  Read Configuration Data — first 96 bytes
19  Read Configuration Data — second 96 bytes

17  Telephone Status
12  Dial Telephone
21  ISP Login
28  DNS Query
```

After that, the game chooses the required TCP/UDP/application protocol operations.

### Wake and sleep behavior

The first byte returned after the GBC/GBA begins talking to a sleeping adapter is garbage. That first transfer wakes the adapter.

Recommended behavior:

1. Perform one serial transfer to wake it.
2. Wait approximately **100 ms**.
3. Start normal packet communication.

Without the delay, more garbage may be received.

While awake and idle during a Game Boy transmission, the adapter returns `D2`.

After roughly **3 seconds without a serial byte**, the adapter sleeps. Sleeping implicitly:

- cancels the command being processed;
- closes current connections;
- ends the session.

## Protocol — Commands

### `0F` — Empty

```text
Sent:     no Packet Data
Received: no reply packet beyond acknowledgement
```

Likely a ping. Not observed in released games.

### `10` — Begin Session

```text
Sent:     ASCII "NINTENDO" — exactly 8 bytes, no NUL
Received: ASCII "NINTENDO" — exactly 8 bytes, no NUL
```

The adapter rejects ordinary commands until a session is opened. Calling Begin Session twice returns an error.

### `11` — End Session

```text
Sent:     empty
Received: empty
```

Ends the session, closes connections and hangs up the telephone line.

### `12` — Dial Telephone

```text
Sent:     1 adapter-related byte + ASCII telephone number
Received: empty on success
```

Known first-byte values:

| Adapter | Normal value | Additional behavior |
|---|---:|---|
| Blue / PDC | `00` | also accepts decimal 16 (`10h`) |
| Green / PHS | `01` | — |
| Red / DDI | `01` | also accepts decimal 9 (`09h`) |
| Yellow / cdmaOne | `02` | field apparently not validated |

Telephone number:

- ASCII digits `0`-`9`;
- `#` and `*` are supported;
- other ASCII bytes are ignored;
- maximum length: **32 bytes**.

### `13` — Hang Up Telephone

```text
Sent:     empty
Received: empty
```

Terminates the call and implicitly closes TCP/UDP connections.

### `14` — Wait For Telephone Call

```text
Sent:     empty
Received: empty on success
```

Waits for / picks up an incoming call. If no call exists, it returns immediately with Error Status code `00`.

### `15` — Transfer Data

```text
Sent:     Connection ID + optional arbitrary data
Received: Connection ID + optional arbitrary data
```

Used for:

- TCP after `23`;
- UDP after `25`;
- direct phone-to-phone transfer after `12` or `14`.

TCP/UDP require successful ISP login (`21`).

For network connections, the first byte is the Connection ID. Multiple connections may be open simultaneously.

For direct telephone transfer, the first byte is ignored and is typically `FF`.

The payload is optional. Sending only the Connection ID is useful when polling for incoming data.

Transfers larger than 254 bytes are split across packets.

While a connection is active:

- sender reply command: `15`;
- receiver reply command: `95`.

When a remote TCP peer has closed and no buffered data remains:

- sender reply: `1F`;
- receiver reply: `9F`;
- length: zero.

For TCP, a no-data `15` waits up to roughly one second for incoming data before replying.

Direct phone-to-phone mode does not automatically expose disconnect status through `15`; games can use `17`, although many rely on receive timeouts.

### `16` — Reset

```text
Sent:     empty
Received: empty
```

Equivalent to ending then beginning a session, and also resets SIO32 mode to default.

Not known to be used by released software.

### `17` — Telephone Status

```text
Sent:     empty
Received: 3 bytes
```

#### Byte 0 — phone status

- `FF`: telephone disconnected.
- Bit 2: line busy / active call.
- Bit 0: incoming call present.

Normal connected values therefore include `00`, `01`, `04`, `05`.

`Net de Get: Mini Game @ 100` refuses to operate when bit 0 is set, i.e. status `05`.

#### Byte 1 — adapter / phone-related

| Adapter | Value |
|---|---:|
| Blue / PDC | `4D` |
| Red / DDI | `48` |
| Yellow / cdmaOne | `48` |

Meaning is unknown.

#### Byte 2

Normally `00`. Pokémon Crystal reacts to `F0` by allowing the player to bypass the usual 10-minute-per-day online battle time limit.

### `18` — SIO32 Mode

```text
Sent:     1 byte: 01 enable, 00 disable
Received: empty
```

Primarily useful on GBA.

With SIO32 enabled:

- serial traffic occurs in 4-byte chunks;
- Packet Data is zero-padded to a 4-byte boundary;
- padding is not included in Packet Data length;
- acknowledgement gains two padding bytes, normally zero;
- magic bytes and the rest of the packet are transferred in four-byte units.

Consequently, the checksum may share a transfer unit with the length field for a zero-length packet, or with the last two data bytes for a non-empty packet.

The mode changes only after the reply packet has completed. Allow roughly **100 ms** after toggling or garbage may be returned.

### `19` — Read Configuration Data

```text
Sent:
  offset   1 byte
  length   1 byte

Received:
  offset   1 byte
  data     requested bytes
```

Reads the adapter's 256-byte configuration memory.

- maximum per request: **128 bytes**;
- most software reads the used 192-byte area in two 96-byte requests.

### `1A` — Write Configuration Data

```text
Sent:
  offset   1 byte
  data     bytes to write

Received:
  offset   1 byte
```

Maximum write: **128 bytes**.

### `21` — ISP Login

```text
Sent:
  login ID length      1 byte
  login ID             N bytes
  password length      1 byte
  password             N bytes
  DNS #1               4 bytes
  DNS #2               4 bytes

Received:
  assigned IPv4        4 bytes
  assigned DNS #1      4 bytes
  assigned DNS #2      4 bytes
```

Logs into the DION dial-up service after dialing with `12`.

Login ID and password are length-prefixed, maximum `20h` bytes each.

IPv4 values are four octet bytes.

If either supplied DNS address is zero, the adapter may assign DNS itself and return it. When explicit DNS addresses are supplied, returned DNS values may be `0.0.0.0`.

### `22` — ISP Logout

```text
Sent:     empty
Received: empty
```

Logs out and closes all connections.

### `23` — Open TCP Connection

```text
Sent:
  IPv4 address   4 bytes
  TCP port       2 bytes, big-endian

Received:
  Connection ID  1 byte
```

Requires ISP login.

Examples:

- TCP 25 — SMTP
- TCP 80 — HTTP
- TCP 110 — POP3

The game implements those protocols; the adapter only opens the TCP connection and transports bytes using `15`.

A real Mobile Adapter supports at most **two simultaneous connections**.

### `24` — Close TCP Connection

```text
Sent:     Connection ID
Received: Connection ID
```

### `25` — Open UDP Connection

```text
Sent:
  IPv4 address   4 bytes
  UDP port       2 bytes, big-endian

Received:
  Connection ID  1 byte
```

The UDP connection remains bound to that remote IP/port until closed. Data returned through `15` does not provide sender/source metadata.

### `26` — Close UDP Connection

```text
Sent:     Connection ID
Received: Connection ID
```

### `28` — DNS Query

```text
Sent:     ASCII domain name
Received: IPv4 address, 4 bytes
```

Uses DNS configured by `21`.

A textual IPv4 address is also accepted and parsed in a manner compatible with POSIX `inet_addr()`, avoiding a DNS lookup.

Embedded NUL bytes truncate the input domain name.

### `3F` — Firmware Version

```text
Sent:     empty
Received: no normal Packet Data response
```

On a real adapter this sends firmware information over the phone-side serial pins and leaves the adapter in a state where ordinary commands are no longer accepted. It appears to be a factory/test mode.

Restrictions/recovery:

- cannot be invoked while the telephone line is in use;
- `16` Reset restores normal command handling;
- Blue/PDC additionally appears recoverable with `11` End Session.

### `6E` — Error Status

Returned in response to a failed command.

```text
Byte 0   command that failed
Byte 1   command-specific error status
```

| Command | Error | Meaning |
|---|---:|---|
| `10` | `01` | Begin Session sent twice |
| `10` | `02` | Invalid contents |
| `11` | `02` | Still connected / failed to disconnect (?) |
| `12` | `00` | Telephone line busy |
| `12` | `01` | Invalid use / already connected |
| `12` | `02` | Invalid contents / first byte wrong |
| `12` | `03` | Communication failed / phone not connected |
| `12` | `04` | Call not established; redial |
| `13` | `01` | Already hung up / phone not connected |
| `14` | `00` | No call received / phone not connected |
| `14` | `01` | Already calling |
| `14` | `03` | Internal error; ringing but pickup failed |
| `15` | `00` | Invalid connection / communication failed |
| `15` | `01` | Call ended or never made |
| `16` | `00` | Still connected / failed to disconnect (?) |
| `18` | `02` | First byte is neither `00` nor `01` |
| `19` | `00` | Internal configuration-read error |
| `19` | `02` | Read outside configuration area / request too large |
| `1A` | `00` | Internal configuration-write error |
| `1A` | `02` | Write outside configuration area / request too large |
| `21` | `01` | Not in a call |
| `21` | `02` | Unknown; possibly timeout |
| `21` | `03` | Unknown; possibly internal |
| `22` | `00` | Not logged in |
| `22` | `01` | Not in a call |
| `22` | `02` | Unknown; possibly timeout |
| `23` | `00` | Too many connections |
| `23` | `01` | Not logged in |
| `23` | `03` | Connection failed |
| `24` | `00` | Invalid / nonexistent connection |
| `24` | `01` | Not logged in |
| `24` | `02` | Unknown |
| `25` | `00` | Too many connections |
| `25` | `01` | Not logged in |
| `25` | `03` | Connection failed; source notes this should not normally occur |
| `26` | `00` | Invalid / nonexistent connection |
| `26` | `01` | Not logged in |
| `26` | `02` | Unknown |
| `28` | `01` | Not logged in |
| `28` | `02` | Invalid contents / lookup failed |

## Configuration Data

The adapter exposes a 256-byte configuration address space. The normal software configuration occupies the first **192 bytes** (`00h-BFh`).

```text
00-01   "MA" ASCII header
02      01 while Mobile Trainer registration is in progress;
        81 after registration is complete

04-07   Primary DNS:   210.196.3.183
08-0B   Secondary DNS: 210.141.112.163

0C-15   Login ID, form gXXXXXXXXX
        Mobile Trainer exposes 9 editable characters

2C-43   User email address, e.g. XXXXXXXX@YYYY.dion.ne.jp
4A-5D   SMTP server, e.g. mail.XXXX.dion.ne.jp
5E-70   POP server, e.g. pop.XXXX.dion.ne.jp

76-8D   Configuration Slot #1
8E-A5   Configuration Slot #2
A6-BD   Configuration Slot #3

BE-BF   16-bit big-endian checksum
```

### Configuration slots

Each slot can contain:

- 8-byte telephone number;
- 16-byte ID string.

Telephone number uses a BCD-like representation:

- `0A` = `#`
- `0B` = `*`
- `0F` = end of telephone number

Defaults:

| Phone family | Telephone | ID string |
|---|---|---|
| PDC / CDMA | `#9677` | `DION PDC/CDMAONE` |
| PHS / DDI | `0077487751` | `DION DDI-POCKET` |

Mobile Trainer configures only Slot #1. Remaining slots are filled with `FF`/`00` patterns.

An unidentified Device ID can cause the adapter to overwrite configuration data with garbage values.

### Configuration checksum

The value at `BE-BF` is the 16-bit additive sum of bytes `00-BD`.

Compatible games generally read and validate this configuration before attempting ISP login. Configuration problems commonly produce error `25-000`.

If a `19` or `1A` operation would cross the 256-byte configuration boundary, the **whole operation is cancelled**. No partial transfer occurs; an Error Status packet is returned.

---

# EX Monopoly (GBA)

## General Information

Game Boy Advance title published by Takara, released July 13, 2001.

Mobile Adapter features:

- downloadable news;
- monthly **Mobile Cup** competition;
- three COM games are played and the sum of their scores is uploaded.

## Server Structure

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/A7/AGB-AMOJ/information.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/A7/AGB-AMOJ/query_T.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/A7/AGB-AMOJ/query_M.cgb
http://gameboy.datacenter.ne.jp/cgb/upload?name=/A7/AGB-AMOJ/0.regist.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/A7/AGB-AMOJ/10.temporary.cgb
```

## `information.cgb`

Required size: exactly `2560` bytes (`0A00h`). If shorter, remaining memory retains data from the previous download.

Layout:

- 64 lines;
- 20 two-byte pairs per line.

Validation:

- final pair of each non-final line starts with `FE`;
- final line terminates with `FF`;
- a line is empty if all pairs except the final terminator begin with `A3`;
- if all lines are empty, the file is rejected as corrupt.

Pair parser:

| First byte | Behavior |
|---|---|
| `00-F0` | Draw pair as a tile and advance one tile |
| `F1-FD` | Ignore |
| `FE` | Move to leftmost tile on next line |
| `FF` | Stop parsing immediately |

## `query_T.cgb` / `query_M.cgb`

Same binary response format.

- `query_T.cgb`: POST `today=00`; all-time ranking.
- `query_M.cgb`: `today` selects current/previous monthly ranking.

POST form:

```text
myname=<80 hex digits>&today=<2 hex digits>
```

Response:

```text
00              Ranking count N high byte; should be 00
01              Ranking count N low byte; N <= 10
02...           N ranking entries, 56 bytes each
02 + 56*N       2 bytes; 0000 = player's rank absent
04 + 56*N       Optional player's ranking entry
```

Ranking entry — 56 bytes:

```text
00-03   Rank, big-endian
04-2B   myname structure
2C-33   myscore structure
34      Gender: 00 male, 01 female
35      Age
36      State / prefecture
37      today: high nibble = year modulo 16; low nibble = month
```

`myname` — 40 bytes:

```text
00-03   Player name, right-padded FF
04-23   Email, right-padded 00
24      today
25-27   Normally 00; not validated on download
```

`myscore` — 8 bytes:

```text
00-03   Total score; divisible by 5; maximum 60
04-07   Total cash in dollars
```

## `0.regist.cgb`

Uploading a Mobile Cup result sends **two POST requests** containing:

```text
myname
myscore
gender
age
state
today
```

Values are raw bytes.

Difference:

- first POST: both `today` values are `00`;
- second POST: both contain their correct values.

**Compatibility requirement:** the server must not send a response body. A body prevents the game from closing the connection correctly and it then fails to request `10.temporary.cgb`.

## `10.temporary.cgb`

POST:

```text
myscore=<16 hex digits>
```

Response:

```text
00-01   0000 = no rank
02-05   Optional rank, big-endian
```

Ranks above 10 are displayed as unranked.

Before authentication completes, the game's initial GET sends `Content-Length: 24` but no request body.

## String Format

Control behavior:

- `F1-FD`: ignored by most text code.
- `FE`: line break.
- `FF`: terminator.
- `0200-025E`, valid only in `information.cgb`, map to ASCII `20-7E`.
- `023C` corresponds to ASCII `5C` but is displayed as `¥`.

```text
        0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
00      あ い う え お か き く け こ さ し す せ そ た
10      ち つ て と な に ぬ ね の は ひ ふ へ ほ ま み
20      む め も や ゆ よ ら り る れ ろ わ を ん ゃ ゅ
30      ょ 。 、 が ぎ ぐ げ ご ざ じ ず ぜ ぞ だ ぢ づ
40      で ど ば び ぶ べ ぼ ぱ ぴ ぷ ぺ ぽ ア イ ウ エ
50      オ カ キ ク ケ コ サ シ ス セ ソ タ チ ツ テ ト
60      ナ ニ ヌ ネ ノ ハ ヒ フ ヘ ホ マ ミ ム メ モ ヤ
70      ユ ヨ ラ リ ル レ ロ ワ ヲ ン ャ ュ ョ ー ！ ガ
80      ギ グ ゲ ゴ ザ ジ ズ ゼ ゾ ダ ヂ ヅ デ ド バ ビ
90      ブ ベ ボ パ ピ プ ペ ポ ＄ ０ １ ２ ３ ４ ５ ６
A0      ７ ８ ９ 　 ァ ィ ゥ ェ ォ ッ ？ ヴ っ 家 軒 抵
B0      当 価 格 建 設 水 道 費 抖 鉄 会 社 電 力 地 中
C0      海 公 井 通 ぁ ぃ ぅ ぇ ぉ ゛ ゜ 枚 倍 Ａ Ｂ Ｃ
D0      Ｄ Ｅ Ｆ Ｇ Ｈ Ｉ Ｊ Ｋ Ｌ Ｍ Ｎ Ｏ Ｐ Ｑ Ｒ Ｓ
E0      Ｔ Ｕ Ｖ Ｗ Ｘ Ｙ Ｚ ％ ： ⋯ ♪ ♥︎ ～ 男 女 位
F0      才 入 口 交 渉
```

---

# Game Boy Wars 3 (GBC)

## General Information

Turn-based GBC strategy game. Mobile functions include:

- custom downloadable maps;
- developer messages/news;
- premium mercenary units.

## Server Structure

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/18/CGB-BWWJ/0.map_menu.txt
http://gameboy.datacenter.ne.jp/cgb/download?name=/18/CGB-BWWJ/map/map_****.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/18/CGB-BWWJ/charge/****.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/18/CGB-BWWJ/mbox/mbox_serial.txt
http://gameboy.datacenter.ne.jp/cgb/download?name=/18/CGB-BWWJ/mbox/mbox_**.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/18/CGB-BWWJ/0.youhei_menu.txt
```

Asterisks are variable characters.

## `0.map_menu.txt`

Text format:

```text
[Minimum Map #]    [Maximum Map #]    [Price in yen]
```

- fields are four ASCII digits;
- spaces or tabs may separate fields;
- each line defines a map-ID interval and its service price;
- requested map ID must belong to an interval;
- filename prefix `0` means the menu itself is free.

## `map/map_****.cgb`

The four-digit map ID is inserted into the filename, e.g. `1337 -> map_1337.cgb`.

The format matches maps created in the built-in editor.

```text
00-01   Normally 20 00; apparent ID, not validated
02-03   16-bit map-size sum, little-endian:
        019Fh + (400 - width*height)
04      8-bit data sum/check:
        FEh - (a + b + c + ... through EOF)
20-2B   Map name
2C      Width, 20-50
2D      Height, 20-50
2E...   Terrain tiles
...     Optional unit entries
EOF     FF
```

### Terrain IDs

```text
00  Null / out-of-bounds
01  Red Star base
02  Red Star city
03  Red Star ruined city
04  Red Star factory
05  Red Star ruined factory
06  Red Star airport
07  Red Star ruined airport
08  Red Star simple airport
09  Red Star harbor
0A  Red Star ruined harbor
0B  Red Star Transmission Tower

0C  White Moon base
0D  White Moon city
0E  White Moon ruined city
0F  White Moon factory
10  White Moon ruined factory
11  White Moon airport
12  White Moon ruined airport
13  White Moon simple airport
14  White Moon harbor
15  White Moon ruined harbor
16  White Moon Transmission Tower

17  Neutral city
18  Neutral ruined city
19  Neutral factory
1A  Neutral ruined factory
1B  Neutral airport
1C  Neutral ruined airport
1D  Neutral harbor
1E  Neutral ruined harbor
1F  Neutral Transmission Tower

20  Plains
21  Highway
22  Bridge
23  Bridge
24  Mountains
25  Forest
26  Wasteland
27  Desert
28  River
29  Sea
2A  Shoal
2B-FF Invalid / glitch / null
```

The game mainly validates the map-size and additive checks. Maps impossible to build through the normal editor can therefore be downloaded and played.

### Unit entries

Each unit occupies three bytes:

```text
byte 0   X coordinate
byte 1   Y coordinate
byte 2   Unit ID
```

Terrain suitability is not validated.

### Unit IDs

```text
00  No unit
01  Invalid / DEL
02  Red Star Infantry
03  White Moon Infantry
04  Red Star Missile Infantry
05  White Moon Missle Infantry
06  Red Star Merc Infantry
07  White Moon Merc Infantry
08  Red Star Construction Vehicle
09  White Moon Construction Vehicle
0A  Red Star Supply Vehicle
0B  White Moon Supply Vehicle
0C  Red Star Supply Vehicle S
0D  White Moon Supply Vehicle S
0E  Red Star Transport Truck
0F  White Moon Transport Truck
10  Red Star Transport Truck S
11  White Moon Transport Truck S
12  Red Star Combat Buggy
13  White Moon Combat Buggy
14  Red Star Combat Buggy S
15  White Moon Combat Buggy S
16  Red Star Combat Vehicle
17  White Moon Combat Vehicle
18  Red Star Combat Vehicle S
19  White Moon Combat Vehicle S
1A  Red Star Armored Transport Truck
1B  White Moon Armored Transport Truck
1C  Red Star Armored Transport Truck S
1D  White Moon Armored Transport Truck S
1E  Red Star Rocket Launcher
1F  White Moon Rocket Launcher
20  Red Star Rocket Launcher S
21  White Moon Rocket Launcher S
22  Red Star Anti-Air Tank
23  White Moon Anti-Air Tank
24  Red Star Merc Anti-Air Tank
25  White Moon Merc Anti-Air Tank
26  Red Star Anti-Air Missile
27  White Moon Anti-Air Missile
28  Red Star Anti-Air Missile S
29  White Moon Anti-Air Missile S
2A  Red Star Artillery
2B  White Moon Artillery
2C  Red Star Artillery S
2D  White Moon Artillery S
2E  Red Star Anti-Infantry Tank
2F  White Moon Anti-Infantry Tank
30  Red Star Anti-Infantry Tank S
31  White Moon Anti-Infantry Tank S
32  Red Star Tank Destroyer
33  White Moon Tank Destroyer
34  Red Star Tank Destroyer S
35  White Moon Tank Destroyer S
36  Red Star Tank
37  White Moon Tank
38  Red Star Merc Tank
39  White Moon Merc Tank
3A  Red Star Fighter Jet A
3B  White Moon Fighter Jet A
3C  Red Star Fighter Jet B
3D  White Moon Fighter Jet B
3E  Red Star Fighter Jet S
3F  White Moon Fighter Jet S
40  Red Star Attack Aircraft A
41  White Moon Attack Aircraft A
42  Red Star Attack Aircraft B
43  White Moon Attack Aircraft B
44  Red Star Attack Aircraft S
45  White Moon Attack Aircraft S
46  Red Star Bomber
47  White Moon Bomber
48  Red Star Merc Bomber
49  White Moon Merc Bomber
4A  Red Star Transport Aircraft
4B  White Moon Transport Aircraft
4C  Red Star Aerial Tanker
4D  White Moon Aerial Tanker
4E  Red Star Attack Helicopter
4F  White Moon Attack Helicopter
50  Red Star Attack Helicopter S
51  White Moon Attack Helicopter S
52  Red Star Anti-Sub Helicopter
53  White Moon Anti-Sub Helicopter
54  Red Star Transport Helicopter
55  White Moon Transport Helicopter
56  Red Star Transport Helicopter S
57  White Moon Transport Helicopter S
58  Red Star Aegis Warship
59  White Moon Aegis Warship
5A  Red Star Merc Frigate
5B  White Moon Merc Frigate
5C  Red Star Large Aircraft Carrier
5D  White Moon Large Aircraft Carrier
5E  Red Star Small Aircraft Carrier
5F  White Moon Small Aircraft Carrier
60  Red Star Transport Warship
61  White Moon Transport Warship
62  Red Star Supply Tanker
63  White Moon Supply Tanker
64  Red Star Submarine
65  White Moon Submarine
66  Red Star Submarine S
67  White Moon Submarine S
68  Red Star "Dummy" unit
69  White Star "Dummy" unit
6A  Invalid / DEL
6B-FF Invalid / glitchy
```

Downloaded maps can contain mercenary units that are unavailable in the editor. Such maps remain editable and the units can be removed.

## `charge/****.cgb`

Requested after a successful map purchase/download or mercenary unlock.

The filename is the configured price. File data is largely ignored; an HTTP `200` is what matters. Historically the request itself triggered the provider-side service charge.

The game does not verify that the four price characters are numeric ASCII before using them.

## `mbox/mbox_serial.txt`

Controls the Message Center.

- exactly 16 logical lines;
- each is expected to be a string, apparently numeric ASCII;
- previous values are stored in cartridge RAM;
- a changed line causes the corresponding mailbox file to be downloaded;
- if no value changes, no mailbox data is fetched.

The exact date formatting mechanism is unknown.

## `mbox/mbox_**.cgb`

Mapping:

```text
line 1  -> mbox_00.cgb
line 2  -> mbox_01.cgb
...
line 16 -> mbox_15.cgb
```

Format is essentially text.

- first seven characters are ignored;
- ASCII is supported;
- hiragana/katakana are supported but their encoding is not documented;
- the file **must terminate with CRLF**.

Without CRLF, the game keeps parsing through memory and can overwrite RAM.

## `0.youhei_menu.txt`

Five text lines:

```text
[Price for Merc Infantry]
[Price for Merc AA Tank]
[Price for Merc Tank]
[Price for Merc Bomber]
[Price for Merc Frigate]
```

The leading `0` in the filename indicates that downloading the menu itself carries no service charge.

---

# Hello Kitty no Happy House (GBC)

## General Information

GBC title centered on furniture collection, minigames and communication. Mobile Adapter functionality is primarily email, including sending furniture as gifts.

## Server Structure

No HTTP resource is currently documented.

The game uses:

- SMTP for outgoing mail;
- POP3 for incoming mail.

## Email

Approximate ordinary email:

```text
From: =?ISO-2022-JP?xxxxxxxxxxxxxxxxxxxxxxxx <yyyy@zzzz.dion.ne.jp>
To: =?ISO-2022-JP?xxxxxxxxxxxxxxxxxxxxxxxx <yyyyyyyyy>
Subject: =?ISO-2022-JP?xxxxxxxxxxxxxxxxxxxxxxxx
MIME-Version: 1.0
Content-Type: text/plain; charset="ISO-2022-JP"
Content-Transfer-Encoding: 7bit
X-Mailer: Hello Kitty Happy House
X-Game-title: HKITTY_HH
X-Game-code: CGB-BK7J-00

[message]
```

Gift mail adds:

```text
X-GBmail-type: exclusive
X-HKH-HOUSE: [3-letter code]
```

The three-letter ASCII code selects the furniture item.

## Item Codes

The encoding treats `A=0` ... `Z=25`, but combines the letters using a non-standard Base-10/Base-26-style system where letter positions contribute values multiplied by 10. Consequently several different codes can identify the same numeric item.

Example: value 20 can be encoded as `AAU`, `ABK`, or `ACA`.

| Code 1 | Code 2 | Code 3 | Item |
|---|---|---|---|
| AAB |  |  | Heart Clock |
| AAC |  |  | Pendulum Clock |
| AAD |  |  | Futuristic Clock |
| AAE |  |  | Landscape Painting |
| AAF |  |  | Pop Art Painting |
| AAG |  |  | Kitty Elastomer |
| AAH |  |  | Bronze Angel Statue |
| AAI |  |  | Bronze Goddess Statue |
| AAJ |  |  | Bronze Kitty Statue |
| AAK | ABA |  | Hanging Scroll |
| AAL | ABB |  | Dragon Pennant |
| AAM | ABC |  | Noble Pennant |
| AAN | ABD |  | Wide TV |
| AAO | ABE |  | Cute TV |
| AAP | ABF |  | Wall-mounted TV |
| AAQ | ABG |  | Digital Component Stereo |
| AAR | ABH |  | Component Stereo |
| AAS | ABI |  | Gramophone |
| AAT | ABJ |  | Massage Chair 1 |
| AAU | ABK | ACA | Massage Chair 2 |
| AAV | ABL | ACB | Relaxing Chair |
| AAW | ABM | ACC | Globe |
| AAX | ABN | ACD | Cosmic Globe |
| AAY | ABO | ACE | Miniature House |
| AAZ | ABP | ACF | Pink Chest |
| ABQ | ACG |  | Japanese Drawer |
| ABR | ACH |  | Toy Case |
| ABS | ACI |  | Japanese Vase |
| ABT | ACJ |  | Western Vase |
| ABU | ACK | ADA | Arabian Vase |
| ABV | ACL | ADB | Tetra Aquarium |
| ABW | ACM | ADC | Turtle Aquarium |
| ABX | ACN | ADD | Arowana Aquarium |
| ABY | ACO | ADE | Floor Light |
| ABZ | ACP | ADF | Standing Light |
| ACQ | ADG |  | Mood Light |
| ACR | ADH |  | Doggy Doll |
| ACS | ADI |  | Sheep Doll |
| ACT | ADJ |  | Lion Doll |
| ACU | ADK | AEA | Puppet Storage Box |
| ACV | ADL | AEB | Robot Base |
| ACW | ADM | AEC | Doll House |
| ACX | ADN | AED | Magazine Rack |
| ACY | ADO | AEE | Letter Rack |
| ACZ | ADP | AEF | Bookstand |
| ADQ | AEG |  | Hat Stand |
| ADR | AEH |  | Coat Stand |
| ADS | AEI |  | Dear Daniel Doll |
| ADT | AEJ |  | Pink Living Room Furniture |
| ADU | AEK | AFA | Blue Living Room Furniture |
| ADV | AEL | AFB | White Living Room Furniture |
| ADW | AEM | AFC | Thai Living Room Furniture |
| ADX | AEN | AFD | Chinese Living Room Furniture |
| ADY | AEO | AFE | Asian Living Room Furniture |
| ADZ | AEP | AFF | Japanese Living Room Furniture |
| AEQ | AFG |  | Wooden Japanese Chestnut Living Room Furniture |
| AER | AFH |  | Wajima Lacquer Living Room Furniture |
| AES | AFI |  | Cozy Living Room Furniture |
| AET | AFJ |  | Checkered Living Room Furniture |
| AEU | AFK | AGA | Pop Living Room Furniture |
| AEV | AFL | AGB | Old Living Room Furniture |
| AEW | AFM | AGC | Old-fashioned Living Room Furniture |
| AEX | AFN | AGD | Antique Living Room Furniture |
| AEY | AFO | AGE | Heart-themed Living Room Furniture |
| AEZ | AFP | AGF | Apple-themed Living Room Furniture |
| AFQ | AGG |  | Flower-themed Living Room Furniture |
| AFR | AGH |  | Red Kotatsu |
| AFS | AGI |  | Blue Kotatsu |
| AFT | AGJ |  | Yellow Kotatsu |
| AFU | AGK | AHA | Extravagant Living Room Furniture |
| AFV | AGL | AHB | Elegant Living Room Furniture |
| AFW | AGM | AHC | Hello Kitty-themed Living Room Furniture |
| AFX | AGN | AHD | Red Art Studio |
| AFY | AGO | AHE | Blue Art Studio |
| AFZ | AGP | AHF | Elegant Art Studio |
| AGQ | AHG |  | Model Train |
| AGR | AHH |  | Toy Blocks |
| AGS | AHI |  | Playing House Set |
| AGT | AHJ |  | Standing Table |
| AGU | AHK | AIA | Flower-pattern Table |
| AGV | AHL | AIB | Glass Table |
| AGW | AHM | AIC | Japanese Flower Arranged Desk |
| AGX | AHN | AID | Flower Arrangement |
| AGY | AHO | AIE | Bonsai |
| AGZ | AHP | AIF | Red Carpet |
| AHQ | AIG |  | Green Carpet |
| AHR | AIH |  | Blue Carpet — documented as blue but appears purple |
| AHS | AII |  | Blue Playground Slide |
| AHT | AIJ |  | Red Playground Slide — documented as red but appears pink |
| AHU | AIK | AJA | White Playground Slide |
| AHV | AIL | AJB | Easy Chair |
| AHW | AIM | AJC | Tranquil Chair |
| AHX | AIN | AJD | Relaxing Chair |
| AHY | AIO | AJE | Gold Tearoom |
| AHZ | AIP | AJF | Silver Tearoom |
| AIQ | AJG |  | Play Set |
| AIR | AJH |  | Changing-clothes Box |
| AIS | AJI |  | Changing-clothes Case |
| AIT | AJJ |  | Strange Box |
| AIU | AJK | AKA | Somersault Platform |
| AIV | AJL | AKB | Jump Sheet |
| AIW | AJM | AKC | Trampoline |
| AIX | AJN | AKD | Pink Refrigerator |
| AIY | AJO | AKE | Wood-grain Refrigerator |
| AIZ | AJP | AKF | Play Refrigerator |
| AJQ | AKG |  | White Iron |
| AJR | AKH |  | Green Iron |
| AJS | AKI |  | Purple Iron |
| AJT | AKJ |  | Brown Builder — workout set |
| AJU | AKK | ALA | Purple Builder — workout set |
| AJV | AKL | ALB | Green Builder — workout set |
| AJW | AKM | ALC | Brown Runner — treadmill |
| AJX | AKN | ALD | Red Runner — documented as red but appears pink |
| AJY | AKO | ALE | Blue Runner — treadmill |
| AJZ | AKP | ALF | Flower Piano |
| AKQ | ALG |  | Star Piano |
| AKR | ALH |  | Classic Piano |
| AKS | ALI |  | Crystal Ball Set |
| AKT | ALJ |  | Fortune-Telling Set |
| AKU | ALK | AMA | Tarot Card Divination |

---

# Mario Kart Advance (GBA)

## General Information

Mario Kart Advance / Mario Kart: Super Circuit supports the Mobile Adapter for:

- Mobile GP time competitions;
- online rankings;
- downloadable ghost data.

## Server Structure

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/01/AGB-AMKJ/index.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/01/AGB-AMKJ/rule.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/01/AGB-AMKJ/*total.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/01/AGB-AMKJ/*query.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/01/AGB-AMKJ/*0.dlghost.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/01/AGB-AMKJ/*0.dlghost2.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/01/AGB-AMKJ/*0.dlghost3.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/01/AGB-AMKJ/*0.dlghostdr.cgb
http://gameboy.datacenter.ne.jp/cgb/ranking?name=/01/AGB-AMKJ/*0.dlghostst.cgb
http://gameboy.datacenter.ne.jp/cgb/upload?name=/01/AGB-AMKJ/*0.entry.cgb
```

`*` is replaced by a line/string from `index.cgb`.

## `index.cgb`

- 21 non-empty logical lines, each <= 255 bytes;
- followed by a 22nd empty line.

Lines 1-20 correspond to the 20 Super Circuit tracks:

- 16 initially available tracks;
- first four unlockable tracks.

Line 21 corresponds to the current Mobile GP.

The strings are inserted into subsequent ranking/upload URLs.

## `rule.cgb`

CRLF text file, 13-45 lines.

```text
Line 1   Filename/path component to join
         http://gameboy.datacenter.ne.jp/cgb/download?name=/01/AGB-AMKJ/*
         max 20 bytes
Line 2   First date rules may be downloaded/viewed, YYYYMMDD
Line 3   Last date rules may be downloaded, YYYYMMDD
Line 4   First date next rules may be downloaded/viewed, YYYYMMDD
Line 5   Last date next rules may be downloaded, YYYYMMDD
Line 6   First date ranking entry/upload is open, YYYYMMDD
Line 7   Last date ranking entry/upload is open, YYYYMMDD
Line 8   First date rankings may be viewed, YYYYMMDD
Line 9   Last date rankings may be viewed, YYYYMMDD
Line 10  Special rules, 8 hexadecimal digits
Line 11  Track number, 2 digits
Line 12  Number of attempts, 2 digits
Line 13  Number of description lines, 2 digits
Line 14+ Description
```

Special-rule digits, in order:

1. enable coins;
2. enable item boxes;
3. give triple mushroom at start;
4. mushrooms-only mode;
5. enable COM opponents;
6. forced driver: driver number + 1, `0` = any;
7. starting coin count divided by 5;
8. five-lap race.

Boolean enable values are active whenever their digit is non-zero.

## `total.cgb`

Exactly four bytes: a big-endian integer containing the number of ranked ghosts. Used to select rank numbers queried for the overall-ranking category.

## `query.cgb`

POST body:

```text
myid=<32 hex digits>&
myrecord=<4 hex digits>&
pickuprecord=<4 hex digits>&
state=<2 hex digits>&
driver=<2 hex digits>&
rk_1=<8 hex digits>&
rk_2=<8 hex digits>&
rk_3=<8 hex digits>&
rk_4=<8 hex digits>&
rk_5=<8 hex digits>&
rk_6=<8 hex digits>&
rk_7=<8 hex digits>&
rk_8=<8 hex digits>&
rk_9=<8 hex digits>&
rk_10=<8 hex digits>&
rk_11=<8 hex digits>
```

- `pickuprecord`: actual player time.
- `myrecord`: actual time + 1/100 second.
- `rk_1..rk_11`: requested global rank positions.

Response sequence:

```text
Global ranking set
2-byte rival count, high then low
Up to 11 rival ranking entries
Global player rank
11 overall ranking entries

-- Mobile GP response ends here --

State ranking set
State player rank
Driver ranking set
Driver player rank
4-byte global ranked-player count, big-endian
```

### Ranking set

```text
00      Year high
01      Year low
02      Month
03      Day
04      Hour
05      Minute
06-09   Ranked-player count, big-endian
0A-0D   Total-player count, big-endian
0E      Top-entry count N high
0F      Top-entry count N low; N <= 11
10...   Up to 11 ranking entries
```

### Ranking entry

```text
00-03   Rank, big-endian
04      Driver
05-09   Nickname
0A-0B   Race time
0C-1B   Kart ID
```

### Player rank

```text
00-01   0000 = rank absent
02-05   Rank, big-endian, optional
06-07   0000 = extended info absent
08-0B   Extended rank, big-endian; appears to override previous rank
0C      Extended driver
0D-0E   Extended race time
```

### Overall ranking entry

```text
00-01   0000 = entry absent
02-1D   Optional ranking entry
```

## `0.dlghost.cgb`, `0.dlghost2.cgb`, `0.dlghost3.cgb`

### Global-rank download — `0.dlghost.cgb`

```text
ghostrank=<8 hex digits>&state=00&driver=00
```

### Time-based download — `0.dlghost2.cgb`

```text
ghostscore=<4 hex digits>&state=00&driver=00
```

`ghostscore` is 1/100 second slower than the desired time.

### Kart-ID download — `0.dlghost3.cgb`

```text
myid=<32 hex digits>&state=00&driver=00
```

Shared response:

```text
0000      Year high, unused
0001      Year low, unused
0002      Month, unused
0003      Day, unused
0004      Hour, unused
0005      Minute, unused
0006-0009 Global ranked-player count, big-endian
000A-000B 0000 = file ends here
000C      Driver
000D-0011 Nickname
0012-0013 Race time
0014-1013 Ghost data
1014-1023 Kart ID
1024-1027 Global ranked-player count, big-endian
1028-102B Unknown / unused
102C-102F State ranked-player count, big-endian
1030-1033 Driver ranked-player count, big-endian
```

## `0.dlghostdr.cgb`, `0.dlghostst.cgb`, `0.dlghostid.cgb`

Use the same POST format as `0.dlghost.cgb`.

Purpose:

- `0.dlghostdr.cgb`: filter/select by driver;
- `0.dlghostst.cgb`: filter/select by state;
- `0.dlghostid.cgb`: intended global-ID download; in practice replaced by `0.dlghost.cgb`.

Response:

```text
0000      Year high, unused
0001      Year low, unused
0002      Month, unused
0003      Day, unused
0004      Hour, unused
0005      Minute, unused
0006-0009 Global ranked-player count, big-endian
000A-000B 0000 = file ends here
000C-001C Optional Kart ID
```

## `0.entry.cgb`

Uploaded using HTTP POST. The response body is irrelevant.

```text
0000-000F Kart ID
0010      Track
0011      Driver
0012-0016 Nickname
0017      State
0018-0019 Unknown
001A-001B Race time
001C-101B Ghost data
101C-102B Player name
102C-1037 Phone number
1038-103F Postal code
1040-10BF Home address
```

Outside Mobile GP, personal information is masked:

- the two number fields use forward slashes;
- text fields use asterisks.

In an unmodified game, the postal code is seven digits followed by lowercase `p`.

## String Format

`00` behaves as a terminator. The game often terminates ROM strings using multiple NUL bytes and downloaded text commonly uses CR/LF.

```text
        0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
00      危 ！ ” ＃ ＄ ％ ’ ＆ （ ） ＊ ＋ ， ー ． ／
10      ０ １ ２ ３ ４ ５ ６ ７ ８ ９ ： ； ＜ ＝ ＞ ？
20      ＠ Ａ Ｂ Ｃ Ｄ Ｅ Ｆ Ｇ Ｈ Ｉ Ｊ Ｋ Ｌ Ｍ Ｎ Ｏ
30      Ｐ Ｑ Ｒ Ｓ Ｔ Ｕ Ｖ Ｗ Ｘ Ｙ Ｚ ［ ￥ ］ ＾ ＿
40      ‘ ａ ｂ ｃ ｄ ｅ ｆ ｇ ｈ ｉ ｊ ｋ ｌ ｍ ｎ ｏ
50      ｐ ｑ ｒ ｓ ｔ ｕ ｖ ｗ ｘ ｙ ｚ ｛ ｜ ｝ 〜
60      ぁ あ ぃ い ぅ う ぇ え ぉ お か が き ぎ く ぐ
70      け げ こ ご さ ざ し じ す ず せ ぜ そ ぞ た だ
80      ち ぢ っ つ づ て で と ど な に ぬ ね の は ば
90      ぱ ひ び ぴ ふ ぶ ぷ へ べ ぺ ほ ぼ ぽ ま み む
A0      め も ゃ や ゅ ゆ ょ よ ら り る れ ろ わ を ん
B0      ァ ア ィ イ ゥ ウ ェ エ ォ オ カ ガ キ ギ ク グ
C0      ケ ゲ コ ゴ サ ザ シ ジ ス ズ セ ゼ ソ ゾ タ ダ
D0      チ ヂ ッ ツ ヅ テ デ ト ド ナ ニ ヌ ネ ノ ハ バ
E0      パ ヒ ビ ピ フ ブ プ ヘ ベ ペ ホ ボ ポ マ ミ ム
F0      メ モ ャ ヤ ュ ユ ョ ヨ ラ リ ル レ ロ ワ ヲ ン
```

---

# Mobile Pro Yakyuu (GBA)

## General Information

`Mobile Pro Yakyuu - Kantoku no Saihai` / Mobile Professional Baseball is a GBA baseball game published by Mobile21 in 2001. It shipped with 2000 NPB data and could download updated roster/player data.

## Server Structure

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/AGB-AMBJ/counter.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/AGB-AMBJ/200.member.cgb
```

## `counter.cgb`

Exactly one byte: the current version of `200.member.cgb`.

- built-in ROM data is effectively version `00`;
- matching version means no re-download;
- versions need not be sequential.

## `200.member.cgb`

Saved directly into game backup data.

Compressed file limit:

```text
6000h bytes = 24 KiB
```

Boot/download decompression sequence:

1. GBA BIOS `SWI #13h` — `HuffUnComp`.
2. Intermediate result -> `SWI #11h` — `LZ77UnCompWram`.
3. Final data copied to `02000000h`.

Intermediate and final decompressed-data limits: `8000h` bytes each.

First 16 final bytes:

```text
00-03   Pointer to player data, little-endian
04-07   Pointer to all-star data, little-endian
08-0B   Pointer to team data, little-endian
0C-0F   Pointer to season data, little-endian
```

Most data is packed into little-endian bitfields. A notation such as `09.4` means bit 4 of byte `09`.

## Player Data

Starts with 12 little-endian four-byte pointers. Each points to 25 player profiles for one team.

### Player profile

```text
00.0-03.7   Pointer to long name; width <= 6 chars
04.0-07.7   Pointer to short name; width <= 3 chars
08.0-08.7   Squad number; 100-109 represent 00-09 with leading zero
09.0-09.3   Position: 0 pitcher, 1 catcher, 2 first, 3 second,
            4 third, 5 shortstop, 6 left, 7 center, 8 right
09.4-09.5   Pitching hand: 0 right, 1 left, 2 both
09.6        0 infielder, 1 otherwise
09.7-0A.0   Batting hand: 0 right, 1 left, 2 both
0A.1-0B.0   RBI
0B.1-0B.7   Stolen bases
0C.0-0C.7   Height, cm
0D.0-0D.7   Weight, kg
0E.0-0E.6   Birth year, no century
0E.7-0F.2   Birth month
0F.3-0F.7   Birth day
10.0-10.7   Batting games played
11.0-12.1   At-bats
12.2-13.1   Runs scored
13.2-14.2   Hits
14.3-15.1   Doubles
15.2-15.6   Triples
15.7-16.5   Home runs
16.6-17.1   Pitching shutouts
17.2-18.3   Batting average * 1000
18.4-19.2   Pitching games played
19.3-19.7   Complete games
1A.0-1B.1   Innings pitched * 3
1B.2-1B.6   Wins
1B.7-1C.3   Losses
1C.4-1D.1   Saves
1D.2-1E.1   Walks
1E.2-1E.6   Hit batters
1E.7-1F.7   Strikeouts
20.0-21.1   ERA * 100
21.2-23.7   Always zero
24.0-25.1   "Bat distance" points
25.2-26.3   "Bat skill" points
26.4-27.5   "Bat accuracy" points
27.6-28.7   "Base running" points
29.0-2A.1   "Catch ball" points
2A.2-2B.3   "Throw distance" points
2B.4-2C.5   "Pitch judgement" points
2C.6-2D.7   "Movement" points
2E.0-2F.1   "Catcher" points
2F.2-30.3   "Pitch speed" points
30.4-31.5   "Ball speed" points
31.6-32.7   "Sharpness" points
33.0-34.1   "Control" points
34.2-35.3   "Endurance" points
35.4-36.1   Batting indicator top-left index
36.2-36.4   Batting indicator width
36.5-36.7   Batting indicator height
37.0-37.5   Catching indicator top-left index
37.6-38.0   Catching indicator width
38.1-38.3   Catching indicator height
38.4-38.6   Level: 0=S, 1-6=A-F
38.7-3C.1   3-bit skill multipliers for positions
3C.2-3C.7   Always zero
3D.0-3D.3   Unknown pitch strength
3D.4-3D.7   Unknown pitch strength
3E.0-3E.3   Curve
3E.4-3E.7   Change-up
3F.0-3F.3   Slider
3F.4-3F.7   Shoot
40.0-40.3   Sinker
40.4-40.7   Fork
41.0-41.3   Always zero
41.4-41.7   Unknown pitch strength
42.0-43.7   Always zero
```

Skill indicator:

- 6x6 matrix;
- top-left index = `(row * 6) + column`;
- all-zero position/dimensions hides it;
- catching indicator takes priority when overlapping batting indicator;
- multipliers 0-5 correspond to x0.5, x0.6, etc.

The first eight players on a team must occupy all non-pitcher positions; player 9 must be a pitcher.

## All-Star Data

Two four-byte little-endian pointers:

1. Central League;
2. Pacific League.

Each points to 25 specifiers:

```text
00.0-00.3   Team number
00.4-01.0   Player number
01.1-01.4   Position
01.5-03.7   Always zero
```

The first eight members again fill all non-pitcher positions, and the ninth is a pitcher.

## Team Data

Array of 12 profiles, not pointers.

```text
00.0-03.7   Pointer to team name; width <= 8 chars
04.0-07.7   Pointer to manager name; width <= 8 chars
08.0-08.6   Founding year, no century
08.7-09.2   Founding month
09.3-09.7   Founding day
0A.0-0B.4   Total wins
0B.5-0D.1   Total losses
0D.2-0D.7   League wins
0E.0-0F.0   Average game length? minutes
0F.1-10.2   Win rate * 1000
10.3-13.7   Always zero
```

Fixed team order:

1. Yomiuri Giants — Central
2. Chunichi Dragons — Central
3. Yokohama BayStars — Central
4. Yakult Swallows — Central
5. Hiroshima Toyo Carp — Central
6. Hanshin Tigers — Central
7. Fukuoka Daiei Hawks — Pacific
8. Seibu Lions — Pacific
9. Nippon-Ham Fighters — Pacific
10. Orix BlueWave — Pacific
11. Chiba Lotte Marines — Pacific
12. Osaka Kintetsu Buffaloes — Pacific

## Season Data

One byte, `00-03`, selecting the season represented by the downloaded data:

```text
00  2000
01  2001
02  2002
03  2003
```

## String Format

- `00`: terminator.
- `5B` (`[`): switch to half-width font.
- `5D` (`]`): switch back to default full-width font.
- other bytes are interpreted with the next byte as two-byte Shift-JIS.

JIS X 0208 support documented by Dan Docs:

- Row 1 is supported except these characters, which render as spaces:

```text
゛゜´¨ヽヾゝゞ〃仝〆〇‐‖∥‥÷≠∴♂♀°′″℃¢£§
```

- Row 2 renders as spaces except:

```text
◆□■△▲▽▼※→←↑↓
```

- Rows 3-5: supported.
- Rows 6-8: spaces.
- Circled digits `①` through `⑩` in row 13: full-width only.
- Level-1 kanji, rows 16-47: full-width only.

---

# Mobile Trainer (GBC)

## General Information

Mobile Trainer is the GBC configuration utility bundled with every Mobile Adapter GB. It also acts as a basic web browser and email client.

Released January 27, 2001.

## Server Structure

Observed HTTP URL:

```text
http://gameboy.datacenter.ne.jp/01/CGB-B9AJ/index.html
```

Also uses:

- POP3 TCP port 110;
- SMTP TCP port 25.

Other URLs exist in ROM but are not documented as observed in normal use.

## `index.html`

Acts as the Mobile Adapter home page. Nintendo could publish news and links to other pages. Little survives about the original content beyond screenshots.

## Web Browser

Supported HTML subset:

| Element | Behavior |
|---|---|
| `<a>` | Hyperlinks selectable with D-pad + A |
| `<b>` | Text becomes red rather than black |
| `<br>` | New line |
| `<div>` | Starts a new line; `align=""` supported |
| `<center>` | Centers text; must be inside `<html>...</html>` |
| `<html>` | Generally not otherwise required |
| `<hr>` | Supported |
| `<img>` | 1BPP BMP only; 404 shows broken-image icon |
| `<title>` | Supported |
| `<li>` | Supported |
| `<ol>` | Supported |
| `<ul>` | Supported; small dot bullets |

Manual URL entry is not available. Navigation is therefore constrained to the home page and hyperlinks reachable from it.

Bookmarks are supported. Editing the save externally can make a bookmark target an arbitrary URL.

Browsing time was billable because the Mobile Adapter maintained an active mobile connection. The browser has an option to disconnect while viewing a loaded page, stopping the connection timer.

### BMP restrictions for `<img>`

- 1BPP only.
- Maximum image size: **144x96**.
- Width and height values exceeding 8-bit range are rejected even though BMP dimensions are normally 32-bit.
- Pixel-data offset must fit / be interpreted as a 16-bit value.
- BPP 16-bit field must equal `0001h`.
- Planes 16-bit field must equal `0001h`.
- 32-bit compression flags must be zero.
- 32-bit number-of-color-maps field must be zero.

Much of the rest of the BMP header is ignored. Some editor-generated BMPs may require manual header changes.

## Email

The service is standard unencrypted POP3/SMTP at the application level.

Approximate outgoing message:

```text
MIME-Version: 1.0
From: xxxx@yyyy.dion.ne.jp (=?ISO-2022-JP?zzzzzzzzzzzzzzzz)
To: [email_address]
Subject: =?ISO-2022-JP?xxxx
X-Game-title: MOBILE TRAINER
X-Game-code: CGB-B9AJ-00
Content-Type: text/plain; charset=iso-2022-jp

[content]
```

Text is ISO-2022 based.

Mobile Trainer does not itself validate the destination email address; it passes it to the SMTP server and reports server errors.

### Security behavior

There is no encryption on POP3 or SMTP. POP user ID and password are transmitted in plaintext, which by modern standards exposes enough information to impersonate the account across Mobile Adapter software.

---

# Net de Get: Mini Game @ 100 (GBC)

## General Information

Konami GBC title released June 12, 2001.

Important hardware characteristic: it is the only known game using **MBC6**, allowing downloadable minigames to be stored in cartridge Flash and launched offline.

## Server Structure

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/CGB-BMVJ/h0000.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/CGB-BMVJ/h0*.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/CGB-BMVJ/h8*.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/CGB-BMVJ/RomList.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/CGB-BMVJ/
```

## `h0000.cgb`, `h0*.cgb`

After a built-in minigame is played, the Server option unlocks. After password entry, `h0000.cgb` is fetched by HTTP GET.

Five-byte header:

```text
00   4D  'M'
01   4E  'N'
02   47  'G'
03   4C  'L'
04   Number of menu items
```

Then each menu item has a five-byte filename.

If a filename begins with ASCII `0` or `8`, it is inserted into:

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/CGB-BMVJ/h*.cgb
```

The five-byte filename **must contain a NUL terminator**, otherwise copying continues until a NUL happens to be encountered.

If the first character is neither `0` nor `8`, the selection instead downloads `RomList.cgb`.

After filenames come NUL-terminated menu names in the custom text encoding.

The file must terminate with:

```text
00 00 01
```

Otherwise crashes and/or save corruption can occur.

Available evidence suggests the original file contained one menu item: `ミニゲームリスト`.

## `h8*.cgb`

Message file. After download, the game disconnects and displays it.

```text
00-07   BG palette 0: ordinary text + background parts
08-17   BG palettes 1-2: colored text
18-37   BG palettes 3-6: unused
38-3F   BG palette 7: most background/header/B hint
40-47   OBJ palette 0: blinking arrows
48-7F   OBJ palettes 1-7: unused
80      Number of pages, 1-10
81-82   Pointer to page 1 text
...     Additional page pointers
```

Palettes are GBC RGB555, four colors per palette, little-endian.

For BG palettes:

- color 0 = foreground;
- color 1 = shadow;
- color 3 = background;
- color 3 should match between BG palettes 0 and 7.

File contents are mapped/read from `B000h`; text pointers can therefore be interpreted as file offsets plus `B000h`.

## `RomList.cgb`

Contains the catalog of minigames, Flash usage and type/category metadata.

### Entry count

```text
00   Number of entries, 1-78
```

### Offset table

Two-byte little-endian internal offset per entry, beginning at byte `01`.

### Entry data structure

```text
00      Number of required 8 KiB memory blocks
        > 10h means it cannot be downloaded
01      Category icon
02-05   Game ID "Gxyz", e.g. G000
08-0A   Three minimum category levels
0C-0D   Minimum hidden level A, little-endian;
        unmet => entry hidden
0E-0F   Minimum hidden level B, little-endian;
        unmet => entry hidden
10      String length 1: minigame title
11...   Title text; ideally <= 12 fixed-width chars
...     String length 2
...     Additional description; ideal max 0Fh
...     String length 3
...     Server filename
...     00 filename terminator, not counted in length 3
...     Minigame type
```

The first four filename characters, or characters before the first period if fewer, are displayed as the price in yen.

### Category icons

```text
00  Question Mark      Unspecified / misc
01  Boxing Glove       Action
02  Green Head         Puzzle
03  Running Person     Orthodox / possibly platformer
04  Sword              RPG
05  Green Sheet        Simulation
06  Fighter Jet        Shooter
07  Red Square         Adventure
08  Blue Square (P)    Program / full minigame
09  Green Square (D)   Unknown
0A  Red Square (A)     Append / additional data
0B  Brown Square (S)   Unknown
```

### Minigame types

```text
01  Blue Square (P)    Program
02  Green Square (D)   Unknown
04  Red Square (A)     Append
08  Brown Square (S)   Unknown
```

## Minigame download URL

The selected filename is appended to:

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/CGB-BMVJ/
```

Expected naming convention begins with numeric price, then a period, then an ID/name. Example:

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/A4/CGB-BMVJ/1234.G000.cgb
```

The numeric prefix is what marks the request as a billable service.

The download stage blindly accepts returned binary data; minigame validation occurs later.

## Download Wrapper

Wrapper before actual minigame data:

```text
00             Comment length
01..Length     Comment, unused
Length+01      Number of blocks? unused
Length+02      Normally 05; 00 disables compression
Length+03      Compressed size low, unused if no compression
Length+04      Compressed size high, unused if no compression
Length+05      Uncompressed size low
Length+06      Uncompressed size high
Length+07      Even check byte? unused
Length+08      Odd check byte? unused
Length+09...   Compressed minigame stream
```

### Compression format

Proprietary canonical-Huffman-based format with multiple trees. Bitfields are packed big-endian with no padding between fields or compressed chunks.

Per compressed chunk:

```text
16 bits   Number of data symbols

5 bits    Highest character in auxiliary tree A + 1; 1-19
for chars from 0:
  3+ bits Code bit length
          0 => character absent
          if first 3 bits are 111, continue counting 1s until 0;
          actual length = number of 1s + 4; max 16
after character #2:
  2 bits  Number of characters to skip; next = value + 3

9 bits    Highest character in data tree + 1; 0-262
if 0:
  9 bits  Constant data-tree character; 0-261
otherwise for each data-tree character:
  Aux A character:
    0 => this char absent
    1 => this and 2-17 following chars absent
    2 => this and 19+ following chars absent
    >2 => code length + 2
  after Aux-A char 1:
    4 bits skip count - 3
  after Aux-A char 2:
    9 bits skip count - 20

4 bits    Highest character in auxiliary tree B + 1; 1-10
for each Aux-B char:
  3+ bits Code bit length, same extension rule as Aux A

for each data symbol:
  Data-tree character
    0-255 => literal output byte
    256+  => copy length = character number + 253 from previous output
             copying may cross chunk boundaries
  after character 256+:
    Aux-B character
      0 => repeat previous output character
      >0 => highest set bit of offset + 1
    0+ bits => remaining offset bits
```

Decompressed chunks are concatenated without padding. The complete output is then:

1. padded with `00` to a 4 KiB boundary;
2. if necessary, padded with `FF` to an 8 KiB boundary.

### Compression disabled

Raw data is processed in 512-byte chunks, except possibly the final shorter chunk. Chunks are concatenated and padded as above.

Each chunk has an additional 256-byte footer area beginning at offset `0200h`. Up to 256 bytes from the **last** footer, stopping at `FF`, become the player's minigame-organization list:

```text
byte 0  Minigame number
        00-0E = one of 15 built-in games
        10-8F = first Flash bank + 10h
        FF    = terminator
byte 1  Box number, 00-06; invalid values ignored
```

## Minigame Format

Using the base address of a Flash ROM bank:

```text
00-02   Usually JR or JP instruction
03-04   Header size, little-endian; always 006Fh
05      Number of memory blocks
06      Primary icon
07      Secondary icon
09-0C   Game ID, e.g. G000
0D-0E   Append ID; 0000 if not append-related
0F...   NUL-terminated title
24...   NUL-terminated dialog-box text
44      Must be FF for valid minigame
4D-6C   Append data, format depends on Append ID
6D-6E   Additive sum of all other bytes, little-endian
6F...   Code + data
```

On launch:

1. MBC6 maps Flash into Bank 0 (`4000-5FFFh`).
2. Game performs `CALL 4000h`.
3. The header jump starts the downloaded program.

Downloaded code executes **directly from Flash**, rather than being copied to WRAM first.

Checksum details:

- includes padding bytes;
- checksum values `003Bh` or `00B3h` bypass verification entirely;
- for minigames larger than 56 KiB / seven banks, only the first 256 bytes are summed.

### Minigame type icons in downloaded headers

```text
00  Gray P      Program? probably disabled
01  Blue P      Program
02  Green D     Unknown
03  Green D     Unknown
04  Red A       Append
05  Gray A      Append, apparently disabled
06  Gray A      Append, apparently disabled
07  Gray A      Append, apparently disabled
08  Brown S     Unknown
```

### Category icons in downloaded headers

```text
00  Question Mark   Misc
01  Boxing Glove    Action
02  Green Head      Puzzle
03  Running Person  Orthodox / platformer?
04  Sword           RPG
05  Green Sheet     Simulation
06  Fighter Jet     Shooter
07  Green Square    Adventure
```

Values above `08` can draw garbage tile data.

## Slide Puzzle Append Format

The built-in game `とんではねてそろえて` is a 6x4 sliding puzzle. Append ID `05 00` can provide extra images.

Append header data itself is ignored; the first bank contains:

```text
00A0-00D7   BG palettes 0-6, puzzle tiles
00D8-00DF   BG palette 7, border/timer
00E0-00EF   OBJ palettes 0-1, unused
00F0-00F7   OBJ palette 2, cursor
00F8-00FF   OBJ palette 3, cursor arrows
0100-0107   OBJ palette 4, "CLEAR!"
0108-010F   OBJ palette 5, "PRESS A BUTTON"
0110-011F   OBJ palettes 6-7, unused
0120-0133   Preview top-row tilemap
0134-0147   Preview top-row attributes
0148-015B   Preview bottom-row tilemap
015C-016F   Preview bottom-row attributes
0170-017F   Preview left-column tilemap
0180-018F   Preview left-column attributes
0190-019F   Preview right-column tilemap
01A0-01AF   Preview right-column attributes
01B0-01BB   Top-left puzzle tile tilemap, 3x4 tiles
01BC-01C7   Top-left puzzle tile attributes
01C8-03D7   Tilemaps/attributes for next 22 puzzle tiles
03D8-03E3   Bottom-right puzzle tile tilemap
03E4-03EF   Bottom-right puzzle tile attributes
03F0-13EF   VRAM bank 0, tiles 080-17Fh
13F0-1BEF   VRAM bank 1, tiles 080-0FFh
1BF0-1C07   Image title
```

Documented built-in palette values:

- border: `7FFF 1637 1972 0CA8`;
- cursor: `7FFF 2116 000B`;
- arrows: `001F 17FF 7FFF`;
- CLEAR: `35BF 001F 7FFF`;
- PRESS A BUTTON: `0000 001B 7FFF`.

## Rope Puzzle Append Format

`ごろうのロ—プパズル` contains unused support for 16 extra stages using Append ID `01 00`.

Append data begins with a pointer to 1472 bytes in the first bank.

```text
00-01   Offset to stage 01, little-endian
02-03   Offset to stage 02, little-endian
04-1F   Offsets to stages 03-16
```

Each stage is 90 bytes, one byte per tile, row-major.

```text
00  Empty
01  Immovable block
02  Movable block
03  Ladder
04  Finish door — one per stage
10  Starting point — one per stage
```

## String Format

Unused entries effectively behave as spaces; the base game consistently uses `10` for an explicit space.

```text
        0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
00
10         !  "  #  $  %  &  '  (  )  *  +  ‘  -  .  /
20      0  1  2  3  4  5  6  7  8  9  :  ;  <  =  >  ?
30      [  ¥  ]  ×  ÷  {  |  }  ˜  @  ⌜  ⌟  —  ~  、 。
40         A  B  C  D  E  F  G  H  I  J  K  L  M  N  O
50      P  Q  R  S  T  U  V  W  X  Y  Z  ✜  ‥  ^  _  ’
60         a  b  c  d  e  f  g  h  i  j  k  l  m  n  o
70      p  q  r  s  t  u  v  w  x  y  z  Ⓐ  Ⓑ
80      ぁ あ ぃ い ぅ う ぇ え ぉ お か き く け こ さ
90      し す せ そ た ち っ つ て と な に ぬ ね の は
A0      ひ ふ へ ほ ま み む め も ゃ や ゅ ゆ ょ よ ら
B0      り る れ ろ ゎ わ を ん → ← ↑ ↓ •
C0      ァ ア ィ イ ゥ ウ ェ エ ォ オ カ キ ク ケ コ サ
D0      シ ス セ ン タ チ ッ ツ テ ト ナ ニ ヌ ネ ノ ハ
E0      ヒ フ ヘ ホ マ ミ ム メ モ ャ ヤ ュ ユ ョ ヨ ラ
F0      リ ル レ ロ ヮ ワ ヲ ン ☎ ♪ ☺ ☺ ★ ❤ ﾞ ﾟ
```

Notes from the source:

- `33h` is intended to be multiplication, not letter X.
- `5Bh` is the GBC D-pad glyph.
- `7Bh`/`7Ch` are inverted A/B button glyphs.
- `F8h` is also inverse-colored compared with the nearest Unicode representation.
- `FBh` is a second, malformed smiley glyph.
- `FEh` and `FFh` appear **before** the character they modify.

Control codes:

```text
00         End string
01         End line
02 xx      Set text color to xx; default 00
03 xx      Call unknown function with xx; parser behavior around 00 is unusual
04         Clear text field
0F         Wait for A, then resume; continuation is broken and should be avoided
```

## MBC6 Flash Operation

Flash chip used: **MX29F008TC-14**.

Known behavior reverse-engineered from Net de Get:

- Game does not appear to issue chip-ID command `90h`; it directly accesses Flash.
- Sector erase uses command `30h`.
- After `30h`, Net de Get issues `F0h` to terminate the prior erase sequence while status can still be read.
- Flash status byte:
  - bit 7: `1` done, `0` in progress;
  - bit 4: `1` timeout, `0` OK.
- Writes occur in **128-byte portions**.
- At the end of each 128-byte region, e.g. `407Fh`, `40FFh`, the game writes `00`; reads then expose status in a manner similar to erase status.
- `F0h` is used after writing as well.
- Download data is first stored in SRAM, then copied in pieces to WRAM and finally to Flash.
- The game compares Flash contents against the original RAM data after programming and aborts on mismatch.

### Flash banking behavior

After sector-erase command `30h`, the active Flash bank is derived from the bank ID written to:

- `2000h` for Flash mapped at `4000-5FFFh`;
- `3000h` for Flash mapped at `6000-7FFFh`.

That bank appears to be "remembered" for subsequent Flash reads/writes until another Flash command changes the state. The other 8 KiB Flash window can still use its normal bank register for reads.

---

# Zen Nihon GT Senshuken (GBA)

## General Information

`Zen Nihon GT Senshuken`, released internationally as Top Gear GT Championship, is a GBA racing game and Japanese launch title.

Mobile Adapter features:

- downloadable custom tracks;
- downloadable Time Trial ghosts;
- online rankings;
- ghost/ranking uploads.

## Server Structure

Fixed URLs:

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/gtconfig.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/100.gtexcrs***.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/gtgst00.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/gtgst01.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/gtgst02.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/gtgst03.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/gtgst04.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/gtgst05.cgb
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/gtgst06.cgb
```

A dynamic URL prefix stored in `gtconfig.cgb` is used to access:

```text
gtrkconfig.cgb
gtrk00.cgb
gtrk01.cgb
gtrk02.cgb
gtrk03.cgb
gtrk04.cgb
gtrk05.cgb
gtrk06.cgb
```

Ghost files may use arbitrary filenames under:

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/
```

## `gtconfig.cgb`

Exactly **200 bytes (`C8h`)** are relevant; data beyond that is ignored.

```text
00      Service status bitfield
01      Track-enable bitfield for Time Trial ghost downloads
02      Downloadable course ID
03      Course ID intended to restrict ghost uploads
04-C3   Dynamic URL data, ASCII
C4-C7   32-bit additive checksum over 00-C3, little-endian
```

### Service status byte `00`

Course-download state:

- bit 1 set: service disabled with message implying permanent shutdown;
- bit 1 clear + bit 0 set: temporary outage;
- bits 1 and 0 clear: available.

Bits 5 and 4 apply similarly to the other mobile services.

### Ghost-download enable byte `01`

Bits 0-6 correspond to seven tracks:

- bit `0` = enabled;
- bit `1` = disabled.

### Course ID byte `02`

Converted to decimal and formatted as three digits in the filename.

Example:

```text
02 = 30h = decimal 48
-> 100.gtexcrs048.cgb
```

### Upload-course byte `03`

The game contains code intended to limit custom-course ghost uploads to the configured course ID, but uploads still proceed even when the ID does not match. The field is therefore functionally ineffective.

### Dynamic URL

`04-C3` contains a NUL-terminated ASCII URL/prefix used for ranking files.

## `gtrkconfig.cgb`

Exactly 8 bytes:

```text
00      Enable/disable ranking menus by track
01      Intended upload-enable bitfield by track
02-03   Unused
04-07   32-bit additive checksum of 00-03, little-endian
```

Byte `00`: bits 0-6, where `0` enables a track and `1` disables it.

Byte `01` is intended to gate ghost uploads but, like `gtconfig.cgb` byte `03`, does not actually prevent uploads.

## `100.gtexcrs***.cgb`

Downloadable custom course. Historical service charge: 100 yen.

`***` is the three-digit decimal representation of `gtconfig.cgb` byte `02`.

File length: **272 bytes**.

```text
0000        Course ID; prevents duplicate purchase
0001        01 = use Famitsu-promotional scenery
0002-0003   Unused, expected 0000
0004-001B   11-character title, custom 16-bit encoding
001C-010B   Racetrack data
010C-010F   32-bit additive checksum of 0000-010B, little-endian
```

### Racetrack data

10x6 grid, four bytes per block, row-major.

```text
byte 0   Block type:
         01 straight
         02 turn
         03 starting position
byte 1   Turn/start orientation subtype
byte 2   Must be 01 for valid block
byte 3   Unused, normally 00
```

Turn subtype:

```text
00  East -> South
01  South -> West
02  West -> North
03  North -> East
```

Starting orientation:

```text
00  Face East
01  Face South
02  Face West
03  Face North
```

## `gtgst00.cgb` - `gtgst06.cgb`

Seven ghost-selection menus, one per track.

Each file: `09E4h` bytes.

Together they expose 30 ghosts per track / 210 menu entries total.

```text
0000-0007   Local last-update timestamp
000A-09DF   Ghost Data Entries
09E0-09E3   32-bit additive checksum of 0000-09DF, little-endian
```

Ghost Data Entry — 84 bytes:

```text
00-33   Mobile Rank Entry
34-53   ASCII ghost-download URL / filename, max 32 chars
```

Final URL form:

```text
http://gameboy.datacenter.ne.jp/cgb/download?name=/28/AGB-AGTJ/<ghost filename>
```

Filename price rules:

- one period: displayed as free;
- two periods: service price must be one of `0, 50, 100, 150, 200, 250, 300` yen or the entry is hidden.

### Ghost time

Four-byte little-endian integer representing hundredths of a second:

```text
byte 0 contribution: value * 0.01 s
byte 1 contribution: value * 256 * 0.01 s
byte 2 contribution: value * 65536 * 0.01 s
byte 3 contribution: value * 16777216 * 0.01 s
```

Maximum accepted/displayable ghost time: **99:59.99**.

## Ghost Data

Downloaded ghost file:

```text
00-33   Mobile Rank Entry
34-EOF  Track Movement Data
```

Unlike ranking lists, byte `00` of the Mobile Rank Entry is used here to force the exact track for the ghost.

Track values:

```text
00  Twin Ring Motegi
01  Fuji Speedway
02  Sportsland Sugo
03  Ti Circuit Aida
04  Central Park Mine Circuit
05  Suzuka Circuit
06  EDIT — custom course slot 1
07  EDIT — custom course slot 2
08  EDIT — custom course slot 3
09  Twin Ring Motegi — Mirror
0A  Fuji Speedway — Mirror
0B  Sportsland Sugo — Mirror
0C  Ti Circuit Aida — Mirror
0D  Central Park Mine Circuit — Mirror
0E  Suzuka Circuit — Mirror
0F  EDIT — Mirror custom slot 1
10  EDIT — Mirror custom slot 2
11  EDIT — Mirror custom slot 3
```

Track Movement Data matches locally generated Time Trial ghost movement data. Downloaded data is effectively copied to Flash RAM; the cartridge storage layer adds a checksum every 4 KiB. The downloaded file itself does not need those per-4KiB checksums.

## `gtrk00.cgb` - `gtrk06.cgb`

Online mobile ranking files.

Each file:

- length `0A34h`;
- one track;
- 50 rank entries;
- each entry is 52 bytes.

```text
0000-0007   Local last-update timestamp
0008-0A2F   Mobile Rank Entries
0A30-0A33   32-bit additive checksum of 0000-0A2F, little-endian
```

### Mobile Rank Entry

```text
00      Race track
01      Weather: 0 sunny, 1 rain
02      Car type
03      Transmission: 0 automatic, 1 manual
04      Gear ratio: 0 low, 1 medium, 2 high
05      Steering: 0 slow, 1 medium, 2 quick
06      Brake: 0 soft, 1 medium, 2 hard
07      Tire: 0 soft, 1 medium, 2 hard
08      Aerodynamics: 0 low, 1 medium, 2 high
09      Course ID for custom courses
0A-0B   Unused, expected zero
0C-0D   Handicap weight kg, little-endian; max 990;
        UI shows in steps of 10; may be zero
0E-23   11-character player name, custom 16-bit encoding
24-27   Completion time, little-endian hundredths-of-second value
28-2F   GMT registration timestamp
30-33   Ghost ID, little-endian; must not be zero
```

Timestamp:

```text
00-01   Year, little-endian
02      Month
03      Day
04      Hour
05      Minute
06      Second
07      Unused, normally zero
```

## Ghost Entry Upload

Ranking entry is sent as an **SMTP email attachment**, not an HTTP upload.

Message form:

```text
From: xxxxxxxx@yyyy.dion.ne.jp
To:
Subject: GT-CHAMP-ENTRY
X-Game-code: AGB-AGTJ-00
X-Game-title: GT-CHAMP
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="--AGB-AGTJ"
----AGB-AGTJ
Content-Type: text/plain; charset=iso-2022-jp
Context-Transfer-Encoding: 7bit
-----------------------
[Japanese failure-warning text]
-----------------------
----AGB-AGTJ
Content-Type: application/octec-stream; name="gtent**.cgb"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="gtent**.cgb"
DATA
----AGB-AGTJ--
```

`application/octec-stream` and `Context-Transfer-Encoding` are preserved spelling/field quirks from the game; Dan Docs explicitly notes that `octec-stream` is not a transcription typo.

Attachment name is `gtent00.cgb` through `gtent06.cgb`, depending on track.

Attachment format:

```text
0000-001F   Player email address
0020-0053   Mobile Rank Entry
0054-2FAB   Track Movement Data
2FAC-2FAF   Always zero
2FB0-2FB3   32-bit additive checksum of 0000-2FAF, little-endian
```

Upload-specific behavior:

- uploaded player name is limited to five characters;
- uploaded Ghost ID is calculated starting from `020031DCh`, then adding remaining Mobile Rank Entry bytes and every Track Movement Data byte.

## Character Encoding

Custom 16-bit character table:

```text
        0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
000        !  "  #  $  %  &  '  (  )  *  +  ,  -  .  /
010     0  1  2  3  4  5  6  7  8  9  :  ;  <  =  >  ?
020     @  A  B  C  D  E  F  G  H  I  J  K  L  M  N  O
030     P  Q  R  S  T  U  V  W  X  Y  Z  [  ¥  ]  ^  _
040     `  a  b  c  d  e  f  g  h  i  j  k  l  m  n  o
050     p  q  r  s  t  u  v  w  x  y  z  {  |  }  ~  〒
060     ☆ ★ ○ ● ◎ ◇ ◆ □ ■ △ ▲ ▽ ▼ ❤ ♂ ♀
070     \\ ≠ ＜ ＞ ± ✕ ÷ ‖ ‘ ’ “ ” 〔 〕 《 》
080        。 「 」 、 ・ ヲ ァ ィ ゥ ェ ォ ャ ュ ョ ッ
090     ー ア イ ウ エ オ カ キ ク ケ コ サ シ ス セ ソ
0A0     タ チ ツ テ ト ナ ニ ヌ ネ ノ ハ ヒ フ ヘ ホ マ
0B0     ミ ム メ モ ヤ ユ ヨ ラ リ ル レ ロ ワ ン ゛ ゜
0C0     ‥ … ヰ ヴ ヱ    ガ ギ グ ゲ ゴ ザ ジ ズ ゼ ゾ
0D0     ダ ヂ ヅ デ ド パ ピ プ ペ ポ バ ビ ブ ベ ボ ♪
0E0     ∞ 〖 〗 ℃ ¢ £ § ＝ ～ ™ © ® → ← ↑ ↓
0F0        。 『 』 、 ・ を ぁ ぃ ぅ ぇ ぉ ゃ ゅ ょ っ
100     ー あ い う え お か き く け こ さ し す せ そ
110     た ち つ て と な に ぬ ね の は ひ ふ へ ほ ま
120     み む め も や ゆ よ ら り る れ ろ わ ん ゛ ゜
130     ‥ … ゐ    ゑ    が ぎ ぐ げ ご ざ じ ず ぜ ぞ
140     だ ぢ づ で ど ぱ ぴ ぷ ぺ ぽ ば び ぶ べ ぼ
```

Additional notes:

- user input uses characters `000h`, `081h`, `084h`, `0F5h`, `100h` as part of its keyboard/input handling;
- `0BEh`/`0BFh` appear on the katakana keyboard;
- `12Eh`/`12Fh` appear on the hiragana keyboard;
- `0C0h`, `0C1h`, `130h`, `131h` are unavailable for user input and their downloadable-content usage is unknown;
- `135h` and all values from `14Fh` onward render garbage tiles and should not be used;
- `FFFFh` is the string terminator.

---

## Source / Attribution

Original research and documentation: **Dan Docs** by Shonumi and credited contributors.  
Source page: https://shonumi.github.io/dandocs.html  
The source page states: **"Consider all information within this document to be Public Domain. Copy and share as you please."**