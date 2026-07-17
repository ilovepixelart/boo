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
let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
wave.update(
    waveform: (0..<40).map { Float($0 % 5) / 5.0 }, peakRms: 0.8, isRecording: true,
    isTranscribing: false)
wave.update(waveform: [], peakRms: 0, isRecording: false, isTranscribing: true)
wave.update(waveform: [0.2, 0.4], peakRms: 0.4, isRecording: false, isTranscribing: false)
if let rep = wave.bitmapImageRepForCachingDisplay(in: wave.bounds) {
    wave.cacheDisplay(in: wave.bounds, to: rep)
    check(true, "the waveform draws in every state")
} else {
    check(false, "the waveform view yields a drawing rep")
}

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
} else {
    check(false, "Settings builds its view controller")
}
settings.window?.close()

// ── Onboarding download window headless ──
appDelegate.showDownloadWindow()
check(appDelegate.downloadWindow != nil, "the onboarding download window opens")
check(appDelegate.onboardingStart != nil, "its Download action is wired")
appDelegate.downloadWindow?.close()
appDelegate.downloadWindow = nil
appDelegate.modelDownloader = nil
appDelegate.onboardingStart = nil

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

        appDelegate.openSettings()
        check(appDelegate.settingsWindowController != nil, "Settings opens from the app")
        _ = appDelegate.settingsWindowController?.window?.contentViewController?.view
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
