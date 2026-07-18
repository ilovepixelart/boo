// Host-runnable tests for the pure Settings model-combo logic. No windows.h, so
// it runs on the Linux/macOS CI runners too:
//
//   cc -I windows/src windows/tests/modelsel_test.c windows/src/modelsel.c
//      -o modelsel_test && ./modelsel_test
//   (one command; a literal backslash here would trip gcc's -Wcomment)
//
// What it pins: the disk-vs-download partition boundary (an off-by-one there
// would swap a model load for a download or index past the arrays), the
// loaded-model lookup that positions the selection dot, and the decimal-MB
// truncation in the download row label.

#include "modelsel.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;
static void check(int ok, const char *label) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

int main(void) {
    // ── boo_model_pick: 3 on-disk, then 2 downloadable ──
    {
        int sub = -999;
        check(boo_model_pick(-1, 3, 2, &sub) == BOO_PICK_NONE,
              "a cleared combo (-1) picks nothing");
        check(boo_model_pick(0, 3, 2, &sub) == BOO_PICK_DISK && sub == 0,
              "index 0 is the first on-disk model");
        check(boo_model_pick(2, 3, 2, &sub) == BOO_PICK_DISK && sub == 2,
              "the last on-disk index maps straight through");
        check(boo_model_pick(3, 3, 2, &sub) == BOO_PICK_DOWNLOAD && sub == 0,
              "the first index past the disk models is download #0");
        check(boo_model_pick(4, 3, 2, &sub) == BOO_PICK_DOWNLOAD && sub == 1,
              "the last downloadable index maps to absent #1");
        check(boo_model_pick(5, 3, 2, &sub) == BOO_PICK_NONE,
              "an index past both lists picks nothing");
        // No downloadable models: everything past the disk list is nothing.
        check(boo_model_pick(3, 3, 0, &sub) == BOO_PICK_NONE,
              "no absent models means no download rows");
    }

    // ── boo_model_current_index: where the selection dot lands ──
    {
        const char *paths[] = {"/a/ggml-base.bin", "/b/ggml-small.bin",
                               "/c/ggml-large.bin"};
        check(boo_model_current_index(paths, 3, "/b/ggml-small.bin") == 1,
              "the loaded model resolves to its combo row");
        check(boo_model_current_index(paths, 3, "/x/none.bin") == -1,
              "a loaded model not in the list clears the selection");
        check(boo_model_current_index(paths, 3, NULL) == -1,
              "no loaded model clears the selection");
    }

    // ── boo_model_download_label: decimal-MB, truncating ──
    {
        char buf[64];
        boo_model_download_label(buf, sizeof(buf), "ggml-base.en.bin", 147000000ULL);
        check(strcmp(buf, "ggml-base.en.bin  (download, 147 MB)") == 0,
              "the label reports whole decimal megabytes");
        boo_model_download_label(buf, sizeof(buf), "tiny.bin", 999999ULL);
        check(strcmp(buf, "tiny.bin  (download, 0 MB)") == 0,
              "a sub-megabyte model truncates to 0 MB");
    }

    printf(failures ? "modelsel_test: FAIL\n" : "modelsel_test: ok\n");
    return failures ? 1 : 0;
}
