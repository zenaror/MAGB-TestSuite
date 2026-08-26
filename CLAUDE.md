# CLAUDE.md

This file provides instructions for Claude Code when working on this repository.

## Project Overview

This repository contains a **Game Boy Color homebrew TestSuite ROM** written in C using **GBDK-2020**.

Its purpose is to validate implementations of the **Mobile Adapter GB** protocol, especially:

* physical or emulated Mobile Adapter GB implementations;
* `libmobile`;
* `libmobile-bgb`;
* REON-compatible services;
* emulator serial/link implementations;
* future Mobile Adapter-compatible hardware.

The ROM is primarily a **diagnostic client**.

It must exercise the real Mobile Adapter GB protocol through the Game Boy Color serial port and provide useful results on the GBC screen.

This is NOT a Pokémon Crystal clone and must not contain Pokémon-specific game code.

---

# Responsibility Boundary

Claude Code is responsible for:

* designing the TestSuite architecture;
* implementing the source code;
* maintaining protocol code;
* compiling the project;
* fixing compiler and linker errors;
* validating ROM metadata/header;
* creating host-side protocol tests where practical;
* ensuring the repository remains buildable;
* documenting protocol decisions.

Claude Code is NOT responsible for proving that the TestSuite works against real hardware or a complete emulator/network environment.

Actual runtime testing will be performed manually by the project owner using environments such as:

```text
Game Boy Color
Mobile Adapter GB

or

BGB
  ->
libmobile-bgb
  ->
libmobile
  ->
REON / network services
```

When runtime testing reveals a problem, the project owner will provide logs, symptoms, screenshots, received bytes, or other observations.

Use that feedback to correct the implementation.

Do not block development because the physical/emulated Mobile Adapter environment is unavailable locally.

---

# Primary Goal

Maintain a ROM capable of testing the main Mobile Adapter GB interaction flows:

1. Adapter/session initialization
2. Mobile Adapter command exchange
3. ISP connection
4. DNS
5. TCP
6. HTTP data transfer
7. Point-to-point connection
8. Raw P2P data exchange
9. Protocol diagnostics

Correct protocol behavior is more important than graphical presentation.

Priority order:

```text
correct wire protocol
> successful compilation
> deterministic diagnostics
> error handling
> maintainability
> UI appearance
```

---

# Target Platform

Target ONLY:

```text
Nintendo Game Boy Color
SM83 CPU
GBDK-2020
```

The ROM should be built as **CGB-only**.

Do NOT implement Game Boy Advance communication.

Do NOT use:

* GBA NORMAL8 APIs;
* GBA NORMAL32;
* SIO32 transport;
* `REG_SIOCNT`;
* ARM code;
* libgba;
* GBA DMA;
* GBA interrupt APIs.

The Mobile Adapter command for SIO32 may be declared as a protocol constant for completeness, but it must NOT be enabled by this TestSuite.

---

# Toolchain

The project uses:

```text
GBDK-2020
```

Prefer the current SM83 target syntax supported by modern GBDK:

```sh
-msm83:gb
```

The ROM must be marked Game Boy Color only using the appropriate GBDK linker option:

```sh
-Wm-yC
```

The resulting ROM should have:

```text
ROM header offset 0x143 = 0xC0
```

---

# Build Is Mandatory

After modifying source code, Claude MUST build the project whenever the GBDK toolchain is available.

Do not finish a coding task with statements such as:

```text
This should compile.
```

Actually compile it.

At minimum run:

```sh
make
```

For significant changes, prefer:

```sh
make clean
make
```

Compilation warnings and errors related to the modified code should be investigated.

Do not leave known compiler errors for the user to discover.

---

# Toolchain Discovery

Before assuming a GBDK installation path, inspect the environment.

Use:

```sh
command -v lcc || true
printf 'GBDK_HOME=%s\n' "$GBDK_HOME"
```

If `GBDK_HOME` is defined:

```sh
"$GBDK_HOME/bin/lcc" -v
```

Otherwise:

```sh
lcc -v
```

The Makefile should allow configuration such as:

```make
GBDK_HOME ?= /opt/gbdk
LCC ?= $(GBDK_HOME)/bin/lcc
```

Do not unnecessarily hardcode a developer-specific path.

---

# Expected Build Commands

The normal workflow must remain:

```sh
make
```

and:

```sh
make clean
```

The expected output should be something similar to:

```text
build/mobile_adapter_testsuite.gbc
```

