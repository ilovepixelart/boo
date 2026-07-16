// Transcript delivery: clipboard, then a synthesized Ctrl+V.
#ifndef BOO_INJECT_H
#define BOO_INJECT_H

#include "app.h"

typedef enum {
    BOO_DELIVER_FAILED,    // not even the clipboard worked
    BOO_DELIVER_CLIPBOARD, // on the clipboard; paste was skipped or unsafe
    BOO_DELIVER_PASTED,    // on the clipboard and pasted into the target
} BooDeliverResult;

// Puts `utf8` on the clipboard (owned by `owner`'s window) and, when `target`
// is still the foreground window, pastes it there with a synthesized Ctrl+V.
// Never pastes anywhere else: if focus moved during transcription the
// transcript stays on the clipboard instead of landing in the wrong app.
BooDeliverResult boo_inject_deliver(HWND owner, HWND target, const char *utf8);

#endif // BOO_INJECT_H
