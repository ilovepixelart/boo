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

    /// Open the diagnostic log at ~/Library/Logs/Boo/boo.log. Never logs
    /// recognized text (see docs/logging-and-crash-reporting.md).
    private func initLogging() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Boo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        boo_log_init(dir.appendingPathComponent("boo.log").path, Int32(BOO_LOG_INFO))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        initLogging()
        // Microphone only. Accessibility is requested later, the first time a
        // paste actually needs it, see PermissionsManager.
        PermissionsManager.ensurePermissions()

        guard let modelPath = findModelPath() else {
            boo_log(Int32(BOO_LOG_ERROR), "no speech model found")
            showModelNotFoundAlert()
            NSApp.terminate(nil)
            return
        }
        NSLog("Boo: loading model %@", modelPath)

        guard let ctx = boo_init(modelPath) else {
            boo_log(Int32(BOO_LOG_ERROR), "speech model failed to load")
            let alert = NSAlert()
            alert.messageText = "Could not load the model"
            alert.informativeText = """
                \(modelPath)

                The file exists but whisper could not read it. It may be corrupt \
                or truncated, try downloading it again.
                """
            alert.alertStyle = .warning
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        booCtx = ctx
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

    @objc func themeDidChange() {
        overlayWindow?.applyTheme(ThemeManager.shared.current)
    }

    @objc func opacityDidChange(_ notification: Notification) {
        guard let value = notification.object as? Double else { return }
        overlayWindow?.opacity = CGFloat(value)
        overlayWindow?.backgroundColor = ThemeManager.shared.current.bgWithAlpha(CGFloat(value))
    }

    @objc func autoTypeDidChange(_ notification: Notification) {
        guard let value = notification.object as? Bool else { return }
        overlayWindow?.autoType = value
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ctx = booCtx {
            boo_deinit(ctx)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Directories Boo looks in for a model, most specific first.
    private var modelSearchDirs: [String] {
        let appDir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let projectDir = (appDir as NSString).deletingLastPathComponent

        return [
            NSHomeDirectory() + "/.boo/models",  // where the README tells you to put it
            "models",  // cwd, for `zig build run`
            projectDir + "/models",  // source checkout: zig-out/Boo.app → ../models
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

        let fm = FileManager.default
        for dir in modelSearchDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            let models =
                entries
                // ggml-silero-* is the VAD model, not a speech model; without
                // this exclusion it could win the alphabetical tiebreak.
                .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") && !$0.hasPrefix("ggml-silero") }
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

    private func downloadVadModel() {
        let dir = NSHomeDirectory() + "/.boo/models"
        let dest = URL(fileURLWithPath: dir + "/ggml-silero-v6.2.0.bin")
        let url = URL(
            string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
        )!

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

    private func showModelNotFoundAlert() {
        let alert = NSAlert()
        alert.messageText = "No speech model found"
        alert.informativeText = """
            Boo needs a speech model, which isn't bundled.

            Download one into ~/.boo/models/ and relaunch.

            Recommended, best accuracy, 25 languages (669 MB):
            mkdir -p ~/.boo/models
            curl -L -o ~/.boo/models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \\
              https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin

            Lighter and faster, English only (148 MB):
            curl -L -o ~/.boo/models/ggml-base.en.bin \\
              https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

            Searched:
            \(modelSearchDirs.map { "  • \($0)" }.joined(separator: "\n"))
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            let cmd = """
                mkdir -p ~/.boo/models && curl -L -o ~/.boo/models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
                https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin
                """
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
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
