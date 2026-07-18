#ifndef BOO_HISTORY_H
#define BOO_HISTORY_H

// Pure (no windows.h): the overlay transcript history's bounded-FIFO policy and
// the UTF-8 display-truncation boundary, split out of overlay.c so the
// eviction, index-removal, and multi-byte-boundary logic can be tested on any
// host (see windows/tests/history_test.c). The stored pointers are malloc'd by
// the caller; an evicted or removed entry is freed here.

#include <stddef.h>

// Append `owned` to items[0..*count), keeping at most `cap` entries. At capacity
// the oldest (items[0]) is freed and the survivors shift down before the append,
// so items[0] is always the oldest. A NULL `owned` is a no-op.
void boo_history_push(void *items[], int *count, int cap, void *owned);

// Free items[index] and shift the tail down to close the gap. An out-of-range
// index is a no-op.
void boo_history_remove(void *items[], int *count, int index);

// The largest offset <= `start` at which `utf8` does not fall inside a
// multi-byte sequence: walks back off UTF-8 continuation bytes (10xxxxxx) so a
// truncated display copy never splits a code point. `start` is a byte offset.
size_t boo_utf8_trunc_len(const char *utf8, size_t start);

#endif
