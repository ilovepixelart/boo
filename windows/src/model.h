// Whisper model discovery for the Windows apprt.
#ifndef BOO_MODEL_H
#define BOO_MODEL_H

#include <stddef.h>
#include <wchar.h>

// Search order: %BOO_MODEL%, %USERPROFILE%\.boo\models, .\models,
// %LOCALAPPDATA%\boo\models. Returns a malloc'd UTF-8 path (the process code
// page is UTF-8 via the manifest, so whisper's fopen accepts it), or NULL.
char *boo_model_find(void);

// Fills `buf` with the "no model installed" instructions, download command
// included, with the primary directory expanded for this user.
void boo_model_missing_hint(wchar_t *buf, size_t len);

#endif // BOO_MODEL_H
