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
// the default is present, and selection stays in bounds. Then the UI layer:
// ModelDownloader against a local HTTP server, the Settings and onboarding
// windows headless, and (BOO_HARNESS_BOOT=1, the CI macOS job) a full app
// boot around a real model. The boot stays opt-in because on a dev machine
// it would grab the microphone TCC prompt and the global hotkey.
//
// UserDefaults writes here land in the bare binary's own domain, never in
// Boo.app's, so the checks may set and clear preferences freely.

import AppKit
import CryptoKit

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print("\(ok ? "  ok  " : "  FAIL") \(label)")
    if !ok { failures += 1 }
}

/// Pump the main run loop until `done` (downloader closures and model swaps
/// hop through the main queue); false on timeout.
func pump(seconds: TimeInterval, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return done()
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

// inputText's fallback: with Ghostty absent the AppleScript engine cannot
// resolve its bundle id, so injection fails cleanly and the caller pastes
// instead. Guarded on Ghostty's absence so a machine that has it installed
// never launches it or trips the Automation prompt here.
if NSWorkspace.shared.urlForApplication(withBundleIdentifier: GhosttyInjector.ghosttyBundleID) == nil {
    check(
        !GhosttyInjector.inputText("harness fallback"),
        "inputText reports failure when Ghostty is unavailable")
}

// ── PermissionsManager (non-prompting Accessibility check) ──
// hasAccessibility forwards AXIsProcessTrusted; requestAccessibilityIfNeeded
// returns that same trust and, once run, stays stable so a granted paste never
// re-prompts. The mic TCC prompt and the denied-mic modal need a user at the
// machine, so they stay uncovered.
let axTrusted = PermissionsManager.hasAccessibility
check(
    PermissionsManager.requestAccessibilityIfNeeded() == axTrusted,
    "requestAccessibilityIfNeeded reports the current Accessibility trust")
check(
    PermissionsManager.requestAccessibilityIfNeeded() == axTrusted,
    "a repeat Accessibility check stays stable and never re-prompts")

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

// The palette accessors and the surface-tint helper: pure color math the app
// only reaches once a theme is applied to a live overlay.
func rgba(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return (r, g, b, a)
}
let paletteTheme = themes.current
check(
    paletteTheme.green == paletteTheme.palette[10] && paletteTheme.blue == paletteTheme.palette[12]
        && paletteTheme.magenta == paletteTheme.palette[13] && paletteTheme.white == paletteTheme.palette[15],
    "the palette accessors map to their ANSI indices")
let surf = rgba(paletteTheme.surfaceColor(0.5))
let base = rgba(paletteTheme.bg)
check(
    surf.a == 0.5 && surf.r >= base.r && surf.g >= base.g && surf.b >= base.b,
    "surfaceColor lightens the background and takes the given alpha")
let brightTheme = BooTheme(
    name: "bright", bg: NSColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1), fg: .white,
    palette: Array(repeating: .white, count: 16))
let clamped = rgba(brightTheme.surfaceColor(1))
check(clamped.r == 1 && clamped.g == 1 && clamped.b == 1, "surfaceColor clamps each channel at 1")

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

// ── ModelDownloader against a local HTTP server ──
// A real download end to end: progress, SHA-256 verify, install into
// ~/.boo/models, and the checksum-mismatch failure. The payload's name is not
// ggml-*, so model discovery can never pick the leftover up even if cleanup
// fails.

_ = NSApplication.shared  // windows + run loop below need the app object

let serveDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("boo-harness-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: serveDir, withIntermediateDirectories: true)
let payload = Data("boo harness payload".utf8)
try? payload.write(to: serveDir.appendingPathComponent("boo-harness-test.bin"))
let payloadSha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

let server = Process()
server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
server.arguments = [
    "python3", "-c",
    """
    import http.server, socketserver, sys, os
    os.chdir(sys.argv[1])
    httpd = socketserver.TCPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
    """,
    serveDir.path,
]
let serverOut = Pipe()
server.standardOutput = serverOut
server.standardError = FileHandle.nullDevice
var port = 0
do {
    try server.run()
    if let line = String(
        data: serverOut.fileHandleForReading.availableData, encoding: .utf8)
    {
        port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
} catch {
    port = 0
}
check(port > 0, "local HTTP server is up (port \(port))")

if port > 0 {
    func harnessModel(sha: String) -> BooModelInfo {
        BooModelInfo(
            filename: strdup("boo-harness-test.bin"),
            url: strdup("http://127.0.0.1:\(port)/boo-harness-test.bin"),
            sha256: strdup(sha), label: strdup("harness"), note: strdup("harness"),
            size: UInt64(payload.count))
    }

    var donePath: String?
    var progressed = false
    var failWhy: String?
    ModelDownloader(
        onProgress: { progressed = $0 > 0 },
        onDone: { donePath = $0 },
        onFail: { failWhy = $0 }
    ).start(model: harnessModel(sha: payloadSha))
    check(
        pump(seconds: 30, until: { donePath != nil || failWhy != nil }) && failWhy == nil,
        "a good download completes (\(failWhy ?? "ok"))")
    check(progressed, "progress was reported")
    check(
        donePath?.hasSuffix(".boo/models/boo-harness-test.bin") == true,
        "the verified file lands in ~/.boo/models")
    if let done = donePath {
        check(FileManager.default.fileExists(atPath: done), "the installed file exists")
        try? FileManager.default.removeItem(atPath: done)
    }

    donePath = nil
    failWhy = nil
    ModelDownloader(
        onProgress: { _ in },
        onDone: { donePath = $0 },
        onFail: { failWhy = $0 }
    ).start(model: harnessModel(sha: String(repeating: "0", count: 64)))
    check(
        pump(seconds: 30, until: { donePath != nil || failWhy != nil }) && donePath == nil,
        "a wrong pin refuses the download")
    check(failWhy?.contains("checksum") == true, "the failure names the checksum")
}
server.terminate()
try? FileManager.default.removeItem(at: serveDir)

// ── WaveformView drawn headless ──
// The view's job is to make recording / transcribing / idle visually distinct;
// assert that, not merely that a frame rendered. Each state is cached to its
// own bitmap and the pixels compared: recording draws amplitude-scaled bars,
// transcribing a breathing sine, idle flat minimal bars, so a state that
// rendered identically to idle would mean the state never reached drawing.
let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
let bars = (0..<40).map { Float($0 % 5) / 5.0 }
func renderWave(peak: Float, recording: Bool, transcribing: Bool) -> Data? {
    wave.update(waveform: bars, peakRms: peak, isRecording: recording, isTranscribing: transcribing)
    guard let rep = wave.bitmapImageRepForCachingDisplay(in: wave.bounds) else { return nil }
    wave.cacheDisplay(in: wave.bounds, to: rep)
    return rep.tiffRepresentation
}
let recordingFrame = renderWave(peak: 0.8, recording: true, transcribing: false)
let transcribingFrame = renderWave(peak: 0, recording: false, transcribing: true)
let idleFrame = renderWave(peak: 0, recording: false, transcribing: false)
check(
    idleFrame != nil && recordingFrame != nil && recordingFrame != idleFrame,
    "the recording waveform renders amplitude bars, distinct from idle")
check(
    transcribingFrame != nil && transcribingFrame != idleFrame,
    "the transcribing waveform renders its own animation, distinct from idle")

// ── AppDelegate helpers (no app boot) ──
let prefs = UserDefaults.standard
prefs.set(5.0, forKey: AppDelegate.opacityDefaultsKey)
check(AppDelegate.savedOpacity() == 1.0, "out-of-range opacity falls back to 1.0")
prefs.set(0.5, forKey: AppDelegate.opacityDefaultsKey)
check(AppDelegate.savedOpacity() == 0.5, "in-range opacity is honored")
prefs.removeObject(forKey: AppDelegate.opacityDefaultsKey)
check(AppDelegate.savedOpacity() == 1.0, "absent opacity means the default")
prefs.set(false, forKey: AppDelegate.autoTypeDefaultsKey)
check(!AppDelegate.savedAutoType(), "persisted auto-type off is honored")
prefs.removeObject(forKey: AppDelegate.autoTypeDefaultsKey)
check(AppDelegate.savedAutoType(), "absent auto-type defaults to on")

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate

let installed = appDelegate.installedModels()
check(
    !installed.contains { $0.name.hasPrefix("ggml-silero") },
    "discovery never offers a VAD model as a speech model")
check(
    zip(installed, installed.dropFirst()).allSatisfy {
        (boo_model_rank($0.name), $0.name) <= (boo_model_rank($1.name), $1.name)
    }, "installed models come ranked, most capable first")

var switched: Bool?
appDelegate.switchModel(path: "/nonexistent") { switched = $0 }
check(switched == false, "a swap without a context reports failure")
appDelegate.updateStatusBar()  // no context: must be a quiet no-op

appDelegate.opacityDidChange(Notification(name: .opacityChanged, object: 0.7))
check(AppDelegate.savedOpacity() == 0.7, "an opacity change persists")
appDelegate.opacityDidChange(Notification(name: .opacityChanged, object: "junk"))
check(AppDelegate.savedOpacity() == 0.7, "a malformed opacity payload is ignored")
appDelegate.autoTypeDidChange(Notification(name: .autoTypeChanged, object: false))
check(!AppDelegate.savedAutoType(), "an auto-type change persists")
prefs.removeObject(forKey: AppDelegate.opacityDefaultsKey)
prefs.removeObject(forKey: AppDelegate.autoTypeDefaultsKey)

// The status-bar recording poll: a start notification spins up the 2Hz timer
// (its tick is a quiet no-op without a context), a stop notification schedules
// the wind-down.
appDelegate.recordingStateChanged(Notification(name: .booRecordingStarted))
check(appDelegate.statusBarTimer != nil, "recording-started starts the status-bar poll")
_ = pump(seconds: 0.6, until: { false })  // let the timer tick once
appDelegate.recordingStateChanged(Notification(name: .booRecordingStopped))
appDelegate.statusBarTimer?.invalidate()
appDelegate.statusBarTimer = nil
check(
    appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
    "closing the last window terminates the app")

// ── Settings window headless ──
let settings = SettingsWindowController()
_ = settings.window?.contentViewController?.view  // forces the whole setupUI
if let vc = settings.window?.contentViewController as? SettingsViewController {
    check(
        vc.numberOfRows(in: vc.themeTableView) == ThemeManager.shared.themes.count,
        "Settings lists every theme")
    vc.filterThemes("dark")
    let darkCount = vc.filteredThemes.count
    check(
        darkCount > 0 && darkCount < ThemeManager.shared.themes.count,
        "the theme search filters (\(darkCount) match)")
    check(
        vc.tableView(vc.themeTableView, viewFor: nil, row: 0) != nil,
        "a theme row renders")
    vc.filterThemes("")
    let current = ThemeManager.shared.currentIndex
    vc.themeTableView.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
    vc.tableViewSelectionDidChange(
        Notification(name: NSTableView.selectionDidChangeNotification))
    check(ThemeManager.shared.currentIndex == current, "re-selecting keeps the theme")
    vc.opacityChanged(vc.opacitySlider)
    vc.autoTypeChanged(vc.autoTypeCheckbox)
    vc.updatePreview()
    vc.reloadModelList()
    check(
        vc.modelPopup.numberOfItems >= installed.count,
        "the model dropdown merges disk and manifest")

    vc.searchField.stringValue = "light"
    vc.searchChanged(vc.searchField)
    let lightCount = vc.filteredThemes.count
    check(
        lightCount > 0 && lightCount < ThemeManager.shared.themes.count,
        "the search-field action filters the list (\(lightCount) match)")
    vc.searchField.stringValue = ""
    vc.searchChanged(vc.searchField)

    if let curRow = vc.filteredThemes.firstIndex(where: { $0.0 == ThemeManager.shared.currentIndex }) {
        check(
            vc.tableView(vc.themeTableView, viewFor: nil, row: curRow) != nil,
            "the current theme's row renders with its accent highlight")
    }

    // A model already on disk selected with no live context: the swap is
    // refused and reported, never left as a silent dead dropdown.
    if let installedIdx = vc.modelChoices.firstIndex(where: { $0.path != nil }) {
        vc.modelPopup.selectItem(at: installedIdx)
        vc.modelChanged(vc.modelPopup)
        check(
            vc.modelStatus.stringValue.contains("Could not load"),
            "selecting a disk model without a context reports the refused swap")
    }
} else {
    check(false, "Settings builds its view controller")
}
settings.window?.close()

// ── Overlay window headless ──
// A sentinel context stands in for a booted core: this overlay drives only the
// pure-UI paths (transcript bubbles, theming, status flashes), which never call
// into the core, so the pointer is never dereferenced. Recording and waveform
// polling touch the core and stay behind BOO_HARNESS_BOOT below.
let overlay = OverlayWindow(booCtx: OpaquePointer(bitPattern: 0xB00)!)
check(overlay.canBecomeKey && overlay.canBecomeMain, "the overlay can become the key and main window")
// ARC owns the overlay, so AppKit must not release it on close (closing it
// while Settings keeps the app alive would otherwise over-release it).
check(!overlay.isReleasedWhenClosed, "the overlay is not auto-released on close")

overlay.appDidActivate(Notification(name: NSWorkspace.didActivateApplicationNotification))  // no app: ignored
if let other = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
}) {
    overlay.appDidActivate(
        Notification(
            name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: other]))
    check(overlay.previousApp === other, "the overlay tracks the last non-Boo app")
}

