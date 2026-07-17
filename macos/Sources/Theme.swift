import Cocoa

struct BooTheme {
    let name: String
    let bg: NSColor
    let fg: NSColor
    let palette: [NSColor]  // 16 ANSI colors

    // Convenience accessors matching Ghostty palette indices
    var dim: NSColor { palette[8] }  // bright black
    var red: NSColor { palette[9] }  // bright red
    var green: NSColor { palette[10] }  // bright green
    var yellow: NSColor { palette[11] }  // bright yellow
    var blue: NSColor { palette[12] }  // bright blue
    var magenta: NSColor { palette[13] }  // bright magenta
    var cyan: NSColor { palette[14] }  // bright cyan
    var white: NSColor { palette[15] }  // bright white

    func bgWithAlpha(_ alpha: CGFloat) -> NSColor {
        return bg.withAlphaComponent(alpha)
    }

    func surfaceColor(_ alpha: CGFloat) -> NSColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.getRed(&r, green: &g, blue: &b, alpha: &a)
        return NSColor(red: min(r + 0.05, 1), green: min(g + 0.05, 1), blue: min(b + 0.05, 1), alpha: alpha)
    }
}

class ThemeManager {
    static let shared = ThemeManager()

    var themes: [BooTheme] = []
    var currentIndex: Int = 0

    var current: BooTheme {
        guard currentIndex < themes.count else { return defaultTheme }
        return themes[currentIndex]
    }

    private let defaultTheme = BooTheme(
        name: "Ghostty",
        bg: NSColor(red: 0x29 / 255.0, green: 0x2c / 255.0, blue: 0x33 / 255.0, alpha: 1),
        fg: NSColor.white,
        palette: [
            NSColor(red: 0x1d / 255.0, green: 0x1f / 255.0, blue: 0x21 / 255.0, alpha: 1),
            NSColor(red: 0xbf / 255.0, green: 0x6b / 255.0, blue: 0x69 / 255.0, alpha: 1),
            NSColor(red: 0xb7 / 255.0, green: 0xbd / 255.0, blue: 0x73 / 255.0, alpha: 1),
            NSColor(red: 0xe9 / 255.0, green: 0xc8 / 255.0, blue: 0x80 / 255.0, alpha: 1),
            NSColor(red: 0x88 / 255.0, green: 0xa1 / 255.0, blue: 0xbb / 255.0, alpha: 1),
            NSColor(red: 0xad / 255.0, green: 0x95 / 255.0, blue: 0xb8 / 255.0, alpha: 1),
            NSColor(red: 0x95 / 255.0, green: 0xbd / 255.0, blue: 0xb7 / 255.0, alpha: 1),
            NSColor(red: 0xc5 / 255.0, green: 0xc8 / 255.0, blue: 0xc6 / 255.0, alpha: 1),
            NSColor(red: 0x66 / 255.0, green: 0x66 / 255.0, blue: 0x66 / 255.0, alpha: 1),
            NSColor(red: 0xc5 / 255.0, green: 0x57 / 255.0, blue: 0x57 / 255.0, alpha: 1),
            NSColor(red: 0xbc / 255.0, green: 0xc9 / 255.0, blue: 0x5f / 255.0, alpha: 1),
            NSColor(red: 0xe1 / 255.0, green: 0xc6 / 255.0, blue: 0x5e / 255.0, alpha: 1),
            NSColor(red: 0x83 / 255.0, green: 0xa5 / 255.0, blue: 0xd6 / 255.0, alpha: 1),
            NSColor(red: 0xbc / 255.0, green: 0x99 / 255.0, blue: 0xd4 / 255.0, alpha: 1),
            NSColor(red: 0x83 / 255.0, green: 0xbe / 255.0, blue: 0xb1 / 255.0, alpha: 1),
            NSColor(red: 0xea / 255.0, green: 0xea / 255.0, blue: 0xea / 255.0, alpha: 1),
        ]
    )

    init() {
        loadThemes()
    }

    private func loadThemes() {
        // Enumerate the themes dir here, but parse each file through the shared
        // core parser (boo_theme_parse_file) so macOS, Linux and Windows read
        // one implementation of the Ghostty format.
        themes = [defaultTheme]

        guard let dir = findThemesDir(),
            let files = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else {
            print("No themes directory found, using default only")
            return
        }

        for file in files.sorted() {
            let path = (dir as NSString).appendingPathComponent(file)
            var colors = BooThemeColors()
            if boo_theme_parse_file(path, &colors) {
                themes.append(makeTheme(name: file, colors: colors))
            }
        }

        if let idx = themes.firstIndex(where: { $0.name == "Ghostty Default Style Dark" }) {
            currentIndex = idx
        }
        print("Loaded \(themes.count) themes")
    }

    private func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    private func makeTheme(name: String, colors: BooThemeColors) -> BooTheme {
        var palette = [NSColor]()
        palette.reserveCapacity(16)
        withUnsafeBytes(of: colors.palette) { raw in
            let buf = raw.bindMemory(to: UInt32.self)
            for i in 0..<16 { palette.append(color(buf[i])) }
        }
        return BooTheme(name: name, bg: color(colors.bg), fg: color(colors.fg), palette: palette)
    }

    private func findThemesDir() -> String? {
        // Bundle path: /path/to/boo/zig-out/Boo.app
        // We want:     /path/to/boo/themes
        let bundlePath = Bundle.main.bundlePath
        let bundleDir = (bundlePath as NSString).deletingLastPathComponent  // zig-out/
        let projectDir = (bundleDir as NSString).deletingLastPathComponent  // boo/

        let candidates = [
            projectDir + "/themes",
            bundleDir + "/themes",
            (Bundle.main.resourcePath ?? "") + "/themes",
            NSHomeDirectory() + "/.boo/themes",
            FileManager.default.currentDirectoryPath + "/themes",
        ]

        print("Searching for themes directory:")
        for path in candidates {
            let exists = FileManager.default.fileExists(atPath: path)
            print("  \(exists ? "✓" : "✗") \(path)")
            if exists {
                return path
            }
        }
        return nil
    }

    func selectTheme(at index: Int) {
        guard index >= 0, index < themes.count else { return }
        currentIndex = index
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }
}

extension Notification.Name {
    static let themeChanged = Notification.Name("BooThemeChanged")
    static let booRecordingStarted = Notification.Name("BooRecordingStarted")
    static let booRecordingStopped = Notification.Name("BooRecordingStopped")
}
