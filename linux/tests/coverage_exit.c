// Linked ONLY into the instrumented smoke build (scripts/coverage.sh):
// ui-smoke.sh stops the app with SIGTERM, which would end the process without
// running gcov's atexit hook, silently discarding every counter. Turn SIGTERM
// into exit() so the .gcda files actually flush. exit() from a handler is not
// async-signal-safe; acceptable for a coverage harness that is about to die.
#include <signal.h>
#include <stdlib.h>

static void on_term(int sig) {
    (void)sig;
    exit(0);
}

__attribute__((constructor)) static void install_term_exit(void) {
    signal(SIGTERM, on_term);
}
