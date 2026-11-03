import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A color chip, with a checkerboard behind translucent colors.
struct Swatch: View {
    let color: RGBColor
    var cornerRadius: CGFloat = 8
    var simulation: VisionSimulation = .normal
    var outline = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if !color.isOpaque { Checkerboard().clipShape(shape) }
            shape.fill(simulation.apply(color).color)
        }
        .overlay {
            if outline { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
        }
    }
}

struct Checkerboard: View {
    var square: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let columns = Int(ceil(size.width / square)), rows = Int(ceil(size.height / square))
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 1 {
                    context.fill(Path(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)), with: .color(Color(white: 0.84)))
                }
            }
        }
    }
}

/// Colors being dragged inside Chroma, so a drop can tell a reorder from an add.
@MainActor
enum ColorDrag {
    static var items: [ColorItem] = []
    static var source: ColorSource?
    /// The text handed out with the drag, to recognize it when it comes back.
    private static var text: String?

    /// Text for other apps: one value per line in the copy format.
    static func provider(for items: [ColorItem], from source: ColorSource?) -> NSItemProvider {
        self.items = items
        self.source = source
        let text = items.map { AppSettings.shared.string($0.color) }.joined(separator: "\n")
        self.text = text
        return NSItemProvider(object: text as NSString)
    }

    /// The colors in a drop: the in-app drag if there is one, otherwise whatever colors the text holds.
    static func colors(from strings: [String]) -> [ColorItem] {
        let text = strings.joined(separator: "\n")
        if isOurs(strings) { return items }
        let parsed = ColorParser.extractAll(from: text)
        let fromText = parsed.isEmpty ? strings.compactMap(ColorParser.parse) : parsed
        return fromText.map { ColorItem(color: $0) }
    }

    /// Whether a drop is the drag Chroma started, rather than leftover state from one that ended elsewhere.
    static func isOurs(_ strings: [String]) -> Bool {
        !items.isEmpty && text != nil && strings.joined(separator: "\n") == text
    }

    static func reset() {
        items = []
        source = nil
        text = nil
    }
}

/// A small confirmation that floats near the pointer after a pick or a copy.
@MainActor
final class PickToast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(color: RGBColor, title: String, detail: String, near point: CGPoint? = nil) {
        let view = NSHostingView(rootView: ToastView(color: color, title: title, detail: detail))
        let size = view.fittingSize
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = view
        let anchor = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        var origin = CGPoint(x: anchor.x + 18, y: anchor.y - size.height - 18)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 }, completionHandler: {
                MainActor.assumeIsolated { panel?.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

struct ToastView: View {
    let color: RGBColor
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Swatch(color: color, cornerRadius: 7)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(detail).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: 360, alignment: .leading)
        .glassEffect(.regular, in: .capsule)
        .padding(14)
        .fixedSize()
    }
}

/// A row of formats with copy buttons, used by the inspector and the menu.
struct FormatRow: View {
    let color: RGBColor
    let format: ColorFormat
    @ObservedObject private var settings = AppSettings.shared
    @State private var copied = false

    var body: some View {
        let value = settings.string(color, format: format)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(format.name).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button {
                Clipboard.copy(value)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help("Copy \(format.name)")
        }
        .padding(.vertical, 2)
    }
}

/// Picks the default copy format, grouped like Settings.
struct FormatMenu: View {
    @ObservedObject private var settings = AppSettings.shared
    var label: String = "Format"

    var body: some View {
        Picker(label, selection: $settings.copyFormatID) {
            ForEach(Self.groups(settings.allFormats), id: \.0) { group, formats in
                Section(group) {
                    ForEach(formats) { Text($0.name).tag($0.id) }
                }
            }
        }
    }

    static func groups(_ formats: [ColorFormat]) -> [(String, [ColorFormat])] {
        var order: [String] = []
        var grouped: [String: [ColorFormat]] = [:]
        for format in formats {
            if grouped[format.group] == nil { order.append(format.group) }
            grouped[format.group, default: []].append(format)
        }
        return order.map { ($0, grouped[$0]!) }
    }
}

/// Shows a menu of things to do with one color: shared by the menu, the dock and the library.
struct ColorActions: View {
    let item: ColorItem
    var source: ColorSource?
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Button("Copy \(settings.copyFormat.name)") { Clipboard.copy(settings.string(item.color)) }
        Menu("Copy As") {
            ForEach(FormatMenu.groups(settings.allFormats), id: \.0) { group, formats in
                Section(group) {
                    ForEach(formats) { format in
                        Button(format.name) { Clipboard.copy(settings.string(item.color, format: format)) }
                    }
                }
            }
        }
        Divider()
        Button("Show in Library") { AppCoordinator.shared?.showLibrary(select: item.color) }
        Button("Check Contrast…") { AppCoordinator.shared?.showContrast(text: item.color) }
        Menu("Add to Palette") {
            ForEach(library.palettes.filter { !$0.isLocked }) { palette in
                Button(palette.name) { library.add([item], to: .palette(palette.id)) }
            }
            Divider()
            Button("New Palette") {
                let id = library.createPalette(colors: [ColorItem(color: item.color)])
                AppCoordinator.shared?.showLibrary(source: .palette(id))
            }
        }
        if let source, !library.isLocked(source) {
            Divider()
            Button("Remove", role: .destructive) { library.remove([item.id], from: source) }
        }
    }
}

extension View {
    /// Hides the view without removing it from layout.
    @ViewBuilder
    func hidden(_ hidden: Bool) -> some View {
        if hidden { self.hidden() } else { self }
    }
}

extension UTType {
    static let gimpPalette = UTType(filenameExtension: "gpl") ?? .data
    static let adobeSwatchExchange = UTType(filenameExtension: "ase") ?? .data
    static let appleColorList = UTType(filenameExtension: "clr") ?? .data
}
