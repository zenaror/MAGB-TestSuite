#include "serial_hw.h"

#include <gb/gb.h>
#include <gb/cgb.h>
#include <gb/hardware.h>

bool serial_hw_init(void)
{
    /* Reports the wrong-console case instead of drawing it. This file
     * used to print a fatal screen here, which pulled <gbdk/console.h>
     * and <stdio.h> into the hardware layer -- the one layer a homebrew
     * author is most likely to copy wholesale, and the one that should
     * know nothing about how (or whether) the program has a screen.
     * The message now lives in the app layer (ui_fatal_not_cgb()). */
    if (_cpu != CGB_TYPE) {
        return false;
    }
    cpu_fast();

    serial_abort();
    return true;
}

serial_hw_result_t serial_transfer_byte(uint8_t tx, uint8_t *rx)
{
    uint16_t budget = SERIAL_HW_BYTE_TIMEOUT;

    SB_REG = tx;
    /* Two writes, not one: prime the clock-source/speed bits with the
     * start bit still clear, THEN set the start bit in a second write.
     * Confirmed against Pokémon Crystal's real, working Mobile Adapter
     * driver (lib/mobile/main.asm, every rSC write site) -- it never
     * writes the start bit and the speed/clock bits in the same byte.
     * A single combined write (the "0x83 in one go" this TestSuite
     * used originally) was confirmed via BGB to leave the adapter
     * emulation seeing only idle bytes forever, even though the exact
     * same byte sequence, fed directly into the real libmobile source
     * off-hardware, parses and ACKs correctly -- i.e. the packet
     * content was always right, only this low-level register-write
     * sequencing was wrong. */
    SC_REG = SIOF_CLOCK_INT | SIOF_SPEED_32X;
    SC_REG = SIOF_XFER_START | SIOF_CLOCK_INT | SIOF_SPEED_32X;

    while (SC_REG & SIOF_XFER_START) {
        if (--budget == 0U) {
            serial_abort();
            return SERIAL_HW_TIMEOUT;
        }
    }

    *rx = SB_REG;
    return SERIAL_HW_OK;
}

bool serial_is_busy(void)
{
    return (SC_REG & SIOF_XFER_START) != 0U;
}

void serial_abort(void)
{
    SC_REG = 0U;
}

void serial_wait_vblanks(uint8_t frames)
{
    uint8_t i;
    for (i = 0U; i < frames; i++) {
        vsync();
    }
}

uint16_t serial_now(void)
{
    return sys_time;
}

uint16_t serial_elapsed_frames(uint16_t since)
{
    /* sys_time is a free-running 16-bit counter; unsigned subtraction
     * yields the correct elapsed value across wraparound. */
    return (uint16_t)(sys_time - since);
}
