// Native-runner tests for the settings registry persistence. Includes the
// sources under test so their statics are reachable (the model_test.c pattern);
// settings.c pulls in model.c and download.c (its frontend deps) which define
// disjoint statics. Runs via `zig build win-tests` on the Windows CI job.
//
// These touch the REAL registry under HKCU\Software\Boo (a fresh CI runner has
// none), and delete the key at the end so nothing is left behind.

#include "model.c"
#include "download.c"
#include "settings.c"

#include <stdio.h>

static int failures = 0;

static void check(bool ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    printf("settings_test:\n");

    // Two fake themes so the theme choice can round-trip by name.
    BooThemeEntry themes[2] = {0};
    themes[0].name = L"Aardvark";
    themes[1].name = L"Zzz";

    // ── load_prefs / save_prefs round-trip ──
    {
        BooApp app = {0};
        app.settings.themes = themes;
        app.settings.theme_count = 2;
        app.settings.current_theme = 1; // "Zzz"
        app.settings.opacity_pct = 63;
        app.settings.auto_type = false;
        save_prefs(&app);

        BooApp got = {0};
        got.settings.themes = themes;
        got.settings.theme_count = 2;
        got.settings.current_theme = -1; // as boo_settings_init leaves it
        load_prefs(&got);
        check(got.settings.opacity_pct == 63, "opacity round-trips through the registry");
        check(!got.settings.auto_type, "auto_type round-trips");
        check(got.settings.current_theme == 1, "the theme choice round-trips by name");
    }

    // ── an out-of-range persisted opacity is rejected, defaults kept ──
    {
        HKEY key;
        RegCreateKeyExW(HKEY_CURRENT_USER, BOO_REG_KEY, 0, NULL, 0, KEY_WRITE, NULL, &key,
                        NULL);
        const DWORD bad = 250;
        RegSetValueExW(key, L"Opacity", 0, REG_DWORD, (const BYTE *)&bad, sizeof(bad));
        RegCloseKey(key);

        BooApp got = {0};
        got.settings.current_theme = -1;
        load_prefs(&got);
        check(got.settings.opacity_pct == 100,
              "an out-of-range persisted opacity falls back to 100");
    }

    // ── no key at all: the built-in defaults ──
    {
        RegDeleteTreeW(HKEY_CURRENT_USER, BOO_REG_KEY);
        BooApp got = {0};
        got.settings.current_theme = -1;
        load_prefs(&got);
        check(got.settings.opacity_pct == 100 && got.settings.auto_type &&
                  got.settings.current_theme == -1,
              "no registry key means the built-in defaults");
    }

    // ── save_model_choice persists the wide path so it round-trips ──
    {
        save_model_choice("C:\\m\\ggml-x.bin");
        WCHAR model[MAX_PATH];
        DWORD sz = sizeof(model);
        const LSTATUS r = RegGetValueW(HKEY_CURRENT_USER, BOO_REG_KEY, L"Model",
                                       RRF_RT_REG_SZ, NULL, model, &sz);
        check(r == ERROR_SUCCESS, "the model choice is persisted");
        char *u = boo_to_utf8(model);
        check(u && strcmp(u, "C:\\m\\ggml-x.bin") == 0,
              "the persisted model path round-trips");
        free(u);
    }

    // ── model_swap_begin ignores a re-select of the already-loaded model ──
    {
        BooApp app = {0};
        app.settings.model_current = _strdup("same-model");
        app.model_swap_worker = NULL;
        model_swap_begin(&app, NULL, NULL, "same-model");
        check(app.model_swap_worker == NULL,
              "re-selecting the loaded model starts no swap");
        free(app.settings.model_current);
    }

    RegDeleteTreeW(HKEY_CURRENT_USER, BOO_REG_KEY); // leave nothing behind
    printf("settings_test: %s\n", failures ? "FAIL" : "all checks passed");
    return failures ? 1 : 0;
}
