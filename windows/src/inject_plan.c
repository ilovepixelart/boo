// Pure paste-chord planner. See inject_plan.h.
//
// Why key-ups first: SendInput does not reset keyboard state, so a user still
// physically holding Shift from the Ctrl+Shift+Space hotkey would turn the
// injected Ctrl+V into Ctrl+Shift+V. The caller waits for the modifiers to
// lift first (the polite path); whatever is still held after the wait gets an
// explicit key-up here (the PowerToys path).

#include "inject_plan.h"

int boo_inject_plan_paste(unsigned held, BooKeyEvent *out) {
    int n = 0;

    if (held & BOO_HELD_SHIFT) out[n++] = (BooKeyEvent){BOO_VK_SHIFT, BOO_KEY_UP};
    if (held & BOO_HELD_MENU) out[n++] = (BooKeyEvent){BOO_VK_MENU, BOO_KEY_UP};
    if (held & BOO_HELD_LWIN) out[n++] = (BooKeyEvent){BOO_VK_LWIN, BOO_KEY_UP};
    if (held & BOO_HELD_RWIN) out[n++] = (BooKeyEvent){BOO_VK_RWIN, BOO_KEY_UP};

    out[n++] = (BooKeyEvent){BOO_VK_CONTROL, BOO_KEY_DOWN};
    out[n++] = (BooKeyEvent){BOO_VK_V, BOO_KEY_DOWN};
    out[n++] = (BooKeyEvent){BOO_VK_V, BOO_KEY_UP};
    out[n++] = (BooKeyEvent){BOO_VK_CONTROL, BOO_KEY_UP};

    return n;
}
