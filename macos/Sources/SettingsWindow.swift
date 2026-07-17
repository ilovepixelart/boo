import Cocoa

class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 490),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Boo Settings"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.contentViewController = SettingsViewController()
    }
}

class SettingsViewController: NSViewController {
    var searchField: NSSearchField!
    var themeTableView: NSTableView!
    var opacitySlider: NSSlider!
    var opacityLabel: NSTextField!
    var autoTypeCheckbox: NSButton!
    var themePreview: NSView!
    var modelPopup: NSPopUpButton!
    var modelStatus: NSTextField!
    var modelProgress: NSProgressIndicator!
    var filteredThemes: [(Int, BooTheme)] = []
    var modelChoices: [ModelChoice] = []
    // Retained while a settings-initiated model download runs.
    var modelDownloader: ModelDownloader?

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 490))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        filterThemes("")
    }

    private func setupUI() {
        // Main vertical stack
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        // ── Opacity ──
        let opacityRow = NSStackView()
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8

        let opacityTitle = NSTextField(labelWithString: "Opacity")
        opacityTitle.font = .systemFont(ofSize: 13, weight: .medium)
        opacityRow.addArrangedSubview(opacityTitle)

        // Controls open at the persisted values, so the first interaction
        // adjusts the real state rather than stomping it with defaults.
        let savedOpacity = AppDelegate.savedOpacity()
        opacitySlider = NSSlider(
            value: savedOpacity, minValue: 0.1, maxValue: 1.0, target: self,
            action: #selector(opacityChanged(_:)))
        opacitySlider.controlSize = .regular
        opacityRow.addArrangedSubview(opacitySlider)

        opacityLabel = NSTextField(labelWithString: String(format: "%.2f", savedOpacity))
        opacityLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        opacityLabel.alignment = .right
        opacityLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        opacityRow.addArrangedSubview(opacityLabel)

        stack.addArrangedSubview(opacityRow)

        // ── Auto-type ──
        let savedAutoType = AppDelegate.savedAutoType()
        autoTypeCheckbox = NSButton(
            checkboxWithTitle: "Auto-type into focused app after transcription", target: self,
            action: #selector(autoTypeChanged(_:)))
        autoTypeCheckbox.state = savedAutoType ? .on : .off
        autoTypeCheckbox.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(autoTypeCheckbox)

        // ── Model ──
        // One dropdown merging models on disk with the curated manifest;
        // entries not yet downloaded are tagged, and picking one downloads it
        // (progress below), then swaps to it.
        let modelTitle = NSTextField(labelWithString: "Model")
        modelTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(modelTitle)

        modelPopup = NSPopUpButton()
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        stack.addArrangedSubview(modelPopup)

        modelProgress = NSProgressIndicator()
        modelProgress.isIndeterminate = false
        modelProgress.minValue = 0
        modelProgress.maxValue = 100
        modelProgress.isHidden = true
        stack.addArrangedSubview(modelProgress)

        modelStatus = NSTextField(labelWithString: "")
        modelStatus.font = .systemFont(ofSize: 11)
        modelStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(modelStatus)

        reloadModelList()

        // ── Theme section ──
        let themeTitle = NSTextField(labelWithString: "Theme")
        themeTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(themeTitle)

        // Search field
        searchField = NSSearchField()
        searchField.placeholderString = "Search themes..."
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        stack.addArrangedSubview(searchField)

        // Theme list
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        themeTableView = NSTableView()
        themeTableView.headerView = nil
        themeTableView.rowHeight = 28
        themeTableView.style = .plain
        themeTableView.delegate = self
        themeTableView.dataSource = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
        column.title = "Theme"
        themeTableView.addTableColumn(column)

        scrollView.documentView = themeTableView
        stack.addArrangedSubview(scrollView)

        // Theme preview
        themePreview = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 40))
        themePreview.wantsLayer = true
        themePreview.layer?.cornerRadius = 8
        themePreview.heightAnchor.constraint(equalToConstant: 40).isActive = true
        updatePreview()
        stack.addArrangedSubview(themePreview)
    }

    @objc func opacityChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        opacityLabel.stringValue = String(format: "%.2f", value)
        NotificationCenter.default.post(name: .opacityChanged, object: value)
    }

    @objc func autoTypeChanged(_ sender: NSButton) {
        NotificationCenter.default.post(name: .autoTypeChanged, object: sender.state == .on)
    }

    /// Refill the model popup: models on disk first (ranked), then curated
    /// manifest models not yet downloaded, tagged with their size. Selects the
    /// loaded model.
    func reloadModelList() {
        guard let app = appDelegate else { return }
        let installed = app.installedModels()
        modelChoices = installed.map { ModelChoice(title: $0.name, path: $0.path, manifest: nil) }
        var count = 0
        if let models = boo_models(&count) {
            let onDisk = Set(installed.map { $0.name })
            for i in 0..<count where !onDisk.contains(String(cString: models[i].filename)) {
                let m = models[i]
                let name = String(cString: m.filename)
                modelChoices.append(
                    ModelChoice(
                        title: "\(name)  (download, \(m.size / 1_000_000) MB)",
                        path: nil, manifest: m))
            }
        }
        modelPopup.removeAllItems()
        for choice in modelChoices {
            modelPopup.addItem(withTitle: choice.title)
        }
        if let current = app.currentModelPath,
            let idx = modelChoices.firstIndex(where: { $0.path == current })
        {
            modelPopup.selectItem(at: idx)
        }
    }

    @objc func modelChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard let app = appDelegate, idx >= 0, idx < modelChoices.count else { return }
        let choice = modelChoices[idx]
        guard let path = choice.path else {
            if let manifest = choice.manifest { downloadAndSwitch(to: manifest) }
            return
        }
        guard path != app.currentModelPath else { return }
        if let ctx = app.booCtx, boo_is_recording(ctx) || boo_is_transcribing(ctx) {
            modelStatus.stringValue = "Stop recording first."
            reloadModelList()  // snap the selection back to the loaded model
            return
        }
        modelPopup.isEnabled = false
        modelStatus.stringValue = "Loading \(choice.title)…"
        app.switchModel(path: path) { [weak self] ok in
            guard let self = self else { return }
            self.modelPopup.isEnabled = true
            self.modelStatus.stringValue =
                ok
                ? "Loaded \(choice.title)."
                : "Could not load \(choice.title); keeping the previous model."
            if !ok { self.reloadModelList() }
        }
    }

    /// Fetch a not-yet-downloaded manifest model (progress bar under the
    /// dropdown), then swap to it like any installed model.
    private func downloadAndSwitch(to manifest: BooModelInfo) {
        let name = String(cString: manifest.filename)
        modelPopup.isEnabled = false
        modelProgress.doubleValue = 0
        modelProgress.isHidden = false
        modelStatus.stringValue = "Downloading \(name)…"
        let downloader = ModelDownloader(
            onProgress: { [weak self] percent in self?.modelProgress.doubleValue = percent },
            onDone: { [weak self] path in
                guard let self = self else { return }
                self.modelProgress.isHidden = true
                self.modelPopup.isEnabled = true
                self.appDelegate?.switchModel(path: path) { ok in
                    self.reloadModelList()
                    self.modelStatus.stringValue =
                        ok ? "Downloaded and switched to \(name)." : "Downloaded, but it could not be loaded."
                }
            },
            onFail: { [weak self] why in
                guard let self = self else { return }
                self.modelProgress.isHidden = true
                self.modelPopup.isEnabled = true
                self.modelStatus.stringValue = why
                self.reloadModelList()
            })
        modelDownloader = downloader
        downloader.start(model: manifest)
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        filterThemes(sender.stringValue)
    }

    func filterThemes(_ query: String) {
        let q = query.lowercased()
        let all = ThemeManager.shared.themes
        if q.isEmpty {
            filteredThemes = all.enumerated().map { ($0.offset, $0.element) }
        } else {
            filteredThemes = all.enumerated()
                .filter { $0.element.name.lowercased().contains(q) }
                .map { ($0.offset, $0.element) }
        }
        themeTableView.reloadData()

        // Select current theme in the list
        if let row = filteredThemes.firstIndex(where: { $0.0 == ThemeManager.shared.currentIndex }) {
            themeTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func updatePreview() {
        let theme = ThemeManager.shared.current
        themePreview.layer?.backgroundColor = theme.bg.cgColor

        // Remove old subviews
        themePreview.subviews.forEach { $0.removeFromSuperview() }

        // Add color swatches
        let swatchStack = NSStackView()
        swatchStack.orientation = .horizontal
        swatchStack.spacing = 4
        swatchStack.translatesAutoresizingMaskIntoConstraints = false
        themePreview.addSubview(swatchStack)

        NSLayoutConstraint.activate([
            swatchStack.centerYAnchor.constraint(equalTo: themePreview.centerYAnchor),
            swatchStack.leadingAnchor.constraint(equalTo: themePreview.leadingAnchor, constant: 12),
        ])

        for i in 0..<16 {
            let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 4
            swatch.layer?.backgroundColor = theme.palette[i].cgColor
            swatch.widthAnchor.constraint(equalToConstant: 18).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
            swatchStack.addArrangedSubview(swatch)
        }
    }
}

extension SettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int {
        return filteredThemes.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let (idx, theme) = filteredThemes[row]

        let cell = NSStackView()
        cell.orientation = .horizontal
        cell.spacing = 8

        // Color swatch showing bg color
        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.layer?.backgroundColor = theme.bg.cgColor
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.borderWidth = 0.5
        swatch.widthAnchor.constraint(equalToConstant: 20).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 20).isActive = true
        cell.addArrangedSubview(swatch)

        // Theme name
        let label = NSTextField(labelWithString: theme.name)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        if idx == ThemeManager.shared.currentIndex {
            label.textColor = .controlAccentColor
        }
        cell.addArrangedSubview(label)

        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        let row = themeTableView.selectedRow
        guard row >= 0, row < filteredThemes.count else { return }
        let (idx, _) = filteredThemes[row]
        ThemeManager.shared.selectTheme(at: idx)
        updatePreview()
        themeTableView.reloadData()
    }
}

/// One model-dropdown entry: a model on disk (`path` set) or a curated
/// manifest model not yet downloaded (`manifest` set); picking the latter
/// downloads it first. Exactly one of the two is set.
struct ModelChoice {
    let title: String
    let path: String?
    let manifest: BooModelInfo?
}
