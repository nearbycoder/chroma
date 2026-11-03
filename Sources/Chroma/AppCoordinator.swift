import AppKit
import Combine
import SwiftUI

@main
@MainActor
enum ChromaMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests load the app as their host; keep it inert.
        guard NSClassFromString("XCTestCase") == nil else { return }
        MainMenu.install()
        let coordinator = AppCoordinator()
        coordinator.start()
        self.coordinator = coordinator
        pendingURLs.forEach(coordinator.open(url:))
        pendingURLs.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let coordinator else {
            pendingURLs += urls
            return
        }
        urls.forEach(coordinator.open(url:))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { coordinator?.showLibrary() }
        return false
    }
}

@MainActor
final class AppCoordinator {
    private(set) static weak var shared: AppCoordinator?

    private(set) var session: PickerSession?
    private var isStarting = false
    private let statusBar = StatusBarController()
    private let settingsWindow = SettingsWindowController()
    private let welcomeWindow = WelcomeWindowController()
    let libraryWindow = LibraryWindowController()
    let contrastWindow = ContrastWindowController()
    let dock = ColorDockController()
    private let toast = PickToast()
    private var cancellables: Set<AnyCancellable> = []

    /// True when a debug screenshot script is driving the app.
    static var isHarness: Bool { ProcessInfo.processInfo.environment["CHROMA_HARNESS"] != nil }

    func start() {
        Self.shared = self
        _ = LibraryStore.shared
        statusBar.install()

        AppSettings.shared.$shortcuts
            .sink { [weak self] shortcuts in self?.registerHotKeys(shortcuts) }
            .store(in: &cancellables)
        AppSettings.shared.$showDock
            .removeDuplicates()
            .sink { [weak self] show in show ? self?.dock.show() : self?.dock.hide() }
            .store(in: &cancellables)

        // Accessory app while only the menu bar item is up; a regular app (Dock icon, ⌘-Tab) while a window is open.
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateActivationPolicy() } }
            .store(in: &cancellables)

        #if DEBUG
        if let script = Harness.script {
            Harness.start(script, coordinator: self)
            return
        }
        #endif
        if !AppSettings.shared.hasOnboarded {
            welcomeWindow.show()
        }
    }

    private func registerHotKeys(_ shortcuts: [ShortcutAction: Shortcut?]) {
        var unavailable: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] ?? nil else {
                HotKeyCenter.shared.unregister(id: action.hotKeyID)
                continue
            }
            let ok = HotKeyCenter.shared.register(id: action.hotKeyID, shortcut: shortcut) { [weak self] in
                // Don't fire while the user is typing a new shortcut into Settings.
                guard !AppState.shared.isRecordingShortcut else { return }
                self?.perform(action)
            }
            if !ok { unavailable.insert(action) }
        }
        AppState.shared.unavailableShortcuts = unavailable
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .pick: session == nil ? pick() : session?.end()
        case .contrast: showContrast()
        case .library: showLibrary()
        case .dock: AppSettings.shared.showDock.toggle()
        }
    }

    // MARK: Picking

    /// Freezes the screens and shows the loupe. Picks are copied and saved, or handed to `purpose`.
    func pick(_ purpose: PickPurpose = .copy) {
        guard session == nil, !isStarting else {
            purpose.cancel()
            return
        }
        guard ScreenPermission.isGranted || DemoSnapshot.isEnabled else {
            purpose.cancel()
            welcomeWindow.show()
            return
        }
        isStarting = true
        Task { [self] in
            defer { isStarting = false }
            let snapshots: [ScreenSnapshot]
            do {
                if let demo = try DemoSnapshot.load() {
                    snapshots = demo
                } else {
                    snapshots = try await ScreenCapture.captureAllScreens()
                }
            } catch {
                NSLog("Chroma: capture failed: \(error)")
                AppState.shared.refreshPermission()
                purpose.cancel()
                welcomeWindow.show()
                return
            }
            let session = PickerSession(snapshots: snapshots, purpose: purpose)
            var picked: [RGBColor] = []
            session.onPick = { [weak self, weak session] color, keepPicking in
                picked.append(color)
                self?.didPick(color, all: picked, keepPicking: keepPicking, app: session?.sourceApp?.bundleIdentifier)
            }
            session.onEnd = { [weak self] in self?.session = nil }
            self.session = session
            session.show()
        }
    }

    /// Picks one color and returns it (nil if cancelled), for Shortcuts.
    func pickColor() async -> RGBColor? {
        await withCheckedContinuation { continuation in
            pick(.deliver { color in
                if let color { LibraryStore.shared.recordPick(color) }
                continuation.resume(returning: color)
            })
        }
    }

    private func didPick(_ color: RGBColor, all: [RGBColor], keepPicking: Bool, app: String?) {
        let settings = AppSettings.shared
        LibraryStore.shared.recordPick(color)
        let format = settings.formatForCopy(app: app)
        if settings.copyOnPick {
            // Several picks in one go land on the clipboard together, one per line.
            Clipboard.copy(all.map { settings.string($0, format: format) }.joined(separator: "\n"))
        }
        if settings.playSound { NSSound(named: "Pop")?.play() }
        if settings.showPickToast && !keepPicking {
            let text = settings.string(color, format: format)
            let title = settings.copyOnPick ? (all.count > 1 ? "Copied \(all.count) colors" : "Copied") : "Saved"
            toast.show(color: color, title: title, detail: text)
        }
        statusBar.refreshIcon()
    }

    /// Copies a color in the default format and confirms it with a toast.
    func copy(_ color: RGBColor, format: ColorFormat? = nil, toastAt point: CGPoint? = nil) {
        let text = AppSettings.shared.string(color, format: format)
        Clipboard.copy(text)
        toast.show(color: color, title: "Copied", detail: text, near: point)
    }

    /// Copies several colors, one per line.
    func copy(_ colors: [RGBColor]) {
        guard let first = colors.first else { return }
        guard colors.count > 1 else { return copy(first) }
        let values = colors.map { AppSettings.shared.string($0) }
        Clipboard.copy(values.joined(separator: "\n"))
        toast.show(color: first, title: "Copied \(colors.count) colors", detail: values.joined(separator: ", "))
    }

    // MARK: Windows

    func showLibrary(select color: RGBColor? = nil, source: ColorSource? = nil) {
        libraryWindow.show(select: color, source: source)
        updateActivationPolicy()
    }

    func showContrast(text: RGBColor? = nil, background: RGBColor? = nil) {
        contrastWindow.show(text: text, background: background)
        updateActivationPolicy()
    }

    func showSettings(_ tab: SettingsTab? = nil) {
        if let tab { AppState.shared.settingsTab = tab }
        settingsWindow.show()
        updateActivationPolicy()
    }

    func showWelcome() {
        welcomeWindow.show()
    }

    private func updateActivationPolicy() {
        guard !Self.isHarness else { return }
        // A minimized window still needs the Dock icon to come back.
        let open = [libraryWindow.window, contrastWindow.window, settingsWindow.window].contains { $0?.isVisible == true || $0?.isMiniaturized == true }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if open { NSApp.activate() }
        }
    }

    // MARK: URL scheme

    /// `chroma://pick`, `chroma://contrast?text=…&background=…`, `chroma://library?color=…`,
    /// `chroma://dock`, `chroma://add?color=…&palette=…`, `chroma://settings`.
    func open(url: URL) {
        guard url.scheme == "chroma" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func color(_ name: String) -> RGBColor? { items.first { $0.name == name }?.value.flatMap(ColorParser.parse) }
        switch url.host ?? url.path {
        case "pick": pick()
        case "contrast": showContrast(text: color("text") ?? color("fg"), background: color("background") ?? color("bg"))
        case "library": showLibrary(select: color("color"))
        case "dock": AppSettings.shared.showDock.toggle()
        case "settings": showSettings()
        case "add":
            guard let c = color("color") else { return }
            let library = LibraryStore.shared
            if let name = items.first(where: { $0.name == "palette" })?.value {
                let id = library.palettes.first { $0.name == name }?.id ?? library.createPalette(name: name)
                library.add([c], to: .palette(id))
            } else {
                library.recordPick(c)
            }
        default: break
        }
    }
}

