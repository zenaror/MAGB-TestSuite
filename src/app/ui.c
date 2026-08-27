#include "ui.h"
#include "magb_commands.h"
#include "magb_config.h"
#include "sound.h"

#include <gb/gb.h>
#include <gbdk/console.h>
#include <stdio.h>
#include <string.h>

static const char *const kMenuLabels[UI_MENU_COUNT] = {
    "ADAPTER / SESSION",
    "READ CONFIG",
    "ISP PASSWORD",
    "ISP / HTTP",
    "P2P CALLER",
    "P2P LISTENER"
};

void ui_init(void)
{
    cls();
}

bool ui_check_cancel(void)
{
    return (joypad() & J_B) != 0U;
}

/** Blocks for one newly-pressed key and returns it (edge-triggered). */
static uint8_t wait_key_edge(void)
{
    uint8_t prev = joypad();
    uint8_t cur;
    uint8_t pressed;
    for (;;) {
        vsync();
        cur = joypad();
        pressed = (uint8_t)(cur & (uint8_t)~prev);
        prev = cur;
        if (pressed != 0U) {
            return pressed;
        }
    }
}

bool ui_prompt_continue(void)
{
    for (;;) {
        uint8_t pressed = wait_key_edge();
        if (pressed & J_A) return true;
        if (pressed & J_B) return false;
    }
}

ui_menu_item_t ui_main_menu(bool *want_trace)
{
    static uint8_t sel = 0U;
    uint8_t i;

    *want_trace = false;

    for (;;) {
        uint8_t pressed;

        cls();
        /* Identifies exactly which build is running, so a stale ROM/
         * process can't be mistaken for a fresh one -- this bit us
         * during hardware/BGB testing. Local builds show __TIME__ (the
         * compiler-provided compile time, already a quoted string
         * literal); CI builds override BUILD_VERSION_STR to the 7-char
         * commit hash instead (see .github/workflows/build-release.yml),
         * since compile time alone doesn't identify which commit a
         * CI-built ROM came from. BUILD_VERSION_STR arrives as a bare,
         * unquoted token (e.g. -DBUILD_VERSION_STR=abc1234), not a
         * ready-made string -- this GBDK/SDCC lcc strips a quoted -D
         * value's quotes entirely (confirmed: -DFOO=\"bar\" defines FOO
         * as the bare token bar, not the string "bar", breaking string
         * concatenation), so the stringizing operator below builds the
         * actual string literal in C instead of relying on the shell/
         * Makefile to pass one through intact. */
#ifdef BUILD_VERSION_STR
#define BUILD_VERSION_STRINGIFY_(x) #x
#define BUILD_VERSION_STRINGIFY(x) BUILD_VERSION_STRINGIFY_(x)
#define BUILD_VERSION_TEXT BUILD_VERSION_STRINGIFY(BUILD_VERSION_STR)
#else
#define BUILD_VERSION_TEXT __TIME__
#endif
        printf("MOBILE ADAPTER GB\nTESTSUITE " BUILD_VERSION_TEXT "\n");
        for (i = 0U; i < UI_MENU_COUNT; i++) {
            gotoxy(0U, (uint8_t)(4U + i));
            /* Deliberately two calls, not printf("%c%s\n", ...): GBDK's
             * printf mis-renders when a %c argument is immediately
             * followed by a %s argument in the same call (confirmed
             * both on real hardware and in emulation -- see
             * docs/protocol-notes.md). */
            putchar((i == sel) ? '>' : ' ');
            printf("%s\n", kMenuLabels[i]);
        }
        gotoxy(0U, 16U);
        printf("A:RUN SELECT:TRACE");

        pressed = wait_key_edge();
        if (pressed & J_UP) {
            sel = (sel == 0U) ? (uint8_t)(UI_MENU_COUNT - 1U) : (uint8_t)(sel - 1U);
            sound_select();
        } else if (pressed & J_DOWN) {
            sel = (uint8_t)((sel + 1U) % UI_MENU_COUNT);
            sound_select();
        } else if (pressed & J_A) {
            sound_select();
            return (ui_menu_item_t)sel;
        } else if (pressed & J_SELECT) {
            sound_select();
            *want_trace = true;
            return (ui_menu_item_t)sel;
        }
    }
}

#define SUBMENU_MAX_VISIBLE 8U

