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

// With a saved restore token, SelectDevices replays it so the portal re-grants
// silently instead of prompting again; and either device state with no session
// handle yet must yield no payload rather than a malformed request.
static void test_select_devices_restore_token(void) {
    g_print("SelectDevices restore token:\n");

    save_restore_token("tok-abc");
    BooTextInject ti = {0};
    ti.session_handle = g_strdup(SESSION);
    ti.state = BOO_INJECT_SELECTING_DEVICES;

    g_autoptr(GVariant) payload = g_variant_ref_sink(make_payload(&ti, "boo_00000002"));
    g_autoptr(GVariant) options = g_variant_get_child_value(payload, 1);
    const char *token = NULL;
    g_assert_true(g_variant_lookup(options, "restore_token", "&s", &token));
    g_assert_cmpstr(token, ==, "tok-abc");
    g_print("  ok  a saved token is replayed in SelectDevices\n");

    clear_restore_token();
    g_free(ti.session_handle);

    BooTextInject no_session = {0};
    no_session.state = BOO_INJECT_SELECTING_DEVICES;
    g_assert_null(make_payload(&no_session, "x"));
    no_session.state = BOO_INJECT_STARTING;
    g_assert_null(make_payload(&no_session, "x"));
    g_print("  ok  no session handle yields no payload\n");
}