overlay.addTranscript("harness bubble one")
overlay.addTranscript("harness bubble two")
overlay.applyTheme(ThemeManager.shared.current)  // recolors the existing bubbles
check(overlay.transcripts.count == 2, "transcripts accumulate in history")

let bubbleButtons =
    (overlay.transcriptStack.arrangedSubviews.last?.subviews ?? [])
    .compactMap { $0 as? NSStackView }
    .flatMap { $0.arrangedSubviews }
    .compactMap { $0 as? NSButton }
if let copyButton = bubbleButtons.first {
    NSPasteboard.general.clearContents()
    overlay.copyBubbleText(copyButton)
    check(
        NSPasteboard.general.string(forType: .string) == "harness bubble two",
        "a bubble's copy button copies its transcript")
}
if bubbleButtons.count >= 2, let dismissButton = bubbleButtons.last {
    let before = overlay.transcriptStack.arrangedSubviews.count
    overlay.dismissBubble(dismissButton)
    check(
        pump(seconds: 2, until: { overlay.transcriptStack.arrangedSubviews.count < before }),
        "a bubble's dismiss button removes it")
}

if let closeButton = overlay.standardWindowButton(.closeButton) {
    closeButton.isHidden = true
    closeButton.alphaValue = 0
    check(
        pump(seconds: 1.5, until: { !closeButton.isHidden && closeButton.alphaValue >= 1 }),
        "the traffic-light timer restores hidden window buttons")
}