uint8_t ui_select_submenu(const char *title, const char *const *labels, uint8_t count)
{
    uint8_t sel = 0U;
    uint8_t i;

    for (;;) {
        uint8_t pressed;

        cls();
        printf("%s\n\n", title);
        for (i = 0U; i < count && i < SUBMENU_MAX_VISIBLE; i++) {
            gotoxy(0U, (uint8_t)(2U + i));
            putchar((i == sel) ? '>' : ' ');
            printf("%s\n", labels[i]);
        }
        gotoxy(0U, 16U);
        printf("A:RUN B:BACK");

        pressed = wait_key_edge();
        if (pressed & J_UP) {
            sel = (sel == 0U) ? (uint8_t)(count - 1U) : (uint8_t)(sel - 1U);
            sound_select();
        } else if (pressed & J_DOWN) {
            sel = (uint8_t)((sel + 1U) % count);
            sound_select();
        } else if (pressed & J_A) {
            sound_select();
            return sel;
        } else if (pressed & J_B) {
            sound_select();
            return count;
        }
    }
}

const char *ui_result_str(magb_result_t r)
{
    switch (r) {
    case MAGB_OK:                     return "OK";
    case MAGB_ERR_TIMEOUT:            return "TIMEOUT";
    case MAGB_ERR_NOT_CGB:            return "NOT A CGB";
    case MAGB_ERR_ADAPTER_NOT_FOUND:  return "ADAPTER NOT FOUND";
    case MAGB_ERR_BAD_MAGIC:          return "BAD MAGIC";
    case MAGB_ERR_BAD_LENGTH:         return "BAD LENGTH";
    case MAGB_ERR_PAYLOAD_TOO_LARGE:  return "PAYLOAD TOO LARGE";
    case MAGB_ERR_BAD_CHECKSUM:       return "BAD CHECKSUM";
    case MAGB_ERR_BAD_ACK:            return "BAD ACK";
    case MAGB_ERR_BAD_DEVICE_ID:      return "BAD DEVICE ID";
    case MAGB_ERR_UNEXPECTED_COMMAND: return "UNEXPECTED CMD";
    case MAGB_ERR_REMOTE_UNSUPPORTED: return "REMOTE: UNSUPPORTED";
    case MAGB_ERR_REMOTE_CHECKSUM:    return "REMOTE: CHECKSUM";
    case MAGB_ERR_REMOTE_INTERNAL:    return "REMOTE: INTERNAL";
    case MAGB_ERR_REMOTE_STATUS:      return "ADAPTER ERROR STATUS";
    case MAGB_ERR_SESSION:            return "SESSION ERROR";
    case MAGB_ERR_PHONE:              return "PHONE ERROR";
    case MAGB_ERR_ISP:                return "ISP ERROR";
    case MAGB_ERR_DNS:                return "DNS ERROR";
    case MAGB_ERR_TCP:                return "TCP ERROR";
    case MAGB_ERR_P2P:                return "P2P ERROR";
    case MAGB_ERR_CANCELLED:          return "CANCELLED";
    default:                          return "UNKNOWN ERROR";
    }
}

void ui_show_result(const char *title, const test_result_t *result)
{
    if (result->passed) {
        sound_success();
    } else {
        sound_error();
    }

    cls();
    printf("%s\n\n", title);
    printf("RESULT: %s\n\n", result->passed ? "PASS" : "FAIL");
    if (result->detail[0][0] != '\0') {
        printf("%s\n", result->detail[0]);
    }
    if (result->detail[1][0] != '\0') {
        printf("%s\n", result->detail[1]);
    }
    if (result->official_code[0] != '\0') {
        /* The official Nintendo Mobile Adapter error code for this
         * situation, e.g. "24-000" -- see docs/protocol-notes.md. */
        printf("CODE: %s\n", result->official_code);
    }
    if (!result->passed) {
        printf("\n%s\n", ui_result_str(result->result));
    }
    gotoxy(0U, 16U);
    printf("A/B: MENU");
    (void)ui_prompt_continue();
}

static uint8_t trace_physical_index(const magb_context_t *ctx, uint16_t logical_index)
{
    uint16_t oldest_physical = (ctx->trace_count < MAGB_TRACE_LEN) ? 0U : ctx->trace_head;
    return (uint8_t)((oldest_physical + logical_index) % MAGB_TRACE_LEN);
}

#define TRACE_SHOWN_PAIRS 14U

