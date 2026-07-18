import Cocoa

/// Delivers a finished transcript into another app: Ghostty's direct AppleScript
/// API when the target is Ghostty, otherwise a clipboard-and-⌘V paste that
/// preserves whatever was on the clipboard before. Split out of OverlayWindow so
/// the delivery decision is not tangled into a 700-line NSWindow subclass. This
/// is the irreducible shell (Ghostty AppleScript, the Accessibility prompt,
/// async dispatch, CGEvent keystroke synthesis); the pure, unit-tested pieces
/// (clipboard snapshot/restore, keyboard-layout resolution) live in
/// PasteResolution.
enum TextDelivery {
    /// What happened, for the caller to surface in its status line.
    enum Outcome {
        case pasted  // delivered into the target (Ghostty or a synthesized ⌘V)
        case copiedNeedsAccessibility  // on the clipboard; ⌘V needs Accessibility
    }

    /// Deliver `text` to `target` (the last-focused non-Boo app, or nil for
    /// clipboard-only). `viaHotkey` means the target is already focused, so skip
    /// re-activation. `onOutcome` fires on the main queue once the outcome is
    /// known; the paste path resolves after a short settle delay.
    static func deliver(
        _ text: String, to target: NSRunningApplication?, viaHotkey: Bool,
        onOutcome: @escaping (Outcome) -> Void
    ) {
        // Ghostty fast-path: its AppleScript API (1.3+) writes into the pty
        // directly, no clipboard clobber, no re-activation, immune to Secure
        // Input. It addresses Ghostty's own front window, so Ghostty doesn't even
        // need to be frontmost. On any failure, fall through to the generic paste.
        if GhosttyInjector.isGhostty(target), GhosttyInjector.inputText(text) {
            onOutcome(.pasted)
            return
        }

        // Everything below synthesizes a ⌘V keystroke, which needs Accessibility.
        // Ask for it here, the first time it's actually required, rather than at
        // launch: the Ghostty path above never needs it, so a Ghostty user should
        // never see the "control this computer" prompt at all.
        guard PermissionsManager.requestAccessibilityIfNeeded() else {
            // Not granted (yet). The transcript is already on screen and about to
            // be copied, so the caller says what happened instead of going silent.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onOutcome(.copiedNeedsAccessibility)
            return
        }

        // Step 1: Put text on clipboard, snapshotting every format first so a
        // non-text clipboard (image, RTF, files) is restored rather than
        // destroyed by the transient transcript paste.
        let pasteboard = NSPasteboard.general
        let oldItems = PasteResolution.snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // The change count right after our write; if anything else writes the
        // clipboard before the restore fires, we must not clobber it.
        let stamp = pasteboard.changeCount

        // Step 2: If started via button click, re-activate the target app. If
        // started via hotkey, it is ALREADY focused, don't switch.
        if !viaHotkey, let app = target {
            app.activate()
        }

        // Step 3: Paste via clipboard, the most universally reliable method.
        // Hotkey path: the target app is already focused and the pasteboard write
        // above completed synchronously, so only a small settle delay remains;
        // with streaming transcription at ~50ms these sleeps are the bulk of
        // stop-to-pasted-text latency. Button path: 0.5s covers the re-activation.
        let delay = viaHotkey ? 0.05 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasted = performPaste()
            // A synthesized paste can be silently dropped (CGEvent creation
            // failed); report copied-not-pasted rather than a false "pasted", so
            // the transcript isn't reported delivered when it is only on the
            // clipboard.
            onOutcome(pasted ? .pasted : .copiedNeedsAccessibility)

            // Restore the prior clipboard 200ms later, but only if the paste
            // actually fired and nothing else has written the clipboard since:
            // a failed paste leaves the transcript for a manual ⌘V, and a fresh
            // copy the user made in the meantime must not be clobbered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if PasteResolution.shouldRestoreClipboard(
                    pasted: pasted, hadPriorItems: !oldItems.isEmpty,
                    currentChangeCount: pasteboard.changeCount, stamp: stamp)
                {
                    pasteboard.clearContents()
                    pasteboard.writeObjects(oldItems)
                }
            }
        }
    }

    /// Synthesize ⌘V. Returns false if the key events could not be created, so
    /// the caller can report copied-not-pasted instead of a false success.
    private static func performPaste() -> Bool {
        // CGEvent only, no AppleScript, no extra permission dialogs.
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = PasteResolution.pasteKeyCode
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        // Brief key-hold so slow event loops register the chord; 20ms is plenty
        // for ⌘V, and this sleep runs on the main thread.
        usleep(20000)
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
        return true
    }
}