overlay.flashStatus("pasted")
check(overlay.statusLabel.stringValue == "pasted", "flashStatus shows a transient message")
check(
    pump(seconds: 3, until: { overlay.statusLabel.stringValue == OverlayWindow.idleHint }),
    "flashStatus settles back on the idle hint")

// A flash that a newer status supersedes must be left alone: the delayed revert
// only fires while the label still reads the flashed text.
overlay.flashStatus("copied")
overlay.statusLabel.stringValue = "recording..."
_ = pump(seconds: 3, until: { false })  // let the flash's revert deadline pass
check(
    overlay.statusLabel.stringValue == "recording...",
    "flashStatus leaves a superseded status untouched")

// Auto-type delivery with no Ghostty target and Accessibility not granted: the
// transcript must fall back to the clipboard and say so, never silently vanish.
// Guarded on the missing grant so a dev machine that has granted Accessibility
// never actually synthesizes a ⌘V keystroke from the harness.
if !PermissionsManager.hasAccessibility {
    NSPasteboard.general.clearContents()
    overlay.typeTextIntoFocusedApp("delivery fallback")
    check(
        overlay.statusLabel.stringValue == "copied, grant Accessibility to auto-paste"
            && NSPasteboard.general.string(forType: .string) == "delivery fallback",
        "auto-type without Accessibility copies the transcript and explains")
}

