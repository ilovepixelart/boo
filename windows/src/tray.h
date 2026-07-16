// Notification-area icon, the Windows analog of the macOS menu-bar item.
#ifndef BOO_TRAY_H
#define BOO_TRAY_H

#include "app.h"

bool boo_tray_add(HWND hwnd);
void boo_tray_remove(HWND hwnd);
void boo_tray_set_recording(HWND hwnd, bool recording);

// Explorer broadcasts this registered message when the taskbar (re)starts;
// icons must be re-added on it or they vanish after an Explorer crash.
UINT boo_tray_taskbar_created_msg(void);

// Right-click / keyboard menu. `anchor` is the screen point the shell handed
// us in the version-4 callback's wParam.
void boo_tray_show_menu(HWND hwnd, POINT anchor, bool recording);

#endif // BOO_TRAY_H