The exact name may differ if already established by the repository.

Do not rename existing build artifacts without a reason.

---

# Build Validation

After a successful build, validate the CGB ROM header.

For example:

```sh
xxd -s 0x143 -l 1 build/mobile_adapter_testsuite.gbc
```

Expected byte:

```text
c0
```

If another tool such as `hexdump` is available instead, that is acceptable.

The important requirement is to verify that the produced ROM is CGB-only.

---

# Host-Side Tests

Pure protocol logic should remain independent from GBDK hardware APIs whenever practical.

Examples include:

* checksum calculation;
* endian conversion;
* command serialization;
* packet validation;
* response command calculation;
* bounds checking.

These functions may be tested with native host tools such as GCC.

If host tests exist, run them after relevant protocol changes.

For example:

```sh
make test
```

or:

```sh
cc \
    -Iinclude \
    tests/host/test_packet.c \
    src/protocol/magb_packet.c \
    -o build/test_packet

./build/test_packet
```

Prefer adding a `make test` target if one does not already exist and doing so remains simple.

---

# Runtime Tests

Do NOT attempt to substitute fake runtime tests for real Mobile Adapter testing.

Do not fake:

* adapter responses;
* ISP login success;
* DNS success;
* TCP success;
* HTTP responses;
* P2P connections.

Runtime verification is performed by the project owner.

When implementing a feature that cannot be tested locally:

1. compile it;
2. run available unit/static tests;
3. inspect protocol serialization;
4. verify bounds and state transitions;
5. document what needs to be tested manually.

Example final report:

```text
Build: PASS
Host tests: PASS

Manual verification required:
- Begin Session against libmobile
- ISP login
- DNS query
- TCP transfer
```

This is preferable to pretending that external communication was validated.

---

# Technical References

Use these references when protocol behavior needs to be confirmed.

## Dan Docs

Primary wire-protocol reference:

```text
https://shonumi.github.io/dandocs.html#magb
```

Focus on sections beginning with:

```text
[Mobile Adapter GB]
```

Use it for:

* packet format;
* commands;
* ACK behavior;
* adapter IDs;
* checksums;
* wait bytes;
* configuration;
* session behavior.

---

# Pokémon Crystal Mobile

Reference:

```text
https://github.com/gb-mobile/pokecrystal-mobile-eng
```

Use this to understand how a real commercial GBC title orchestrated Mobile Adapter functionality.

Useful areas include:

```text
mobile/
lib/mobile/
home/mobile.asm
home/serial.asm
```

Use it for high-level behavior such as:

* session lifecycle;
* telephone connection;
* ISP setup;
* DNS;
* TCP;
* HTTP;
* P2P;
* mobile battles/trades;
* datacenter communication.

Do NOT port Pokémon gameplay logic.

---

# libma

Reference:

```text
https://github.com/mid-kid/libma
```

Use this as a reference for Nintendo's Mobile Adapter client abstraction.

Useful for:

* command sequencing;
* connection lifecycle;
* error handling;
* network operations;
* high-level Mobile Adapter concepts.

Its GBA-specific transport must NOT be copied into this GBC project.

---

# libmobile

Reference:

```text
https://github.com/REONTeam/libmobile
```

This is particularly important because this TestSuite is intended to validate libmobile behavior.

Inspect implementation details when necessary, especially:

```text
mobile.c
mobile.h
commands.c
commands.h
serial.c
serial.h
config.c
config.h
dns.c
dns.h
```

The ROM should produce normal Mobile Adapter GB traffic rather than special-casing libmobile.

---

# libmobile-bgb

Reference:

```text
https://github.com/REONTeam/libmobile-bgb
```

Use it to understand the expected connection between:

```text
BGB serial port
    ->
libmobile-bgb
    ->
libmobile
```

Do not introduce BGB-specific behavior into the ROM itself.

---

# REON

Reference:

```text
https://github.com/REONTeam/reon
```

Use this to understand recreated Mobile System GB services when implementing Internet-facing TestSuite cases.

Do not invent REON endpoints.

If an endpoint is not known or stable, keep hostname/path configuration compile-time configurable.

---

# LinkMobile

Reference:

```text
https://github.com/afska/gba-link-connection
```

Especially:

```text
lib/LinkMobile.hpp
```

Use it as an architectural reference for:

* state machines;
* timeouts;
* asynchronous command processing;
* P2P;
* connection state;
* retries.

Do NOT copy its GBA hardware layer.

---

