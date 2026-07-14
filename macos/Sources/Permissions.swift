import AVFoundation
import ApplicationServices
import Cocoa

enum PermissionsManager {

    /// Ask only for what Boo cannot work without, the microphone.
    ///
    /// Accessibility is deliberately NOT requested here. It is needed solely to
    /// synthesize the ⌘V fallback paste, and plenty of sessions never reach that
    /// path: dictating into Ghostty goes through its AppleScript API instead, and
    /// auto-type can be switched off entirely. Prompting up front showed everyone
    /// a "Boo would like to control this computer" dialog for a capability they
    /// might never use, the most alarming prompt we have, asked first, for no
    /// reason. It is now requested at the moment it is first actually needed.
    static func ensurePermissions() {
        requestMicrophone()
    }

    // MARK: - Accessibility (only for the ⌘V fallback paste)

    /// Is Accessibility already granted? Never prompts, safe to call on a timer.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Whether we've already shown the Accessibility prompt this launch.
    private static var didPromptAccessibility = false

    /// Ensure Accessibility, prompting **at most once per launch**.
    ///
    /// The subtlety that bit us: `AXIsProcessTrustedWithOptions` with the prompt
    /// option shows the system dialog *every* time it's called while untrusted ,
    /// not just the first. Since this is called on every fallback paste, calling
    /// the prompting variant each time meant a permission dialog on every single
    /// recording. So prompt once; after that, only the non-prompting check runs,
    /// and if it's still not granted the caller falls back to clipboard-only.
    @discardableResult
    static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }

        if !didPromptAccessibility {
            didPromptAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
            return AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        return false
    }

    // MARK: - Microphone (required, Boo does nothing without it)

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
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
