// Host-runnable tests for the pure overlay transcript-history policy. No
// windows.h, so it compiles with any C compiler and runs on the Linux/macOS CI
// runners too:
//
//   cc -I windows/src windows/tests/history_test.c windows/src/history.c
//      -o history_test && ./history_test
//   (one command; a literal backslash here would trip gcc's -Wcomment)
//
// What it pins: the bounded FIFO evicts the OLDEST at capacity and keeps the
// rest in order (a wrong memmove or count would reorder the transcript history),
// and index removal closes the gap without disturbing the survivors.

#include "history.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static int failures = 0;
static void check(int ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// A heap marker tagged with the push order, so FIFO order survives across
// evictions and removals without dereferencing an entry the module has freed.
static int *marker(int v) {
    int *p = malloc(sizeof(int));
    if (p) *p = v;
    return p;
}

static void free_all(void *items[], int count) {
    for (int i = 0; i < count; i++) free(items[i]);
}

int main(void) {
    // ── bounded FIFO: fills, then evicts the oldest and preserves order ──
    {
        void *items[4] = {0};
        int count = 0;
        for (int i = 0; i < 4; i++) boo_history_push(items, &count, 4, marker(i));
        check(count == 4, "fills to capacity");
        boo_history_push(items, &count, 4, marker(4)); // evicts marker 0
        check(count == 4, "stays at capacity after overflow");
        check(*(int *)items[0] == 1 && *(int *)items[3] == 4,
              "the oldest entry is evicted and the newest appended last");
        int ordered = 1;
        for (int i = 0; i < 4; i++)
            if (*(int *)items[i] != i + 1) ordered = 0;
        check(ordered, "the survivors keep chronological order after eviction");
        free_all(items, count);
    }

    // ── a NULL push is ignored (a failed card conversion must not grow count) ──
    {
        void *items[4] = {0};
        int count = 0;
        boo_history_push(items, &count, 4, marker(0));
        boo_history_push(items, &count, 4, NULL);
        check(count == 1, "a NULL entry is not stored");
        free_all(items, count);
    }

    // ── index removal closes the gap without touching the survivors ──
    {
        void *items[4] = {0};
        int count = 0;
        for (int i = 0; i < 4; i++) boo_history_push(items, &count, 4, marker(i));
        boo_history_remove(items, &count, 1); // drop marker 1
        check(count == 3, "removal shrinks the count");
        check(*(int *)items[0] == 0 && *(int *)items[1] == 2 && *(int *)items[2] == 3,
              "removal closes the gap and keeps the rest in order");
        boo_history_remove(items, &count, 9); // out of range
        boo_history_remove(items, &count, -1);
        check(count == 3, "an out-of-range removal is a no-op");
        free_all(items, count);
    }

    printf(failures ? "history_test: FAIL\n" : "history_test: ok\n");
    return failures ? 1 : 0;
}
