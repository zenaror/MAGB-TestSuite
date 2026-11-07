# AGENTS.md — MAGB TestSuite

This repository contains a clean-room, Game Boy Color diagnostic ROM for the real Mobile Adapter GB protocol. It is not a game ROM; do not add protected game code, ROM data, graphics, or credentials.

## Project layout

- `gbdk/` is the C implementation built with GBDK-2020/SDCC. Run its build and host tests from that directory.
- `rgbds/` is the independent SM83 assembly implementation built with RGBDS. Follow its README and documentation; GBDK-specific instructions do not apply there.
- `server/` contains synthetic MAGBTEST fixtures used by the buffer checks. See `server/README.md`.
- The root README maps the public protocol, integration, testing, and implementation documentation.

## Working rules

- State which implementation (`gbdk/` or `rgbds/`) is in scope before changing or testing it. Keep the two implementations independent and behaviorally aligned.
- Target CGB/SM83 only. Do not add Game Boy Advance code or APIs.
- For GBDK code changes, run `make` and `make test` in `gbdk/`; verify the ROM header byte at `0x143` is `0xC0`. For RGBDS code changes, run `make` in `rgbds/` and verify its CGB-only header.
- A successful build or host test does not establish adapter, emulator, or network runtime behavior. Report runtime evidence only when that environment was actually tested.
- Follow the protocol and layering contracts in the implementation documentation. Keep payload lengths explicit, bound external waits, and report failures instead of inventing successful responses.
- Update the public documentation when behavior changes. Preserve human authorship and licensing; do not add AI co-author trailers automatically.
- Do not commit or push unless the project owner requests it.
