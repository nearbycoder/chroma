import AppKit
import SwiftUI

@MainActor
final class ContrastModel: ObservableObject {
    @Published var text: RGBColor { didSet { AppSettings.shared.defaults.set(text.hexString, forKey: "contrastText") } }
    @Published var background: RGBColor { didSet { AppSettings.shared.defaults.set(background.hexString, forKey: "contrastBackground") } }
    @Published var simulation: VisionSimulation = .normal

    init() {
        let defaults = AppSettings.shared.defaults
        text = defaults.string(forKey: "contrastText").flatMap(RGBColor.init(hex:)) ?? RGBColor(hex: "1D1D1F")!
        background = defaults.string(forKey: "contrastBackground").flatMap(RGBColor.init(hex:)) ?? RGBColor(hex: "F5F5F7")!
    }

    /// The text as it actually appears, composited over the background.
    var visibleText: RGBColor { text.over(background.opaque) }
    var ratio: Double { visibleText.contrastRatio(with: background.opaque) }
    var apca: Double { visibleText.apcaContrast(on: background.opaque) }

    func swap() {
        let t = text
        text = background
        background = t
    }
}

@MainActor
final class ContrastWindowController {
    private(set) var window: NSWindow?
    let model = ContrastModel()

    func show(text: RGBColor? = nil, background: RGBColor? = nil) {
        if let text { model.text = text }
        if let background { model.background = background }
        if window == nil {
            let hosting = NSHostingController(rootView: ContrastView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Contrast Checker"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ChromaContrast")
            self.window = window
            if !window.setFrameUsingName("ChromaContrast") { window.center() }
        }
        if AppCoordinator.isHarness {
            window?.orderBack(nil)
        } else {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Hides the window while picking from the screen, then brings it back.
    func pick(_ assign: @escaping (RGBColor) -> Void) {
        window?.orderOut(nil)
        AppCoordinator.shared?.pick(.deliver { color in
            if let color {
                LibraryStore.shared.recordPick(color)
                assign(color)
            }
            AppCoordinator.shared?.showContrast()
        })
    }
}

struct ContrastView: View {
    @ObservedObject var model: ContrastModel
    @ObservedObject private var library = LibraryStore.shared
    @State private var target: ContrastLevel = .aa
    @State private var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 12) {
                preview
                Picker("Simulate", selection: $model.simulation) {
                    ForEach(VisionSimulation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .frame(width: 300)

            VStack(alignment: .leading, spacing: 16) {
                ColorWellRow(title: "Text", color: $model.text, pick: { AppCoordinator.shared?.contrastWindow.pick { model.text = $0 } })
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.snappy) { model.swap() }
                    } label: {
                        Label("Swap", systemImage: "arrow.up.arrow.down")
                    }
                    .controlSize(.small)
                    Spacer()
                }
                ColorWellRow(title: "Background", color: $model.background, showsAlpha: false, pick: { AppCoordinator.shared?.contrastWindow.pick { model.background = $0 } })
                Divider()
                results
                Divider()
                fixes
            }
            .frame(width: 300)
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 22)
    }

    private var preview: some View {
        let text = model.simulation.apply(model.text).color
        let background = model.simulation.apply(model.background.opaque).color
        return VStack(alignment: .leading, spacing: 10) {
            Text("Aa")
                .font(.system(size: 64, weight: .bold, design: .rounded))
            Text("Large heading text")
                .font(.system(size: 22, weight: .semibold))
            Text("Body text at regular size needs a contrast of at least 4.5 to 1 to meet WCAG AA, and 7 to 1 for AAA.")
                .font(.system(size: 13))
            Text("Small print and captions are the hardest to read.")
                .font(.system(size: 11))
            HStack(spacing: 10) {
                Text("Button")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(text, lineWidth: 1.5))
                Image(systemName: "heart.fill")
                Image(systemName: "star.fill")
                Image(systemName: "bell.fill")
            }
            .padding(.top, 4)
        }
        .foregroundStyle(text)
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }

    private var results: some View {
        let ratio = model.ratio
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.2f", ratio))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(": 1").font(.title2).foregroundStyle(.secondary)
                Spacer()
                Text(verdict(ratio))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(ratio >= 4.5 ? Color.green : ratio >= 3 ? Color.orange : Color.red)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Normal text").foregroundStyle(.secondary)
                    ContrastBadge(label: "AA", passes: ratio >= 4.5)
                    ContrastBadge(label: "AAA", passes: ratio >= 7)
                }
                GridRow {
                    Text("Large text").foregroundStyle(.secondary)
                    ContrastBadge(label: "AA", passes: ratio >= 3)
                    ContrastBadge(label: "AAA", passes: ratio >= 4.5)
                }
                GridRow {
                    Text("Icons and UI").foregroundStyle(.secondary)
                    ContrastBadge(label: "AA", passes: ratio >= 3)
                }
            }
            .font(.callout)
            HStack(spacing: 6) {
                Text("APCA").font(.callout.weight(.semibold))
                Text(String(format: "Lc %.0f", model.apca)).font(.callout).monospacedDigit()
                Text(ContrastFixer.apcaGuidance(model.apca)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help("APCA is the contrast method proposed for WCAG 3. It accounts for which color is the text.")
        }
    }

    private var fixes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Target", selection: $target) {
                    Text("AA (4.5:1)").tag(ContrastLevel.aa)
                    Text("AAA (7:1)").tag(ContrastLevel.aaa)
                    Text("Large text (3:1)").tag(ContrastLevel.aaLarge)
                }
                .fixedSize()
            }
            HStack {
                Button("Fix Text") { fixText() }
                Button("Fix Background") { fixBackground() }
            }
            .disabled(model.ratio >= target.minimum)
            HStack {
                Button("Save Pair to Palette") { savePair() }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).transition(.opacity)
                }
            }
        }
        .controlSize(.small)
    }

    private func verdict(_ ratio: Double) -> String {
        switch ratio {
        case 7...: "Excellent"
        case 4.5..<7: "Good"
        case 3..<4.5: "Large text only"
        default: "Poor"
        }
    }

    private func fixText() {
        if let fixed = ContrastFixer.fix(text: model.text, background: model.background, target: target.minimum) {
            withAnimation { model.text = fixed }
        } else {
            flash("Even black or white can't reach that on this background.")
        }
    }

    private func fixBackground() {
        if let fixed = ContrastFixer.fix(text: model.background.opaque, background: model.visibleText, target: target.minimum) {
            withAnimation { model.background = fixed }
        } else {
            flash("No background lightness reaches that with this text color.")
        }
    }

    private func savePair() {
        let items = [ColorItem(color: model.text, name: "Text"), ColorItem(color: model.background, name: "Background")]
        let id = library.createPalette(name: library.uniqueName("Contrast \(model.text.hexString) on \(model.background.hexString)"), colors: items,
                                       note: String(format: "Contrast %.2f:1", model.ratio))
        flash("Saved as “\(library.palette(id)?.name ?? "")”")
    }

    private func flash(_ text: String) {
        withAnimation { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { if message == text { message = nil } } }
    }
}

/// A swatch that opens an editor, a text field and an eyedropper.
struct ColorWellRow: View {
    let title: String
    @Binding var color: RGBColor
    var showsAlpha = true
    let pick: () -> Void
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Button {
                    editing = true
                } label: {
                    Swatch(color: color, cornerRadius: 7)
                        .frame(width: 34, height: 26)
                }
                .buttonStyle(.plain)
                .help("Edit")
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    ColorEditor(color: $color, showsAlpha: showsAlpha)
                        .padding(16)
                        .frame(width: 280)
                }
                ColorTextField(color: $color)
                Button(action: pick) {
                    Image(systemName: "eyedropper")
                }
                .help("Pick from the screen")
                Menu {
                    ForEach(LibraryStore.shared.history.prefix(12)) { item in
                        Button {
                            color = item.color
                        } label: {
                            Text("\(item.color.hexString)  \(item.displayName)")
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Recent colors")
            }
        }
    }
}
