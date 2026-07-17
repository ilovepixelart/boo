// Console-subsystem entry for the instrumented coverage build of the Windows
// app (scripts/coverage.sh, windows-native section). mingw gcc would need
// -municode to start at the real wWinMain, but the link goes through zig c++
// (for the whisper archive's bundled-libc++ ABI), which does not know that
// flag; a plain main() forwarding to wWinMain sidesteps it. The console
// window this opens is harmless on a CI runner.

#include <windows.h>

int WINAPI wWinMain(HINSTANCE hinst, HINSTANCE prev, PWSTR cmdline, int show);

int main(void) {
    return wWinMain(GetModuleHandleW(NULL), NULL, GetCommandLineW(), SW_SHOWNORMAL);
}