void ui_show_trace(const magb_context_t *ctx)
{
    uint16_t total_pairs = ctx->trace_count / 2U;
    uint16_t start_pair = (total_pairs > TRACE_SHOWN_PAIRS) ? (total_pairs - TRACE_SHOWN_PAIRS) : 0U;
    uint16_t i;

    cls();
    printf("PROTOCOL TRACE\n\n");

    if (ctx->trace_count == 0U) {
        printf("(EMPTY)\n");
    } else {
        for (i = start_pair; i < total_pairs; i++) {
            uint8_t idx_tx = trace_physical_index(ctx, (uint16_t)(i * 2U));
            uint8_t idx_rx = trace_physical_index(ctx, (uint16_t)(i * 2U + 1U));
            /* %hx is GBDK printf's byte-sized hex conversion (always
             * exactly 2 digits) -- GBDK's printf has no %02x/width
             * support, see include/stdio.h's documented format list. */
            printf("TX %hx RX %hx\n", (unsigned char)ctx->trace[idx_tx].value,
                   (unsigned char)ctx->trace[idx_rx].value);
        }
    }

    gotoxy(0U, 16U);
    printf("A/B: MENU");
    (void)ui_prompt_continue();
}

static void print_ascii_field(const uint8_t *bytes, uint8_t len)
{
    uint8_t i;
    for (i = 0U; i < len; i++) {
        char c = (char)bytes[i];
        if (c < 0x20 || c > 0x7E) {
            c = '.';
        }
        putchar(c);
    }
    putchar('\n');
}

/* Field offsets live in magb_network.h (MAGB_CONFIG_OFF_*) -- shared
 * with test_runner.c's email tests, which read the same fields to
 * find the adapter's configured email/SMTP/POP servers. */

#define CONFIG_PAGE_COUNT 3U

/* Draws one page of the config screen. Every line is placed with an
 * explicit gotoxy() rather than relying on cumulative cursor position
 * after each printf/print_ascii_field call -- a field that happens to
 * land exactly on the 20-column boundary (e.g. a 10-char "LOGIN ID: "
 * prefix + a 10-char login, or a field printed via print_ascii_field
 * at exactly the field width) was observed on real BGB to sometimes
 * leave a stray blank row before the next line, which then pushed
 * later content down into the fixed A/B prompt row and got overwritten
 * by it. Explicit positioning makes each line's row deterministic
 * regardless of that. Splitting into pages (session/network, mail,
 * ISP dial slot) was requested after the same screenshot showed the
 * single-screen version simply didn't fit in 18 rows. */
