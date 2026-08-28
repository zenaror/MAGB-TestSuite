/** Layer 1 -- GBC serial hardware transport.
 *
 * This module owns SB_REG/SC_REG and knows nothing about the Mobile
 * Adapter GB wire protocol (magic bytes, commands, checksums, ...).
 * It exists so the protocol layer never touches hardware registers
 * directly and so the timeout strategy lives in exactly one place.
 */
#ifndef SERIAL_HW_H
#define SERIAL_HW_H

#include <stdint.h>
#include <stdbool.h>

typedef enum {
    SERIAL_HW_OK = 0,
    SERIAL_HW_TIMEOUT
} serial_hw_result_t;

/* Bounded polling budget for a single SB/SC byte transfer.
 *
 * This is a plain decrementing loop counter, not a calibrated
 * microsecond timer: SDCC code generation and CGB single/double
 * speed mode both change how long one iteration actually takes.
 * The only property that matters here is that the value is finite,
 * so a disconnected/absent adapter can never hang the ROM inside a
 * single byte transfer. Higher-level, multi-second waits (dialing,
 * DNS, TCP, waiting for a P2P call, ...) are bounded separately by
 * the protocol layer using sys_time (see magb_session.c /
 * magb_network.c), which is a real ~60 Hz VBlank frame counter.
 */
#define SERIAL_HW_BYTE_TIMEOUT 60000U

/** Must be called once at startup.
 *
 * Verifies the console is a CGB (this TestSuite is CGB-only per
 * project requirements) and switches the CPU to double speed via
 * cpu_fast(). Never returns if the console is not a CGB -- it shows
 * a fatal platform error screen instead, because silently falling
 * back to DMG timings would produce a serial clock the real Mobile
 * Adapter GB / libmobile does not expect.
 */
void serial_hw_init(void);

/** Transfers one byte in each direction over SB/SC.
 *
 * Always drives the internal clock at CGB double speed
 * (SIOF_XFER_START | SIOF_CLOCK_INT | SIOF_SPEED_32X, i.e. 0x83) --
 * the Game Boy is always the clock master talking to the Mobile
 * Adapter, so there is no external-clock mode to support.
 *
 * On SERIAL_HW_TIMEOUT, *rx is left unmodified and the transfer is
 * aborted (see serial_abort()).
 */
serial_hw_result_t serial_transfer_byte(uint8_t tx, uint8_t *rx);

/** True while a transfer is in flight (SC_REG start bit still set). */
bool serial_is_busy(void);

/** Forces the transfer-start bit off. Used after a timeout so a
 * later transfer does not observe a stale in-progress transfer. */
void serial_abort(void);

/** Busy-waits for the given number of VBlanks using vsync().
 * Used for the ~100 ms post-wake delay (about 7 frames @ ~59.7 Hz). */
void serial_wait_vblanks(uint8_t frames);

/** Snapshot of the free-running ~60 Hz frame counter (sys_time).
 * Used by higher layers to build multi-second timeouts without
 * depending on any particular busy-loop timing. */
uint16_t serial_now(void);

/** Frames elapsed since `since`, correctly handling sys_time wraparound
 * (sys_time is a 16-bit unsigned VBlank counter). */
uint16_t serial_elapsed_frames(uint16_t since);

#endif /* SERIAL_HW_H */
