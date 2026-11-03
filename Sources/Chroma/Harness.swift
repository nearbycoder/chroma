#if DEBUG
import AppKit
import SwiftUI

/// Debug-only scripted runs for screenshots, without covering the screen:
///   CHROMA_HARNESS=window:library Chroma               a window, ordered to the back
///   CHROMA_DEMO_IMAGE=backdrop.png CHROMA_HARNESS="move 900 400; zoom 13" Chroma    the picker
/// Prints `HARNESS_WINDOW <number>` for `screencapture -l`. Uses its own settings and a demo library.
@MainActor
enum Harness {
    static var script: String? { ProcessInfo.processInfo.environment["CHROMA_HARNESS"] }

    static func start(_ script: String, coordinator: AppCoordinator) {
        switch ProcessInfo.processInfo.environment["CHROMA_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        seedLibrary()
        let settings = AppSettings.shared
        settings.hasOnboarded = true
        settings.showDock = false
        settings.copyFormatID = "hex"
        settings.shownFormatIDs = AppSettings.defaultShownFormats

        guard script.hasPrefix("window:") else {
            coordinator.pick()
            return
        }
        let name = String(script.dropFirst("window:".count))
        let before = Set(NSApp.windows.map(\.windowNumber))
        var minWidth: CGFloat = 300
        switch name {
        case "library":
            coordinator.showLibrary(select: LibraryStore.shared.palettes.first?.colors.dropFirst(2).first?.color)
            if let first = LibraryStore.shared.palettes.first { coordinator.libraryWindow.model.source = .palette(first.id) }
            if let item = LibraryStore.shared.palettes.first?.colors.dropFirst(2).first { coordinator.libraryWindow.model.selection = [item.id] }
        case "library-multi":
            coordinator.showLibrary()
            if let first = LibraryStore.shared.palettes.first {
                coordinator.libraryWindow.model.source = .palette(first.id)
                coordinator.libraryWindow.model.selection = Set(first.colors[5...7].map(\.id))
            }
        case "contrast":
            coordinator.showContrast(text: RGBColor(hex: "7C5CFF"), background: RGBColor(hex: "F4F1EA"))
        case "contrast-dark":
            coordinator.showContrast(text: RGBColor(hex: "FFB86B"), background: RGBColor(hex: "1E1B2E"))
        case "welcome":
            coordinator.showWelcome()
        case "menu":
            showMenu()
        case "toast":
            coordinator.copy(RGBColor(hex: "6A5AE0") ?? .black, toastAt: CGPoint(x: 400, y: 400))
            minWidth = 20
        case "dock":
            LibraryStore.shared.palettes.indices.prefix(3).forEach { index in
                LibraryStore.shared.updatePalette(LibraryStore.shared.palettes[index].id) { $0.inDock = true }
            }
            settings.dockEdge = .right
            settings.dockOffset = 0.5
            settings.showDock = true
            minWidth = 20
        default:
            if name.hasPrefix("settings") {
                let tab = SettingsTab(rawValue: String(name.dropFirst("settings".count + 1))) ?? .general
                coordinator.showSettings(tab)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = NSApp.windows.first(where: { !before.contains($0.windowNumber) && $0.isVisible && $0.frame.width > minWidth }) else {
                print("HARNESS_WINDOW none")
                return
            }
            print("HARNESS_WINDOW \(window.windowNumber)")
            fflush(stdout)
        }
    }

    /// The menu bar popover's contents in a plain window, since a popover can't be captured on its own.
    private static var menuWindow: NSWindow?
    private static func showMenu() {
        let hosting = NSHostingController(rootView: MenuPopover(close: {}).background(.regularMaterial))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 14
        window.contentView?.layer?.masksToBounds = true
        window.orderBack(nil)
        menuWindow = window
    }

    static func run(_ script: String, session: PickerSession, windows: [PickerWindow]) {
        for window in windows {
            window.level = .normal
            window.orderBack(nil)
        }
        let screen = windows.first?.snapshot.screen.frame ?? .zero
        for command in script.split(separator: ";") {
            let parts = command.split(separator: " ").map(String.init)
            guard let name = parts.first else { continue }
            let numbers = parts.dropFirst().compactMap(Double.init)
            switch name {
            case "move" where numbers.count == 2:
                // Top-left origin, in points, like the backdrop image.
                session.moveTo(CGPoint(x: screen.minX + numbers[0], y: screen.maxY - numbers[1]))
            case "zoom" where numbers.count == 1: AppSettings.shared.loupeZoom = Int(numbers[0]) | 1
            case "size" where numbers.count == 1: AppSettings.shared.loupeSize = numbers[0]
            case "format" where parts.count == 2:
                while session.format.id != parts[1] && AppSettings.shared.shownFormats.contains(where: { $0.id == parts[1] }) { session.cycleFormat() }
            case "nogrid": AppSettings.shared.showGrid = false
            case "hint": session.showControls(for: 60)
            case "picked": session.showPickedHint(["FF7A59", "FFB547", "2EC4B6", "6A5AE0"].compactMap { RGBColor(hex: $0) })
            default: print("Harness: skipped \(command)")
            }
        }
        session.update()
        if let window = windows.first {
            print("HARNESS_WINDOW \(window.windowNumber)")
            fflush(stdout)
        }
    }

    /// Demo palettes and history, so screenshots don't show anyone's real library.
    static func seedLibrary() {
        func items(_ list: [(String, String?)]) -> [ColorItem] {
            list.compactMap { hex, name in RGBColor(hex: hex).map { ColorItem(color: $0, name: name) } }
        }
        var brand = Palette(name: "Orbit Brand", colors: items([
            ("1B1F3B", "Midnight"), ("3D3B8E", "Deep Indigo"), ("6A5AE0", "Iris"), ("8F7CF7", nil), ("C9BFFF", "Lavender Mist"),
            ("FF7A59", "Coral"), ("FFB547", "Marigold"), ("2EC4B6", "Lagoon"), ("F4F1EA", "Paper"), ("FFFFFF", nil),
        ]), note: "Primary colors for the Orbit app and marketing site.")
        brand.inDock = true
        var sunset = Palette(name: "Sunset", colors: items([("2B2D42", nil), ("5C3C66", nil), ("A44A6F", nil), ("E26D5C", nil), ("F6AE6B", nil), ("FAD6A5", nil)]))
        sunset.inDock = true
        let ocean = Palette(name: "Ocean", colors: items([("03045E", nil), ("023E8A", nil), ("0077B6", nil), ("0096C7", nil), ("00B4D8", nil), ("48CAE4", nil), ("90E0EF", nil), ("CAF0F8", nil)]))
        let system = Palette(name: "Apple System", colors: items([
            ("FF3B30", "Red"), ("FF9500", "Orange"), ("FFCC00", "Yellow"), ("34C759", "Green"), ("00C7BE", "Mint"), ("30B0C7", "Teal"),
            ("32ADE6", "Cyan"), ("007AFF", "Blue"), ("5856D6", "Indigo"), ("AF52DE", "Purple"), ("FF2D55", "Pink"), ("A2845E", "Brown"),
        ]))
        let history = items([
            ("6A5AE0", nil), ("FF7A59", nil), ("2EC4B6", nil), ("1B1F3B", nil), ("F6AE6B", nil), ("0077B6", nil), ("E26D5C", nil),
            ("34C759", nil), ("FFB547", nil), ("3D3B8E", nil), ("AF52DE", nil), ("F4F1EA", nil), ("023E8A", nil), ("FF2D55", nil),
        ])
        LibraryStore.shared.replaceAll(history: history, palettes: [brand, sunset, ocean, system])
        LibraryStore.shared.activePaletteID = brand.id
    }
}
#endif
