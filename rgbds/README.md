# Mobile Adapter GB TestSuite -- RGBDS implementation

A from-scratch, hand-written SM83 assembly implementation, built with
[RGBDS](https://rgbds.gbdev.io/), living alongside the working
[`gbdk/`](../gbdk/) C implementation of the same TestSuite -- see the
repo root `README.md` for how the two relate, and `docs/status.md` in
this directory for exactly what's implemented so far (early/partial;
don't assume feature parity with `gbdk/`).

## Build

```sh
make
```

Requires RGBDS (`rgbasm`, `rgblink`, `rgbfix`) on `PATH`, or point at a
specific install:

```sh
make RGBASM=/path/to/rgbasm RGBLINK=/path/to/rgblink RGBFIX=/path/to/rgbfix
```

Output: `build/mobile_adapter_testsuite_rgbds.gbc`, a CGB-only
(`0x143 = 0xC0`), no-mapper, 32 KiB ROM. Also copied to the shared
`../emulador/` if that directory exists (see `gbdk/docs/testing.md`).

```sh
make clean
```

## Using this in your own homebrew

Want the Mobile Adapter GB protocol code in your own ROM, not just to
run this diagnostic one? `docs/integration-guide.md` covers exactly
what to copy (`src/hw/`, `src/protocol/`, not `src/app/`), the one real
coupling point you need to stub out (`SetStatus::`), and worked recipes
for a session and an ISP/HTTP fetch.
