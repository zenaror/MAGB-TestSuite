/* Host tests for the wire-format number formatting.
 *
 * These exist because an untested formatter put a malformed HTTP header
 * on the wire: "Content-Length:" with no value, because SDCC's sprintf
 * dropped the conversions. See include/magb_fmt.h. The cases below are
 * the ones that would have caught it, plus the leading-zero cases that
 * only bite for a minority of checksum values. */
#include "magb_fmt.h"

#include <stdio.h>
#include <string.h>

static int g_failures;

static void check_str(const char *what, const char *got, const char *want)
{
    if (strcmp(got, want) == 0) {
        printf("[PASS] %s -> \"%s\"\n", what, got);
    } else {
        printf("[FAIL] %s -> \"%s\", expected \"%s\"\n", what, got, want);
        g_failures++;
    }
}

static void t_u16(uint16_t v, const char *want)
{
    char buf[32];
    char label[64];
    *magb_fmt_u16(buf, v) = '\0';
    sprintf(label, "u16(%u)", (unsigned)v);
    check_str(label, buf, want);
}

static void t_hex16(uint16_t v, const char *want)
{
    char buf[32];
    char label[64];
    *magb_fmt_hex16(buf, v) = '\0';
    sprintf(label, "hex16(0x%04X)", (unsigned)v);
    check_str(label, buf, want);
}

int main(void)
{
    char buf[128];
    char *p;

    /* Content-Length values this ROM actually sends. */
    t_u16(128U, "128");
    t_u16(8192U, "8192");
    /* Zero must be a digit, not nothing -- an empty Content-Length is
     * exactly the failure this module was written for. */
    t_u16(0U, "0");
    t_u16(1U, "1");
    t_u16(10U, "10");
    t_u16(65535U, "65535");

    /* The two real checksums, and the padding cases. */
    t_hex16(0x1FC0U, "1FC0");
    t_hex16(0xF000U, "F000");
    /* A checksum with a zero high nibble: "F00" here would be rejected
     * by REON's %04X comparison, and one value in sixteen looks like
     * this. */
    t_hex16(0x0F00U, "0F00");
    t_hex16(0x0000U, "0000");
    t_hex16(0x000AU, "000A");
    t_hex16(0xABCDU, "ABCD");

    /* A full header tail, chained the way the tests build one. The
     * length matters as much as the content: the bug that started this
     * was a request seven bytes shorter than intended. */
    p = buf;
    p = magb_fmt_str(p, "Content-Length: ");
    p = magb_fmt_u16(p, 128U);
    p = magb_fmt_str(p, "\r\nX-Test-Checksum: ");
    p = magb_fmt_hex16(p, 0x1FC0U);
    p = magb_fmt_str(p, "\r\n\r\n");
    *p = '\0';
    check_str("chained header tail", buf,
              "Content-Length: 128\r\nX-Test-Checksum: 1FC0\r\n\r\n");
    if ((size_t)(p - buf) != strlen(buf)) {
        printf("[FAIL] returned cursor disagrees with strlen\n");
        g_failures++;
    } else {
        printf("[PASS] returned cursor == strlen (%u)\n", (unsigned)strlen(buf));
    }

    if (g_failures != 0) {
        printf("\n%d format test(s) failed.\n", g_failures);
        return 1;
    }
    printf("\nAll format tests passed.\n");
    return 0;
}
