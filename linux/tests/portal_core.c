// Exercises portal.c's Request/Response state machine directly.
//
// portal.c is #included (not linked) so its file-local on_response and the
// two-completion free accounting are reachable. The payload suites
// (portal_payloads.c) link portal.c as a separate translation unit, so its
// statics are invisible there, and the live-bus integration test only drives
// the method-reply side (the mock returns errors, never a Response signal).
// This is the only place the Response handler and the "free once both
// completions land" invariant, the reason the PortalRequest struct exists, get
// unit coverage.
//
//   cc portal_core.c -I../src -I../../include $(pkg-config --cflags --libs gtk4)

#include "portal.c"

// Records what on_response delivered, so a test can assert whether the callback
// fired, and with what.
typedef struct {
    int calls;
    guint32 response;
    gboolean had_results;
} Recorder;

static void record_response(guint32 response, GVariant *results, gpointer user_data) {
    Recorder *rec = user_data;
    rec->calls++;
    rec->response = response;
    rec->had_results = results != NULL;
}

// A fresh heap request wired to `rec`, both completions pending, with an empty
// subscription slot so portal_request_drop_subscription is a no-op and dbus may
// be NULL. Mirrors boo_portal_call's setup minus the live bus.
static PortalRequest *make_req(Recorder *rec, guint *slot) {
    PortalRequest *req = g_new0(PortalRequest, 1);
    req->subscription = slot;  // *slot == 0, so unsubscribe is never reached
    req->on_response = record_response;
    req->user_data = rec;
    req->signal_pending = TRUE;
    req->call_pending = TRUE;
    return req;
}

static int failures = 0;
static void check(gboolean ok, const char *label) {
    g_print("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    // A wrong-signature Response is dropped: no callback, but the request is
    // completed so the state machine does not stall. call_pending is cleared so
    // the release inside on_response frees req; nothing touches it afterward.
    {
        Recorder rec = {0};
        guint slot = 0;
        PortalRequest *req = make_req(&rec, &slot);
        req->call_pending = FALSE;
        GVariant *bad = g_variant_ref_sink(g_variant_new("(s)", "not a response"));
        on_response(NULL, NULL, NULL, NULL, NULL, bad, req);
        check(rec.calls == 0, "a wrong-signature Response invokes no callback");
        g_variant_unref(bad);
    }

    // A well-formed (ua{sv}) Response decodes the code and results dict and
    // dispatches exactly once. call_pending cleared so release frees req after.
    {
        Recorder rec = {0};
        guint slot = 0;
        PortalRequest *req = make_req(&rec, &slot);
        req->call_pending = FALSE;
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
        g_variant_builder_add(&b, "{sv}", "session_handle", g_variant_new_string("s"));
        GVariant *ok =
            g_variant_ref_sink(g_variant_new("(u@a{sv})", 42u, g_variant_builder_end(&b)));
        on_response(NULL, NULL, NULL, NULL, NULL, ok, req);
        check(rec.calls == 1, "a valid Response invokes the callback exactly once");
        check(rec.response == 42, "the response code is decoded from the tuple");
        check(rec.had_results, "the results dict is handed to the callback");
        g_variant_unref(ok);
    }

    // Reorder-safe free: the Response signal lands before the method reply
    // (call_pending still TRUE), so on_response fires the callback but must NOT
    // free the request; on_call_done will. Assert it survived, then free it.
    {
        Recorder rec = {0};
        guint slot = 0;
        PortalRequest *req = make_req(&rec, &slot);
        GVariant *ok =
            g_variant_ref_sink(g_variant_new("(u@a{sv})", 0u, g_variant_new("a{sv}", NULL)));
        on_response(NULL, NULL, NULL, NULL, NULL, ok, req);
        check(rec.calls == 1, "the callback fires on the early Response");
        check(!req->signal_pending, "the signal is marked complete");
        check(req->call_pending, "the request outlives on_response until the reply lands");
        g_free(req);  // stands in for on_call_done's later release
        g_variant_unref(ok);
    }

    g_print(failures ? "portal_core: FAIL\n" : "portal_core: ok\n");
    return failures ? 1 : 0;
}