// A portal failure BEFORE the restore token is replayed (CreateSession) or AFTER
// it is consumed (Start) must not wipe a still-valid token; only a failure at
// SelectDevices, the step that sends it, drops it. Wiping on any failure forced a
// needless permission re-prompt on the next launch after a transient error.
static void test_restore_token_kept_on_unrelated_failure(void) {
    g_print("Restore token on failure:\n");

    g_autoptr(GVariant) empty = g_variant_ref_sink(g_variant_new_parsed("@a{sv} {}"));

    save_restore_token("keep-me");
    BooTextInject early = {0};
    early.state = BOO_INJECT_CREATING_SESSION;
    on_response(2, empty, &early); // generic failure, token never sent yet
    g_autofree char *survived = load_restore_token();
    g_assert_cmpstr(survived, ==, "keep-me");

    BooTextInject selecting = {0};
    selecting.state = BOO_INJECT_SELECTING_DEVICES;
    on_response(2, empty, &selecting); // failure where the token was replayed
    g_assert_null(load_restore_token());

    g_print("  ok  kept on unrelated failure, dropped at SelectDevices\n");
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

// boo_text_inject_paste routes on the session state: a ready session schedules
// exactly one delayed chord (debounced), a failed one is a silent no-op (the
// clipboard copy already happened), and a session still coming up latches the
// paste to fire when it turns ready. No main loop runs here, so the scheduled
// timeout never fires (it would need the live bus); the source id proves it was
// armed, and it is removed before the stack handle dies.
static void test_paste_scheduling(void) {
    g_print("Paste scheduling:\n");

    boo_text_inject_paste(NULL); // the NULL guard must not crash

    BooTextInject ready = {0};
    ready.state = BOO_INJECT_READY;
    boo_text_inject_paste(&ready);
    g_assert_cmpuint(ready.paste_timeout, !=, 0);
    const guint armed = ready.paste_timeout;
    boo_text_inject_paste(&ready); // debounce: a second paste reuses the one timer
    g_assert_cmpuint(ready.paste_timeout, ==, armed);
    g_source_remove(ready.paste_timeout);

    BooTextInject failed = {0};
    failed.state = BOO_INJECT_FAILED;
    boo_text_inject_paste(&failed);
    g_assert_false(failed.pending_paste);
    g_assert_cmpuint(failed.paste_timeout, ==, 0);

    BooTextInject coming = {0};
    coming.state = BOO_INJECT_CREATING_SESSION;
    boo_text_inject_paste(&coming);
    g_assert_true(coming.pending_paste); // latched until the session is ready
    g_assert_cmpuint(coming.paste_timeout, ==, 0);

    g_print("  ok  ready schedules once, failed no-ops, pending latches\n");
}

// on_response's terminal branches (no request() dispatch, so no live bus): Start
// success turns the session ready, persists the fresh single-use token, and
// flushes a queued paste; a Start that did not grant the keyboard fails and
// drops the stale token; a CreateSession reply with no handle fails.
static void test_start_response(void) {
    g_print("Start response:\n");

    clear_restore_token();
    BooTextInject ok = {0};
    ok.state = BOO_INJECT_STARTING;
    ok.pending_paste = TRUE;
    g_autoptr(GVariant) started = g_variant_ref_sink(
        g_variant_new_parsed("@a{sv} {'devices': <uint32 1>, 'restore_token': <'fresh'>}"));
    on_response(0, started, &ok);
    g_assert_cmpint(ok.state, ==, BOO_INJECT_READY);
    g_autofree char *persisted = load_restore_token();
    g_assert_cmpstr(persisted, ==, "fresh");   // the Start token is written back
    g_assert_false(ok.pending_paste);          // the queued paste fired...
    g_assert_cmpuint(ok.paste_timeout, !=, 0); // ...arming the chord
    g_source_remove(ok.paste_timeout);
    clear_restore_token();

    save_restore_token("stale");
    BooTextInject denied = {0};
    denied.state = BOO_INJECT_STARTING;
    g_autoptr(GVariant) no_kbd =
        g_variant_ref_sink(g_variant_new_parsed("@a{sv} {'devices': <uint32 0>}"));
    on_response(0, no_kbd, &denied);
    g_assert_cmpint(denied.state, ==, BOO_INJECT_FAILED);
    g_assert_null(load_restore_token()); // a denied keyboard drops the token

    BooTextInject no_handle = {0};
    no_handle.state = BOO_INJECT_CREATING_SESSION;
    g_autoptr(GVariant) empty = g_variant_ref_sink(g_variant_new_parsed("@a{sv} {}"));
    on_response(0, empty, &no_handle);
    g_assert_cmpint(no_handle.state, ==, BOO_INJECT_FAILED);

    g_print("  ok  ready+token on grant, failed+token-dropped on denial, failed on no handle\n");
}

// A whitespace-only token file reads back as "no token", not an empty string,
// and make_payload has nothing to build once the session is past setup.
static void test_blank_token_and_ready_payload(void) {
    g_print("Blank token + ready payload:\n");

    save_restore_token("   \n");
    g_assert_null(load_restore_token());
    clear_restore_token();

    BooTextInject ready = {0};
    ready.state = BOO_INJECT_READY;
    g_assert_null(make_payload(&ready, "x"));
    g_print("  ok  blank token ignored, no payload once ready\n");
}

// With no session bus (a null parent application), the client is created inert:
// state FAILED, paste is a no-op, and free is clean with nothing allocated.
static void test_inert_without_bus(void) {
    g_print("Inert without a bus:\n");

    BooTextInject *ti = boo_text_inject_new(NULL);
    g_assert_nonnull(ti);
    g_assert_cmpint(ti->state, ==, BOO_INJECT_FAILED);
    boo_text_inject_paste(ti); // no-op on a failed session
    boo_text_inject_free(ti);
    g_print("  ok  no bus -> failed, paste no-ops, free is clean\n");
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

// on_response routes a portal reply: a non-zero code is a decline or rejection
// (reported), and on success it dispatches on the step. Only the branches that
// touch no live bus are exercised here: the reason mapping, the missing-handle
// failure, and the already-bound path that skips BindShortcuts.
static void test_shortcut_response(void) {
    g_print("Shortcut response:\n");

    // A fresh handle + recorder per case, since report_unavailable latches once.
    UnavailRec r1 = {0}, r2 = {0}, r3 = {0}, r4 = {0};
    BooGlobalShortcut declined = {.on_unavailable = record_unavailable, .user_data = &r1};
    BooGlobalShortcut rejected = {.on_unavailable = record_unavailable, .user_data = &r2};
    BooGlobalShortcut no_handle = {
        .on_unavailable = record_unavailable, .user_data = &r3, .step = BOO_GS_CREATE_SESSION};
    BooGlobalShortcut bound = {
        .on_unavailable = record_unavailable, .user_data = &r4, .step = BOO_GS_LIST_SHORTCUTS};

    g_autoptr(GVariant) empty = g_variant_ref_sink(g_variant_new_parsed("@a{sv} {}"));
    on_response(1, empty, &declined);
    g_assert_cmpstr(r1.reason, ==, "the shortcut was declined");
    on_response(2, empty, &rejected);
    g_assert_cmpstr(r2.reason, ==, "the desktop rejected the request");

    // CreateSession succeeded (response 0) but returned no handle: reported.
    on_response(0, empty, &no_handle);
    g_assert_nonnull(g_strstr_len(r3.reason, -1, "no session handle"));

    // ListShortcuts finds our shortcut already bound: skip the dialog, report
    // nothing (this is the whole reason we call ListShortcuts first).
    g_autoptr(GVariant) have = g_variant_ref_sink(g_variant_new_parsed(
        "{'shortcuts': <[('toggle-record', {'description': <'x'>})]>}"));
    on_response(0, have, &bound);
    g_assert_cmpint(r4.count, ==, 0);

    g_print("  ok  reasons mapped, missing handle reported, already-bound skips the dialog\n");
    g_free(r1.reason);
    g_free(r2.reason);
    g_free(r3.reason);
}

#endif

int main(void) {
#ifdef TEST_TEXT_INJECT
    test_remote_desktop();
    test_select_devices_options();
    test_restore_token_roundtrip();
    test_select_devices_restore_token();
    test_restore_token_kept_on_unrelated_failure();
    test_paste_chord();
    test_paste_scheduling();
    test_start_response();
    test_blank_token_and_ready_payload();
    test_inert_without_bus();
#else
    test_global_shortcuts();
    test_already_bound();
    test_session_handle_lookup();
    test_shortcut_error();
    test_shortcut_activated();
    test_shortcut_response();
#endif

    g_print("PASS\n");
    return 0;
}
