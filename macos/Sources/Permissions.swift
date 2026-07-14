import Cocoa
import ApplicationServices
import AVFoundation

enum PermissionsManager {

    /// Ask only for what Boo cannot work without — the microphone.
    ///
    /// Accessibility is deliberately NOT requested here. It is needed solely to
    /// synthesize the ⌘V fallback paste, and plenty of sessions never reach that
    /// path: dictating into Ghostty goes through its AppleScript API instead, and
    /// auto-type can be switched off entirely. Prompting up front showed everyone
    /// a "Boo would like to control this computer" dialog for a capability they
    /// might never use — the most alarming prompt we have, asked first, for no
    /// reason. It is now requested at the moment it is first actually needed.
    static func ensurePermissions() {
        requestMicrophone()
    }

    // MARK: - Accessibility (only for the ⌘V fallback paste)

    /// Is Accessibility already granted? Never prompts — safe to call on a timer.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt for Accessibility, but only if it isn't already granted.
    ///
    /// Passing kAXTrustedCheckOptionPrompt shows the system dialog when untrusted
    /// and does nothing when trusted, so the guard is belt-and-braces — it also
    /// keeps us from re-prompting a user who has already said no, and makes the
    /// intent obvious at the call site.
    @discardableResult
    static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Microphone (required — Boo does nothing without it)

    private static func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { NSLog("Boo: microphone access denied") }
            }

        case .denied, .restricted:
            DispatchQueue.main.async { showMicrophoneDeniedAlert() }

        @unknown default:
            break
        }
    }

    private static func showMicrophoneDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = """
            Boo needs microphone access for speech-to-text.

            Open System Settings > Privacy & Security > Microphone and enable Boo.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
