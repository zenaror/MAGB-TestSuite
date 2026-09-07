#!/usr/bin/env python3
"""Fails if any banked function is reached by a direct CALL from outside
its own bank.

This is the third of `make check-banking`'s assertions, and the one that
catches a BANKED annotation mismatch. If a function is defined `BANKED`
but its prototype is not (or vice versa), SDCC compiles and links
cleanly and emits an ordinary `call <addr>` instead of routing through
___sdcc_bcall_ehl. At runtime the caller then jumps to that address with
the WRONG bank mapped and executes whatever happens to live there --
usually ROM filler, which on SM83 is 0xFF, which decodes as `rst 38` and
parks the CPU at PC=0x0038. That is a silent build and a dead ROM, and
it is exactly the failure the Makefile's own banking note describes.

Usage: check_far_calls.py <rom.gbc> <rom.noi>

The .noi is GBDK's NoICE symbol file (produced by -debug); banked symbol
addresses appear there as 0xBBAAAA, bank in the high half.
"""
import re
import sys

# The set of banked functions is discovered from the symbol file rather
# than listed here on purpose. A hardcoded list only ever protects the
# functions someone remembered to add to it, and the realistic mistake
# is adding a NEW function to the banked module and forgetting BANKED on
# both its prototype and its definition -- SDCC says nothing when the
# two agree, so only the emitted call reveals it. Deriving the list from
# the ROM covers whatever is actually in a banked bank today.
#
# (The opposite slip -- BANKED on one side but not the other -- is
# already caught by SDCC itself, "error 98: conflict with previous
# declaration".)
BANK_SIZE = 0x4000
CALL_OPCODE = 0xCD


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: check_far_calls.py <rom.gbc> <rom.noi>")
    rom_path, noi_path = sys.argv[1], sys.argv[2]

    with open(rom_path, "rb") as f:
        rom = f.read()
    with open(noi_path, encoding="utf-8", errors="replace") as f:
        noi = f.read()

    syms = {}
    for m in re.finditer(r"^DEF (\S+) 0x([0-9A-Fa-f]+)$", noi, re.M):
        syms[m.group(1)] = int(m.group(2), 16)

    # C function symbols only: SDCC also emits scope/line-number entries
    # (G$/XG$/C$/A$...) that share an address with the real symbol and
    # would just duplicate every finding.
    banked = sorted(
        (name, addr)
        for name, addr in syms.items()
        if (addr >> 16) >= 1 and name.startswith("_") and "$" not in name
    )

    if not banked:
        print("check-banking: FAIL - no banked functions found in %s;" % noi_path)
        print("  either banking regressed to a single bank, or the .noi is stale.")
        return 1

    failures = []
    for name, addr in banked:
        bank, offset = addr >> 16, addr & 0xFFFF

        # A direct call is the 3 bytes `CD <lo> <hi>` of the function's
        # in-window address. Occurrences inside the function's own bank
        # are fine: same-bank calls need no trampoline.
        pattern = bytes([CALL_OPCODE, offset & 0xFF, (offset >> 8) & 0xFF])
        bank_start = bank * BANK_SIZE
        bank_end = bank_start + BANK_SIZE

        hits = []
        i = rom.find(pattern)
        while i >= 0:
            if not (bank_start <= i < bank_end):
                hits.append(i)
            i = rom.find(pattern, i + 1)

        if hits:
            failures.append(
                "%s (bank %d, 0x%04X): direct CALL from outside its bank at %s"
                % (name, bank, offset, ", ".join("0x%05X" % h for h in hits))
            )

    if failures:
        print("check-banking: FAIL - banked functions reached without the trampoline:")
        for line in failures:
            print("  " + line)
        print("  A BANKED mismatch between prototype and definition does this.")
        print("  See include/gb00_auth.h and the Makefile's banking note.")
        return 1

    print(
        "check-banking: %d banked functions (%s), all reached via the trampoline OK"
        % (len(banked), ", ".join(n for n, _ in banked))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