// ── TextDelivery (extracted from OverlayWindow) ──
// snapshotPasteboard must deep-copy every type so a non-text clipboard survives
// the transient transcript paste that clears it. Uses a private named pasteboard
// so the real system clipboard is never touched.
let deliveryPb = NSPasteboard(name: NSPasteboard.Name("boo-delivery-test"))
deliveryPb.clearContents()
let priorItem = NSPasteboardItem()
priorItem.setData(Data("prior clipboard".utf8), forType: .string)
deliveryPb.writeObjects([priorItem])
let snapshot = TextDelivery.snapshotPasteboard(deliveryPb)
check(snapshot.count == 1, "snapshotPasteboard copies each pasteboard item")
deliveryPb.clearContents()
deliveryPb.setString("transient transcript", forType: .string)  // the paste clobbers it
deliveryPb.clearContents()
deliveryPb.writeObjects(snapshot)  // restore from the snapshot
check(
    deliveryPb.string(forType: .string) == "prior clipboard",
    "the snapshot restores the prior clipboard after a clobber")
deliveryPb.releaseGlobally()

// resolveKeyCode finds the virtual key that types a character on the active
// layout, so ⌘V pastes on Dvorak/AZERTY, not just QWERTY. "v" exists on every
// Latin layout, so it must resolve to an in-range key; the paste key falls back
// to QWERTY's 0x09 only when resolution fails.
if let vKey = TextDelivery.resolveKeyCode(for: "v") {
    check(vKey < 128, "resolveKeyCode maps 'v' to an in-range virtual key")
} else {
    check(false, "resolveKeyCode should map 'v' on a Latin layout")
}
check(TextDelivery.pasteKeyCode < 128, "the paste key is a valid virtual key")

overlay.startDisplayLink()
overlay.stopDisplayLink()
check(overlay.waveformLink?.isPaused == true, "the waveform display link pauses on stop")

overlay.close()
check(overlay.waveformLink == nil, "closing the overlay tears down the display link")

// ── Onboarding download window headless ──
appDelegate.showDownloadWindow()
check(appDelegate.downloadWindow != nil, "the onboarding download window opens")
check(appDelegate.onboardingStart != nil, "its Download action is wired")

// Drive the wired downloader to fail with no network (empty URL): the window's
// onFail closure must surface the reason in the status line and leave the
// dialog usable, never freeze it. The onDone/onProgress closures need a real
// fetch plus a loadable model (boo_init), so they stay for the booted CI job.
let onboardingStatus = appDelegate.downloadWindow?.contentView?.subviews
    .compactMap { $0 as? NSTextField }.first
appDelegate.modelDownloader?.start(model: badModel)
check(
    onboardingStatus?.stringValue == "The model's download URL is invalid.",
    "a failed onboarding download surfaces the reason in the window")

