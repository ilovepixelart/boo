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
            popup.addItem(withTitle: "\(cs(m.label))  (\(cs(m.note)))")
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
        // Wire the controls to a downloader the button action can reach.
        modelDownloader = ModelDownloader(
            models: models, count: count, popup: popup, bar: bar, status: status,
            button: button, window: win
        ) { [weak self] path in
            win.close()
            self?.startWithModel(path: path)
        }
        downloadWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func startModelDownload(_ sender: NSButton) {
        modelDownloader?.start()
    }

    private func cs(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? ""
    }
}

/// Streams the selected model with progress, verifies its pinned SHA-256, moves
/// it into ~/.boo/models, and reports the final path.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private let models: UnsafePointer<BooModelInfo>
    private let count: Int
    private let popup: NSPopUpButton
    private let bar: NSProgressIndicator
    private let status: NSTextField
    private let button: NSButton
    private let window: NSWindow
    private let onDone: (String) -> Void
    private var session: URLSession?
    private var model: BooModelInfo?

    init(
        models: UnsafePointer<BooModelInfo>, count: Int, popup: NSPopUpButton,
        bar: NSProgressIndicator, status: NSTextField, button: NSButton, window: NSWindow,
        onDone: @escaping (String) -> Void
    ) {
        self.models = models
        self.count = count
        self.popup = popup
        self.bar = bar
        self.status = status
        self.button = button
        self.window = window
        self.onDone = onDone
    }

    func start() {
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < count, let url = URL(string: str(models[idx].url)) else { return }
        model = models[idx]
        button.isEnabled = false
        popup.isEnabled = false
        window.standardWindowButton(.closeButton)?.isEnabled = false  // no mid-download close
        status.stringValue = "Downloading…"
        let cfg = URLSessionConfiguration.default
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        session?.downloadTask(with: url).resume()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let total = Double(model?.size ?? 0)
        if total > 0 { bar.doubleValue = Double(totalBytesWritten) / total * 100 }
    }

    // Must move/verify synchronously: URLSession deletes `location` on return.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let model = model else { return }
        guard let data = try? Data(contentsOf: location, options: .mappedIfSafe) else {
            fail("Could not read the download.")
            return
        }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hex == str(model.sha256) else {
            fail("Downloaded file failed its checksum. Try again.")
            return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".boo/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(str(model.filename))
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            fail("Could not save the model file.")
            return
        }
        boo_log(Int32(BOO_LOG_INFO), "model downloaded and verified")
        onDone(dest.path)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        if let error = error { fail("Download failed: \(error.localizedDescription)") }
    }

    private func fail(_ why: String) {
        boo_log(Int32(BOO_LOG_ERROR), "model download failed")
        status.stringValue = why
        button.isEnabled = true
        popup.isEnabled = true
        window.standardWindowButton(.closeButton)?.isEnabled = true
    }

    private func str(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? ""
    }
}
