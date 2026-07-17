// Model discovery, enumeration, and download, shared by the entry point
// (auto-discovery, onboarding dialog) and the settings model switcher.
#pragma once

#include <gtk/gtk.h>

#include "boo.h"

// Best usable speech model, or NULL. $BOO_MODEL wins outright, then the
// explicit Settings choice (see boo_saved_model_read), then the ranked scan
// of the model directories. Truncated files (boo_model_verify) are skipped
// everywhere. Caller frees.
char *boo_find_model_path(void);

// Best Silero VAD model, or NULL. $BOO_VAD_MODEL wins outright. Caller frees.
char *boo_find_vad_model_path(void);

// The writable models directory (created if missing). Caller frees.
char *boo_models_write_dir(void);

// Every usable speech model on disk (full paths), ranked most capable first
// (boo_model_rank, alphabetical tiebreak), deduplicated by filename so the
// first search directory shadows later ones, truncated files skipped.
// Free with g_ptr_array_unref.
GPtrArray *boo_installed_models(void);

// Stream one manifest model to the models directory with progress, verify its
// pinned SHA-256, and move it into place. `on_done` gets the final path (valid
// only during the call); `on_fail` gets a user-facing reason. Both fire on the
// main loop. The progress bar is ref'd for the transfer; the caller keeps any
// other UI (status, buttons, window deletability) itself.
typedef void (*BooDownloadDone)(const char *path, gpointer user_data);
typedef void (*BooDownloadFail)(const char *why, gpointer user_data);
void boo_model_download(const BooModelInfo *model, GtkProgressBar *progress,
                        BooDownloadDone on_done, BooDownloadFail on_fail,
                        gpointer user_data);
