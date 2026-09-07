# Makefile for the Mobile Adapter GB TestSuite (GBC-only, GBDK-2020).
#
# Usage:
#   make               build build/mobile_adapter_testsuite_gbdk.gbc
#   make test          build and run the host-side protocol unit tests
#   make clean         remove build/ artifacts
#
# Toolchain discovery:
#   GBDK_HOME defaults to /opt/gbdk, the common Linux/macOS install
#   location. Override it on the command line or in the environment
#   for any other installation, e.g.:
#
#     make GBDK_HOME=$HOME/gbdk-2020/gbdk
#
GBDK_HOME ?= /opt/gbdk
LCC       := $(GBDK_HOME)/bin/lcc

CC        ?= cc

BUILD_DIR := build
# Deliberately a different filename than rgbds/build/mobile_adapter_testsuite_rgbds.gbc
# -- both builds copy into the shared ../emulador/ below, so distinct
# names keep one implementation's ROM from silently overwriting the
# other's there.
ROM       := $(BUILD_DIR)/mobile_adapter_testsuite_gbdk.gbc

# Local emulator working directory (e.g. a BGB install), at the
# repo root (../emulador -- shared across implementations, one level
# up from this gbdk/ directory). Every build copies the freshly built
# ROM there automatically; not required to exist -- the copy is
# skipped with a message if missing, it never fails the build.
EMU_DIR := ../emulador

# ROM name shown in the cartridge header (max 16 chars).
ROM_NAME  := MAGB TESTSUITE

INCLUDE_DIR := include

SRCS := \
    src/main.c \
    src/hw/serial_hw.c \
    src/protocol/magb_packet.c \
    src/protocol/magb_session.c \
    src/protocol/magb_network.c \
    src/protocol/magb_config.c \
    src/protocol/magb_fmt.c \
    src/app/test_runner.c \
    src/app/ui.c \
    src/app/gb00_auth.c \
    src/app/save.c \
    src/app/sound.c

# CFLAGS_EXTRA: extra -D/-I flags, e.g. to override include/test_config.h
# defaults without editing it, or to generate BGB-compatible debug
# symbols (.noi/.sym/.cdb) for a given build without making that the
# default:
#   make GBDK_HOME=... CFLAGS_EXTRA='-DTEST_HTTP_HOST=\"myserver.example\"'
#   make GBDK_HOME=... CFLAGS_EXTRA=-debug
CFLAGS_EXTRA ?=

