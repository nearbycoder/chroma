import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?

    static let repositoryURL = URL(string: "https://github.com/nearbycoder/chroma")!
    static let websiteURL = URL(string: "https://nearbycoder.github.io/chroma/")!

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "Chroma"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuPopover(close: { [weak self] in self?.popover.performClose(nil) }))

        refreshIcon()
        LibraryStore.shared.$history
            .map { $0.first?.color }
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIcon() } }
            .store(in: &cancellables)
        AppSettings.shared.$tintMenuBarIcon
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIcon() } }
            .store(in: &cancellables)
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        let pickFirst = AppSettings.shared.menuBarClick == .picker
        if pickFirst != secondary {
            AppCoordinator.shared?.pick()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func refreshIcon() {
        guard let button = item?.button else { return }
        let tint = AppSettings.shared.tintMenuBarIcon ? LibraryStore.shared.latest : nil
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = Self.menuBarIcon(fill: tint, dark: dark)
    }

    /// A droplet: an outline template, or filled with the last picked color.
    static func menuBarIcon(fill: RGBColor?, dark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: 9, y: 1.8))
            drop.curve(to: NSPoint(x: 14.6, y: 10.9), controlPoint1: NSPoint(x: 11.2, y: 4.6), controlPoint2: NSPoint(x: 14.6, y: 7.4))
            drop.appendArc(withCenter: NSPoint(x: 9, y: 10.9), radius: 5.6, startAngle: 0, endAngle: 180, clockwise: false)
            drop.curve(to: NSPoint(x: 9, y: 1.8), controlPoint1: NSPoint(x: 3.4, y: 7.4), controlPoint2: NSPoint(x: 6.8, y: 4.6))
            drop.close()
            drop.lineWidth = 1.5
            drop.lineJoinStyle = .round
            let ink: NSColor = fill == nil ? .black : (dark ? .white : .black)
            if let fill {
                fill.opaque.nsColor.setFill()
                drop.fill()
            } else {
                // A highlight inside the outline, so it reads as a drop and not a pin.
                let shine = NSBezierPath()
                shine.move(to: NSPoint(x: 6.1, y: 10.6))
                shine.appendArc(withCenter: NSPoint(x: 9, y: 10.9), radius: 2.9, startAngle: 174, endAngle: 120, clockwise: true)
                shine.lineWidth = 1.3
                shine.lineCapStyle = .round
                ink.setStroke()
                shine.stroke()
            }
            ink.setStroke()
            drop.stroke()
            return true
        }
        image.isTemplate = fill == nil
        return image
    }
}

/// A color in the popover, which grows a little under the pointer.
struct MenuSwatch: View {
    let color: RGBColor
    @State private var hovering = false

    var body: some View {
        Swatch(color: color, cornerRadius: 6)
            .frame(width: 24, height: 24)
            .scaleEffect(hovering ? 1.15 : 1)
            .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 3, y: 1)
            .zIndex(hovering ? 1 : 0)
            .animation(.snappy(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The popover under the menu bar item: the latest color, quick actions, history and palettes.
struct MenuPopover: View {
    let close: () -> Void
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var state = AppState.shared
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            if let latest = library.history.first {
                header(latest)
            } else {
                emptyHeader
            }
            actions
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !state.hasScreenPermission {
                        permissionNotice
                    }
                    historySection
                    ForEach(library.palettes) { palette in
                        paletteSection(palette)
                    }
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // A popover sizes to its content, and a scroll view has no height of its own; cap it at 380.
            .frame(height: min(max(contentHeight, 60), 380))
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { state.refreshPermission() }
    }

    private func header(_ item: ColorItem) -> some View {
        HStack(spacing: 12) {
            Swatch(color: item.color, cornerRadius: 12)
                .frame(width: 52, height: 52)
                .onDrag { ColorDrag.provider(for: [item], from: .history) }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.headline).lineLimit(1)
                Text(settings.string(item.color))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                FormatMenu(label: "")
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            Button {
                close()
                AppCoordinator.shared?.copy(item.color)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(12)
    }

    private var emptyHeader: some View {
        VStack(spacing: 4) {
            Text("No colors yet").font(.headline)
            Text("Pick one from anywhere on screen.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            actionButton("Pick", "eyedropper", shortcut: .pick) {
                close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { AppCoordinator.shared?.pick() }
            }
            actionButton("Contrast", "circle.lefthalf.filled", shortcut: .contrast) {
                close()
                AppCoordinator.shared?.showContrast()
            }
            actionButton("Library", "square.grid.2x2", shortcut: .library) {
                close()
                AppCoordinator.shared?.showLibrary()
            }
            actionButton(settings.showDock ? "Hide Dock" : "Dock", "dock.rectangle", shortcut: .dock) {
                settings.showDock.toggle()
            }
        }
    }

    private func actionButton(_ title: String, _ symbol: String, shortcut: ShortcutAction, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(height: 18)
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help(settings.shortcut(shortcut).map { "\(title) (\($0.displayString))" } ?? title)
    }

    private var permissionNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Screen Recording is off").font(.callout.weight(.medium))
                Text("Chroma needs it to read colors on screen.").font(.caption).foregroundStyle(.secondary)
                Button("Allow…") {
                    close()
                    AppCoordinator.shared?.showWelcome()
                }
                .controlSize(.small)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History").font(.subheadline.weight(.semibold))
                Spacer()
                if !library.history.isEmpty {
                    Button("Clear") { library.clearHistory() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if library.history.isEmpty {
                Text("Colors you pick show up here.").font(.caption).foregroundStyle(.secondary)
            } else {
                swatchGrid(Array(library.history.prefix(30)), source: .history)
            }
        }
    }

    private func paletteSection(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(palette.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if palette.isLocked {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    library.activePaletteID = library.activePaletteID == palette.id ? nil : palette.id
                } label: {
                    Image(systemName: library.activePaletteID == palette.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(library.activePaletteID == palette.id ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(library.activePaletteID == palette.id ? "New picks are added to this palette" : "Add new picks to this palette")
            }
            if palette.colors.isEmpty {
                Text("Empty").font(.caption).foregroundStyle(.secondary)
            } else {
                swatchGrid(palette.colors, source: .palette(palette.id))
            }
        }
    }

    private func swatchGrid(_ items: [ColorItem], source: ColorSource) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 5), count: 10), alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                MenuSwatch(color: item.color)
                    .help("\(item.displayName)  \(settings.string(item.color))")
                    .accessibilityElement()
                    .accessibilityLabel("\(item.displayName), \(item.color.hexString)")
                    .accessibilityAddTraits(.isButton)
                    .onTapGesture {
                        close()
                        AppCoordinator.shared?.copy(item.color)
                    }
                    .onDrag { ColorDrag.provider(for: [item], from: source) }
                    .contextMenu { ColorActions(item: item, source: source) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                close()
                AppCoordinator.shared?.showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