# GBDK Documentation

Reference:

```text
https://gbdk.org/docs/api/
```

Use installed GBDK headers as the ultimate authority for API names supported by the actual toolchain version.

When documentation and installed headers differ, write code that compiles against the installed version unless doing so would violate the protocol.

---

# Hardware Communication

Physical Mobile Adapter communication occurs through the Game Boy serial registers:

```c
SB_REG
SC_REG
```

Relevant GBDK constants normally include:

```c
SIOF_XFER_START
SIOF_CLOCK_INT
SIOF_SPEED_32X
```

The Mobile Adapter uses the fast Game Boy Color serial mode.

Prefer:

```c
SC_REG =
    SIOF_XFER_START |
    SIOF_CLOCK_INT |
    SIOF_SPEED_32X;
```

which is normally equivalent to:

```text
0x83
```

Do NOT blindly use:

```text
0x81
```

because that omits the GBC high-speed serial bit.

Prefer symbolic GBDK definitions over unexplained numeric constants.

---

# CGB Double-Speed Mode

Investigate/use GBDK:

```c
cpu_fast();
```

where appropriate.

The ROM is CGB-only.

If platform detection is performed, use the installed GBDK-supported mechanism such as:

```c
_cpu == CGB_TYPE
```

or its current equivalent.

Document any important relationship between:

```text
CGB CPU double speed
SC serial speed bit
Mobile Adapter serial timing
```

---

# Serial Transfer Requirements

The low-level serial layer should look conceptually like:

```c
serial_result_t serial_transfer_byte(
    uint8_t tx,
    uint8_t *rx,
    uint16_t timeout
);
```

A transfer fundamentally performs:

```c
SB_REG = tx;

SC_REG =
    SIOF_XFER_START |
    SIOF_CLOCK_INT |
    SIOF_SPEED_32X;
```

Never use an unbounded loop such as:

```c
while (SC_REG & 0x80);
```

without timeout handling.

A missing adapter must not permanently freeze the TestSuite.

Always provide a bounded timeout.

---

# Adapter Wake-Up

The Mobile Adapter may sleep after inactivity.

The session implementation should account for adapter wake behavior.

When appropriate:

1. perform an initial sacrificial serial transfer;
2. ignore its response;
3. wait roughly 100 ms;
4. begin the real protocol exchange.

A VBlank-based delay is acceptable on GBC.

For example, approximately seven frames is close to the required wake delay.

Do not treat the sacrificial wake byte as protocol data.

---

# Mobile Adapter Packet Format

Do not rely on packed C structs.

Serialize fields explicitly.

Basic structure:

```text
99 66
COMMAND
00
LENGTH_HIGH
LENGTH_LOW
PAYLOAD...
CHECKSUM_HIGH
CHECKSUM_LOW
ACK...
```

Magic:

```text
99 66
```

For normal GBC Mobile Adapter communication:

```text
maximum payload = 254 bytes
length high = 0
```

Oversized payloads must return an error.

Do not silently truncate them.

---

# Checksum

Checksum is a 16-bit unsigned sum of:

```text
command
reserved byte
length high
length low
payload bytes
```

Do NOT include:

```text
99 66
```

Transmit the checksum big-endian:

```text
high byte
low byte
```

---

# Known Serialization Test

The Begin Session command must use:

```text
Command: 0x10
Payload: "NINTENDO"
Length: 8
```

Expected bytes through the checksum:

```text
99 66
10 00 00 08
4E 49 4E 54 45 4E 44 4F
02 77
```

Expected checksum:

```text
0x0277
```

Keep this as a host-side regression test.

---

# Protocol Command Constants

Keep command IDs centralized.

At minimum support constants for:

```text
0x0F Empty
0x10 Begin Session
0x11 End Session
0x12 Dial Telephone
0x13 Hang Up
0x14 Wait For Telephone Call
0x15 Transfer Data
0x16 Reset
0x17 Telephone Status
0x18 Enable SIO32
0x19 Read Configuration
0x1A Write Configuration

0x21 ISP Login
0x22 ISP Logout
0x23 Open TCP Connection
0x24 Close TCP Connection
0x25 Open UDP Connection
0x26 Close UDP Connection
0x28 DNS Query
```

Verify values against protocol references before modifying or extending them.

---

# Request / Response Commands

Responses normally use:

```text
response = command | 0x80
```

Examples:

```text
0x10 -> 0x90
0x15 -> 0x95
```

Important:

