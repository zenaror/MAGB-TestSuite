# Makefile for the Mobile Adapter GB TestSuite -- RGBDS/SM83 assembly
# implementation (see rgbds/docs/status.md for what's actually built so
# far; this is an early, in-progress sibling of the working gbdk/
# implementation, not a drop-in replacement for it yet).
#
# Usage:
#   make               build build/mobile_adapter_testsuite_rgbds.gbc
#   make clean         remove build/ artifacts
#
# Toolchain discovery:
#   RGBASM/RGBLINK/RGBFIX default to being on PATH (the common case once
#   RGBDS is installed via a package manager or its own installer).
#   Override for a local/custom build, e.g.:
#
#     make RGBASM=/path/to/rgbasm RGBLINK=/path/to/rgblink RGBFIX=/path/to/rgbfix
#
RGBASM  ?= rgbasm
RGBLINK ?= rgblink
RGBFIX  ?= rgbfix

BUILD_DIR := build
# Deliberately a different filename than gbdk/build/mobile_adapter_testsuite_gbdk.gbc
# (both copy into the same shared ../emulador/ below) -- same name would
# silently overwrite whichever implementation built most recently.
ROM       := $(BUILD_DIR)/mobile_adapter_testsuite_rgbds.gbc

# Local emulator working directory, shared with the GBDK implementation
# (see the repo root's README.md / gbdk/docs/testing.md) -- one level up
# from this rgbds/ directory, same as gbdk/Makefile's EMU_DIR. Not
# required to exist; the copy is skipped with a message if missing.
EMU_DIR := ../emulador

ROM_NAME := MAGB TESTSUITE

INCLUDE_DIR := include

SRCS := \
    src/main.asm \
    src/hw/serial.asm \
    src/hw/joypad.asm \
    src/protocol/packet.asm \
    src/protocol/session.asm \
    src/protocol/config.asm \
    src/app/text.asm \
    src/app/sound.asm \
    src/app/gb00_auth.asm \
    src/app/net_extra.asm

OBJS := $(patsubst src/%.asm,$(BUILD_DIR)/%.o,$(SRCS))

# RGBASM stopped auto-inserting/auto-stripping a `nop` after `halt`
# entirely as of rgbds v0.8.0 (the old opt-in `-H`/`-h` flags were
# removed along with the behavior) -- whatever `nop` is literally
# written in source (e.g. src/hw/serial.asm's fatal_not_cgb-equivalent
# halt loop, a deliberate DMG-halt-bug guard) is kept as-is, no flag
# needed. `-i` for `--include` was also removed in that same release;
# use `-I` instead.
# RGBASMFLAGS_EXTRA lets a caller pass extra rgbasm defines, e.g. the
# build-identifying commit hash CI injects into the menu title (see
# main.asm's sMenuTitle2 comment and .github/workflows/build-release.yml):
#   make RGBASMFLAGS_EXTRA="-D BUILD_VERSION_STR=abc1234"
RGBASMFLAGS_EXTRA ?=
RGBASMFLAGS := -I $(INCLUDE_DIR)/ -W all $(RGBASMFLAGS_EXTRA)

.PHONY: all clean toolchain-check

all: toolchain-check $(ROM)

toolchain-check:
	@for tool in "$(RGBASM)" "$(RGBLINK)" "$(RGBFIX)"; do \
		if ! command -v "$$tool" >/dev/null 2>&1; then \
			echo "error: '$$tool' not found"; \
			echo "  install RGBDS (https://rgbds.gbdev.io/) or set RGBASM/RGBLINK/RGBFIX, e.g.:"; \
			echo "    make RGBASM=/path/to/rgbasm RGBLINK=/path/to/rgblink RGBFIX=/path/to/rgbfix"; \
			exit 1; \
		fi; \
	done

$(BUILD_DIR)/%.o: src/%.asm $(wildcard $(INCLUDE_DIR)/*.inc) | $(BUILD_DIR)
	@mkdir -p $(dir $@)
	"$(RGBASM)" $(RGBASMFLAGS) -o $@ $<

$(ROM): $(OBJS) | $(BUILD_DIR)
	"$(RGBLINK)" -o $(ROM) $(OBJS)
	"$(RGBFIX)" -Cv -j -l 0x33 -p 0xFF -m 0x00 -t "$(ROM_NAME)" $(ROM)
	@if [ -d "$(EMU_DIR)" ]; then \
		cp "$(ROM)" "$(EMU_DIR)/"; \
		echo "copied $(ROM) -> $(EMU_DIR)/"; \
	else \
		echo "skipped: $(EMU_DIR) does not exist"; \
	fi

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
