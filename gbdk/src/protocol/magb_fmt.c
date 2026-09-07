#include "magb_fmt.h"

static const char kHexDigits[] = "0123456789ABCDEF";

char *magb_fmt_str(char *out, const char *s)
{
    while (*s != '\0') {
        *out++ = *s++;
    }
    return out;
}

char *magb_fmt_u16(char *out, uint16_t v)
{
    /* Written into a scratch buffer least-significant digit first, then
     * reversed out. 65535 is five digits, so five is the whole range;
     * the do/while is what makes 0 print as "0" rather than nothing,
     * which is the exact shape of bug this module exists to prevent. */
    char digits[5];
    uint8_t n = 0U;

    do {
        digits[n++] = (char)('0' + (v % 10U));
        v = (uint16_t)(v / 10U);
    } while (v != 0U);

    while (n != 0U) {
        *out++ = digits[--n];
    }
    return out;
}

char *magb_fmt_hex8(char *out, uint8_t v)
{
    *out++ = kHexDigits[(v >> 4) & 0x0FU];
    *out++ = kHexDigits[v & 0x0FU];
    return out;
}

char *magb_fmt_hex16(char *out, uint16_t v)
{
    out = magb_fmt_hex8(out, (uint8_t)(v >> 8));
    return magb_fmt_hex8(out, (uint8_t)(v & 0xFFU));
}
