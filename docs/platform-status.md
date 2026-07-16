# Platform status in detail

What the [README's status table](../README.md#status) means, precisely. macOS is the reference implementation; the ledger below tracks the other two.

Linux ships as a **preview** Flatpak. Being precise about what that means, because "preview" usually isn't:

**Verified:**
- Builds and links against GTK4 / libadwaita / PipeWire (CI, every push).
- **Audio actually works.** In a real Ubuntu VM, Boo's PipeWire backend captured 6 s of speech (96,568 samples @ 16 kHz, RMS tracking the signal) and whisper transcribed it correctly. Reproduce with [`linux/tests/audio.sh`](../linux/tests/audio.sh).
- **GlobalShortcuts portal**: CreateSession → BindShortcuts (`toggle-record`, `CTRL+SHIFT+space`) → an `Activated` signal reaches Boo's callback. *(CI, every push.)*
- **RemoteDesktop portal**: CreateSession → SelectDevices (keyboard, persisted grant) → Start, and a paste emits exactly `Ctrl↓ Shift↓ V↓ V↑ Shift↑ Ctrl↑`. *(CI, every push.)*
- The restore token persists, so the permission prompt appears **once**, not every launch.

**Verified against real desktop portal backends, not just the mock:**
- **GNOME 46** (Ubuntu 24.04 LTS): RemoteDesktop is present; GlobalShortcuts is **absent** (the `.portal` manifest doesn't list it and a `CreateSession` returns "No such interface"). Boo detects this and says so (see [the Linux guide](install-linux.md#permissions)).
- **KDE Plasma**: its `xdg-desktop-portal-kde` manifest **does** declare GlobalShortcuts, and its backend serviced a real `CreateSession` (returning a proper Request path), so the hotkey is a live capability there, unlike GNOME 46.

**Not verified:**
- A full end-to-end hotkey *bind* on a live KDE/Hyprland session (KDE's Qt backend needs a real display, which a headless VM only partly provides). The interface is confirmed present and responsive; a human on real KDE hardware is the remaining check.
- The GTK4 UI has not been driven by a human on a real desktop.

**The Linux app is smaller than the macOS one:** no menu-bar item, no settings dialog, no theme picker, and it doesn't stay on top. Recording, transcription and auto-paste all work.

**Windows is experimental**, one notch below the Linux preview, and the label is precise:

**Verified:**
- The full app (Zig core + whisper + WASAPI backend + Win32 frontend) compiles and links for x86_64 and ARM64, natively on a Windows runner and cross-compiled from Linux/macOS (CI, every push).
- The core's unit tests, the audio maths, the SRWLOCK mutex shim, and the whole C ABI contract including the leak test, pass natively on Windows (CI, every push).
- The paste chord is pinned by a host-run unit test: exactly Ctrl+V reaches the target, with held Shift/Alt/Win released first ([`windows/tests/inject_plan_test.c`](../windows/tests/inject_plan_test.c)).

**Not verified:** nobody has yet run Boo on real Windows hardware, so microphone capture, the tray icon, the hotkey, focus behavior and auto-paste are design-validated but untested in the wild. The full checklist a human needs to run once is [`windows/tests/manual.md`](../windows/tests/manual.md); it is the gate for promoting Windows to preview. Streaming transcription is not wired into the Windows frontend yet; it transcribes when you stop, like the pre-streaming releases. Bug reports are genuinely useful here.
