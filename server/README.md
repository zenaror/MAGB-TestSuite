# MAGBTEST server fixtures

The `SMALL BUFFER` and `BIG BUFFER` tests talk to synthetic endpoints on
a [REON](https://github.com/REONTeam/reon) server. These are those
endpoints. They live here so the tests are reproducible without access
to any particular person's server — REON has no shared git remote, so
until now the only copy of these files was on one production host.

Nothing here is needed to *build* either ROM. It is needed to *pass* the
two buffer tests.

## Layout

Copy the tree under `web/` into your REON checkout, preserving paths:

```
web/cgb/download/01/MAGBTEST/0.bigbuffer.php     8192 B, checksum F000
web/cgb/download/01/MAGBTEST/0.smallbuffer.php    128 B, checksum 1FC0, GET + POST
web/cgb/upload/01/MAGBTEST/0.bigbuffer.php        verifies an uploaded body
```

## One required change to REON itself

`web/htdocs/cgb/download.php` must let the small buffer past the
front-controller's cost auth, or it is never reached. Change:

```php
$skipCostAuth = preg_match('#/news/\d+\.news\.php$#i', $name) === 1;
```

to:

```php
$skipCostAuth = preg_match('#/news/\d+\.news\.php$#i', $name) === 1
    || preg_match('#^/01/MAGBTEST/0\.smallbuffer\.(cgb|php)$#i', $name) === 1;
```

The pattern is anchored to the exact full path on purpose, not a
`/MAGBTEST/` prefix. This rule **skips** the front controller's
authentication, so it must never widen to a path that does not perform
its own — `0.smallbuffer.php` calls `doAuth(2)` itself, and
`0.bigbuffer.php` does not. Verified as rejected by the anchor:
`.../0.smallbuffer.cgb/../../CGB-BXTJ/0.news.cgb`,
`/x/01/MAGBTEST/...`, and `...cgbX` all fall through to normal auth.

## Things that look like details and are not

- **`.cgb` resolves to `.php`.** `core.php` falls back to `.php` when
  the literal file is missing, so the ROMs request
  `/01/MAGBTEST/0.bigbuffer.cgb`. Do not rename the files.
- **The `0.` prefix is load-bearing.** `getCost()` reads the leading
  dot-separated component; a numeric one means "auth required", and `0`
  means it costs nothing. Removing the prefix changes the auth
  behaviour, it does not just rename the file.
- **The two tests use different halves of REON's auth**, which is why
  both exist. `download.php` calls `doAuth(1)` and `upload.php` calls
  `doAuth()` (type 0), which is the big buffer's route: it trades the
  Authorization for a `Gb-Auth-ID` and needs a third request carrying
  it. The small buffer goes through `doAuth(2)` on a single URL and
  reuses the Authorization for its POST. See
  `gbdk/docs/protocol-notes.md`, "GB00: download and upload do NOT
  authenticate the same way".
- **`doAuth` runs before the file is looked up.** A `401` from one of
  these paths is therefore no evidence the fixture is installed — a
  missing file and a present one challenge identically. Check for the
  body, not the challenge.
- **Compare the checksum case-insensitively anyway.** Both ROMs now
  send uppercase, so the fixtures' `strtoupper()` is belt-and-braces
  rather than load-bearing. It was load-bearing until recently: GBDK
  emitted lowercase via SDCC's `%hx` while RGBDS used its own uppercase
  table, and only the server's normalisation hid the disagreement. Both
  sides now build the header with an explicit, host-tested formatter
  (`gbdk/include/magb_fmt.h`), so the two ROMs put identical bytes on
  the wire — but keep the normalisation, because a client you did not
  write may not.
- **`X-Test-User` is only meaningful if the account exists** on the
  host you point at. On a fresh test server it reports whatever that
  server resolves.

## Not included

The `magbtest_log.php` request instrumentation used while developing
these tests is deliberately absent. It writes request bodies to disk,
which is a decision each host operator should make deliberately rather
than inherit from a copy-paste, and it is specific to one server's
debugging setup rather than to running the tests.
