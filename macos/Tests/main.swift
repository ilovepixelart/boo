// Swift unit-test harness, compiled together with the sources under test by
// scripts/coverage.sh (plain swiftc, no Xcode project), mirroring the C test
// harnesses. Prints one line per check and exits nonzero on any failure.
//
// What it pins: GhosttyInjector's subroutine event, the injection security
// boundary. The transcript must reach the boo_inject handler byte-identical
// as event DATA, never as script source, so no payload can execute. The
// round-trip goes through a local echo handler, so no Ghostty (and no
// Automation permission) is needed. Plus ThemeManager against the REAL core
// parser (the harness links libboo-core): the full Ghostty theme set loads,
// the default is present, and selection stays in bounds.

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

// Theme handling through the REAL core parser (boo_theme_parse_file): the
// harness runs from the repo root, so ThemeManager finds ./themes and parses
// the full Ghostty set. Pins the load, the default, and selection bounds.
let themes = ThemeManager.shared
check(themes.themes.count >= 400, "parses the Ghostty theme set (\(themes.themes.count) themes)")
check(
    themes.themes.contains { $0.name == "Ghostty Default Style Dark" },
    "the default theme is present")
check(
    themes.current.palette.count == 16,
    "a theme carries the full 16-color palette")

let originalIndex = themes.currentIndex
themes.selectTheme(at: -1)
check(themes.currentIndex == originalIndex, "negative selection is ignored")
themes.selectTheme(at: themes.themes.count)
check(themes.currentIndex == originalIndex, "past-the-end selection is ignored")
if themes.themes.count > 1 {
    let target = (originalIndex + 1) % themes.themes.count
    themes.selectTheme(at: target)
    check(themes.currentIndex == target, "selectTheme moves the current index")
    check(themes.current.name == themes.themes[target].name, "current follows the index")
}

// ModelDownloader's error path: a bad manifest URL must surface through
// onFail (callers freeze their UI before calling start), never return
// silently and leave a dead dialog.
var urlFails = 0
let badModel = BooModelInfo(
    filename: strdup("x.bin"), url: strdup(""), sha256: strdup("00"),
    label: strdup("x"), note: strdup("x"), size: 1)
ModelDownloader(
    onProgress: { _ in }, onDone: { _ in },
    onFail: { _ in urlFails += 1 }
).start(model: badModel)
check(urlFails == 1, "a bad download URL reports through onFail")

exit(failures == 0 ? 0 : 1)
