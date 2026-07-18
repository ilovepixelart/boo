#include "modelsel.h"

#include <stdio.h>
#include <string.h>

int boo_model_pick(int combo_index, int disk_count, int absent_count, int *out_index) {
    if (combo_index < 0) return BOO_PICK_NONE;
    if (combo_index < disk_count) {
        *out_index = combo_index;
        return BOO_PICK_DISK;
    }
    const int absent_index = combo_index - disk_count;
    if (absent_index < absent_count) {
        *out_index = absent_index;
        return BOO_PICK_DOWNLOAD;
    }
    return BOO_PICK_NONE;
}

int boo_model_current_index(const char *const *paths, int count, const char *current) {
    if (!current) return -1;
    for (int i = 0; i < count; i++)
        if (strcmp(paths[i], current) == 0) return i;
    return -1;
}

int boo_model_download_label(char *buf, size_t len, const char *filename,
                             uint64_t size_bytes) {
    return snprintf(buf, len, "%s  (download, %u MB)", filename,
                    (unsigned)(size_bytes / 1000000));
}
