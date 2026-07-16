// Host-runnable test for the pure paste-chord planner. No windows.h, so it
// compiles with any C compiler and runs in CI on Linux/macOS runners:
//
//   cc -I windows/src windows/tests/inject_plan_test.c
//      windows/src/inject_plan.c -o inject_plan_test && ./inject_plan_test
//   (one command; a literal backslash here would trip gcc's -Wcomment)
//
// What it pins down: the chord that reaches the target app must be exactly
// Ctrl+V. A physically held Shift/Alt/Win that is not released first turns it
// into a different shortcut entirely (the Ctrl+Shift+V bug this design
// exists to avoid), and a released Ctrl would break the chord itself.

#include "inject_plan.h"

#include <assert.h>
#include <stdio.h>

static void expect_chord_at(const BooKeyEvent *ev, int start) {
    assert(ev[start + 0].vk == BOO_VK_CONTROL && ev[start + 0].action == BOO_KEY_DOWN);
    assert(ev[start + 1].vk == BOO_VK_V && ev[start + 1].action == BOO_KEY_DOWN);
    assert(ev[start + 2].vk == BOO_VK_V && ev[start + 2].action == BOO_KEY_UP);
    assert(ev[start + 3].vk == BOO_VK_CONTROL && ev[start + 3].action == BOO_KEY_UP);
}

static void test_no_modifiers_is_a_bare_chord(void) {
    BooKeyEvent ev[BOO_PLAN_MAX];
    int n = boo_inject_plan_paste(0, ev);
    assert(n == 4);
    expect_chord_at(ev, 0);
}

static void test_held_shift_is_released_before_the_chord(void) {
    // The regression this guards: user still holds Ctrl+Shift from the
    // hotkey; without the release the target receives Ctrl+Shift+V.
    BooKeyEvent ev[BOO_PLAN_MAX];
    int n = boo_inject_plan_paste(BOO_HELD_SHIFT, ev);
    assert(n == 5);
    assert(ev[0].vk == BOO_VK_SHIFT && ev[0].action == BOO_KEY_UP);
    expect_chord_at(ev, 1);
}

static void test_every_interfering_modifier_is_released(void) {
    BooKeyEvent ev[BOO_PLAN_MAX];
    unsigned all = BOO_HELD_SHIFT | BOO_HELD_MENU | BOO_HELD_LWIN | BOO_HELD_RWIN;
    int n = boo_inject_plan_paste(all, ev);
    assert(n == 8);
    for (int i = 0; i < 4; i++) {
        assert(ev[i].action == BOO_KEY_UP);
        // A held Ctrl is never released: the chord presses it anyway.
        assert(ev[i].vk != BOO_VK_CONTROL);
    }
    expect_chord_at(ev, 4);
}

int main(void) {
    test_no_modifiers_is_a_bare_chord();
    test_held_shift_is_released_before_the_chord();
    test_every_interfering_modifier_is_released();
    printf("inject_plan: all tests passed\n");
    return 0;
}
