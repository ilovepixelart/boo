#ifndef BOO_MODELSEL_H
#define BOO_MODELSEL_H

// Pure (no windows.h): the Settings model-combo's index and label logic, split
// out of settings.c so the disk-vs-download partition, the loaded-model lookup,
// and the download-row label can be host-tested (see windows/tests/modelsel_test.c).

#include <stddef.h>
#include <stdint.h>

// What a combo selection refers to: nothing, an on-disk model, or a
// not-yet-downloaded manifest model.
enum { BOO_PICK_NONE, BOO_PICK_DISK, BOO_PICK_DOWNLOAD };

// Resolve a combo selection index. The combo lists `disk_count` on-disk models
// first, then `absent_count` downloadable ones. Returns a BOO_PICK_* kind and,
// for DISK/DOWNLOAD, writes the index within that sub-list to *out_index.
int boo_model_pick(int combo_index, int disk_count, int absent_count, int *out_index);

// The index of the loaded model (`current`, a UTF-8 path) among `paths`, or -1
// if none matches or `current` is NULL (-1 as a combo cursor clears it).
int boo_model_current_index(const char *const *paths, int count, const char *current);

// Format the "<filename>  (download, N MB)" row for a downloadable model, where
// N is size_bytes / 1e6 (decimal MB, truncated). Returns snprintf's result.
int boo_model_download_label(char *buf, size_t len, const char *filename,
                             uint64_t size_bytes);

#endif
