// Swift unit-test harness, compiled together with the sources under test by
// scripts/coverage.sh (plain swiftc, no Xcode project), mirroring the C test
// harnesses. Prints one line per check and exits nonzero on any failure.
//
// What it pins: GhosttyInjector's subroutine event, the injection security
// boundary. The transcript must reach the boo_inject handler byte-identical
// as event DATA, never as script source, so no payload can execute. The
// round-trip goes through a local echo handler, so no Ghostty (and no
// Automation permission) is needed.

import AppKit

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print("\(ok ? "  ok  " : "  FAIL") \(label)")
    if !ok { failures += 1 }
}

// isGhostty keys strictly off the bundle id; a bare test binary has none.
check(!GhosttyInjector.isGhostty(nil), "nil app is not Ghostty")
check(!GhosttyInjector.isGhostty(NSRunningApplication.current), "this process is not Ghostty")

// Round-trip every payload shape through a local boo_inject handler: the
// event must dispatch by name, and the text must arrive exactly as sent.
let echo = NSAppleScript(
    source: """
        on boo_inject(theText)
            return theText
        end boo_inject
        """)!

let payloads = [
    "hello world",
    "\" & (do shell script \"touch /tmp/boo-test-canary\") & \"",
    "back\\slash \"quotes\"\nnewline\ttab\rcr",
    "unicode ✨ émojis 日本語",
    "tell application \"Finder\" to activate",
]
for payload in payloads {
    var error: NSDictionary?
    let result = echo.executeAppleEvent(GhosttyInjector.injectEvent(payload), error: &error)
    check(
        error == nil && result.stringValue == payload,
        "round-trips \(payload.debugDescription)")
}
check(
    !FileManager.default.fileExists(atPath: "/tmp/boo-test-canary"),
    "no payload executed (no canary file)")

exit(failures == 0 ? 0 : 1)