static void draw_config_page(const uint8_t config[MAGB_CONFIG_SIZE], uint8_t page)
{
    /* Both pre-computed into plain locals, then passed to printf() as
     * bare variables -- confirmed via isolated GBDK/SDCC tests (real
     * BGB screenshot showed "769/0"/"770/256" instead of "1/3"/"2/3")
     * that this printf's %u rendering breaks specifically when handed
     * an inline cast-of-an-expression argument like
     * "(uint8_t)(page + 1U)" directly; a plain already-computed
     * variable works fine. Also deliberately three separate one-
     * specifier printf() calls, not printf("%u/%u", ...), which
     * produces the same kind of garbage independent of the above. The
     * title itself was also one character over the 20-column screen
     * width ("ADAPTER CONFIG (0x19)" is 21 chars), which combined with
     * the old single gotoxy(15,0) overwrite to produce the corrupted
     * first two rows. Dropped "(0x19)" (a command-ID detail with no
     * space left on the same row) to fit. */
    uint8_t page_num = (uint8_t)(page + 1U);
    uint8_t page_count = CONFIG_PAGE_COUNT;

    cls();
    printf("ADAPTER CONFIG");
    gotoxy(15U, 0U);
    printf("%u", page_num);
    gotoxy(16U, 0U);
    printf("/");
    gotoxy(17U, 0U);
    printf("%u", page_count);

    if (page == 0U) {
        uint8_t reg_state = config[MAGB_CONFIG_OFF_REG_STATE];
        gotoxy(0U, 2U);
        /* Two putchar() calls, not "(%c%c)" in the printf above: this
         * GBDK/SDCC printf drops the second %c (confirmed via an
         * isolated test -- "(M )" instead of "(MA)"), the same class of
         * bug as the %u one described above, just a different
         * specifier. Matches ui_main_menu()'s existing "%c immediately
         * followed by %s" workaround for the same underlying class of
         * printf bug. */
        printf("HDR: %hx %hx (", (unsigned char)config[MAGB_CONFIG_OFF_MAGIC],
               (unsigned char)config[MAGB_CONFIG_OFF_MAGIC + 1U]);
        putchar(config[MAGB_CONFIG_OFF_MAGIC]);
        putchar(config[MAGB_CONFIG_OFF_MAGIC + 1U]);
        printf(")");
        gotoxy(0U, 3U);
        printf("REG STATE: %hx ", (unsigned char)reg_state);
        /* Both documented values (0x01 "in progress", 0x81 "complete")
         * have bit 0 set -- bit 7 is what actually distinguishes them
         * (Dan Docs' "Configuration Data" section; confirmed against a
         * real captured config.bin showing 0x01, not 0x81, before this
         * fix -- see docs/protocol-notes.md). */
        printf("%s", (reg_state == MAGB_REG_STATE_COMPLETE) ? "(REG)" :
                      (reg_state == MAGB_REG_STATE_PENDING) ? "(PENDING)" : "(NONE)");
        gotoxy(0U, 4U);
        printf("DNS1 %u.%u.%u.%u",
               config[MAGB_CONFIG_OFF_DNS1], config[MAGB_CONFIG_OFF_DNS1 + 1U],
               config[MAGB_CONFIG_OFF_DNS1 + 2U], config[MAGB_CONFIG_OFF_DNS1 + 3U]);
        gotoxy(0U, 5U);
        printf("DNS2 %u.%u.%u.%u",
               config[MAGB_CONFIG_OFF_DNS2], config[MAGB_CONFIG_OFF_DNS2 + 1U],
               config[MAGB_CONFIG_OFF_DNS2 + 2U], config[MAGB_CONFIG_OFF_DNS2 + 3U]);
        gotoxy(0U, 7U);
        printf("LOGIN ID:");
        gotoxy(0U, 8U);
        print_ascii_field(&config[MAGB_CONFIG_OFF_LOGIN_ID], MAGB_CONFIG_LOGIN_ID_LEN);
        gotoxy(0U, 10U);
        printf("CHECKSUM: %s", magb_config_checksum_ok(config) ? "OK" : "BAD");
    } else if (page == 1U) {
        gotoxy(0U, 2U);
        printf("EMAIL:");
        gotoxy(0U, 3U);
        print_ascii_field(&config[MAGB_CONFIG_OFF_EMAIL], 20U);
        gotoxy(0U, 4U);
        print_ascii_field(&config[MAGB_CONFIG_OFF_EMAIL + 20U], MAGB_CONFIG_EMAIL_LEN - 20U);
        gotoxy(0U, 6U);
        printf("SMTP:");
        gotoxy(0U, 7U);
        print_ascii_field(&config[MAGB_CONFIG_OFF_SMTP], MAGB_CONFIG_SMTP_LEN);
        gotoxy(0U, 9U);
        printf("POP:");
        gotoxy(0U, 10U);
        print_ascii_field(&config[MAGB_CONFIG_OFF_POP], MAGB_CONFIG_POP_LEN);
    } else {
        /* Configuration Slot 1 -- the ISP dial string Mobile Trainer
         * actually configured. This is what Dial (0x12) sends now
         * (magb_isp_identity_t in test_runner.c), not a compile-time
         * TEST_ISP_PHONE default -- shown here so the two can be
         * compared directly. */
        char phone[17];
        (void)magb_config_decode_phone(&config[MAGB_CONFIG_OFF_SLOT1], phone, sizeof(phone));
        gotoxy(0U, 2U);
        printf("SLOT 1 PHONE:");
        gotoxy(0U, 3U);
        if (phone[0] != '\0') {
            printf("%s", phone);
        } else {
            printf("(EMPTY)");
        }
        gotoxy(0U, 5U);
        printf("SLOT 1 ID:");
        gotoxy(0U, 6U);
        print_ascii_field(&config[MAGB_CONFIG_OFF_SLOT1 + MAGB_CONFIG_SLOT_PHONE_LEN],
                           MAGB_CONFIG_SLOT_ID_LEN);
    }

    gotoxy(0U, 16U);
    printf("LEFT/RIGHT: PAGE");
    gotoxy(0U, 17U);
    printf("A/B: MENU");
}

