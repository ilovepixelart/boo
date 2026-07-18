import Carbon
import Cocoa

/// The pure, host-testable pieces of text delivery, split out of TextDelivery so
/// the clipboard snapshot/restore decision and the keyboard-layout resolution
/// can be unit-tested in isolation while TextDelivery keeps only the CGEvent and
/// async-dispatch shell. See macos/Tests/main.swift.
enum PasteResolution {
    /// Whether to restore the prior clipboard after a paste: only when the paste
    /// actually fired, there was prior content to restore, and nothing else has
    /// written the clipboard since our own write (comparing the change count to
    /// the stamp taken right after we wrote), so a fresh user copy is not
    /// clobbered and a failed paste leaves the transcript for a manual ⌘V.
    static func shouldRestoreClipboard(
        pasted: Bool, hadPriorItems: Bool, currentChangeCount: Int, stamp: Int
    ) -> Bool {
        pasted && hadPriorItems && currentChangeCount == stamp
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
