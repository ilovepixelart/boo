// Pure paste-injection decisions: which key events to synthesize for the paste
// chord (given the modifiers the user is physically holding), and whether a
// synthesized paste should be attempted at all (given the window layout). No
// windows.h, so the unit test compiles and runs on any host
// (windows/tests/inject_plan_test.c).
#ifndef BOO_INJECT_PLAN_H
#define BOO_INJECT_PLAN_H

#include <stdbool.h>

// Virtual-key codes the plan can emit (mirror winuser.h values).
#define BOO_VK_SHIFT   0x10
#define BOO_VK_CONTROL 0x11
#define BOO_VK_MENU    0x12
#define BOO_VK_LWIN    0x5B
#define BOO_VK_RWIN    0x5C
#define BOO_VK_V       0x56

// Bitmask of physically held modifiers.
#define BOO_HELD_SHIFT 0x01
#define BOO_HELD_MENU  0x02
#define BOO_HELD_LWIN  0x04
#define BOO_HELD_RWIN  0x08

typedef enum { BOO_KEY_DOWN, BOO_KEY_UP } BooKeyAction;

typedef struct {
    unsigned short vk;
    BooKeyAction action;
} BooKeyEvent;

#define BOO_PLAN_MAX 8

// Fills `out` (capacity BOO_PLAN_MAX) with the events for a paste chord:
// key-ups for every held modifier that would corrupt Ctrl+V into a different
// chord (Shift, Alt, Win; a held Ctrl is harmless, the chord presses it
// anyway), then Ctrl down, V down, V up, Ctrl up. Returns the event count.
int boo_inject_plan_paste(unsigned held, BooKeyEvent *out);

// Whether a synthesized paste should be attempted at all: only when a target
// window exists, differs from Boo's own window, and is the current foreground
// (so the Ctrl+V lands where dictation started, not back in Boo). Handles are
// opaque pointers so this stays windows.h-free. false => clipboard only.
bool boo_inject_target_eligible(const void *target, const void *owner,
                                const void *foreground);

#endif // BOO_INJECT_PLAN_H
