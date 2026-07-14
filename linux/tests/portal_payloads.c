// Verifies the D-Bus payloads Boo sends to the XDG portals.
//
// GVariant format strings are parsed at runtime, not compile time: a malformed
// one aborts the process the first time it executes. Since the portal code only
// runs on a live Linux desktop, a typo here would otherwise surface as a crash
// on a user's machine rather than a build failure. These tests execute every
// payload builder and assert the exact D-Bus signature each portal method
// expects, so a bad format string fails CI instead.
//
// The portal .c files are included directly so the static payload builders are
// reachable; they live in separate translation units because both define
// helpers of the same name.

#include <glib.h>
#include <string.h>

#ifdef TEST_TEXT_INJECT
#include "text_inject.c"
#else
#include "global_shortcut.c"
#endif

static void expect_signature(GVariant *v, const char *expected, const char *what) {
    v = g_variant_ref_sink(v);
    const char *actual = g_variant_get_type_string(v);
    if (strcmp(actual, expected) != 0) {
        g_error("%s: signature %s, expected %s", what, actual, expected);
    }
    g_print("  ok  %-14s %-18s %s\n", what, actual, g_variant_print(v, TRUE));
    g_variant_unref(v);
}

// A plausible session handle, shaped like one the portal would hand back.
static const char *const SESSION =
    "/org/freedesktop/portal/desktop/session/1_23/boo_ab12cd34";

#ifdef TEST_TEXT_INJECT

// Signatures per org.freedesktop.portal.RemoteDesktop.
static void test_remote_desktop(void) {
    g_print("RemoteDesktop:\n");

    BooTextInject ti = {0};
    ti.session_handle = g_strdup(SESSION);

    expect_signature(make_create_session_payload(&ti, "boo_00000001"),
                     "(a{sv})", "CreateSession");
    expect_signature(make_select_devices_payload(&ti, "boo_00000002"),
                     "(oa{sv})", "SelectDevices");
    expect_signature(make_start_payload(&ti, "boo_00000003"),
                     "(osa{sv})", "Start");

    // Exactly as boo_notify_keysym builds it.
    expect_signature(g_variant_new_parsed("(%o, @a{sv} {}, %i, %u)",
                                          ti.session_handle, (gint32)XKS_V,
                                          KEY_PRESSED),
                     "(oa{sv}iu)", "NotifyKeysym");

    g_free(ti.session_handle);
}

// SelectDevices must request the keyboard and ask the portal to persist the
// grant, or the user is re-prompted on every launch.
static void test_select_devices_options(void) {
    g_print("SelectDevices options:\n");

    BooTextInject ti = {0};
    ti.session_handle = g_strdup(SESSION);

    GVariant *payload =
        g_variant_ref_sink(make_select_devices_payload(&ti, "boo_00000002"));
    GVariant *options = g_variant_get_child_value(payload, 1);

    guint32 types = 0, persist = 0;
    g_assert_true(g_variant_lookup(options, "types", "u", &types));
    g_assert_cmpuint(types & DEVICE_KEYBOARD, ==, DEVICE_KEYBOARD);
    g_assert_true(g_variant_lookup(options, "persist_mode", "u", &persist));
    g_assert_cmpuint(persist, ==, PERSIST_UNTIL_REVOKED);
    g_print("  ok  keyboard requested, persist_mode=%u\n", persist);

    g_variant_unref(options);
    g_variant_unref(payload);
    g_free(ti.session_handle);
}

// A restore token is what turns the second launch into a silent one.
static void test_restore_token_roundtrip(void) {
    g_print("Restore token:\n");

    boo_save_restore_token("test-token-123");
    char *loaded = boo_load_restore_token();
    g_assert_cmpstr(loaded, ==, "test-token-123");
    g_free(loaded);

    boo_clear_restore_token();
    g_assert_null(boo_load_restore_token());
    g_print("  ok  save -> load -> clear\n");
}

#else

// Signatures per org.freedesktop.portal.GlobalShortcuts.
static void test_global_shortcuts(void) {
    g_print("GlobalShortcuts:\n");

    BooGlobalShortcut gs = {0};
    expect_signature(boo_make_payload(&gs, BOO_METHOD_CREATE_SESSION, "boo_1"),
                     "(a{sv})", "CreateSession");

    gs.session_handle = g_strdup(SESSION);
    expect_signature(boo_make_payload(&gs, BOO_METHOD_BIND_SHORTCUTS, "boo_2"),
                     "(oa(sa{sv})sa{sv})", "BindShortcuts");

    g_free(gs.session_handle);
}

// The handle arrives as a plain string, not an object path — reading it with
// the wrong type would silently yield NULL and disable the hotkey.
static void test_session_handle_lookup(void) {
    g_print("CreateSession response:\n");

    GVariant *results = g_variant_ref_sink(
        g_variant_new_parsed("{'session_handle': <%s>}", SESSION));

    const char *handle = NULL;
    g_assert_true(g_variant_lookup(results, "session_handle", "&s", &handle));
    g_assert_cmpstr(handle, ==, SESSION);
    g_print("  ok  session_handle extracted\n");

    g_variant_unref(results);
}

#endif

// The predicted request path is the whole reason the Response signal is not
// missed; the portal derives the same path from our unique name.
static void test_request_path(void) {
    g_print("Request path:\n");

    // ":1.42" -> "1_42"; dots are illegal in object path components.
    const char *unique = ":1.42";
    char *name = g_strdup(&unique[1]); // strip the leading ':'
    for (char *p = name; *p; p++) {
        if (*p == '.') *p = '_';
    }
    char *path = g_strdup_printf("%s/request/%s/%s", PORTAL_OBJECT_PATH, name,
                                 "boo_00000001");
    g_assert_cmpstr(
        path, ==,
        "/org/freedesktop/portal/desktop/request/1_42/boo_00000001");
    g_assert_true(g_variant_is_object_path(path));
    g_print("  ok  %s\n", path);

    g_free(path);
    g_free(name);
}

int main(void) {
#ifdef TEST_TEXT_INJECT
    test_remote_desktop();
    test_select_devices_options();
    test_restore_token_roundtrip();
#else
    test_global_shortcuts();
    test_session_handle_lookup();
#endif
    test_request_path();

    g_print("PASS\n");
    return 0;
}
