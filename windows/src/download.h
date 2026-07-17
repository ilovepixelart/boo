// Manifest model download for the Windows apprt: streams over WinHTTP on a
// worker thread to models\<name>.part, verifies the pinned SHA-256 (CNG),
// renames into place, and reports back to a window via messages:
//   BOO_MSG_DL_PROGRESS: wParam = percent downloaded (0..100)
//   BOO_MSG_DL_DONE: wParam = ok; lParam = malloc'd UTF-8 string the receiver
//   frees: the final model path on success, a user-facing reason on failure.
// The notify window must outlive the transfer (freeze its close button, like
// the model swap does); the manifest entry is static core storage.
#ifndef BOO_DOWNLOAD_H
#define BOO_DOWNLOAD_H

#include "app.h"

bool boo_download_start(HWND notify, const BooModelInfo *model);

#endif // BOO_DOWNLOAD_H