# GBC-only build:
#   -Wm-yC     mark the ROM as CGB-only (header byte 0x143 = 0xC0)
#   -Wm-yn"..."  set the cartridge title
#
#   -Wl-yt0x1B   cartridge type MBC5 + RAM + BATTERY (header 0x147)
#   -Wl-ya1      one 8 KiB cart RAM bank (header 0x149)
#
# The battery-backed RAM is not for the mapper's sake -- it holds the
# ISP password across power cycles (src/app/save.c). The mapper came
# first, for code space; once it was there, RAM+BATTERY was a header
# byte away and the password no longer has to be retyped every boot.
# See include/save.h on what that means for the resulting .sav file.
#   -Wm-yoA      let bankpack size the ROM (auto bank count)
#   -autobank    run bankpack to assign `#pragma bank 255` areas
#
# BANKING (MBC5), and why it is deliberately kept this narrow:
#
# An earlier attempt turned -autobank on and let bankpack scatter this
# project's modules across banks. It built and reported the right
# header bytes, but hung on a blank screen at runtime: the call graph
# here (main -> ui -> test_runner -> magb_network -> magb_session,
# deep and mutual across many files) is a much harder automatic-banking
# case than a scene-by-scene asset viewer, and autobank alone does NOT
# guarantee every cross-bank call site gets a correct far-call -- SDCC
# needs each function actually called across a bank boundary marked
# BANKED explicitly, on both prototype and definition. That attempt was
# reverted and the ROM stayed single-bank/no-mapper (32 KiB).
#
# What is different now: exactly ONE translation unit is banked,
# src/app/gb00_auth.c (`#pragma bank 255`, ~5 KiB of MD5/base64/GB00
# code). It exports four functions, all marked GB00_BANKED on both
# sides, and it calls nothing outside itself -- so there is exactly one
# kind of cross-bank edge in the whole ROM, and it is annotated. Every
# other module stays in the always-mapped bank 0/1 window exactly as
# before, which is what keeps calls *out of* the banked module (and all
# existing call paths) safe without any further annotation.
#
# That one move freed ~5 KiB in the fixed window -- enough to fit the
# BIG BUFFER test (~4 KiB), which did not fit at 32 KiB. Bank 2 has
# ~11 KiB left for future growth; if a second module ever needs
# banking, annotate it the same way rather than widening -autobank's
# reach across the existing call graph.
#
# Two flags below are load-bearing for that to actually work at
# runtime, both for the same underlying reason: this ROM's non-banked
# code (~30 KiB) does not fit in bank 0, so the linker lays `_CODE` out
# FLAT across the whole 0x0000-0x7FFF window -- banks 0 AND 1. That is
# fine on its own (bank 1 is what MBC5 maps at reset and we never leave
# it), but it means anything living above 0x3FFF temporarily ceases to
# exist for as long as the banked module is mapped in.
#
#   -Wb-min=2
#     bankpack defaults to handing out bank 1 first -- physically the
#     same ROM the flat `_CODE` already occupies. That produced
#     "Multiple write ... Possible overflow from Bank 0 into Bank 1"
#     and would have corrupted both. Banked modules start at bank 2.
#
#   -Wl-b_HOME=0x0200 -Wl-b_CODE=0x0C00
#     `_HOME` holds ___sdcc_bcall_ehl, the trampoline that performs the
#     bank switch and the far call. By default the linker emits `_CODE`
#     first and `_HOME` after it, which put the trampoline at 0x76E1 --
#     inside the switchable window, so the instant it wrote bank 2 to
#     the MBC5 register it unmapped ITSELF and the CPU carried on
#     executing whatever gb00_auth happened to have at that address.
#     Pinning `_HOME` to 0x0200 and starting `_CODE` after it keeps the
#     trampoline (and everything else in _HOME) in bank 0. 0x0C00 leaves
#     _HOME room to grow; if it ever outgrows that the linker overlaps
#     the two areas, so `make check-banking` verifies the result rather
#     than trusting the constant.
#
# The same reasoning is why src/app/gb00_auth.c calls NOTHING external
# -- it has local copies of memcpy/strlen instead of <string.h>'s,
# which the linker placed at 0x6DF2/0x7732. See that file's header
# comment. Interrupt handlers are fine as-is: the 0x40/0x48 vectors
# dispatch into crt0 code below 0x1000 and the serial IRQ is unused
# (this ROM polls SC_REG), so nothing in an ISR path is ever unmapped.
LCCFLAGS := -msm83:gb -Wm-yC -Wl-yt0x1B -Wl-ya1 -Wm-yoA -autobank -Wb-ext=.rel -Wb-min=2 \
            -Wl-b_HOME=0x0200 -Wl-b_CODE=0x0C00 \
            -Wm-yn"$(ROM_NAME)" -I$(INCLUDE_DIR) $(CFLAGS_EXTRA)

.PHONY: all clean test toolchain-check check-banking

all: toolchain-check $(ROM)

toolchain-check:
	@if [ ! -x "$(LCC)" ]; then \
		echo "error: GBDK lcc not found at $(LCC)"; \
		echo "  set GBDK_HOME to your GBDK-2020 install, e.g.:"; \
		echo "    make GBDK_HOME=/path/to/gbdk"; \
		exit 1; \
	fi

