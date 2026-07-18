// Verifies the D-Bus payloads Boo sends to the XDG portals.
//
// GVariant format strings are parsed at runtime, not compile time: a malformed
// one aborts the process the first time it executes. Since the portal code only
// runs on a live Linux desktop, a typo here would otherwise surface as a crash
// on a user's machine rather than a build failure. These tests execute every
// payload builder and assert the exact D-Bus signature each portal method
// expects, so a bad format string fails CI instead.
//
// The portal .c files are included directly so their static payload builders are
// reachable; they live in separate translation units because both define a
// `make_payload` keyed off their own state.

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

    ti.state = BOO_INJECT_CREATING_SESSION;
    expect_signature(make_payload(&ti, "boo_00000001"), "(a{sv})", "CreateSession");

    ti.state = BOO_INJECT_SELECTING_DEVICES;
    expect_signature(make_payload(&ti, "boo_00000002"), "(oa{sv})", "SelectDevices");

    ti.state = BOO_INJECT_STARTING;
    expect_signature(make_payload(&ti, "boo_00000003"), "(osa{sv})", "Start");

    // Exactly as notify_keysym builds it.
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
    ti.state = BOO_INJECT_SELECTING_DEVICES;

    g_autoptr(GVariant) payload =
        g_variant_ref_sink(make_payload(&ti, "boo_00000002"));
    g_autoptr(GVariant) options = g_variant_get_child_value(payload, 1);

    guint32 types = 0, persist = 0;
    g_assert_true(g_variant_lookup(options, "types", "u", &types));
    g_assert_cmpuint(types & DEVICE_KEYBOARD, ==, DEVICE_KEYBOARD);
    g_assert_true(g_variant_lookup(options, "persist_mode", "u", &persist));
    g_assert_cmpuint(persist, ==, PERSIST_UNTIL_REVOKED);
    g_print("  ok  keyboard requested, persist_mode=%u\n", persist);

    g_free(ti.session_handle);
}

// A restore token is what turns the second launch into a silent one.
static void test_restore_token_roundtrip(void) {
    g_print("Restore token:\n");

    save_restore_token("test-token-123");
    char *loaded = load_restore_token();
    g_assert_cmpstr(loaded, ==, "test-token-123");
    g_free(loaded);

    clear_restore_token();
    g_assert_null(load_restore_token());
    g_print("  ok  save -> load -> clear\n");
}

// The paste chord must be a well-formed Ctrl+Shift+V: the modifiers enclose the
// key so the target sees exactly that shortcut, and every press is mirrored by a
// release in reverse order so nothing stays held (a stuck Shift or Ctrl would
// corrupt the user's next keystrokes).
static void test_paste_chord(void) {
    g_print("Paste chord:\n");

    BooChordEvent chord[BOO_PASTE_CHORD_LEN];
    const int n = build_paste_chord(chord);

    const BooChordEvent want[] = {
        {XKS_CONTROL_L, KEY_PRESSED}, {XKS_SHIFT_L, KEY_PRESSED},  {XKS_V, KEY_PRESSED},
        {XKS_V, KEY_RELEASED},        {XKS_SHIFT_L, KEY_RELEASED}, {XKS_CONTROL_L, KEY_RELEASED},
    };
    g_assert_cmpint(n, ==, (int)G_N_ELEMENTS(want));
    for (int i = 0; i < n; i++) {
        g_assert_cmpuint(chord[i].keysym, ==, want[i].keysym);
        g_assert_cmpuint(chord[i].state, ==, want[i].state);
    }
    g_print("  ok  Ctrl+Shift+V, %d events, press/release balanced\n", n);
}

#else

// Signatures per org.freedesktop.portal.GlobalShortcuts.
static void test_global_shortcuts(void) {
    g_print("GlobalShortcuts:\n");

    BooGlobalShortcut gs = {0};

    gs.step = BOO_GS_CREATE_SESSION;
    expect_signature(make_payload(&gs, "boo_1"), "(a{sv})", "CreateSession");

    gs.session_handle = g_strdup(SESSION);

    gs.step = BOO_GS_LIST_SHORTCUTS;
    expect_signature(make_payload(&gs, "boo_2"), "(oa{sv})", "ListShortcuts");

    gs.step = BOO_GS_BIND_SHORTCUTS;
    expect_signature(make_payload(&gs, "boo_3"), "(oa(sa{sv})sa{sv})",
                     "BindShortcuts");

    g_free(gs.session_handle);
}

