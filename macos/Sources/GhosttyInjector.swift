// Ghostty fast-path: inject text through Ghostty's AppleScript API instead of
// synthesizing a Cmd+V keystroke.
//
// Ghostty 1.3+ exposes `input text ... to <terminal>`, which feeds the text
// straight into the terminal's pty as a paste. Compared to the generic
// clipboard + CGEvent route this:
//   - never touches the user's clipboard,
//   - honors bracketed paste and bypasses Ghostty's unsafe-paste prompt,
//   - keeps working while Secure Input is active (password prompts swallow
//     synthesized CGEvents — the classic dictation failure mode),
//   - needs only the one-time Automation permission, not Accessibility,
//   - reaches Ghostty's front window even when Ghostty isn't frontmost, so
//     the caller can skip re-activating it.
//
// The API is marked preview in Ghostty 1.3 ("expected API changes in 1.4"),
// and older Ghostty versions don't have it at all — so every failure here is
// non-fatal and the caller falls back to the CGEvent path.

import AppKit

enum GhosttyInjector {
    static let ghosttyBundleID = "com.mitchellh.ghostty"

    static func isGhostty(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier == ghosttyBundleID
    }

    /// Injects `text` into the focused terminal of Ghostty's front window.
    /// Returns false on any failure (Ghostty < 1.3, Automation permission
    /// denied, no terminal window) so the caller can fall back.
    static func inputText(_ text: String) -> Bool {
        let source = """
        tell application id "\(ghosttyBundleID)"
            input text "\(escapeForAppleScript(text))" to focused terminal of selected tab of front window
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            NSLog("Boo: Ghostty AppleScript injection failed, falling back to paste: %@", message)
            return false
        }
        return true
    }

    /// Escape a transcript for embedding in an AppleScript string literal.
    ///
    /// The transcript is interpolated into AppleScript source, so a stray quote
    /// could in principle break out of the literal and run arbitrary script. It
    /// can't: a literal is delimited solely by `"`, and its only escapes are the
    /// five below, so escaping backslash and quote closes the breakout. The
    /// order matters — backslash MUST be first, or the backslashes this adds to
    /// the quotes would themselves be doubled.
    ///
    /// Verified adversarially (see the repo's security notes): payloads such as
    /// `" & (do shell script "…") & "` round-trip through AppleScript exactly
    /// equal to the input, and no injected command runs. If you change this,
    /// re-run that check — it is a security boundary, not cosmetics.
    private static func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")   // must be first
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
