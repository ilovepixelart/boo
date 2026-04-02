import Cocoa
import ApplicationServices

class PermissionsManager {

    /// Check and request all required permissions on first launch
    static func ensurePermissions() {
        checkAccessibility()
        checkMicrophone()
    }

    // MARK: - Accessibility (required for auto-type / keyboard simulation)

    static func checkAccessibility() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if trusted {
            print("Permissions: Accessibility ✓")
        } else {
            print("Permissions: Accessibility — prompting user")
        }
    }

    // MARK: - Microphone (required for recording)

    static func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("Permissions: Microphone ✓")
        case .notDetermined:
            print("Permissions: Microphone — requesting")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("Permissions: Microphone \(granted ? "✓ granted" : "✗ denied")")
            }
        case .denied, .restricted:
            print("Permissions: Microphone ✗ denied — showing alert")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Microphone Access Required"
                alert.informativeText = "Boo needs microphone access for speech-to-text.\n\nGo to System Settings > Privacy & Security > Microphone and enable Boo."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
        @unknown default:
            break
        }
    }
}

// AVCaptureDevice needs AVFoundation
import AVFoundation
