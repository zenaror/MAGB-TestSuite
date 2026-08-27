# Makefile for the Mobile Adapter GB TestSuite (GBC-only, GBDK-2020).
#
# Usage:
#   make               build build/mobile_adapter_testsuite.gbc
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
ROM       := $(BUILD_DIR)/mobile_adapter_testsuite.gbc

# Local emulator working directory (e.g. a BGB install), at the
# project root. Every build copies the freshly built ROM there
# automatically; not required to exist -- the copy is skipped with a
# message if missing, it never fails the build.
EMU_DIR := emulador

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
    src/app/test_runner.c \
    src/app/ui.c \
    src/app/gb00_auth.c \
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
# Tried -Wm-yt0x19 -Wm-yoA -autobank (MBC5 + GBDK's automatic bank
# assignment, matching examples/gb/hblank_copy) to fit the on-screen
# keyboard added for password/IP entry once the ROM outgrew 32 KiB.
# The ROM built and reported the right header bytes, but hung at a
# blank screen at runtime -- this project's call graph (main -> ui ->
# test_runner -> magb_network -> magb_session, deep and mutual across
# many files) is a much harder automatic-banking case than a
# scene-by-scene asset viewer, and diagnosing/annotating every
# cross-bank call correctly (SDCC needs functions actually called
# across a bank boundary marked BANKED explicitly; autobank alone does
# not guarantee every call site gets a correct far-call) was judged too
# large and too risky a change to make good on this session, given a
# real user testing on real hardware. Reverted; the ROM stays
# single-bank/no-mapper (32 KiB) and the code that didn't fit was
# trimmed instead -- see docs/protocol-notes.md if this needs
# revisiting once the ROM grows again.
LCCFLAGS := -msm83:gb -Wm-yC -Wm-yn"$(ROM_NAME)" -I$(INCLUDE_DIR) $(CFLAGS_EXTRA)

.PHONY: all clean test toolchain-check

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

test: $(BUILD_DIR)/test_packet $(BUILD_DIR)/test_config
	$(BUILD_DIR)/test_packet
	$(BUILD_DIR)/test_config

$(BUILD_DIR)/test_packet: tests/host/test_packet.c src/protocol/magb_packet.c | $(BUILD_DIR)
	$(CC) -Wall -Wextra -I$(INCLUDE_DIR) -DMAGB_HOST_TEST \
	    tests/host/test_packet.c src/protocol/magb_packet.c \
	    -o $@

$(BUILD_DIR)/test_config: tests/host/test_config.c src/protocol/magb_config.c | $(BUILD_DIR)
	$(CC) -Wall -Wextra -I$(INCLUDE_DIR) -DMAGB_HOST_TEST \
	    tests/host/test_config.c src/protocol/magb_config.c \
	    -o $@

clean:
	rm -rf $(BUILD_DIR)
