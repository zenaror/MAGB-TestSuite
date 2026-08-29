# Mobile Adapter GB TestSuite

A Game Boy Color homebrew ROM that exercises the real Mobile Adapter GB
protocol over the serial port, for validating physical/emulated
adapters, `libmobile`, and REON-compatible services.

This repository holds more than one implementation of the same
TestSuite, each in its own top-level directory:

- **[`gbdk/`](gbdk/)** — the current, working implementation: C via
  GBDK-2020/SDCC. See [`gbdk/README.md`](gbdk/README.md) for build
  instructions.
- [`rgbds/`](rgbds/) — a hand-written SM83 assembly implementation via
  RGBDS, early in progress (hardware serial layer + packet framing so
  far). See [`rgbds/docs/status.md`](rgbds/docs/status.md) for exactly
  what's implemented.

Each implementation is self-contained (its own build, its own docs) so
they can be developed and released independently. [`CLAUDE.md`](CLAUDE.md)
at the repo root covers both: the project brief and protocol
references apply to either implementation, and it says explicitly
which parts of it are GBDK-specific.

`emulador/` (a local emulator working directory, e.g. a BGB install)
and `config.bin` (a real captured Mobile Adapter configuration file)
are shared across implementations rather than duplicated per
directory — see `gbdk/docs/testing.md` for how each is used and
provisioned. Neither is part of this repository (both are
`.gitignore`d).