void ui_show_config(const uint8_t config[MAGB_CONFIG_SIZE])
{
    uint8_t page = 0U;

    for (;;) {
        uint8_t pressed;

        draw_config_page(config, page);
        pressed = wait_key_edge();
        if (pressed & J_LEFT) {
            page = (page == 0U) ? (uint8_t)(CONFIG_PAGE_COUNT - 1U) : (uint8_t)(page - 1U);
        } else if (pressed & J_RIGHT) {
            page = (uint8_t)((page + 1U) % CONFIG_PAGE_COUNT);
        } else if (pressed & (J_A | J_B)) {
            return;
        }
    }
}

/* Like wait_key_edge(), but a D-pad direction held past REPEAT_DELAY
 * frames also fires a synthetic repeat event every REPEAT_INTERVAL
 * frames after that, so holding a direction moves the cursor/cycles a
 * character faster than one press per step. Still blocks internally on
 * vsync() and only returns once per meaningful event (a fresh edge or a
 * repeat tick) -- never once per raw frame.
 *
 * That distinction matters here: an earlier attempt at this returned
 * once per *frame* regardless of input (a single vsync() + immediate
 * return), which made the editor's for(;;) loop call cls()/printf()
 * continuously at 60Hz instead of only on actual key events. Sampling
 * the CPU's PC during a PyBoy investigation at that point would almost
 * always land inside GBDK's own console/font drawing code -- which is
 * exactly what was seen and (incorrectly) diagnosed as the ROM being
 * stuck in an infinite loop. It wasn't stuck; it was just redrawing the
 * whole screen 60 times a second forever, since nothing in that version
 * ever blocked waiting for a new input. Blocking here restores the same
 * call cadence wait_key_edge() has (one call = one visible change) while
 * still supporting repeat via held_frames[] persisting across calls. See
 * [[magb-input-hang-gbdk]] for the fuller writeup of that investigation. */
#define REPEAT_DELAY    18U /* ~0.3s held before repeat starts */
#define REPEAT_INTERVAL 6U  /* then repeats roughly 10x/sec */

static uint8_t s_repeat_prev;
static uint8_t s_repeat_held[4];

/** Must be called once right before an editor's input loop starts, so a
 * key already held from selecting the menu entry that opened the editor
 * isn't misread as a fresh edge on the very first poll. */
static void wait_key_repeat_reset(void)
{
    s_repeat_prev = joypad();
    s_repeat_held[0] = 0U;
    s_repeat_held[1] = 0U;
    s_repeat_held[2] = 0U;
    s_repeat_held[3] = 0U;
}

static uint8_t wait_key_repeat(void)
{
    static const uint8_t kDpadMasks[4] = { J_UP, J_DOWN, J_LEFT, J_RIGHT };

    for (;;) {
        uint8_t cur;
        uint8_t edge;
        uint8_t fired;
        uint8_t i;

        vsync();
        cur = joypad();
        edge = (uint8_t)(cur & (uint8_t)~s_repeat_prev);
        s_repeat_prev = cur;

        fired = (uint8_t)(edge & (uint8_t)(J_A | J_B));

        for (i = 0U; i < 4U; i++) {
            if (cur & kDpadMasks[i]) {
                if (s_repeat_held[i] == 0U ||
                    (s_repeat_held[i] >= REPEAT_DELAY &&
                     (uint8_t)((s_repeat_held[i] - REPEAT_DELAY) % REPEAT_INTERVAL) == 0U)) {
                    fired = (uint8_t)(fired | kDpadMasks[i]);
                }
                if (s_repeat_held[i] < 0xFFU) {
                    s_repeat_held[i]++;
                }
            } else {
                s_repeat_held[i] = 0U;
            }
        }

        if (fired != 0U) {
            return fired;
        }
    }
}

