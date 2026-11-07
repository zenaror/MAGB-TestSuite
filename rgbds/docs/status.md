# RGBDS implementation status

This page describes the public feature set and known limits of the SM83
assembly implementation. Source files and the integration guide are the
reference for implementation details. Build success alone does not
establish runtime behavior with an adapter, emulator, or network service.

## Implemented features

- CGB-only ROM with the Mobile Adapter GB packet framing, checksum,
  session handling, command wrappers, and a protocol trace.
- Adapter configuration reading and decoding.
- ISP/HTTP checks, including Tamago Egg, Trainer Home, Small Buffer,
  Big Buffer, SMTP/POP3, and an interactive raw-TCP viewer.
- GB00 challenge/response support for authenticated requests.
- P2P Caller and Listener checks, plus server-conformance testing for
  the Auth Prefix fixture.
- Battery-backed storage for the ISP password; the password is entered
  on the device and is not compiled into the ROM.

See the root README for the purpose of each check and
[`integration-guide.md`](integration-guide.md) for the protocol-module
interfaces.

## Known limitations

- An early ISP/HTTP failure stops without attempting the full teardown
  sequence (TCP Close, ISP Logout, Hang Up, End Session).
- HTTP results do not display the total received-byte count.
- Writing adapter configuration (`0x1A`) is not implemented.
- The built-in font covers ASCII `$20` through `$7A`; later punctuation
  is unavailable.
- Email `STAT` parsing and decimal formatting use 8-bit values, so
  counts above 255 are not represented safely.
- `MagbDial` and `MagbTcpOpen` rely on their current fixed-length call
  sites and do not validate a runtime-provided digit count.
- On non-CGB hardware, serial initialization halts without displaying
  an explanatory message.

## Validation

Run `make` from `rgbds/` and check that the ROM header byte at `0x143`
is `0xC0`. This implementation has no host-side `make test` target.
Use the manual procedures in
[`../gbdk/docs/testing.md`](../../gbdk/docs/testing.md) for runtime
checks, and report those results separately from build validation.
