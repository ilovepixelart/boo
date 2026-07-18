#ifndef BOO_UTF8_H
#define BOO_UTF8_H

// Pure (no windows.h): UTF-8 helpers that the Win32-bound strconv.c cannot host.
// Host-testable (see windows/tests/utf8_test.c).

#include <stddef.h>

// The largest offset <= `start` at which `utf8` does not fall inside a
// multi-byte sequence: walks back off UTF-8 continuation bytes (10xxxxxx) so a
// truncated copy never splits a code point. `start` is a byte offset.
size_t boo_utf8_trunc_len(const char *utf8, size_t start);

#endif
