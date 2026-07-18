#ifndef BOO_HISTORY_H
#define BOO_HISTORY_H

// Pure (no windows.h): the overlay transcript history's bounded-FIFO policy,
// split out of overlay.c so the eviction and index-removal logic can be tested
// on any host (see windows/tests/history_test.c). The stored pointers are
// malloc'd by the caller; an evicted or removed entry is freed here.

// Append `owned` to items[0..*count), keeping at most `cap` entries. At capacity
// the oldest (items[0]) is freed and the survivors shift down before the append,
// so items[0] is always the oldest. A NULL `owned` is a no-op.
void boo_history_push(void *items[], int *count, int cap, void *owned);

// Free items[index] and shift the tail down to close the gap. An out-of-range
// index is a no-op.
void boo_history_remove(void *items[], int *count, int index);

#endif
