#include "history.h"

#include <stdlib.h>
#include <string.h>

void boo_history_push(void *items[], int *count, int cap, void *owned) {
    if (!owned) return;
    if (*count == cap) {
        free(items[0]);
        memmove(&items[0], &items[1], (size_t)(cap - 1) * sizeof(items[0]));
        (*count)--;
    }
    items[(*count)++] = owned;
}

void boo_history_remove(void *items[], int *count, int index) {
    if (index < 0 || index >= *count) return;
    free(items[index]);
    memmove(&items[index], &items[index + 1],
            (size_t)(*count - index - 1) * sizeof(items[0]));
    (*count)--;
}

size_t boo_utf8_trunc_len(const char *utf8, size_t start) {
    size_t len = start;
    while (len > 0 && ((unsigned char)utf8[len] & 0xC0) == 0x80) len--;
    return len;
}