```text
0x95 is NOT the universal Mobile Adapter handshake success byte.
```

It is the response command corresponding to command `0x15`.

Session initialization uses:

```text
0x10 -> 0x90
```

with:

```text
"NINTENDO"
```

as the payload.

---

# Wait Bytes

Relevant flow-control values include:

```c
#define MAGB_ADAPTER_WAIT 0xD2
#define MAGB_GBC_WAIT     0x4B
```

The GBC supplies the serial clock.

When receiving a packet from the adapter, the Game Boy must continue executing serial transfers to clock incoming bytes.

Do not passively wait for the adapter to transmit bytes without Game Boy-generated clocks.

---

# Project Architecture

Keep hardware, protocol, and application logic separate.

Recommended structure:

```text
.
├── Makefile
├── CLAUDE.md
├── README.md
├── .gitignore
│
├── include/
│   ├── serial_hw.h
│   ├── magb_protocol.h
│   ├── magb_commands.h
│   ├── test_config.h
│   ├── test_runner.h
│   └── ui.h
│
├── src/
│   ├── main.c
│   │
│   ├── hw/
│   │   └── serial_hw.c
│   │
│   ├── protocol/
│   │   ├── magb_packet.c
│   │   ├── magb_session.c
│   │   └── magb_network.c
│   │
│   └── app/
│       ├── test_runner.c
│       └── ui.c
│
├── tests/
│   └── host/
│
├── docs/
│
└── build/
```

Follow the existing repository structure if it has already diverged sensibly from this layout.

Do not reorganize working code solely to match this example.

---

# Hardware Layer

Hardware-specific code belongs under:

```text
src/hw/
```

Responsibilities:

* `SB_REG`;
* `SC_REG`;
* serial speed;
* transfer start;
* timeout;
* CGB setup;
* adapter wake timing.

It must NOT know about:

* HTTP;
* DNS;
* ISP credentials;
* phone numbers;
* Mobile Adapter command payload semantics.

---

# Protocol Layer

Protocol-specific code belongs under:

```text
src/protocol/
```

Responsibilities:

* packet serialization;
* packet parsing;
* checksum;
* ACK;
* device ID;
* Mobile Adapter command wrappers;
* session state;
* telephone state;
* ISP;
* DNS;
* TCP;
* P2P transfer.

It must NOT implement menus or joypad navigation.

---

# Application Layer

Application code belongs under:

```text
src/app/
```

Responsibilities:

* TestSuite menu;
* result screens;
* user input;
* diagnostics;
* test orchestration;
* trace display.

Do not mix SB/SC register access into UI code.

---

# TestSuite Menu

The ROM should expose a simple text interface.

Target functionality:

```text
MOBILE ADAPTER
GB TESTSUITE

> Adapter / Session
  ISP / HTTP
  P2P Caller
  P2P Listener
  Protocol Info
```

Controls may use:

```text
UP/DOWN - navigate
A       - run/select
B       - cancel/back
SELECT  - trace/details
```

Complex graphics are unnecessary.

Use GBDK text output where practical.

---

# Test 1 — Adapter / Session

The basic adapter test must perform real protocol traffic.

Expected flow:

```text
Wake adapter
    ->
Begin Session 0x10
    ->
"NINTENDO"
    ->
Validate packet
    ->
Validate checksum
    ->
Validate ACK
    ->
Capture adapter ID
    ->
PASS/FAIL
```

Do NOT declare success based only on receiving one known byte.

After the test, attempt a clean:

```text
0x11 End Session
```

---

# Test 2 — ISP / Internet

The Internet TestSuite should exercise the real Mobile Adapter network command path.

Target sequence:

```text
Begin Session
    ->
Telephone Status
    ->
Dial ISP
    ->
ISP Login
    ->
DNS Query
    ->
TCP Open
    ->
HTTP Request
    ->
HTTP Response
    ->
TCP Close
    ->
ISP Logout
    ->
Hang Up
    ->
End Session
```

The purpose is to verify interaction between the ROM and:

```text
Mobile Adapter implementation
libmobile
network backend
REON-compatible infrastructure
```

The TestSuite does not need to reproduce Pokémon Crystal application behavior.

It only needs to exercise the Mobile Adapter network stack correctly.

---

# HTTP Test

Keep HTTP intentionally simple.

Prefer:

```text
HTTP/1.0
```

A diagnostic request may look conceptually like:

