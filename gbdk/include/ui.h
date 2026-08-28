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
    UI_MENU_ISP_PASSWORD,
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

/** Draws a static "TESTING..." screen -- call right before running a
 * test, so the user sees something changed instead of a frozen-looking
 * screen while a test's internal waits run. Deliberately takes no
 * title (the result screen right after already names the test; a
 * second copy of the same string here would just be a second literal
 * SDCC doesn't pool, and this ROM has no spare bytes for that).
 * `cancelable` shows a "B: CANCEL" hint for tests that actually honor
 * ctx->cancel_check (P2P Caller/Listener only, currently). A test that
 * draws its own screen (e.g. Raw TCP) should simply never call this.
 * A live animation was tried here (a tick callback driven from the
 * protocol layer's own wait loop, mirroring cancel_check) and worked,
 * but cost ~300 bytes this ROM doesn't have to spare -- reverted in
 * favor of this static version per the project owner's own fallback
 * instruction. */
void ui_show_testing(bool cancelable);

/** In-place digit editor for a phone/IP-style number, up to 12 digits.
 * `buf` must be at least 13 bytes (12 digits + NUL) and NUL-terminated
 * on entry; left unchanged if the user cancels with B.
 *
 * `variable_len`: false locks the length at exactly 12 digits (e.g. the
 * Raw TCP IP editor, whose result is always parsed as a fixed 4-octet
 * dotted-quad -- see parse_ip12() in test_runner.c). true additionally
 * lets SELECT/START shrink/grow the active length (down to 1, up to
 * 12) before confirming, and only that many digits are written to
 * `buf` on A -- needed for the P2P Caller field, since libmobile's
 * direct-IP P2P dial requires exactly 12 digits (parsed as an IPv4
 * address) but a relay-based call (a different mechanism entirely, see
 * docs/protocol-notes.md) is dialed with a real phone-number-shaped
 * string, commonly 10 digits, that must reach magb_dial() at its own
 * length rather than padded out to 12. */
bool ui_edit_number(char *buf, const char *label, bool variable_len);

/** In-place text editor for a short (<=UI_EDIT_TEXT_MAX_LEN char)
 * string such as an ISP password -- UP/DOWN cycles the character
 * under the cursor through a space (used as an erase/blank slot) plus
 * A-Z, a-z, 0-9; LEFT/RIGHT moves the cursor. `buf` must be
 * NUL-terminated on entry (the existing value is shown, editable) and
 * have room for `buf_cap` bytes total including the NUL; left
 * unchanged if the user cancels with B. Trailing spaces are trimmed
 * from the result on confirm. */
#define UI_EDIT_TEXT_MAX_LEN 20U
bool ui_edit_text(char *buf, uint8_t buf_cap, const char *label);

/** Generic scrolling list picker (used for the ISP/HTTP sub-test
 * menu). Returns the selected index, or `count` if the user cancels
 * with B. `labels[i]` must stay valid for the call's duration. */
uint8_t ui_select_submenu(const char *title, const char *const *labels, uint8_t count);

/** Converts a magb_result_t to a short (<=20 char) human-readable string. */
const char *ui_result_str(magb_result_t r);

#endif /* UI_H */
