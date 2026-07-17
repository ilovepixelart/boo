// UTF-8 <-> UTF-16 conversion, the one copy. Every returned buffer is
// malloc'd; the caller frees. NULL on conversion failure or OOM.
#ifndef BOO_STRCONV_H
#define BOO_STRCONV_H

#include "app.h"

char *boo_to_utf8(const WCHAR *wide);
WCHAR *boo_to_wide(const char *utf8);

#endif // BOO_STRCONV_H
