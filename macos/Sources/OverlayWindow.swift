import Cocoa

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class OverlayWindow: NSWindow {
    let booCtx: OpaquePointer
    let waveformView: WaveformView
    var isRecording = false
    var isTranscribing = false
    var autoType = true
    var previousApp: NSRunningApplication?
    var startedViaHotkey = false
    var statusLabel: NSTextField!
    var recordButton: NSButton!
    var displayLink: CVDisplayLink?

    // Transcript history
    var transcripts: [String] = []
    var transcriptStack: NSStackView!
    var transcriptScroll: NSScrollView!

    init(booCtx: OpaquePointer) {
        self.booCtx = booCtx
        self.waveformView = WaveformView(frame: .zero)

        let frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.minSize = NSSize(width: 400, height: 300)
        self.maxSize = NSSize(width: 400, height: 800)

        // Normal window level — can go behind other windows like a regular app
        self.level = .normal
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.backgroundColor = NSColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 0.95)
        self.isOpaque = false
        self.hasShadow = true
        self.hidesOnDeactivate = false

        if let screen = NSScreen.main {
            let x = screen.frame.maxX - frame.width - 20
            let y = screen.frame.maxY - frame.height - 50
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }

        setupUI()
        createDisplayLink()
        startTrafficLightTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    @objc func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = app
        }
    }

    private func setupUI() {
        guard let contentView = self.contentView else { return }
        contentView.wantsLayer = true

        // Layout: waveform (top) → transcript scroll (middle, fills space) → status + record button (bottom)

        // ── Waveform (top) ──
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(waveformView)

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(waveformClicked))
        waveformView.addGestureRecognizer(clickGesture)

        // ── Transcript scroll (middle — fills available space) ──
        transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.borderType = .noBorder
        transcriptScroll.drawsBackground = false
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        transcriptStack = NSStackView()
        transcriptStack.orientation = .vertical
        transcriptStack.spacing = 8
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false

        let docView = FlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(transcriptStack)

        transcriptScroll.documentView = docView

        // Pin transcript stack to document view edges — full width
        NSLayoutConstraint.activate([
            transcriptStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 4),
            transcriptStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            // Pin document view width to clip view so content doesn't overflow
            docView.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor),
        ])
        contentView.addSubview(transcriptScroll)

        // ── Bottom bar: status text + record button (centered) ──
        let bottomBar = NSStackView()
        bottomBar.orientation = .vertical
        bottomBar.spacing = 6
        bottomBar.alignment = .centerX
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomBar)

        // Status text
        statusLabel = NSTextField(labelWithString: "ctrl+shift+space")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = ThemeManager.shared.current.dim
        statusLabel.alignment = .center
        bottomBar.addArrangedSubview(statusLabel)

        // Record button — Apple Voice Memos style: simple flat red circle, no ring
        recordButton = NSButton(frame: .zero)
        recordButton.isBordered = false
        recordButton.title = ""
        recordButton.wantsLayer = true
        recordButton.layer?.backgroundColor = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1).cgColor // #FF3B30
        recordButton.layer?.cornerRadius = 20 // 40px circle
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)

        NSLayoutConstraint.activate([
            recordButton.widthAnchor.constraint(equalToConstant: 40),
            recordButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        bottomBar.addArrangedSubview(recordButton)

        // ── Auto Layout: waveform top, scroll middle (fills), bottom bar bottom ──
        let pad: CGFloat = 12
        NSLayoutConstraint.activate([
            waveformView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 32),
            waveformView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            waveformView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            waveformView.heightAnchor.constraint(equalToConstant: 48),

            transcriptScroll.topAnchor.constraint(equalTo: waveformView.bottomAnchor, constant: 8),
            transcriptScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            transcriptScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            transcriptScroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),

            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: pad),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -pad),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -pad),
        ])
    }

    // MARK: - Traffic Lights

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func startTrafficLightTimer() {
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = self.standardWindowButton(buttonType) {
                    if button.alphaValue < 1 || button.isHidden {
                        button.isHidden = false
                        button.alphaValue = 1
                        button.needsDisplay = true
                    }
                }
            }
        }
    }

    // MARK: - Theme

    func applyTheme(_ theme: BooTheme) {
        self.backgroundColor = theme.bgWithAlpha(0.95)
        waveformView.barColorIdle = theme.cyan
        waveformView.barColorRecording = theme.red
        waveformView.barColorThinking = theme.yellow
        statusLabel.textColor = theme.dim

        // Update all existing transcript bubbles
        for view in transcriptStack.arrangedSubviews {
            for subview in view.subviews {
                if let label = subview as? NSTextField, label.font?.fontName.contains("System") == true {
                    if label.font?.pointSize == 13 {
                        label.textColor = theme.fg  // transcript text
                    }
                }
                if let button = subview as? NSButton {
                    button.contentTintColor = theme.dim
                }
                // Also check button bars
                if let stack = subview as? NSStackView {
                    for item in stack.arrangedSubviews {
                        if let btn = item as? NSButton {
                            btn.contentTintColor = theme.dim
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc func toggleRecording() {
        toggleRecording(viaHotkey: false)
    }

    func toggleRecording(viaHotkey: Bool = false) {
        if isRecording {
            stopAndTranscribe()
        } else {
            startRecording(viaHotkey: viaHotkey)
        }
    }

    @objc func waveformClicked() {
        toggleRecording(viaHotkey: false)
    }

    func startRecording(viaHotkey: Bool = false) {
        startedViaHotkey = viaHotkey

        // Warm up mic first (starts audio queue, captures preroll)
        boo_warm_up(booCtx)
        statusLabel.stringValue = "warming up..."

        // Start display link for waveform animation
        startDisplayLink()

        // Start actual recording 500ms later — preroll captures the first words
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            boo_start_recording(self.booCtx)
            self.isRecording = true
            self.statusLabel.stringValue = "recording..."

            // Circle → rounded square
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                self.recordButton.layer?.cornerRadius = 6
            })
        }
    }

    func stopAndTranscribe() {
        boo_stop_recording(booCtx)
        isRecording = false
        statusLabel.stringValue = "thinking..."

        // Square → circle
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            recordButton.layer?.cornerRadius = 20
        })

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = boo_transcribe(self.booCtx)

            DispatchQueue.main.async {
                if let cStr = result {
                    let text = String(cString: cStr)
                    if !text.isEmpty {
                        self.addTranscript(text)
                        if self.autoType {
                            self.typeTextIntoFocusedApp(text)
                        }
                    } else {
                        self.statusLabel.stringValue = "no speech detected"
                    }
                } else {
                    self.statusLabel.stringValue = "no speech detected"
                }
                // Stop display link — no animation needed when idle
                self.stopDisplayLink()
            }
        }
    }

    // MARK: - Transcript History

    func addTranscript(_ text: String) {
        transcripts.append(text)
        statusLabel.stringValue = "ctrl+shift+space"

        let bubble = createTranscriptBubble(text, index: transcripts.count - 1)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.addArrangedSubview(bubble)
        bubble.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true

        // Update document view size
        transcriptStack.layoutSubtreeIfNeeded()
        if let docView = transcriptScroll.documentView {
            let h = transcriptStack.fittingSize.height + 8
            docView.frame = NSRect(x: 0, y: 0, width: transcriptScroll.frame.width, height: h)
        }

        // Scroll to bottom
        DispatchQueue.main.async {
            if let docView = self.transcriptScroll.documentView {
                let maxY = max(0, docView.frame.height - self.transcriptScroll.contentView.bounds.height)
                self.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
                self.transcriptScroll.reflectScrolledClipView(self.transcriptScroll.contentView)
            }
        }
    }

    func createTranscriptBubble(_ text: String, index: Int) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor

        let textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textLabel.textColor = ThemeManager.shared.current.fg
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        let buttonBar = NSStackView()
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 6
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        let copyBtn = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")!, target: self, action: #selector(copyBubbleText(_:)))
        copyBtn.bezelStyle = .accessoryBarAction
        copyBtn.isBordered = false
        copyBtn.tag = index
        copyBtn.contentTintColor = ThemeManager.shared.current.dim
        buttonBar.addArrangedSubview(copyBtn)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonBar.addArrangedSubview(spacer)

        let dismissBtn = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Dismiss")!, target: self, action: #selector(dismissBubble(_:)))
        dismissBtn.bezelStyle = .accessoryBarAction
        dismissBtn.isBordered = false
        dismissBtn.tag = index
        dismissBtn.contentTintColor = ThemeManager.shared.current.dim
        buttonBar.addArrangedSubview(dismissBtn)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(buttonBar)
        container.addSubview(separator)
        container.addSubview(textLabel)

        NSLayoutConstraint.activate([
            buttonBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            buttonBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            buttonBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            buttonBar.heightAnchor.constraint(equalToConstant: 20),

            separator.topAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            textLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            textLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            textLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        return container
    }

    @objc func copyBubbleText(_ sender: NSButton) {
        // Find the bubble container, then find the text label inside it
        var view: NSView? = sender
        while let v = view {
            if v.superview == transcriptStack {
                // Found the bubble — find the NSTextField with transcript text
                for subview in v.subviews {
                    if let label = subview as? NSTextField, label.font?.pointSize == 13 {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(label.stringValue, forType: .string)
                        break
                    }
                }
                break
            }
            view = v.superview
        }

        // Visual feedback
        sender.contentTintColor = ThemeManager.shared.current.cyan
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            sender.contentTintColor = ThemeManager.shared.current.dim
        }
    }

    @objc func dismissBubble(_ sender: NSButton) {
        // Walk up the view hierarchy to find the bubble container in the stack
        var view: NSView? = sender
        while let v = view {
            if v.superview == transcriptStack {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    v.animator().alphaValue = 0
                }, completionHandler: {
                    self.transcriptStack.removeArrangedSubview(v)
                    v.removeFromSuperview()
                    // Update document view size
                    self.transcriptStack.layoutSubtreeIfNeeded()
                    if let docView = self.transcriptScroll.documentView {
                        let h = self.transcriptStack.fittingSize.height + 8
                        docView.frame = NSRect(x: 0, y: 0, width: self.transcriptScroll.frame.width, height: h)
                    }
                })
                return
            }
            view = v.superview
        }
    }

    // MARK: - Auto-Type

    func typeTextIntoFocusedApp(_ text: String) {
        // Step 1: Put text on clipboard
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Step 2: If started via button click, re-activate previous app
        // If started via hotkey, the target app is ALREADY focused — don't switch
        if startedViaHotkey {
        } else if let app = previousApp {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        // Step 3: Paste via clipboard — most universally reliable method
        let delay = startedViaHotkey ? 0.15 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.performPaste()

            // Restore clipboard later
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let old = oldContents {
                    pasteboard.clearContents()
                    pasteboard.setString(old, forType: .string)
                }
            }
        }
    }

    private func performPaste() {
        // CGEvent only — no AppleScript, no extra permission dialogs
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(50000)
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
    }


    // MARK: - Display Link (only active during recording/transcribing)

    func createDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let link = dl else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let window = Unmanaged<OverlayWindow>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { window.updateWaveform() }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        displayLink = link
        // NOT started — only starts when recording begins
    }

    func startDisplayLink() {
        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    func stopDisplayLink() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    func updateWaveform() {
        var bars: Int32 = 0
        guard let data = boo_get_waveform(booCtx, &bars) else { return }
        let count = Int(bars)
        var waveform = [Float](repeating: 0, count: count)
        for i in 0..<count { waveform[i] = data[i] }
        let peak = boo_get_peak_rms(booCtx)
        let recording = boo_is_recording(booCtx)
        let transcribing = boo_is_transcribing(booCtx)

        waveformView.update(waveform: waveform, peakRms: peak, isRecording: recording, isTranscribing: transcribing)

        if recording {
            let samples = boo_get_audio_samples(booCtx)
            let secs = Float(samples) / 16000.0
            statusLabel.stringValue = String(format: "%.0fs", secs)
        }
    }

    deinit {
        if let link = displayLink { CVDisplayLinkStop(link) }
    }
}