appDelegate.downloadWindow?.close()
appDelegate.downloadWindow = nil
appDelegate.modelDownloader = nil
appDelegate.onboardingStart = nil

// With onboarding torn down, the Download button's selector is an inert no-op.
appDelegate.startModelDownload(NSButton())
check(appDelegate.onboardingStart == nil, "the Download selector stays inert with no prepared action")

// ── Full app boot (opt-in: grabs mic TCC + the global hotkey) ──
if ProcessInfo.processInfo.environment["BOO_HARNESS_BOOT"] == "1" {
    if let model = installed.first {
        appDelegate.startWithModel(path: model.path)
        check(appDelegate.booCtx != nil, "the app boots around \(model.name)")
        check(appDelegate.currentModelPath == model.path, "the loaded model is tracked")
        check(appDelegate.overlayWindow != nil, "the overlay exists")
        if let overlay = appDelegate.overlayWindow {
            overlay.applyTheme(ThemeManager.shared.current)
            overlay.addTranscript("harness transcript one")
            overlay.addTranscript("harness transcript two")
            overlay.flashStatus("harness status")
            overlay.updateWaveform()
        }
        appDelegate.updateStatusBar()
        NotificationCenter.default.post(name: .opacityChanged, object: 0.8)
        NotificationCenter.default.post(name: .autoTypeChanged, object: true)
        appDelegate.themeDidChange()
        _ = pump(seconds: 1, until: { false })  // let timers and the link tick

        appDelegate.showMainWindow()
        check(appDelegate.overlayWindow?.isVisible == true, "Show Window brings the overlay up")

        // The record entry points with no microphone (CI runners have none):
        // each must say so and refuse a phantom recording. Guarded on the mic so
        // a machine with a real input device never actually records here.
        if let ctx = appDelegate.booCtx, !boo_has_microphone(ctx), let ov = appDelegate.overlayWindow {
            appDelegate.statusBarToggleRecord()
            check(
                ov.statusLabel.stringValue == "no microphone" && !ov.isRecording,
                "the menu-bar Record item no-ops without a microphone")
            appDelegate.handleHotKey()
            check(!ov.isRecording, "the global hotkey does not record without a microphone")
            ov.waveformClicked()
            check(!ov.isRecording, "clicking the waveform does not record without a microphone")
        }

        // The status-bar poll wind-down with a live context: a stop schedules a
        // 5s settle that, finding the core idle, retires the timer and resets the
        // icon (headless the body early-returns on a nil context).
        appDelegate.recordingStateChanged(Notification(name: .booRecordingStarted))
        check(appDelegate.statusBarTimer != nil, "a booted recording-start arms the status-bar poll")
        appDelegate.recordingStateChanged(Notification(name: .booRecordingStopped))
        check(
            pump(seconds: 7, until: { appDelegate.statusBarTimer == nil }),
            "the poll wind-down retires the timer once the core is idle")

        appDelegate.openSettings()
        check(appDelegate.settingsWindowController != nil, "Settings opens from the app")
        _ = appDelegate.settingsWindowController?.window?.contentViewController?.view
        let firstSettings = appDelegate.settingsWindowController
        appDelegate.openSettings()  // a second open reuses the controller, never rebuilds it
        check(
            appDelegate.settingsWindowController === firstSettings,
            "reopening Settings reuses the existing controller")
        appDelegate.settingsWindowController?.window?.close()

        var swapOK: Bool?
        appDelegate.switchModel(path: model.path) { swapOK = $0 }
        check(
            pump(seconds: 120, until: { swapOK != nil }) && swapOK == true,
            "an in-place model swap succeeds")
        prefs.removeObject(forKey: AppDelegate.modelDefaultsKey)

        appDelegate.overlayWindow?.close()
        appDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification))
        appDelegate.booCtx = nil
    } else {
        check(false, "BOO_HARNESS_BOOT is set but no model is installed")
    }
}

exit(failures == 0 ? 0 : 1)
