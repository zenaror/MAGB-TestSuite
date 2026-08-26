#include "serial_hw.h"

#include <gb/gb.h>
#include <gb/cgb.h>
#include <gb/hardware.h>
#include <gbdk/console.h>
#include <stdio.h>

static void fatal_not_cgb(void);

static void fatal_not_cgb(void)
{
    /* This is an intentional, permanent halt: it is not a wait on
     * external hardware (the Mobile Adapter), it is a refusal to run
     * on the wrong console. The GBC-only serial clock configuration
     * this TestSuite relies on does not apply to DMG/MGB. */
    cls();
    printf("\n FATAL PLATFORM ERROR\n\n"
             " THIS ROM REQUIRES A\n"
             " GAME BOY COLOR.\n\n"
             " CGB-ONLY MOBILE\n"
             " ADAPTER SERIAL MODE\n"
             " IS NOT AVAILABLE ON\n"
             " THIS CONSOLE.\n");
    while (1) {
        vsync();
    }
}

void serial_hw_init(void)
{
    if (_cpu != CGB_TYPE) {
        fatal_not_cgb();
    }
    cpu_fast();

    /* Unlike DMG, a CGB does NOT power on with a legible default
     * background palette -- BGP-equivalent palette 0 is left
     * undefined until explicitly set. Without this call, every
     * printf()/cls() screen in this ROM renders with an undefined
     * (observed: blank white, on both real hardware and BGB) palette
     * even though the tile data/map and CPU execution are otherwise
     * completely correct. set_default_palette() (gb/cgb.h) sets CGB
     * palette 0 to the same white/light-gray/dark-gray/black scheme
     * DMG uses by default. */
    set_default_palette();

    serial_abort();
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
