import Carbon
import Cocoa
import CryptoKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayWindow: OverlayWindow?
    var booCtx: OpaquePointer?
    var statusItem: NSStatusItem?
    var hotKeyRef: EventHotKeyRef?
    var settingsWindowController: SettingsWindowController?
    var statusBarTimer: Timer?
    // Retained while the onboarding download runs (ModelOnboarding.swift).
    var modelDownloader: ModelDownloader?
    var downloadWindow: NSWindow?
    // The onboarding Download button's prepared action, wired to its widgets.
    var onboardingStart: (() -> Void)?
    /// Path of the model currently loaded into the core (Settings shows it).
    private(set) var currentModelPath: String?

    /// Open the diagnostic log at ~/Library/Logs/Boo/boo.log and install the
    /// crash capture (boo-crash.txt beside it; the system .ips still gets
    /// written). Never logs recognized text (see
    /// docs/logging-and-crash-reporting.md).
    private func initLogging() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Boo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        boo_log_init(dir.appendingPathComponent("boo.log").path, Int32(BOO_LOG_INFO))
        boo_crash_init(dir.path)
    }

    func applicationDidFinishLaunching(_: Notification) {
        initLogging()
        // Microphone only. Accessibility is requested later, the first time a
        // paste actually needs it, see PermissionsManager.
        PermissionsManager.ensurePermissions()

        if let modelPath = findModelPath() {
            startWithModel(path: modelPath)
        } else {
            boo_log(Int32(BOO_LOG_ERROR), "no speech model found")
            showModelOnboarding()  // Download… / Choose a File… / Quit
        }

        // After the UI is up: mention a crash report from a previous run.
        DispatchQueue.main.async { self.surfacePreviousCrash() }
    }

    /// Surface a crash report left behind by a previous run (crash capture
    /// writes boo-crash.txt beside the log; see
    /// docs/logging-and-crash-reporting.md). The report is renamed once
    /// shown, so the next launch stays quiet unless a new crash happened.
    /// Nothing is sent anywhere; Reveal opens Finder for the user to inspect
    /// or attach it themselves.
    private func surfacePreviousCrash() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Boo", isDirectory: true)
        let report = dir.appendingPathComponent("boo-crash.txt")
        guard FileManager.default.fileExists(atPath: report.path) else { return }
        let seen = dir.appendingPathComponent("boo-crash-prev.txt")
        try? FileManager.default.removeItem(at: seen)
        try? FileManager.default.moveItem(at: report, to: seen)

        let alert = NSAlert()
        alert.messageText = "Boo crashed last time"
        alert.informativeText =
            "A crash report was saved next to the log. Nothing was sent anywhere."
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Dismiss")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([seen])
        }
    }

    /// Load the model at `path` and bring up the whole app. Shared by
    /// auto-discovery and the onboarding (file picker / download). Terminates on
    /// a load failure.
    func startWithModel(path: String) {
        NSLog("Boo: loading model %@", path)

        guard let ctx = boo_init(path) else {
            boo_log(Int32(BOO_LOG_ERROR), "speech model failed to load")
            let alert = NSAlert()
            alert.messageText = "Could not load the model"
            alert.informativeText = """
                \(path)

                The file exists but whisper could not read it. It may be corrupt \
                or truncated, try downloading it again.
                """
            alert.alertStyle = .warning
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        booCtx = ctx
        currentModelPath = path
        boo_log(Int32(BOO_LOG_INFO), "speech model loaded")

        // Optional streaming VAD: when a Silero model is present, utterances
        // are transcribed at natural pauses while still recording, and only
        // the final one remains after stop. Without it, batch mode as before.
        if let vadPath = findVadModelPath() {
            if boo_load_vad(ctx, vadPath) {
                NSLog("Boo: streaming transcription enabled (%@)", vadPath)
            } else {
                NSLog("Boo: could not load VAD model %@, staying in batch mode", vadPath)
            }
        } else {
            downloadVadModel()
        }

        overlayWindow = OverlayWindow(booCtx: ctx)
        overlayWindow?.makeKeyAndOrderFront(nil)

        // Register global hotkey: Ctrl+Shift+Space
        registerHotKey()

        // Set app icon
        if let iconPath = Bundle.main.path(forResource: "boo", ofType: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOfFile: iconPath)
        }

        // Create main menu with Settings shortcut (Cmd+,)
        setupMenu()

        // Listen for theme/settings changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(opacityDidChange(_:)), name: .opacityChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(autoTypeDidChange(_:)), name: .autoTypeChanged, object: nil)

        // After the observers: the restored theme re-applies through them.
        restorePreferences()

        // Setup status bar item
        setupStatusBar()

        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Boo")
        button.image?.size = NSSize(width: 18, height: 18)
        button.imagePosition = .imageLeading

        // Status bar menu
        let menu = NSMenu()
        menu.addItem(withTitle: "Boo 👻", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let recordItem = NSMenuItem(
            title: "Record (Ctrl+Shift+Space)", action: #selector(statusBarToggleRecord), keyEquivalent: "")
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Show Window", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Boo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu

        // Status bar updates, only poll when recording/transcribing
        NotificationCenter.default.addObserver(
            self, selector: #selector(recordingStateChanged), name: .booRecordingStarted, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(recordingStateChanged), name: .booRecordingStopped, object: nil)
    }

    func updateStatusBar() {
        guard let ctx = booCtx, let button = statusItem?.button else { return }

        let recording = boo_is_recording(ctx)
        let transcribing = boo_is_transcribing(ctx)

        if recording {
            // Red waveform plus a live timer.
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Boo, recording")
            button.contentTintColor = .systemRed

            let totalSecs = Int(Float(boo_get_audio_samples(ctx)) / 16000.0)
            button.title =
                totalSecs < 60
                ? String(format: " %ds", totalSecs)
                : String(format: " %d:%02d", totalSecs / 60, totalSecs % 60)
        } else if transcribing {
            // Transcription blocks for seconds on a big model; without this the
            // menu bar snapped straight back to idle and looked like nothing
            // happened.
            button.image = NSImage(
                systemSymbolName: "waveform.badge.magnifyingglass",
                accessibilityDescription: "Boo, transcribing")
            button.contentTintColor = .secondaryLabelColor
            button.title = ""
        } else {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Boo")
            button.contentTintColor = nil  // system default
            button.title = ""
        }

        button.image?.size = NSSize(width: 18, height: 18)
    }

    @objc func recordingStateChanged(_ notification: Notification) {
        if notification.name == .booRecordingStarted {
            // Start polling status bar at 2Hz
            statusBarTimer?.invalidate()
            statusBarTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.updateStatusBar()
            }
            updateStatusBar()
        } else {
            // Stop polling after a brief delay (let transcription state show)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self, let ctx = self.booCtx else { return }
                if !boo_is_recording(ctx) && !boo_is_transcribing(ctx) {
                    self.statusBarTimer?.invalidate()
                    self.statusBarTimer = nil
                    self.updateStatusBar()  // reset to idle state
                }
            }
        }
    }

    @objc func statusBarToggleRecord() {
        overlayWindow?.toggleRecording(viaHotkey: true)  // treat as hotkey since window may be hidden
    }

    @objc func showMainWindow() {
        overlayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Boo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Boo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Boo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// UserDefaults keys for the persisted preferences; the other frontends
    /// persist theirs (settings.ini, registry), so the reference must too.
    static let opacityDefaultsKey = "opacity"
    static let autoTypeDefaultsKey = "autoType"
    static let themeDefaultsKey = "theme"

    @objc func themeDidChange() {
        overlayWindow?.applyTheme(ThemeManager.shared.current)
        UserDefaults.standard.set(
            ThemeManager.shared.current.name, forKey: AppDelegate.themeDefaultsKey)
    }

    @objc func opacityDidChange(_ notification: Notification) {
        guard let value = notification.object as? Double else { return }
        overlayWindow?.opacity = CGFloat(value)
        overlayWindow?.backgroundColor = ThemeManager.shared.current.bgWithAlpha(CGFloat(value))
        UserDefaults.standard.set(value, forKey: AppDelegate.opacityDefaultsKey)
    }

    @objc func autoTypeDidChange(_ notification: Notification) {
        guard let value = notification.object as? Bool else { return }
        overlayWindow?.autoType = value
        UserDefaults.standard.set(value, forKey: AppDelegate.autoTypeDefaultsKey)
    }

    /// Re-apply the persisted preferences at startup: theme by name (a
    /// removed theme falls back to the default), then opacity and auto-type
    /// onto the fresh overlay. Defaults absent on first run leave the
    /// built-in values (1.0, on, default theme) untouched.
    private func restorePreferences() {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: AppDelegate.themeDefaultsKey),
            let idx = ThemeManager.shared.themes.firstIndex(where: { $0.name == name })
        {
            ThemeManager.shared.selectTheme(at: idx)
        }
        if defaults.object(forKey: AppDelegate.opacityDefaultsKey) != nil {
            let value = defaults.double(forKey: AppDelegate.opacityDefaultsKey)
            if value >= 0.1 && value <= 1.0 {
                overlayWindow?.opacity = CGFloat(value)
                overlayWindow?.backgroundColor =
                    ThemeManager.shared.current.bgWithAlpha(CGFloat(value))
            }
        }
        if defaults.object(forKey: AppDelegate.autoTypeDefaultsKey) != nil {
            overlayWindow?.autoType = defaults.bool(forKey: AppDelegate.autoTypeDefaultsKey)
        }
    }

    func applicationWillTerminate(_: Notification) {
        if let ctx = booCtx {
            boo_deinit(ctx)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return true
    }

    /// ~/.boo/models: where the README tells you to put models and where the
    /// VAD download lands.
    static var userModelsDir: String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".boo")
            .appendingPathComponent("models").path
    }

    /// Directories Boo looks in for a model, most specific first.
    private var modelSearchDirs: [String] {
        let appDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let projectDir = (appDir as NSString).deletingLastPathComponent

        return [
            AppDelegate.userModelsDir,
            "models",  // cwd, for `zig build run`
            (projectDir as NSString).appendingPathComponent("models"),  // source checkout
            Bundle.main.resourcePath ?? "",  // bundled alongside the app
        ].filter { !$0.isEmpty }
    }

    /// Find a whisper model.
    ///
    /// Any of whisper.cpp's GGML models works, so this accepts any `ggml-*.bin`
    /// rather than only the `ggml-base.en.bin` we happen to recommend, pinning
    /// the filename meant a user who followed our own advice and downloaded, say,
    /// large-v3-turbo would be told no model was installed.
    ///
    /// $BOO_MODEL wins outright, matching the Linux frontend.
    private func findModelPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["BOO_MODEL"], !env.isEmpty {
            guard FileManager.default.fileExists(atPath: env) else {
                NSLog("Boo: BOO_MODEL points at %@, which does not exist", env)
                return nil
            }
            return env
        }

        // A model the user explicitly picked in Settings wins over the
        // capability ranking below; a stale choice (file deleted or truncated
        // since) just falls through to auto-discovery.
        if let saved = UserDefaults.standard.string(forKey: AppDelegate.modelDefaultsKey),
            FileManager.default.fileExists(atPath: saved),
            boo_model_verify(saved) != Int32(BOO_MODEL_FILE_TRUNCATED)
        {
            return saved
        }

        let fm = FileManager.default
        for dir in modelSearchDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            let models =
                entries
                // ggml-silero-* is the VAD model, not a speech model; without
                // this exclusion it could win the alphabetical tiebreak.
                .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") && !$0.hasPrefix("ggml-silero") }
                // A truncated file (interrupted manual download) must not be
                // auto-picked; it would fail seconds into launch.
                .filter {
                    boo_model_verify((dir as NSString).appendingPathComponent($0))
                        != Int32(BOO_MODEL_FILE_TRUNCATED)
                }
                .sorted()
            guard !models.isEmpty else { continue }

            // Take the most capable model the user has bothered to download,
            // ranked by the shared core order (boo_model_rank); `models` is
            // pre-sorted, so equal ranks (the unrecognized) break alphabetically.
            let chosen = models.min(by: { boo_model_rank($0) < boo_model_rank($1) }) ?? models[0]
            return (dir as NSString).appendingPathComponent(chosen)
        }
        return nil
    }

    /// UserDefaults key for the model the user explicitly picked in Settings.
    /// Absent until the first manual switch, so a newly downloaded, more
    /// capable model still wins auto-discovery by default.
    static let modelDefaultsKey = "modelPath"

    /// Speech models on disk for the Settings popup: every ggml-*.bin in the
    /// search directories (minus the silero VAD models), deduplicated by
    /// filename so ~/.boo/models shadows a bundled copy, ranked most capable
    /// first with alphabetical tiebreak. Truncated files (an interrupted
    /// manual download, caught by boo_model_verify) are excluded, so the
    /// Settings dropdown offers the re-download entry for them instead.
    func installedModels() -> [(name: String, path: String)] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [(name: String, path: String)] = []
        for dir in modelSearchDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries.sorted()
            where name.hasPrefix("ggml-") && name.hasSuffix(".bin")
                && !name.hasPrefix("ggml-silero") && seen.insert(name).inserted
            {
                let path = (dir as NSString).appendingPathComponent(name)
                if boo_model_verify(path) == Int32(BOO_MODEL_FILE_TRUNCATED) { continue }
                out.append((name, path))
            }
        }
        return out.sorted { (boo_model_rank($0.name), $0.name) < (boo_model_rank($1.name), $1.name) }
    }

    /// Swap the loaded model in place (core boo_reload_model) off the main
    /// thread; loading takes seconds. On failure the core keeps serving with
    /// the old model. On success the choice persists and wins future launches.
    func switchModel(path: String, completion: @escaping (Bool) -> Void) {
        guard let ctx = booCtx, !boo_is_recording(ctx), !boo_is_transcribing(ctx) else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = boo_reload_model(ctx, path)
            DispatchQueue.main.async {
                if ok {
                    self.currentModelPath = path
                    UserDefaults.standard.set(path, forKey: AppDelegate.modelDefaultsKey)
                }
                completion(ok)
            }
        }
    }

    /// Find a Silero VAD model (ggml-silero-*.bin) in the same places as the
    /// whisper model. $BOO_VAD_MODEL wins outright, matching $BOO_MODEL.
    private func findVadModelPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["BOO_VAD_MODEL"], !env.isEmpty {
            guard FileManager.default.fileExists(atPath: env) else {
                NSLog("Boo: BOO_VAD_MODEL points at %@, which does not exist", env)
                return nil
            }
            return env
        }

        let fm = FileManager.default
        for dir in modelSearchDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let models =
                entries
                .filter { $0.hasPrefix("ggml-silero") && $0.hasSuffix(".bin") }
                .sorted()
            if let chosen = models.first {
                return (dir as NSString).appendingPathComponent(chosen)
            }
        }
        return nil
    }

    /// Fetch the Silero VAD model in the background on first run. It is under
    /// 1 MB and carries no size/language decision the user needs to make
    /// (unlike the speech models), so streaming transcription just starts
    /// working; batch mode covers the seconds until it lands. boo_load_vad is
    /// safe to call at any time, including mid-recording.
    // Pinned SHA-256 of ggml-silero-v6.2.0.bin (HuggingFace LFS oid). The file
    // is fetched over TLS, but pinning defends against a compromised mirror
    // handing a substituted GGUF straight to the ggml parser.
    private static let vadModelSHA256 =
        "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

    private static let vadModelName = "ggml-silero-v6.2.0.bin"

    /// Default VAD download base. Fixed on purpose: the SHA-256 pin applies
    /// to whatever the URL serves, so pointing elsewhere cannot weaken it.
    private static let vadModelBaseURL =
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/"

    /// The VAD download source. $BOO_VAD_MODEL_URL lets a mirror stand in for
    /// Hugging Face; the SHA-256 pin applies to whatever the URL serves.
    private static var vadModelURL: URL {
        let fallback = vadModelBaseURL + vadModelName
        let raw = ProcessInfo.processInfo.environment["BOO_VAD_MODEL_URL"] ?? fallback
        return URL(string: raw) ?? URL(string: fallback)!
    }

    private func downloadVadModel() {
        let dir = AppDelegate.userModelsDir
        let dest = URL(fileURLWithPath: dir)
            .appendingPathComponent(AppDelegate.vadModelName)
        let url = AppDelegate.vadModelURL

        NSLog("Boo: fetching the VAD model to enable streaming transcription")
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, response, error in
            guard let tmp = tmp, error == nil,
                (response as? HTTPURLResponse)?.statusCode == 200
            else {
                NSLog(
                    "Boo: VAD model download failed (%@); staying in batch mode",
                    error?.localizedDescription ?? "bad response")
                return
            }
            // Verify before trusting the bytes: a wrong hash means a corrupt or
            // substituted file, so drop it and stay in batch mode.
            guard let data = try? Data(contentsOf: tmp),
                SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                    == AppDelegate.vadModelSHA256
            else {
                NSLog("Boo: VAD model failed checksum; staying in batch mode")
                return
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch {
                NSLog("Boo: could not save the VAD model: %@", error.localizedDescription)
                return
            }
            DispatchQueue.main.async {
                guard let self = self, let ctx = self.booCtx else { return }
                if boo_load_vad(ctx, dest.path) {
                    NSLog("Boo: streaming transcription enabled (%@)", dest.path)
                }
            }
        }
        task.resume()
    }

    // MARK: - Global Hotkey (Ctrl+Shift+Space)

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x424F4F21), id: 1)  // "BOO!"
        var keyRef: EventHotKeyRef?

        // Ctrl+Shift+Space: modifiers = controlKey + shiftKey, keycode = 49 (space)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | shiftKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &keyRef
        )

        if status == noErr {
            hotKeyRef = keyRef
        } else {
            // Most often another app already owns Ctrl+Shift+Space. The Record
            // button and menu bar remain the fallback, as on Linux/Windows, but
            // don't leave the failure entirely silent.
            NSLog(
                "Boo: could not register the Ctrl+Shift+Space hotkey (status %d); "
                    + "use the menu bar or Record button", status)
        }

        // Install handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                delegate.handleHotKey()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        if handlerStatus != noErr {
            NSLog("Boo: could not install the hotkey handler (status %d)", handlerStatus)
        }
    }

    @objc func handleHotKey() {
        guard let _ = booCtx, let window = overlayWindow else { return }
        window.toggleRecording(viaHotkey: true)
    }
}
