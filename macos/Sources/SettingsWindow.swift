import Cocoa

class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
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
    var filteredThemes: [(Int, BooTheme)] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
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

        opacitySlider = NSSlider(value: 0.95, minValue: 0.1, maxValue: 1.0, target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.controlSize = .regular
        opacityRow.addArrangedSubview(opacitySlider)

        opacityLabel = NSTextField(labelWithString: "0.95")
        opacityLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        opacityLabel.alignment = .right
        opacityLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        opacityRow.addArrangedSubview(opacityLabel)

        stack.addArrangedSubview(opacityRow)

        // ── Auto-type ──
        autoTypeCheckbox = NSButton(checkboxWithTitle: "Auto-type into focused app after transcription", target: self, action: #selector(autoTypeChanged(_:)))
        autoTypeCheckbox.state = .on
        autoTypeCheckbox.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(autoTypeCheckbox)

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
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredThemes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = themeTableView.selectedRow
        guard row >= 0, row < filteredThemes.count else { return }
        let (idx, _) = filteredThemes[row]
        ThemeManager.shared.selectTheme(at: idx)
        updatePreview()
        themeTableView.reloadData()
    }
}

extension Notification.Name {
    static let opacityChanged = Notification.Name("BooOpacityChanged")
    static let autoTypeChanged = Notification.Name("BooAutoTypeChanged")
}
