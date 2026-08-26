#include "serial_hw.h"
#include "magb_session.h"
#include "magb_network.h"
#include "test_runner.h"
#include "test_config.h"
#include "ui.h"

#include <string.h>

void main(void)
{
    static magb_context_t ctx;
    static char p2p_number[13] = TEST_P2P_PHONE;
    static test_result_t result;
    static uint8_t config_buf[MAGB_CONFIG_SIZE];

    serial_hw_init(); /* fatal error screen + halt if not a CGB */

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
            ui_show_result("ADAPTER / SESSION", &result);
            break;

        case UI_MENU_ISP_HTTP: {
            static const char *const kIspLabels[] = {
                "TAMAGO EGG",
                "NEWS CONFIG",
                "NEWS (AUTH)",
                "CUSTOM",
                "EMAIL SEND",
                "EMAIL RECV"
            };
            #define ISP_SUBMENU_COUNT 6U
            uint8_t choice = ui_select_submenu("ISP / HTTP", kIspLabels, ISP_SUBMENU_COUNT);

            switch (choice) {
            case 0U:
                test_isp_http(&ctx, &result, TEST_HTTP_HOST, TEST_HTTP_PORT, TEST_HTTP_PATH);
                ui_show_result("TAMAGO EGG", &result);
                break;
            case 1U:
                test_isp_http_gb00(&ctx, &result, TEST_HTTP_HOST, TEST_HTTP_PORT, TEST_HTTP_NEWS_CONFIG_PATH);
                ui_show_result("NEWS CONFIG", &result);
                break;
            case 2U:
                test_isp_http_gb00(&ctx, &result, TEST_HTTP_HOST, TEST_HTTP_PORT, TEST_HTTP_NEWS_PATH);
                ui_show_result("NEWS (AUTH)", &result);
                break;
            case 3U:
                test_isp_http(&ctx, &result, TEST_HTTP_CUSTOM_HOST, TEST_HTTP_CUSTOM_PORT, TEST_HTTP_CUSTOM_PATH);
                ui_show_result("CUSTOM", &result);
                break;
            case 4U:
                test_isp_email_send(&ctx, &result);
                ui_show_result("EMAIL SEND", &result);
                break;
            case 5U:
                test_isp_email_recv(&ctx, &result);
                ui_show_result("EMAIL RECV", &result);
                break;
            default:
                break; /* cancelled (B) */
            }
            break;
        }

        case UI_MENU_P2P_CALLER:
            (void)ui_edit_number(p2p_number, "P2P NUMBER (OR IP)");
            test_p2p_caller(&ctx, &result, p2p_number);
            ui_show_result("P2P CALLER", &result);
            break;

        case UI_MENU_P2P_LISTENER:
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
