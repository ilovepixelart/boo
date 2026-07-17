// Settings: theme picker, opacity, auto-type. Mirrors the macOS gear/Settings
// window and the Linux header-bar Settings dialog (docs/ui-spec.md).
#ifndef BOO_SETTINGS_H
#define BOO_SETTINGS_H

#include "app.h"

// Window class and control ids, shared with the coverage smoke driver
// (windows/tests/drive_app.c), which pokes the live dialog by id.
#define BOO_SETTINGS_CLASS L"BooSettings"
#define IDC_OPACITY        2001
#define IDC_AUTOTYPE       2002
#define IDC_THEMES         2003
#define IDC_OPACITY_VAL    2004
#define IDC_MODEL          2005
#define IDC_MODEL_PROGRESS 2006

// Load every theme (enumerate the themes dir + boo_theme_parse_file) and the
// persisted prefs (registry: theme, opacity, auto-type). Call once, after the
// overlay window exists. Safe to call with no themes dir (uses the default).
void boo_settings_init(BooApp *app);

// Apply the current opacity to the overlay and repaint. Call after init and
// after any change.
void boo_settings_apply(BooApp *app);

// Open (or focus) the modeless Settings dialog.
void boo_settings_open(BooApp *app);

// Free the loaded theme list. Call on overlay destroy.
void boo_settings_free(BooApp *app);

#endif // BOO_SETTINGS_H
