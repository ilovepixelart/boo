#include "utf8.h"

size_t boo_utf8_trunc_len(const char *utf8, size_t start) {
    size_t len = start;
    while (len > 0 && ((unsigned char)utf8[len] & 0xC0) == 0x80) len--;
    return len;
}
