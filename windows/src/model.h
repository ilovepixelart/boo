// Whisper model discovery for the Windows apprt.
#ifndef BOO_MODEL_H
#define BOO_MODEL_H

#include <stddef.h>
#include <wchar.h>

// Search order: %BOO_MODEL%, the model the user picked in Settings
// (HKCU\Software\Boo\Model), %USERPROFILE%\.boo\models, .\models,
// %LOCALAPPDATA%\boo\models. Truncated files (boo_model_verify) are skipped.
// Returns a malloc'd UTF-8 path (the process code page is UTF-8 via the
// manifest, so whisper's fopen accepts it), or NULL.
char *boo_model_find(void);

// Every usable speech model on disk for the Settings dropdown: malloc'd
// UTF-8 full paths into *out (caller frees each and the array), ranked most
// capable first, deduplicated by filename, truncated files skipped. Returns
// the count.
int boo_model_installed(char ***out);

// The filename part of a UTF-8 path (after the last slash or backslash).
const char *boo_model_basename(const char *path);

// Best Silero VAD model on disk (first alphabetically, so a newer version
// wins), as a malloc'd UTF-8 path, or NULL. %BOO_VAD_MODEL% wins outright,
// matching the other frontends.
char *boo_model_find_vad(void);

// Fills `buf` with the "no model installed" instructions, download command
// included, with the primary directory expanded for this user.
void boo_model_missing_hint(wchar_t *buf, size_t len);

#endif // BOO_MODEL_H
