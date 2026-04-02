import Cocoa
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayWindow: OverlayWindow?
    var booCtx: OpaquePointer?
    var statusItem: NSStatusItem?
    var hotKeyRef: EventHotKeyRef?
    var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request all permissions upfront
        PermissionsManager.ensurePermissions()

        // Init Boo core
        let modelPath = findModelPath()
        print("Boo 👻 — Loading model: \(modelPath)")

        booCtx = boo_init(modelPath)
        if booCtx == nil {
            let alert = NSAlert()
            alert.messageText = "Failed to load model"
            alert.informativeText = "Download ggml-base.en.bin to models/ directory"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        print("Model loaded.")

        // Create overlay window
        overlayWindow = OverlayWindow(booCtx: booCtx!)
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
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .themeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(opacityDidChange(_:)), name: .opacityChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(autoTypeDidChange(_:)), name: .autoTypeChanged, object: nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Boo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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

    private func findModelPath() -> String {
        // Check multiple locations
        let appDir = Bundle.main.bundlePath
            .components(separatedBy: "/").dropLast().joined(separator: "/")
        let projectDir = appDir
            .components(separatedBy: "/").dropLast().joined(separator: "/")

        let candidates = [
            // Relative to app bundle (zig-out/Boo.app → zig-out/../models)
            projectDir + "/models/ggml-base.en.bin",
            // Inside app bundle resources
            Bundle.main.resourcePath.map { $0 + "/ggml-base.en.bin" } ?? "",
            // Home directory
            NSHomeDirectory() + "/.boo/models/ggml-base.en.bin",
            // Current working directory
            "models/ggml-base.en.bin",
            // /Applications install
            "/Applications/Boo.app/../models/ggml-base.en.bin",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                print("Found model at: \(path)")
                return path
            }
        }

        print("Model not found. Searched:")
        for path in candidates {
            print("  \(path)")
        }
        return "models/ggml-base.en.bin"
    }

    // MARK: - Global Hotkey (Ctrl+Shift+Space)

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x424F4F21), id: 1) // "BOO!"
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
        }

        // Install handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
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
    }

    @objc func handleHotKey() {
        guard let _ = booCtx, let window = overlayWindow else { return }
        window.toggleRecording(viaHotkey: true)
    }
}
