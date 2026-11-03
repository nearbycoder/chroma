import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// A format the user wrote, saved alongside the built-in ones.
struct CustomFormat: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var template: String

    var format: ColorFormat {
        ColorFormat(id: "custom-" + id.uuidString, name: name, group: "Custom", template: template, isCustom: true)
    }
}

/// "When I pick in Xcode, copy SwiftUI": a format per frontmost app.
struct AppFormatRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var formatID: String
}

enum MenuBarClick: String, CaseIterable, Identifiable {
    case menu, picker
    var id: String { rawValue }
    var title: String { self == .menu ? "Opens the Chroma menu" : "Starts the picker" }
}

enum DockEdge: String, CaseIterable, Identifiable, Codable {
    case left, right, top, bottom
    var id: String { rawValue }
    var isVertical: Bool { self == .left || self == .right }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let copyFormat = "copyFormat"
        static let shownFormats = "shownFormats"
        static let customFormats = "customFormats"
        static let uppercaseHex = "uppercaseHex"
        static let smartFormats = "smartFormats"
        static let appRules = "appRules"
        static let loupeSize = "loupeSize"
        static let loupeZoom = "loupeZoom"
        static let showGrid = "showGrid"
        static let sampleSize = "sampleSize"
        static let copyOnPick = "copyOnPick"
        static let showPickToast = "showPickToast"
        static let playSound = "playSound"
        static let historyLimit = "historyLimit"
        static let menuBarClick = "menuBarClick"
        static let tintMenuBarIcon = "tintMenuBarIcon"
        static let showDock = "showDock"
        static let dockEdge = "dockEdge"
        static let dockOffset = "dockOffset"
        static let dockCollapsed = "dockCollapsed"
        static let libraryFolder = "libraryFolder"
        static let hasOnboarded = "hasOnboarded"
        static let shortcuts = "shortcuts"
    }

    /// Scripted debug runs keep their settings apart from the real ones.
    let defaults = AppCoordinator.isHarness ? UserDefaults(suiteName: "dev.nearby.Chroma.harness")! : .standard

    // Formats
    @Published var copyFormatID: String { didSet { defaults.set(copyFormatID, forKey: Key.copyFormat) } }
    /// Format ids listed in the inspector and menus, in order.
    @Published var shownFormatIDs: [String] { didSet { defaults.set(shownFormatIDs, forKey: Key.shownFormats) } }
    @Published var customFormats: [CustomFormat] { didSet { store(customFormats, Key.customFormats) } }
    @Published var uppercaseHex: Bool { didSet { defaults.set(uppercaseHex, forKey: Key.uppercaseHex) } }
    @Published var smartFormats: Bool { didSet { defaults.set(smartFormats, forKey: Key.smartFormats) } }
    @Published var appRules: [AppFormatRule] { didSet { store(appRules, Key.appRules) } }

    // Picker
    /// Loupe diameter in points.
    @Published var loupeSize: Double { didSet { defaults.set(loupeSize, forKey: Key.loupeSize) } }
    /// Pixels across the loupe (odd, so one sits in the middle).
    @Published var loupeZoom: Int { didSet { defaults.set(loupeZoom, forKey: Key.loupeZoom) } }
    @Published var showGrid: Bool { didSet { defaults.set(showGrid, forKey: Key.showGrid) } }
    /// Average a 1×1, 3×3 or 5×5 square of pixels.
    @Published var sampleSize: Int { didSet { defaults.set(sampleSize, forKey: Key.sampleSize) } }
    @Published var copyOnPick: Bool { didSet { defaults.set(copyOnPick, forKey: Key.copyOnPick) } }
    @Published var showPickToast: Bool { didSet { defaults.set(showPickToast, forKey: Key.showPickToast) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Key.playSound) } }

    // General
    @Published var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: Key.historyLimit) } }
    @Published var menuBarClick: MenuBarClick { didSet { defaults.set(menuBarClick.rawValue, forKey: Key.menuBarClick) } }
    @Published var tintMenuBarIcon: Bool { didSet { defaults.set(tintMenuBarIcon, forKey: Key.tintMenuBarIcon) } }
    @Published var libraryFolder: URL { didSet { defaults.set(libraryFolder.path, forKey: Key.libraryFolder) } }
    @Published var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded) } }

    // Dock
    @Published var showDock: Bool { didSet { defaults.set(showDock, forKey: Key.showDock) } }
    @Published var dockEdge: DockEdge { didSet { defaults.set(dockEdge.rawValue, forKey: Key.dockEdge) } }
    /// Where along its edge the dock sits, 0…1.
    @Published var dockOffset: Double { didSet { defaults.set(dockOffset, forKey: Key.dockOffset) } }
    @Published var dockCollapsed: Bool { didSet { defaults.set(dockCollapsed, forKey: Key.dockCollapsed) } }

    /// A missing entry means the default; `.some(nil)` means the user cleared it.
    @Published var shortcuts: [ShortcutAction: Shortcut?] {
        didSet { store(Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) }), Key.shortcuts) }
    }

    static let defaultShownFormats = ["hex", "cssRGB", "cssHSL", "cssOKLCH", "tailwind", "swiftUI", "uiColorRGB", "nsColorRGB", "compose", "flutter", "androidXML", "name"]
    static let defaultLibraryFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent(AppCoordinator.isHarness ? "Chroma Harness" : "Chroma", isDirectory: true)
    static let loupeSizeRange = 100.0...280.0
    static let loupeZoomRange = 7...41

    private init() {
        defaults.register(defaults: [
            Key.copyFormat: "hex",
            Key.shownFormats: Self.defaultShownFormats,
            Key.uppercaseHex: true,
            Key.smartFormats: true,
            Key.loupeSize: 168.0,
            Key.loupeZoom: 15,
            Key.showGrid: true,
            Key.sampleSize: 1,
            Key.copyOnPick: true,
            Key.showPickToast: true,
            Key.playSound: false,
            Key.historyLimit: 200,
            Key.menuBarClick: MenuBarClick.menu.rawValue,
            Key.tintMenuBarIcon: true,
            Key.showDock: false,
            Key.dockEdge: DockEdge.right.rawValue,
            Key.dockOffset: 0.5,
            Key.dockCollapsed: false,
        ])
        copyFormatID = defaults.string(forKey: Key.copyFormat) ?? "hex"
        shownFormatIDs = defaults.stringArray(forKey: Key.shownFormats) ?? Self.defaultShownFormats
        uppercaseHex = defaults.bool(forKey: Key.uppercaseHex)
        smartFormats = defaults.bool(forKey: Key.smartFormats)
        loupeSize = defaults.double(forKey: Key.loupeSize)
        loupeZoom = defaults.integer(forKey: Key.loupeZoom)
        showGrid = defaults.bool(forKey: Key.showGrid)
        sampleSize = defaults.integer(forKey: Key.sampleSize)
        copyOnPick = defaults.bool(forKey: Key.copyOnPick)
        showPickToast = defaults.bool(forKey: Key.showPickToast)
        playSound = defaults.bool(forKey: Key.playSound)
        historyLimit = defaults.integer(forKey: Key.historyLimit)
        menuBarClick = MenuBarClick(rawValue: defaults.string(forKey: Key.menuBarClick) ?? "") ?? .menu
        tintMenuBarIcon = defaults.bool(forKey: Key.tintMenuBarIcon)
        showDock = defaults.bool(forKey: Key.showDock)
        dockEdge = DockEdge(rawValue: defaults.string(forKey: Key.dockEdge) ?? "") ?? .right
        dockOffset = defaults.double(forKey: Key.dockOffset)
        dockCollapsed = defaults.bool(forKey: Key.dockCollapsed)
        hasOnboarded = defaults.bool(forKey: Key.hasOnboarded)
        libraryFolder = defaults.string(forKey: Key.libraryFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultLibraryFolder

        let decoder = JSONDecoder()
        customFormats = defaults.data(forKey: Key.customFormats).flatMap { try? decoder.decode([CustomFormat].self, from: $0) } ?? []
        appRules = defaults.data(forKey: Key.appRules).flatMap { try? decoder.decode([AppFormatRule].self, from: $0) } ?? Self.defaultAppRules
        let stored = defaults.data(forKey: Key.shortcuts).flatMap { try? decoder.decode([String: Shortcut?].self, from: $0) } ?? [:]
        var shortcuts: [ShortcutAction: Shortcut?] = [:]
        for action in ShortcutAction.allCases {
            shortcuts[action] = stored.keys.contains(action.rawValue) ? stored[action.rawValue]! : action.defaultShortcut
        }
        self.shortcuts = shortcuts
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    static let defaultAppRules: [AppFormatRule] = [
        AppFormatRule(bundleID: "com.apple.dt.Xcode", appName: "Xcode", formatID: "swiftUI"),
        AppFormatRule(bundleID: "com.google.android.studio", appName: "Android Studio", formatID: "compose"),
    ]

    // MARK: Formats

    var allFormats: [ColorFormat] { ColorFormat.builtIn + customFormats.map(\.format) }

    func format(id: String) -> ColorFormat? { allFormats.first { $0.id == id } }

    var copyFormat: ColorFormat { format(id: copyFormatID) ?? .fallback }

    /// The formats listed in the inspector, menus and dock.
    var shownFormats: [ColorFormat] {
        let shown = shownFormatIDs.compactMap(format(id:))
        return shown.isEmpty ? [copyFormat] : shown
    }

    /// The format to copy right now: the frontmost app's rule when smart formats are on, otherwise the default.
    func formatForCopy(app bundleID: String?) -> ColorFormat {
        if smartFormats, let bundleID, let rule = appRules.first(where: { $0.bundleID == bundleID }), let format = format(id: rule.formatID) {
            return format
        }
        return copyFormat
    }

    func string(_ color: RGBColor, format: ColorFormat? = nil) -> String {
        (format ?? copyFormat).string(for: color, uppercaseHex: uppercaseHex)
    }

    func shortcut(_ action: ShortcutAction) -> Shortcut? { shortcuts[action] ?? nil }

    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) { shortcuts[action] = .some(shortcut) }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Chroma: failed to update login item: \(error)")
            }
        }
    }

    func resetToDefaults() {
        copyFormatID = "hex"
        shownFormatIDs = Self.defaultShownFormats
        uppercaseHex = true
        smartFormats = true
        appRules = Self.defaultAppRules
        loupeSize = 168
        loupeZoom = 15
        showGrid = true
        sampleSize = 1
        copyOnPick = true
        showPickToast = true
        playSound = false
        historyLimit = 200
        menuBarClick = .menu
        tintMenuBarIcon = true
        var shortcuts: [ShortcutAction: Shortcut?] = [:]
        for action in ShortcutAction.allCases { shortcuts[action] = action.defaultShortcut }
        self.shortcuts = shortcuts
    }
}

/// Global shortcuts, each registered as a Carbon hot key.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case pick, contrast, library, dock
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pick: "Pick a color"
        case .contrast: "Contrast checker"
        case .library: "Show the library"
        case .dock: "Show or hide the Color Dock"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .pick: .defaultPick
        case .contrast: .defaultContrast
        case .library: .defaultLibrary
        case .dock: .defaultDock
        }
    }

    var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

/// Runtime (non-persisted) state shared across the UI.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var hasScreenPermission = ScreenPermission.isGranted
    @Published var unavailableShortcuts: Set<ShortcutAction> = []
    @Published var isRecordingShortcut = false
    @Published var settingsTab: SettingsTab = .general

    func refreshPermission() {
        let granted = ScreenPermission.isGranted
        if granted != hasScreenPermission {
            hasScreenPermission = granted
        }
    }
}

enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Adds Chroma to the Screen Recording list (once) so the user only has to flip its switch.
    static func request() {
        if !CGRequestScreenCaptureAccess() {
            openSystemSettings()
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quits and reopens Chroma so a newly granted permission takes effect.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
