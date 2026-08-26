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

# ROM name shown in the cartridge header (max 16 chars).
ROM_NAME  := MAGB TESTSUITE

INCLUDE_DIR := include

SRCS := \
    src/main.c \
    src/hw/serial_hw.c \
    src/protocol/magb_packet.c \
    src/protocol/magb_session.c \
    src/protocol/magb_network.c \
    src/app/test_runner.c \
    src/app/ui.c \
    src/app/gb00_auth.c

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

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

test: $(BUILD_DIR)/test_packet
	$(BUILD_DIR)/test_packet

$(BUILD_DIR)/test_packet: tests/host/test_packet.c src/protocol/magb_packet.c | $(BUILD_DIR)
	$(CC) -Wall -Wextra -I$(INCLUDE_DIR) -DMAGB_HOST_TEST \
	    tests/host/test_packet.c src/protocol/magb_packet.c \
	    -o $@

clean:
	rm -rf $(BUILD_DIR)