```text
GET / HTTP/1.0
Host: <configured host>
User-Agent: MAGB-TestSuite/1.0
Connection: close
```

Hostname and path should be configurable.

Do not claim a Pokémon-specific URL is authentic unless it has been confirmed from project references.

The TestSuite should distinguish:

```text
SERIAL FAILURE

MAGB FAILURE

DNS FAILURE

TCP FAILURE

HTTP TRANSPORT PASS

HTTP STATUS ERROR
```

A valid HTTP `404`, for example, proves substantially more of the transport stack than a timeout.

---

# Test 3 — P2P

Support two roles:

```text
P2P Caller
P2P Listener
```

This allows two instances of the same ROM to communicate.

Caller flow should use the actual Mobile Adapter dialing protocol.

Listener flow should use the documented incoming-call mechanism.

After establishing a P2P connection, exchange deterministic binary payloads using Mobile Adapter transfer command `0x15`.

For example:

```text
PING
PONG
```

followed by a known binary test pattern.

PASS requires actual bidirectional byte validation.

---

# Test Configuration

Keep environment-dependent values in one configuration header.

For example:

```text
include/test_config.h
```

Possible configuration:

```c
#define TEST_ISP_PHONE      "#9677"
#define TEST_ISP_LOGIN      "test"
#define TEST_ISP_PASSWORD   "test"

#define TEST_HTTP_HOST      "example"
#define TEST_HTTP_PORT      80
#define TEST_HTTP_PATH      "/"

#define TEST_P2P_PHONE      "127000000001"
```

Defaults must be easy to override.

Do not spread test server configuration throughout protocol source files.

---

# Timeouts

Every operation that can wait for external input must be bounded.

Examples:

* serial byte transfer;
* packet reception;
* ACK reception;
* dialing;
* incoming P2P call;
* ISP login;
* DNS;
* TCP open;
* TCP receive.

The user must always eventually regain control.

The `B` button should abort long-running TestSuite operations where practical.

Never create indefinite loops waiting for hardware.

---

# Memory Constraints

This is an 8-bit Game Boy Color program.

Avoid:

```text
malloc
calloc
recursion
large stack allocations
large local arrays
floating point
unbounded logs
```

Prefer:

```text
static buffers
fixed-size arrays
uint8_t
uint16_t
explicit capacities
```

The Mobile Adapter payload layer must support up to:

```text
254 bytes
```

Do not allocate several 254-byte temporary buffers simultaneously unless necessary.

---

# Binary Data

Mobile Adapter payloads are binary.

Never assume payload data is:

* printable;
* ASCII;
* NUL-terminated.

Always carry explicit lengths.

Do not use string APIs for arbitrary packet data.

---

# Protocol Trace

Provide a small diagnostic trace facility.

At minimum, record recent:

```text
TX byte
RX byte
```

A fixed-size ring buffer is preferred.

For example:

```c
typedef struct {
    uint8_t direction;
    uint8_t value;
} serial_trace_entry_t;
```

A 64 or 128-entry buffer is sufficient.

It should be possible for the user to inspect recent traffic from the TestSuite UI.

This information is especially important because the user will compare the ROM's behavior with external libmobile/emulator logs.

---

# Error Reporting

Do not collapse all failures into:

```text
ERROR
```

Differentiate important cases such as:

```text
TIMEOUT
BAD MAGIC
BAD LENGTH
BAD CHECKSUM
BAD ACK
BAD DEVICE ID
UNEXPECTED RESPONSE
DIAL FAILED
ISP FAILED
DNS FAILED
TCP FAILED
P2P FAILED
CANCELLED
```

When practical, show:

```text
expected command
actual command
last transmitted byte
last received byte
```

This ROM is a diagnostic tool.

---

# No Fake Implementations

Do not add code such as:

```c
return true; /* assume success */
```

or:

```c
/* TODO implement Mobile Adapter */
```

or:

```c
/* fake HTTP response */
```

or:

```c
/* simulate connected state */
```

A feature that is not implemented must explicitly return an unsupported/error status.

Never generate a fake PASS result.

---

# Avoid Placeholder Code

Before considering a change complete, inspect modified source for obvious unfinished work.

Useful command:

```sh
rg -n "TODO|FIXME|XXX|HACK|return true|while *\\( *1 *\\)" \
    src include tests
```

Review matches manually.

Not every `while (1)` is inherently incorrect, for example the main game loop may intentionally run forever.

The important rule is that external hardware waits must never be infinite.

---

# Compiler Compatibility

