import Carbon
import Cocoa

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class OverlayWindow: NSWindow {
    /// The one idle hint; flashStatus reverts by comparing against it, so a
    /// hotkey change must not leave stale copies behind.
    static let idleHint = "ctrl+shift+space"

    let booCtx: OpaquePointer
    let waveformView: WaveformView
    var isRecording = false
    var autoType = true
    // Window background opacity, default fully opaque to match Ghostty. Held
    // here so a theme change reapplies the user's chosen opacity, not a constant.
    var opacity: CGFloat = 1.0
    var previousApp: NSRunningApplication?
    /// Where the transcript is destined, captured when recording starts.
    /// Resolving this at transcription time instead would be wrong: by then
    /// Boo's own window is frontmost, and Boo is never the dictation target.
    var targetApp: NSRunningApplication?
    var startedViaHotkey = false
    var statusLabel: NSTextField!
    var recordButton: NSButton!
    var waveformLink: CADisplayLink?
    // Stored so closing can stop it; an anonymous repeating timer would wake
    // the process at 3.3 Hz forever with no way to cancel it.
    var trafficLightTimer: Timer?

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
        // ARC owns this window (AppDelegate holds it strongly), so AppKit must
        // not also release it on close, or closing the overlay while another
        // window keeps the app alive over-releases it. SettingsWindow does the
        // same.
        self.isReleasedWhenClosed = false

        // Normal window level, can go behind other windows like a regular app
        self.level = .normal
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.backgroundColor = NSColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1.0)
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
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
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

        // ── Transcript scroll (middle, fills available space) ──
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

        // Pin transcript stack to document view edges, full width
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
        statusLabel = NSTextField(labelWithString: OverlayWindow.idleHint)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = ThemeManager.shared.current.dim
        statusLabel.alignment = .center
        bottomBar.addArrangedSubview(statusLabel)

        // Record button, Apple Voice Memos style: simple flat red circle, no ring
        recordButton = NSButton(frame: .zero)
        recordButton.isBordered = false
        recordButton.title = ""
        recordButton.wantsLayer = true
        recordButton.layer?.backgroundColor = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1).cgColor  // #FF3B30
        recordButton.layer?.cornerRadius = 20  // 40px circle
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
    override var canBecomeMain: Bool { canBecomeKey }

    private func startTrafficLightTimer() {
        trafficLightTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = self.standardWindowButton(buttonType),
                    button.alphaValue < 1 || button.isHidden
                {
                    button.isHidden = false
                    button.alphaValue = 1
                    button.needsDisplay = true
                }
            }
        }
    }

    // MARK: - Theme

    func applyTheme(_ theme: BooTheme) {
        self.backgroundColor = theme.bgWithAlpha(opacity)
        waveformView.barColorIdle = theme.cyan
        waveformView.barColorRecording = theme.red
        waveformView.barColorThinking = theme.yellow
        statusLabel.textColor = theme.dim

        // Update all existing transcript bubbles
        for view in transcriptStack.arrangedSubviews {
            for subview in view.subviews {
                if let label = subview as? NSTextField,
                    label.font?.fontName.contains("System") == true,
                    label.font?.pointSize == 13
                {
                    label.textColor = theme.fg  // transcript text
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

    // MARK: - Streaming (VAD-chunked) transcription

    /// One serial queue for boo_stream_tick, per the C API contract; a tick
    /// blocks for one utterance's inference, so it must never run on main.
    private let streamQueue = DispatchQueue(label: "com.boo.stream", qos: .userInitiated)
    private var streamTimer: DispatchSourceTimer?
    /// Tracks the off-main stop+transcribe task so teardown can wait for it: a
    /// quit mid-transcription would otherwise free the context under a live
    /// boo_transcribe (stream ticks are drained by streamQueue, swaps by the
    /// AppDelegate's group, but this task had neither).
    private let transcribeGroup = DispatchGroup()
    private var liveBubbleContainer: NSView?
    private var liveBubbleLabel: NSTextField?

    private func startStreamTicks() {
        let timer = DispatchSource.makeTimerSource(queue: streamQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard boo_stream_tick(self.booCtx), let cStr = boo_get_live_transcript(self.booCtx) else {
                return
            }
            let text = String(cString: cStr)
            DispatchQueue.main.async { self.updateLiveTranscript(text) }
        }
        timer.resume()
        streamTimer = timer
    }

    private func stopStreamTicks() {
        streamTimer?.cancel()
        streamTimer = nil
    }

    /// Stop the background stream ticks and recording so no core call is in
    /// flight when the context is torn down: cancelling the timer stops future
    /// ticks, and the serial-queue barrier waits out any tick already running.
    /// Without this a Cmd+Q mid-dictation frees the context under a live
    /// boo_stream_tick. Safe to call repeatedly and off any prior state.
    func stopForTeardown() {
        stopStreamTicks()
        streamQueue.sync {
            // Empty on purpose: submitting to the serial queue and waiting is a
            // barrier that returns only once any in-flight tick has finished.
        }
        boo_stop_recording(booCtx)
        // A quit landing mid-transcription (stop pressed, then Cmd+Q during the
        // multi-second decode) must not free the context under boo_transcribe.
        transcribeGroup.wait()
    }

    /// Show the committed-so-far text in a dimmed, button-less bubble while
    /// still recording. Replaced by the real transcript bubble on stop. Internal
    /// (not private) so the headless harness can pin the in-place replacement.
    func updateLiveTranscript(_ text: String) {
        guard isRecording, !text.isEmpty else { return }

        if liveBubbleContainer == nil {
            let container = NSView()
            container.wantsLayer = true
            container.layer?.cornerRadius = 10
            container.layer?.backgroundColor = NSColor(white: 1, alpha: 0.03).cgColor

            let label = NSTextField(wrappingLabelWithString: "")
            label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = ThemeManager.shared.current.dim
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            ])

            container.translatesAutoresizingMaskIntoConstraints = false
            transcriptStack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
            liveBubbleContainer = container
            liveBubbleLabel = label
        }

        liveBubbleLabel?.stringValue = text
        layoutTranscriptStack()
    }

    func removeLiveBubble() {
        liveBubbleContainer?.removeFromSuperview()
        liveBubbleContainer = nil
        liveBubbleLabel = nil
    }

    func startRecording(viaHotkey: Bool = false) {
        // One take at a time. The hotkey can fire during the multi-second
        // transcription that follows a stop; the core ignores the start then,
        // so starting the UI too would desync it into a phantom recording.
        guard !boo_is_transcribing(booCtx) else { return }
        // No microphone: Boo still runs, but recording is a no-op. Say so
        // rather than faking a take the core will not actually capture.
        guard boo_has_microphone(booCtx) else {
            statusLabel.stringValue = "no microphone"
            return
        }
        startedViaHotkey = viaHotkey

        // Pin the destination now. `previousApp` tracks the last non-Boo app to
        // activate, so it's the right answer whenever Boo itself holds focus ,
        // which is always true for the Record button, and true for the hotkey
        // too once Boo's window has been clicked.
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetApp =
            (frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier)
            ? previousApp
            : (frontmost ?? previousApp)

        // Instant UI feedback
        isRecording = true
        statusLabel.stringValue = "recording..."
        startDisplayLink()
        NotificationCenter.default.post(name: .booRecordingStarted, object: nil)

        // Circle → rounded square immediately
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            recordButton.layer?.cornerRadius = 6
        })

        // Start recording immediately (warm-up + record in one call)
        // Audio queue starts and recording flag set atomically
        boo_warm_up(booCtx)
        boo_start_recording(booCtx)
        startStreamTicks()
    }

    func stopAndTranscribe() {
        isRecording = false
        stopStreamTicks()
        statusLabel.stringValue = "thinking..."
        NotificationCenter.default.post(name: .booRecordingStopped, object: nil)

        // Square → circle immediately
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            recordButton.layer?.cornerRadius = 20
        })

        // Move EVERYTHING off the main thread, stop audio + transcribe. The task
        // is tracked in transcribeGroup (entered before the dispatch, left when
        // it exits) so a quit waits it out before boo_deinit. `group` is captured
        // strongly so leave() fires even if self is gone, or the group would
        // never empty and teardown would hang.
        let group = transcribeGroup
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { group.leave() }
            guard let self = self else { return }

            // Stop audio on background thread (AudioQueueStop can block)
            boo_stop_recording(self.booCtx)

            // Transcribe with autorelease pool for Metal
            let result: UnsafePointer<CChar>? = autoreleasepool {
                return boo_transcribe(self.booCtx)
            }
            // Copy the transcript off the core's buffer while the context is
            // alive: the returned pointer is freed by boo_deinit, and the
            // main-queue delivery below may run after teardown.
            let text = result.map { String(cString: $0) }

            DispatchQueue.main.async {
                // The provisional live bubble is superseded by the final
                // transcript (or by "no speech") either way.
                self.removeLiveBubble()
                if let text = text, !text.isEmpty {
                    self.addTranscript(text)
                    if self.autoType {
                        self.typeTextIntoFocusedApp(text)
                    } else {
                        // Auto-type off means clipboard-only, never silent:
                        // the transcript must still land somewhere pasteable.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.flashStatus("copied")
                    }
                } else {
                    self.statusLabel.stringValue = "no speech detected"
                }
                // Stop display link, no animation needed when idle
                self.stopDisplayLink()
            }
        }
    }

    /// Show a short-lived delivery outcome ("copied" / "pasted"), then settle
    /// back on the idle hotkey hint, matching the other frontends' transient
    /// confirmations.
    func flashStatus(_ text: String) {
        statusLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.statusLabel.stringValue == text && !self.isRecording {
                self.statusLabel.stringValue = OverlayWindow.idleHint
            }
        }
    }

    // MARK: - Transcript History

    func addTranscript(_ text: String) {
        transcripts.append(text)
        statusLabel.stringValue = OverlayWindow.idleHint

        let bubble = createTranscriptBubble(text, index: transcripts.count - 1)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.addArrangedSubview(bubble)
        bubble.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true

        layoutTranscriptStack()
    }

    /// Resize the document view to the stack and keep the newest text visible.
    private func layoutTranscriptStack() {
        transcriptStack.layoutSubtreeIfNeeded()
        if let docView = transcriptScroll.documentView {
            let h = transcriptStack.fittingSize.height + 8
            docView.frame = NSRect(x: 0, y: 0, width: transcriptScroll.frame.width, height: h)
        }

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

        let copyBtn = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")!, target: self,
            action: #selector(copyBubbleText(_:)))
        copyBtn.bezelStyle = .accessoryBarAction
        copyBtn.isBordered = false
        copyBtn.tag = index
        copyBtn.contentTintColor = ThemeManager.shared.current.dim
        buttonBar.addArrangedSubview(copyBtn)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonBar.addArrangedSubview(spacer)

        let dismissBtn = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Dismiss")!, target: self,
            action: #selector(dismissBubble(_:)))
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
                // Found the bubble, find the NSTextField with transcript text
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
                NSAnimationContext.runAnimationGroup(
                    { ctx in
                        ctx.duration = 0.2
                        v.animator().alphaValue = 0
                    },
                    completionHandler: {
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
        // The delivery mechanism (Ghostty API vs clipboard+⌘V, the clipboard
        // snapshot/restore, the layout-correct paste key) lives in TextDelivery;
        // this maps its outcome onto the status line.
        TextDelivery.deliver(text, to: targetApp ?? previousApp, viaHotkey: startedViaHotkey) {
            [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .pasted:
                self.flashStatus("pasted")
            case .copiedNeedsAccessibility:
                self.statusLabel.stringValue = "copied, grant Accessibility to auto-paste"
            }
        }
    }

    // MARK: - Display Link (only active during recording/transcribing)
    //
    // NSWindow.displayLink (macOS 14+) rather than CVDisplayLink, which Apple
    // deprecated in macOS 15. It fires on the main thread and tracks the display
    // the window is actually on, so it needs neither the hop through
    // DispatchQueue.main nor an unmanaged self pointer that the C callback did.

    func createDisplayLink() {
        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        link.isPaused = true  // only runs while recording / transcribing
        waveformLink = link
    }

    @objc private func displayLinkFired() {
        updateWaveform()
    }

    func startDisplayLink() {
        waveformLink?.isPaused = false
    }

    func stopDisplayLink() {
        waveformLink?.isPaused = true
    }

    func updateWaveform() {
        // The core stops capturing on its own at MAX_RECORDING_SECONDS, to keep
        // an accidentally-abandoned recording from ballooning memory and then
        // freezing the app in whisper. It can't finish the job from inside the
        // audio callback, so notice it here and transcribe what was captured.
        if isRecording && !boo_is_recording(booCtx) {
            // After stopAndTranscribe, whose own "thinking..." would otherwise
            // overwrite this in the same frame and the cap would look silent.
            stopAndTranscribe()
            statusLabel.stringValue = "max length reached"
            return
        }

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

    override func close() {
        // The display link retains its target (this window) and the run loop
        // retains the link, so deinit alone can never run; break the cycle
        // here, where closing actually happens.
        waveformLink?.invalidate()
        waveformLink = nil
        trafficLightTimer?.invalidate()
        trafficLightTimer = nil
        // The workspace observer is unsafe-unretained; drop it so a later
        // activation can't fire the selector on a deallocated window.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        super.close()
    }

    deinit {
        // Belt and suspenders for a teardown path that skips close().
        waveformLink?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
