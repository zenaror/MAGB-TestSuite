#include "ui.h"
#include "magb_commands.h"

#include <gb/gb.h>
#include <gbdk/console.h>
#include <stdio.h>
#include <string.h>

static const char *const kMenuLabels[UI_MENU_COUNT] = {
    "ADAPTER / SESSION",
    "READ CONFIG",
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
        /* __TIME__ is a standard compiler-provided macro (the time
         * this file was compiled). Shown so it's possible to tell,
         * just by looking at the running ROM, whether it's actually
         * the build you just made -- this bit us during hardware/BGB
         * testing, where a stale ROM/process was easy to mistake for
         * a fresh one. */
        printf("MOBILE ADAPTER GB\nTESTSUITE " __TIME__ "\n");
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
        } else if (pressed & J_DOWN) {
            sel = (uint8_t)((sel + 1U) % UI_MENU_COUNT);
        } else if (pressed & J_A) {
            return (ui_menu_item_t)sel;
        } else if (pressed & J_SELECT) {
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
        } else if (pressed & J_DOWN) {
            sel = (uint8_t)((sel + 1U) % count);
        } else if (pressed & J_A) {
            return sel;
        } else if (pressed & J_B) {
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

#define CONFIG_PAGE_COUNT 2U

/* Draws one page of the config screen. Every line is placed with an
 * explicit gotoxy() rather than relying on cumulative cursor position
 * after each printf/print_ascii_field call -- a field that happens to
 * land exactly on the 20-column boundary (e.g. a 10-char "LOGIN ID: "
 * prefix + a 10-char login, or a field printed via print_ascii_field
 * at exactly the field width) was observed on real BGB to sometimes
 * leave a stray blank row before the next line, which then pushed
 * later content down into the fixed A/B prompt row and got overwritten
 * by it. Explicit positioning makes each line's row deterministic
 * regardless of that. Splitting into two pages (session/network vs.
 * mail fields) was requested after the same screenshot showed the
 * single-screen version simply didn't fit in 18 rows. */
static void draw_config_page(const uint8_t config[MAGB_CONFIG_SIZE], uint8_t page)
{
    cls();
    printf("ADAPTER CONFIG (0x19)");
    gotoxy(15U, 0U);
    printf("%u/%u", (uint8_t)(page + 1U), CONFIG_PAGE_COUNT);

    if (page == 0U) {
        gotoxy(0U, 2U);
        printf("MAGIC: %hx %hx", (unsigned char)config[MAGB_CONFIG_OFF_MAGIC],
               (unsigned char)config[MAGB_CONFIG_OFF_MAGIC + 1U]);
        gotoxy(0U, 3U);
        printf("REG STATE: %hx ", (unsigned char)config[MAGB_CONFIG_OFF_REG_STATE]);
        printf("%s", (config[MAGB_CONFIG_OFF_REG_STATE] & 0x01U) ? "(REG)" : "(NONE)");
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
    } else {
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

    for (;;) {
        uint8_t pressed;

        cls();
        printf("%s\n\n", label);
        gotoxy(0U, 3U);
        printf("%s\n", work);
        gotoxy(cursor, 4U);
        printf("^");
        gotoxy(0U, 7U);
        printf("LEFT/RIGHT: MOVE\nUP/DOWN: DIGIT\nA: CONFIRM\nB: CANCEL");

        pressed = wait_key_edge();
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
