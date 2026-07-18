#include "tray_fmt.h"

int boo_tray_elapsed_tip(wchar_t *out, size_t cap, int seconds) {
    if (seconds < 60) {
        return swprintf(out, cap, L"Boo, recording %ds", seconds);
    }
    return swprintf(out, cap, L"Boo, recording %d:%02d", seconds / 60, seconds % 60);
}
