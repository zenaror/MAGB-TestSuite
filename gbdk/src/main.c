#include "serial_hw.h"
#include "magb_session.h"
#include "magb_network.h"
#include "test_runner.h"
#include "test_config.h"
#include "ui.h"
#include "sound.h"

#include <string.h>

void main(void)
{
    static magb_context_t ctx;
    static char p2p_number[13] = TEST_P2P_PHONE;
    /* Session-wide ISP account password. No password field exists
     * anywhere in the documented 192-byte Mobile Adapter configuration
     * (docs/dandocs-magb.md), so unlike login/phone/email/SMTP/POP it
     * can never be read from Read Config -- it has to come from the
     * user. Starts EMPTY (no TEST_ISP_PASSWORD default) -- the
     * password is real account data, never a guessable constant, and
     * silently trying "test" hid every real 401/-ERR failure behind a
     * confusing symptom for a full day of debugging (see
     * docs/protocol-notes.md's GB00 section). Tests that actually
     * authenticate (GB00 HTTP, POP3) now refuse to run at all with an
     * explicit "SET ISP PASSWORD" failure while this is empty
     * (test_runner.c's require_password()), rather than sending a
     * guessed value. Edited in place with ui_edit_text(), kept only in
     * RAM (this ROM has no mapper/save), so it resets to empty on
     * power-off. Capped at TEST_ISP_PASSWORD_MAX_LEN (8) chars --
     * ui_edit_text() derives its own editable length from
     * sizeof(isp_password), so this is the only place that limit needs
     * to be expressed. */
    static char isp_password[TEST_ISP_PASSWORD_MAX_LEN + 1U];
    static char raw_tcp_ip[13] = TEST_ISP_RAW_IP;
    static test_result_t result;
    static uint8_t config_buf[MAGB_CONFIG_SIZE];

    serial_hw_init(); /* fatal error screen + halt if not a CGB */
    sound_init();

    magb_context_init(&ctx);
    ctx.cancel_check = ui_check_cancel;

    ui_init();

    for (;;) {
        bool want_trace = false;
        ui_menu_item_t sel = ui_main_menu(&want_trace);

        if (want_trace) {
            ui_show_trace(&ctx);
            continue;
        }

        switch (sel) {
        case UI_MENU_ADAPTER_SESSION:
            test_adapter_session(&ctx, &result);
            ui_show_result("ADAPTER/SESSION", &result);
            break;

        case UI_MENU_ISP_HTTP: {
            /* "NEWS CONFIG" and "NEWS ARTICLE" both require REON's
             * GB00 auth (confirmed by reading news.php -- see
             * docs/protocol-notes.md); they used to be named
             * "NEWS CONFIG"/"NEWS (AUTH)", which wrongly implied only
             * one of them needed authentication. "NEWS ARTICLE" fetches
             * config *and* article in one ISP session, matching the
             * real game's actual flow (test_isp_news_article()); "NEWS
             * CONFIG" stays available on its own as an isolated
             * diagnostic. */
            static const char *const kIspLabels[] = {
                "TAMAGO EGG",
                "NEWS CONFIG",
                "NEWS ARTICLE",
                "TRAINER HOME",
                "EMAIL SEND",
                "EMAIL RECV",
                "RAW TCP(NC)"
            };
            #define ISP_SUBMENU_COUNT 7U
            uint8_t choice = ui_select_submenu("ISP/HTTP", kIspLabels, ISP_SUBMENU_COUNT);

            /* Shared "TESTING..." for every choice that actually runs a
             * test_result_t-based test (everything except Raw TCP,
             * which draws its own screen, and "cancelled") -- one call
             * site instead of six identical ones. (Reusing kIspLabels[]
             * for the ui_show_result() titles below, instead of the
             * literals each case already has, was tried and measurably
             * cost *more* code than the duplicate strings it removed --
             * SM83 has no hardware multiply, and SDCC's indexing code
             * for a `const char *const[]` is not cheap here even
             * computed once. Plain literals below are the smaller
             * option in practice, not just in theory.) */
            if (choice < 6U) {
                ui_show_testing(false);
            }
            switch (choice) {
            case 0U:
                test_isp_http(&ctx, &result, isp_password, TEST_HTTP_HOST, TEST_HTTP_PORT, TEST_HTTP_PATH);
                ui_show_result("TAMAGO EGG", &result);
                break;
            case 1U:
                test_isp_http_gb00(&ctx, &result, isp_password, TEST_HTTP_HOST, TEST_HTTP_PORT, TEST_HTTP_NEWS_CONFIG_PATH);
                ui_show_result("NEWS CONFIG", &result);
                break;
            case 2U:
                test_isp_news_article(&ctx, &result, isp_password);
                ui_show_result("NEWS ARTICLE", &result);
                break;
            case 3U:
                test_isp_http(&ctx, &result, isp_password, TEST_HTTP_TRAINER_HOME_HOST, TEST_HTTP_TRAINER_HOME_PORT, TEST_HTTP_TRAINER_HOME_PATH);
                ui_show_result("TRAINER HOME", &result);
                break;
            case 4U:
                test_isp_email_send(&ctx, &result, isp_password);
                ui_show_result("EMAIL SEND", &result);
                break;
            case 5U:
                test_isp_email_recv(&ctx, &result, isp_password);
                ui_show_result("EMAIL RECV", &result);
                break;
            case 6U:
                /* No password needed (libmobile doesn't validate ISP
                 * Login credentials, and there is no auth step in a
                 * raw TCP session) -- only the target IP is editable
                 * here. test_isp_raw_tcp() draws and manages its own
                 * screen throughout, including its own "press A/B"
                 * exit prompt, so no ui_show_result() call follows it
                 * (see its declaration in test_runner.h for why). */
                if (ui_edit_number(raw_tcp_ip, "RAW TCP IP", false)) {
                    test_isp_raw_tcp(&ctx, raw_tcp_ip, TEST_ISP_RAW_PORT);
                }
                break;
            default:
                break; /* cancelled (B) */
            }
            break;
        }

        case UI_MENU_ISP_PASSWORD:
            (void)ui_edit_text(isp_password, sizeof(isp_password), "ISP PASSWORD");
            break;

        case UI_MENU_P2P_CALLER:
            if (ui_edit_number(p2p_number, "P2P NUMBER", true)) {
                ui_show_testing(true);
                test_p2p_caller(&ctx, &result, p2p_number);
                ui_show_result("P2P CALLER", &result);
            }
            break;

        case UI_MENU_P2P_LISTENER:
            ui_show_testing(true);
            test_p2p_listener(&ctx, &result);
            ui_show_result("P2P LISTENER", &result);
            break;

        case UI_MENU_READ_CONFIG:
            test_read_config(&ctx, config_buf, &result);
            if (result.passed) {
                ui_show_config(config_buf);
            } else {
                ui_show_result("READ CONFIG", &result);
            }
            break;

        default:
            break;
        }
    }
}
