// First-run model onboarding for Windows: a curated model dropdown
// (boo_models), a progress bar, Download, and Choose a File, mirroring the
// macOS/Linux flow (docs/model-onboarding.md). Opened when no model is
// installed; a successful download or pick boots the app (boo_app_start) and
// closes the dialog. Closing it with the app not started quits.
#ifndef BOO_ONBOARDING_H
#define BOO_ONBOARDING_H

#include "app.h"

// Shared with the coverage smoke driver (windows/tests/drive_app.c), which
// closes the first-run dialog to exercise the quit-without-a-model path.
#define BOO_ONBOARDING_CLASS L"BooOnboarding"

// False when the dialog cannot be created (the caller falls back to the
// static instructions dialog and quits).
bool boo_onboarding_open(BooApp *app);

#endif // BOO_ONBOARDING_H
