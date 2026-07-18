import Carbon
import Cocoa

/// Delivers a finished transcript into another app: Ghostty's direct AppleScript
/// API when the target is Ghostty, otherwise a clipboard-and-⌘V paste that
/// preserves whatever was on the clipboard before. Split out of OverlayWindow so
/// the delivery decision, the clipboard snapshot/restore, and the keyboard-layout
/// resolution are not tangled into a 700-line NSWindow subclass, and so the parts
/// that carry no window state can be unit-tested in isolation.
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
        let oldItems = snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
            performPaste()
            onOutcome(.pasted)  // the explicit per-action outcome the spec asks for (§4.5)

            // Restore clipboard quickly, 200ms is enough for paste to complete.
            // Only when there was prior content, else the transcript stays put (a
            // deliberate re-paste convenience), matching the old behavior.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !oldItems.isEmpty {
                    pasteboard.clearContents()
                    pasteboard.writeObjects(oldItems)
                }
            }
        }
    }

    /// Deep-copy every pasteboard item across all its types, so the snapshot
    /// survives the clearContents that follows. Promised (lazy) data that a
    /// provider won't resolve synchronously is skipped, best-effort.
    static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        return (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func performPaste() {
        // CGEvent only, no AppleScript, no extra permission dialogs.
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = pasteKeyCode
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            return
        }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        // Brief key-hold so slow event loops register the chord; 20ms is plenty
        // for ⌘V, and this sleep runs on the main thread.
        usleep(20000)
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
    }

    // The virtual key that types "v" on the active keyboard layout. Hardcoding
    // 0x09 (QWERTY) meant ⌘V on Dvorak/AZERTY/Colemak pasted the wrong key or
    // nothing, and the transcript was then lost when the clipboard was restored.
    // Resolved per paste, not cached: the layout can change mid-session, and a
    // cached first-layout keycode would then paste the wrong key. The TIS scan is
    // cheap and pastes are user-paced. QWERTY's 0x09 is the fallback.
    static var pasteKeyCode: CGKeyCode { resolveKeyCode(for: "v") ?? 0x09 }

    static func resolveKeyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            let keyLayout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            // Scan the keyboard's virtual keys for the one that, unmodified,
            // produces the target character.
            for code in 0..<128 as Range<CGKeyCode> {
                let status = UCKeyTranslate(
                    keyLayout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars)
                // UnicodeScalar is failable: a lone surrogate (0xD800-0xDFFF)
                // yields nil, so bind rather than force-unwrap and crash.
                if status == noErr, length == 1, let scalar = UnicodeScalar(chars[0]),
                    Character(scalar) == character
                {
                    return code
                }
            }
            return nil
        }
    }
}