Write C compatible with the SDCC compiler bundled with GBDK-2020.

Be conservative with language features.

Prefer:

```text
simple C
explicit integer types
small functions
static allocation
clear control flow
```

over desktop C idioms.

When compiler behavior is uncertain, compile and verify.

---

# Warnings

Do not casually suppress compiler warnings.

Fix:

* incompatible pointer types;
* truncation;
* implicit declarations;
* signed/unsigned bugs;
* uninitialized variables;
* unreachable code;
* overflow problems;

where relevant.

If a warning must remain because of a GBDK/SDCC peculiarity, document it.

---

# Development Workflow

For implementation tasks, follow this general sequence:

```text
1. Inspect existing code.

2. Determine the smallest correct architectural change.

3. Consult protocol references if wire behavior changes.

4. Implement.

5. Run host tests where applicable.

6. Run:
       make clean
       make

7. Fix all build failures caused by the change.

8. Validate the CGB header.

9. Inspect for unfinished placeholders.

10. Report what still requires physical/emulator testing.
```

Do not stop after step 4.

---

# Do Not Rewrite Working Code Without Reason

Before changing an existing module:

* understand its current behavior;
* preserve working public interfaces when practical;
* avoid broad refactors unrelated to the requested feature.

This project deals with timing-sensitive protocol code.

A large cosmetic refactor can introduce protocol regressions.

Prefer small, reviewable changes.

---

# When Runtime Feedback Is Provided

The project owner will manually test the ROM.

Feedback may include:

```text
screen output
BGB behavior
libmobile log
reon log
serial byte trace
timeout location
unexpected response byte
adapter behavior
```

When this happens:

1. treat the reported observation as evidence;
2. identify the corresponding state/packet;
3. compare against protocol references;
4. inspect current serialization/parsing;
5. fix the smallest likely root cause;
6. compile again;
7. report exactly what changed;
8. specify what should be retested.

Do not respond by merely suggesting generic troubleshooting if the source code can be inspected and corrected.

---

# Useful Diagnostic Questions for the Code

When debugging Mobile Adapter communication, determine:

```text
What command was transmitted?

What exact bytes were transmitted?

Was 99 66 present?

Was payload length correct?

Was checksum correct?

What ACK was transmitted?

What ACK was received?

What response command was expected?

What response command was received?

Was the Game Boy still generating serial clocks while receiving?

Was D2 handled as a wait byte?

Was 4B used appropriately?

Did the adapter sleep?

Did the operation hit its timeout?

Was the payload binary-safe?
```

Use these questions to reason about runtime reports.

---

# Documentation

Keep documentation updated when protocol behavior changes.

Important subjects include:

```text
serial clock behavior
0x83 vs 0x81
CGB double speed
packet format
checksum
ACK
D2 / 4B
adapter IDs
Begin Session
NINTENDO payload
ISP flow
DNS
TCP
P2P
timeouts
```

Do not document speculative behavior as established fact.

---

# Copyright / Clean-Room Considerations

This repository may use reverse-engineered protocol information and open-source references.

Do not copy large blocks of code from Pokémon Crystal, Nintendo SDK reconstructions, or other projects without checking their licenses.

Prefer clean implementations based on documented behavior.

Do not include:

* Nintendo ROM data;
* Pokémon ROM data;
* copyrighted graphics;
* game scripts;
* copyrighted binaries.

This TestSuite should remain an independent homebrew diagnostic program.

---

# Definition of Done

A normal implementation task is complete when:

* requested functionality is implemented;
* no fake success paths were introduced;
* buffers are bounded;
* external waits have timeouts;
* protocol code uses explicit lengths;
* host tests pass when applicable;
* `make clean && make` succeeds when GBDK is available;
* the resulting ROM remains CGB-only;
* relevant documentation is updated;
* any remaining manual test requirement is explicitly stated.

The runtime behavior against the actual Mobile Adapter/libmobile environment is verified by the project owner after the compiled ROM is delivered.

---

# Final Response After Code Changes

After completing implementation work, summarize using approximately:

```text
Implemented
- ...

Protocol changes
- ...

Build
- make clean: PASS
- make: PASS
- ROM: build/...
- CGB header: 0xC0

Tests
- host tests: PASS / N/A
- runtime tests: MANUAL

Manual tests requested
- ...
```

If compilation fails because GBDK is not installed, say so explicitly and include the exact failed discovery/build command.

Do not report a successful build unless it actually completed successfully.
