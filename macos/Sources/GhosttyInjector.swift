// Ghostty fast-path: inject text through Ghostty's AppleScript API instead of
// synthesizing a Cmd+V keystroke.
//
// Ghostty 1.3+ exposes `input text ... to <terminal>`, which feeds the text
// straight into the terminal's pty as a paste. Compared to the generic
// clipboard + CGEvent route this:
//   - never touches the user's clipboard,
//   - honors bracketed paste and bypasses Ghostty's unsafe-paste prompt,
//   - keeps working while Secure Input is active (password prompts swallow
//     synthesized CGEvents, the classic dictation failure mode),
//   - needs only the one-time Automation permission, not Accessibility,
//   - reaches Ghostty's front window even when Ghostty isn't frontmost, so
//     the caller can skip re-activating it.
//
// The API is marked preview in Ghostty 1.3 ("expected API changes in 1.4"),
// and older Ghostty versions don't have it at all, so every failure here is
// non-fatal and the caller falls back to the CGEvent path.

import AppKit
import Carbon

enum GhosttyInjector {
    static let ghosttyBundleID = "com.mitchellh.ghostty"

    static func isGhostty(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier == ghosttyBundleID
    }

    /// The script is a fixed handler; the transcript reaches it as an Apple
    /// event parameter (see `inputText`), never as script source, so no
    /// transcript content can become code. This is a security boundary
    /// (see SECURITY.md): if you rework it, keep the text out of the source.
    private static let injectSource = """
        on boo_inject(theText)
            tell application id "\(ghosttyBundleID)"
                input text theText to focused terminal of selected tab of front window
            end tell
        end boo_inject
        """

    /// The subroutine event that carries `text` into the script's boo_inject
    /// handler as its single parameter; the subroutine name must be the
    /// lowercase form of the handler identifier. Split from inputText so the
    /// test harness (macos/Tests) can prove the text arrives byte-identical,
    /// and that none of it executes, without talking to Ghostty.
    static func injectEvent(_ text: String) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(
            NSAppleEventDescriptor(string: "boo_inject"),
            forKeyword: AEKeyword(keyASSubroutineName))
        let params = NSAppleEventDescriptor.list()
        params.insert(NSAppleEventDescriptor(string: text), at: 1)
        event.setParam(params, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    /// Injects `text` into the focused terminal of Ghostty's front window.
    /// Returns false on any failure (Ghostty < 1.3, Automation permission
    /// denied, no terminal window) so the caller can fall back.
    static func inputText(_ text: String) -> Bool {
        guard let script = NSAppleScript(source: injectSource) else { return false }

        var error: NSDictionary?
        script.executeAppleEvent(injectEvent(text), error: &error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            NSLog("Boo: Ghostty AppleScript injection failed, falling back to paste: %@", message)
            return false
        }
        return true
    }
}
