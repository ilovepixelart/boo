// First-run model onboarding: download a curated model with progress, or pick
// one already on disk. Mirrors the Linux flow (docs/model-onboarding.md). The
// curated list + pinned SHA-256s come from the core (boo_models).

import Cocoa
import CryptoKit

extension AppDelegate {
    /// The no-model entry: Download a recommended model, pick one on disk, or quit.
    func showModelOnboarding() {
        let alert = NSAlert()
        alert.messageText = "No speech model found"
        alert.informativeText =
            "Download a recommended model, or choose one you already have on disk."
        alert.addButton(withTitle: "Download…")
        alert.addButton(withTitle: "Choose a File…")
        alert.addButton(withTitle: "Quit")
        switch alert.runModal() {
        case .alertFirstButtonReturn: showDownloadWindow()
        case .alertSecondButtonReturn: chooseModelFile()
        default: NSApp.terminate(nil)
        }
    }

    /// A native open panel; the picked GGML model is loaded and the app opens.
    func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a speech model"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            startWithModel(path: url.path)
        } else {
            NSApp.terminate(nil)  // cancelled with no model to load
        }
    }

    /// A small window: a model dropdown + a progress bar + Download.
    func showDownloadWindow() {
        var count = 0
        guard let models = boo_models(&count), count > 0 else {
            NSApp.terminate(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Download a Model"
        win.center()
        let content = NSView(frame: win.contentView!.bounds)

        let popup = NSPopUpButton(frame: NSRect(x: 20, y: 104, width: 380, height: 26))
        for i in 0..<count {
            let m = models[i]
            popup.addItem(withTitle: "\(booCString(m.label))  (\(booCString(m.note)))")
        }
        content.addSubview(popup)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 74, width: 380, height: 20))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        content.addSubview(bar)

        let status = NSTextField(labelWithString: "Downloads to ~/.boo/models, then opens Boo.")
        status.frame = NSRect(x: 20, y: 48, width: 380, height: 18)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        content.addSubview(status)

        let button = NSButton(
            title: "Download", target: self, action: #selector(startModelDownload(_:)))
        button.frame = NSRect(x: 310, y: 12, width: 90, height: 28)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        content.addSubview(button)

        win.contentView = content

        // The downloader drives these widgets through its closures; the
        // button action just fires the prepared start closure.
        let downloader = ModelDownloader(
            onProgress: { bar.doubleValue = $0 },
            onDone: { [weak self] path in
                win.close()
                // Release the onboarding machinery; nothing re-enters it.
                self?.modelDownloader = nil
                self?.onboardingStart = nil
                self?.downloadWindow = nil
                self?.startWithModel(path: path)
            },
            onFail: { why in
                status.stringValue = why
                button.isEnabled = true
                popup.isEnabled = true
                win.standardWindowButton(.closeButton)?.isEnabled = true
            })
        modelDownloader = downloader
        onboardingStart = {
            let idx = popup.indexOfSelectedItem
            guard idx >= 0, idx < count else { return }
            button.isEnabled = false
            popup.isEnabled = false
            win.standardWindowButton(.closeButton)?.isEnabled = false  // no mid-download close
            status.stringValue = "Downloading…"
            downloader.start(model: models[idx])
        }
        downloadWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func startModelDownload(_: NSButton) {
        onboardingStart?()
    }

}