$(ROM): $(SRCS) $(wildcard $(INCLUDE_DIR)/*.h) | $(BUILD_DIR)
	$(LCC) $(LCCFLAGS) -o $@ $(SRCS)
	@if [ -d "$(EMU_DIR)" ]; then \
		cp "$(ROM)" "$(EMU_DIR)/"; \
		echo "copied $(ROM) -> $(EMU_DIR)/"; \
	else \
		echo "skipped: $(EMU_DIR) does not exist"; \
	fi

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

test: $(BUILD_DIR)/test_packet $(BUILD_DIR)/test_config $(BUILD_DIR)/test_fmt
	$(BUILD_DIR)/test_packet
	$(BUILD_DIR)/test_config
	$(BUILD_DIR)/test_fmt

$(BUILD_DIR)/test_packet: tests/host/test_packet.c src/protocol/magb_packet.c | $(BUILD_DIR)
	$(CC) -Wall -Wextra -I$(INCLUDE_DIR) -DMAGB_HOST_TEST \
	    tests/host/test_packet.c src/protocol/magb_packet.c \
	    -o $@

$(BUILD_DIR)/test_fmt: tests/host/test_fmt.c src/protocol/magb_fmt.c | $(BUILD_DIR)
	$(CC) -Wall -Wextra -I$(INCLUDE_DIR) -DMAGB_HOST_TEST \
	    tests/host/test_fmt.c src/protocol/magb_fmt.c \
	    -o $@

$(BUILD_DIR)/test_config: tests/host/test_config.c src/protocol/magb_config.c | $(BUILD_DIR)
	$(CC) -Wall -Wextra -I$(INCLUDE_DIR) -DMAGB_HOST_TEST \
	    tests/host/test_config.c src/protocol/magb_config.c \
	    -o $@

# Verifies the three runtime invariants the MBC5 banking note above
# depends on. All are silent at build time and fatal at runtime, and all
# are one careless edit away, so check them mechanically rather than by
# reading the map file by hand:
#
#   1. ___sdcc_bcall_ehl (the bank-switch trampoline) must live below
#      0x4000, or it unmaps itself mid-switch.
#   2. src/app/gb00_auth.c, the one banked module, must reference no
#      external symbol other than that trampoline -- anything else it
#      calls would be in the flat _CODE area that bank 2 displaces.
#   3. No banked function may be reached by a direct CALL from outside
#      its bank -- that is what a BANKED annotation mismatch produces,
#      and it builds cleanly and then parks the CPU at PC=0x0038.
#      (Needs python3; skipped with a notice if it is not installed.)
#
# This needs a -debug build for the .noi symbol file, so it builds into
# a scratch directory rather than disturbing $(ROM).
check-banking: toolchain-check | $(BUILD_DIR)
	@rm -rf $(BUILD_DIR)/bankcheck && mkdir -p $(BUILD_DIR)/bankcheck
	@$(LCC) $(LCCFLAGS) -debug -o $(BUILD_DIR)/bankcheck/rom.gbc $(SRCS)
	@addr=$$(sed -n 's/^DEF ___sdcc_bcall_ehl 0x\([0-9A-Fa-f]*\).*/\1/p' \
	    $(BUILD_DIR)/bankcheck/rom.noi); \
	if [ -z "$$addr" ]; then \
	    echo "check-banking: FAIL - ___sdcc_bcall_ehl not found in .noi"; exit 1; \
	fi; \
	if [ $$((0x$$addr)) -ge 16384 ]; then \
	    echo "check-banking: FAIL - trampoline at 0x$$addr is above 0x3FFF;"; \
	    echo "  it would unmap itself on every banked call. See LCCFLAGS."; \
	    exit 1; \
	fi; \
	echo "check-banking: trampoline at 0x$$addr (bank 0) OK"
	@$(LCC) -msm83:gb -I$(INCLUDE_DIR) -c \
	    -o $(BUILD_DIR)/bankcheck/gb00_auth.rel src/app/gb00_auth.c
	@extern=$$(grep '^S ' $(BUILD_DIR)/bankcheck/gb00_auth.rel \
	    | grep 'Ref' | awk '{print $$2}' | grep -v '^___sdcc_bcall_ehl$$' || true); \
	if [ -n "$$extern" ]; then \
	    echo "check-banking: FAIL - banked gb00_auth.c references external symbols:"; \
	    echo "$$extern" | sed 's/^/  /'; \
	    echo "  These live in the flat _CODE area that bank 2 displaces."; \
	    echo "  Add local copies inside gb00_auth.c instead."; \
	    exit 1; \
	fi; \
	echo "check-banking: gb00_auth.c is self-contained OK"
	@if command -v python3 >/dev/null 2>&1; then \
	    python3 tools/check_far_calls.py \
	        $(BUILD_DIR)/bankcheck/rom.gbc $(BUILD_DIR)/bankcheck/rom.noi; \
	else \
	    echo "check-banking: SKIPPED far-call check (python3 not installed)"; \
	fi

clean:
	rm -rf $(BUILD_DIR)