enum Clipboard {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Every color found in the clipboard's text, or its color object.
    static func colors() -> [RGBColor] {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string) {
            let found = ColorParser.extractAll(from: text)
            if !found.isEmpty { return found }
            if let single = ColorParser.parse(text) { return [single] }
        }
        if let color = NSColor(from: pasteboard), let rgb = RGBColor(nsColor: color) { return [rgb] }
        return []
    }
}

/// Picks from a saved image instead of the screen: `CHROMA_DEMO_IMAGE=/path/to.png`.
/// Handy for trying Chroma before granting Screen Recording, and for making screenshots.
enum DemoSnapshot {
    static var path: String? { ProcessInfo.processInfo.environment["CHROMA_DEMO_IMAGE"] }
    static var isEnabled: Bool { path != nil }

    @MainActor
    static func load() throws -> [ScreenSnapshot]? {
        guard let path, let screen = NSScreen.main else { return nil }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let buffer = PixelBuffer(image: image)
        else { throw ScreenCapture.Failure.nothingCaptured }
        return [ScreenSnapshot(screen: screen, image: image, buffer: buffer)]
    }
}

/// A standard menu bar for when a window is open, so ⌘C, ⌘V, ⌘W and friends work.
enum MainMenu {
    @MainActor
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Chroma", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(MenuAction.item("Settings…", key: ",") { AppCoordinator.shared?.showSettings() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Chroma", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Chroma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(MenuAction.item("New Palette", key: "n") { AppCoordinator.shared?.libraryWindow.newPalette() })
        fileMenu.addItem(MenuAction.item("Import Palette…", key: "o") { AppCoordinator.shared?.libraryWindow.importPalettes() })
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let colorItem = NSMenuItem()
        let colorMenu = NSMenu(title: "Color")
        colorMenu.addItem(MenuAction.item("Pick Color", key: "p", modifiers: [.command, .shift]) { AppCoordinator.shared?.pick() })
        colorMenu.addItem(MenuAction.item("Contrast Checker", key: "k", modifiers: [.command, .shift]) { AppCoordinator.shared?.showContrast() })
        colorMenu.addItem(MenuAction.item("Color Dock", key: "d", modifiers: [.command, .shift], isOn: { AppSettings.shared.showDock }) { AppSettings.shared.showDock.toggle() })
        colorItem.submenu = colorMenu
        main.addItem(colorItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(MenuAction.item("Library", key: "l", modifiers: [.command, .shift]) { AppCoordinator.shared?.showLibrary() })
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSObject, NSMenuItemValidation {
    private let action: @MainActor () -> Void
    private let isOn: (@MainActor () -> Bool)?
    private static var retained: [MenuAction] = []

    private init(_ action: @escaping @MainActor () -> Void, isOn: (@MainActor () -> Bool)?) {
        self.action = action
        self.isOn = isOn
    }

    @objc private func run() { MainActor.assumeIsolated { action() } }

    /// Shows a checkmark for items that toggle something.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let isOn { menuItem.state = MainActor.assumeIsolated { isOn() } ? .on : .off }
        return true
    }

    @MainActor
    static func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, isOn: (@MainActor () -> Bool)? = nil, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = MenuAction(action, isOn: isOn)
        retained.append(target)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