// ListShortcuts is what lets Boo skip BindShortcuts, the call that raises the
// approval dialog, when an earlier run already bound the shortcut.
static void test_already_bound(void) {
    g_print("ListShortcuts response:\n");

    g_autoptr(GVariant) ours = g_variant_ref_sink(g_variant_new_parsed(
        "{'shortcuts': <[('toggle-record', {'description': <'x'>})]>}"));
    g_assert_true(already_bound(ours));
    g_print("  ok  our shortcut is recognised as already bound\n");

    g_autoptr(GVariant) theirs = g_variant_ref_sink(g_variant_new_parsed(
        "{'shortcuts': <[('someone-elses', {'description': <'x'>})]>}"));
    g_assert_false(already_bound(theirs));

    g_autoptr(GVariant) none = g_variant_ref_sink(
        g_variant_new_parsed("{'shortcuts': <@a(sa{sv}) []>}"));
    g_assert_false(already_bound(none));
    g_print("  ok  a different shortcut, or none, means we must still bind\n");
}

// The handle arrives as a plain string, not an object path, reading it with the
// wrong type would silently yield NULL and disable the hotkey.
static void test_session_handle_lookup(void) {
    g_print("CreateSession response:\n");

    g_autoptr(GVariant) results = g_variant_ref_sink(
        g_variant_new_parsed("{'session_handle': <%s>}", SESSION));

    const char *handle = NULL;
    g_assert_true(g_variant_lookup(results, "session_handle", "&s", &handle));
    g_assert_cmpstr(handle, ==, SESSION);
    g_print("  ok  session_handle extracted\n");
}

// Recorders for the two client callbacks, so the reason string, the report-once
// latch, and which shortcut id fires can be asserted without a live portal.
typedef struct {
    char *reason;
    int count;
} UnavailRec;

static void record_unavailable(const char *reason, gpointer user_data) {
    UnavailRec *r = user_data;
    g_free(r->reason);
    r->reason = g_strdup(reason);
    r->count++;
}

static void record_activated(gpointer user_data) { (*(int *)user_data)++; }

// on_error maps a portal failure to a user message and reports it at most once:
// the "unsupported" case substitutes the canned GNOME-48 explanation, otherwise
// the raw reason passes through, and the latch swallows a repeat.
static void test_shortcut_error(void) {
    g_print("Shortcut error:\n");

    UnavailRec rec = {0};
    BooGlobalShortcut gs = {0};
    gs.on_unavailable = record_unavailable;
    gs.user_data = &rec;

    on_error("the request failed", FALSE, &gs);
    g_assert_cmpstr(rec.reason, ==, "the request failed");
    g_assert_cmpint(rec.count, ==, 1);

    on_error("again", FALSE, &gs); // the latch: reported once per handle
    g_assert_cmpint(rec.count, ==, 1);
    g_print("  ok  reason passed through, reported once\n");

    UnavailRec rec2 = {0};
    BooGlobalShortcut gs2 = {0};
    gs2.on_unavailable = record_unavailable;
    gs2.user_data = &rec2;
    on_error(NULL, TRUE, &gs2); // unsupported: canned explanation replaces reason
    g_assert_cmpint(rec2.count, ==, 1);
    g_assert_nonnull(g_strstr_len(rec2.reason, -1, "GNOME 48"));
    g_print("  ok  unsupported desktop gets the canned explanation\n");

    g_free(rec.reason);
    g_free(rec2.reason);
}

// on_activated fires the toggle only for Boo's own shortcut id, ignoring any
// other shortcut delivered on the same session.
static void test_shortcut_activated(void) {
    g_print("Shortcut activated:\n");

    int fired = 0;
    BooGlobalShortcut gs = {0};
    gs.on_activated = record_activated;
    gs.user_data = &fired;

    g_autoptr(GVariant) ours = g_variant_ref_sink(
        g_variant_new_parsed("(%o, %s, @a{sv} {})", SESSION, "toggle-record"));
    on_activated(NULL, NULL, NULL, NULL, NULL, ours, &gs);
    g_assert_cmpint(fired, ==, 1);

    g_autoptr(GVariant) theirs = g_variant_ref_sink(
        g_variant_new_parsed("(%o, %s, @a{sv} {})", SESSION, "someone-elses"));
    on_activated(NULL, NULL, NULL, NULL, NULL, theirs, &gs);
    g_assert_cmpint(fired, ==, 1);
    g_print("  ok  fires for our id, ignores others\n");
}

#endif

int main(void) {
#ifdef TEST_TEXT_INJECT
    test_remote_desktop();
    test_select_devices_options();
    test_restore_token_roundtrip();
    test_paste_chord();
#else
    test_global_shortcuts();
    test_already_bound();
    test_session_handle_lookup();
    test_shortcut_error();
    test_shortcut_activated();
#endif

    g_print("PASS\n");
    return 0;
}