bool ui_edit_number(char *buf, const char *label)
{
    char work[13];
    uint8_t cursor = 0U;
    uint8_t i;
    uint8_t existing_len = (uint8_t)strlen(buf);

    for (i = 0U; i < 12U; i++) {
        work[i] = (i < existing_len) ? buf[i] : '0';
    }
    work[12] = '\0';

    wait_key_repeat_reset();
    for (;;) {
        uint8_t pressed;

        cls();
        printf("%s\n\n", label);
        gotoxy(0U, 3U);
        printf("%s\n", work);
        gotoxy(cursor, 4U);
        printf("^");
        gotoxy(0U, 7U);
        printf("LEFT/RIGHT: MOVE\nUP/DOWN: DIGIT\nA: CONFIRM\nB: CANCEL\n(HOLD: FASTER)");

        pressed = wait_key_repeat();
        if (pressed != 0U) {
            sound_select();
        }
        if (pressed & J_LEFT) {
            cursor = (cursor == 0U) ? 11U : (uint8_t)(cursor - 1U);
        } else if (pressed & J_RIGHT) {
            cursor = (uint8_t)((cursor + 1U) % 12U);
        } else if (pressed & J_UP) {
            work[cursor] = (char)('0' + (uint8_t)((work[cursor] - '0' + 1) % 10));
        } else if (pressed & J_DOWN) {
            work[cursor] = (char)('0' + (uint8_t)((work[cursor] - '0' + 9) % 10));
        } else if (pressed & J_A) {
            strcpy(buf, work);
            return true;
        } else if (pressed & J_B) {
            return false;
        }
    }
}

/* Space first (the "blank slot" sentinel used to pad unused
 * positions), then lower-case a-z, upper-case A-Z, then 0-9 -- ordered
 * this way (lower before upper before digits) per the project owner's
 * request, since most real account passwords here are lower-case.
 * A full 2D on-screen keyboard was also tried here per the project
 * owner's request, but reproducibly hung the ROM at runtime and was
 * reverted; see [[magb-input-hang-gbdk]]. */
static const char kTextCharset[] =
    " abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
#define TEXT_CHARSET_LEN ((uint8_t)(sizeof(kTextCharset) - 1U))

static uint8_t text_charset_index(char c)
{
    uint8_t i;
    for (i = 0U; i < TEXT_CHARSET_LEN; i++) {
        if (kTextCharset[i] == c) {
            return i;
        }
    }
    return 0U; /* not found (shouldn't happen for our own buffers) -> space */
}

bool ui_edit_text(char *buf, uint8_t buf_cap, const char *label)
{
    char work[UI_EDIT_TEXT_MAX_LEN + 1U];
    uint8_t max_len = (uint8_t)(buf_cap - 1U);
    uint8_t existing_len = (uint8_t)strlen(buf);
    uint8_t cursor = 0U;
    uint8_t i;
    uint8_t n;

    if (max_len > UI_EDIT_TEXT_MAX_LEN) {
        max_len = UI_EDIT_TEXT_MAX_LEN;
    }
    for (i = 0U; i < max_len; i++) {
        work[i] = (i < existing_len) ? buf[i] : ' ';
    }
    work[max_len] = '\0';

    wait_key_repeat_reset();
    for (;;) {
        uint8_t pressed;

        cls();
        printf("%s\n\n", label);
        gotoxy(0U, 3U);
        printf("%s\n", work);
        gotoxy(cursor, 4U);
        printf("^");
        gotoxy(0U, 7U);
        printf("LEFT/RIGHT: MOVE\nUP/DOWN: CHAR\nA: CONFIRM\nB: CANCEL\n(HOLD: FASTER)");

        pressed = wait_key_repeat();
        if (pressed != 0U) {
            sound_select();
        }
        if (pressed & J_LEFT) {
            cursor = (cursor == 0U) ? (uint8_t)(max_len - 1U) : (uint8_t)(cursor - 1U);
        } else if (pressed & J_RIGHT) {
            cursor = (uint8_t)((cursor + 1U) % max_len);
        } else if (pressed & J_UP) {
            uint8_t idx = (uint8_t)((text_charset_index(work[cursor]) + 1U) % TEXT_CHARSET_LEN);
            work[cursor] = kTextCharset[idx];
        } else if (pressed & J_DOWN) {
            uint8_t idx = text_charset_index(work[cursor]);
            idx = (idx == 0U) ? (uint8_t)(TEXT_CHARSET_LEN - 1U) : (uint8_t)(idx - 1U);
            work[cursor] = kTextCharset[idx];
        } else if (pressed & J_A) {
            n = max_len;
            while (n > 0U && work[n - 1U] == ' ') {
                n--;
            }
            memcpy(buf, work, n);
            buf[n] = '\0';
            return true;
        } else if (pressed & J_B) {
            return false;
        }
    }
}
