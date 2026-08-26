/** Layer 3 -- text UI: menu, joypad, result/trace/config screens.
 * No SB_REG/SC_REG access happens here -- only magb_session.h's
 * public (hardware-agnostic) types and the joypad/console GBDK APIs.
 */
#ifndef UI_H
#define UI_H

#include "magb_session.h"
#include "magb_network.h"
#include "test_runner.h"
#include <stdint.h>
#include <stdbool.h>

typedef enum {
    UI_MENU_ADAPTER_SESSION = 0,
    UI_MENU_READ_CONFIG,
    UI_MENU_ISP_HTTP,
    UI_MENU_P2P_CALLER,
    UI_MENU_P2P_LISTENER,
    UI_MENU_COUNT
} ui_menu_item_t;

void ui_init(void);

/** Draws the main menu and blocks (with a responsive joypad loop)
 * until the user picks a test (A) or asks for the trace viewer
 * (SELECT, returns immediately without running a test). */
ui_menu_item_t ui_main_menu(bool *want_trace);

/** Polled by magb_context_t::cancel_check. */
bool ui_check_cancel(void);

/** Blocks until A or B is pressed (edge-triggered). Returns true for A. */
bool ui_prompt_continue(void);

void ui_show_result(const char *title, const test_result_t *result);
void ui_show_trace(const magb_context_t *ctx);
void ui_show_config(const uint8_t config[MAGB_CONFIG_SIZE]);

/** In-place digit editor for a 12-digit phone/IP-style number.
 * `buf` must be at least 13 bytes (12 digits + NUL) and NUL-terminated
 * on entry; left unchanged if the user cancels with B. */
bool ui_edit_number(char *buf, const char *label);

/** Generic scrolling list picker (used for the ISP/HTTP sub-test
 * menu). Returns the selected index, or `count` if the user cancels
 * with B. `labels[i]` must stay valid for the call's duration. */
uint8_t ui_select_submenu(const char *title, const char *const *labels, uint8_t count);

/** Converts a magb_result_t to a short (<=20 char) human-readable string. */
const char *ui_result_str(magb_result_t r);

#endif /* UI_H */
