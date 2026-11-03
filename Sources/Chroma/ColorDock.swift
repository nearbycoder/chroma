import AppKit
import Combine
import SwiftUI

/// Palettes in a floating strip at the edge of the screen. Click a color to copy it, or drag it into any app.
@MainActor
final class ColorDockController {
    private var panel: DockPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    func show() {
        if panel == nil {
            let panel = DockPanel()
            let hosting = NSHostingView(rootView: DockView(controller: self))
            hosting.sizingOptions = [.intrinsicContentSize]
            panel.contentView = hosting
            self.panel = panel

            // Resize and re-snap whenever the contents or the screens change.
            let library = LibraryStore.shared
            let settings = AppSettings.shared
            Publishers.Merge4(
                library.$palettes.map { _ in () },
                library.$history.map { _ in () },
                settings.$dockCollapsed.map { _ in () },
                settings.$dockEdge.map { _ in () }
            )
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.layout(animated: true) } }
            .store(in: &cancellables)
        }
        layout(animated: false)
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel?.animator().alphaValue = 1 }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }, completionHandler: {
            // A quick hide-then-show must not end hidden.
            MainActor.assumeIsolated { if !AppSettings.shared.showDock { panel.orderOut(nil) } }
        })
    }

    private var screen: NSScreen? {
        panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// How many swatches fit along the edge before wrapping to another line.
    var maxPerLine: Int {
        let settings = AppSettings.shared
        guard let visible = screen?.visibleFrame else { return 16 }
        let length = settings.dockEdge.isVertical ? visible.height : visible.width
        return max(4, Int((length - 120) / DockView.pitch))
    }

    /// Places the panel against its edge at the saved offset.
    func layout(animated: Bool) {
        guard let panel, let hosting = panel.contentView, let visible = screen?.visibleFrame else { return }
        let size = hosting.fittingSize
        let settings = AppSettings.shared
        let offset = settings.dockOffset.clamped01
        var origin = CGPoint.zero
        switch settings.dockEdge {
        case .left: origin = CGPoint(x: visible.minX, y: visible.minY + (visible.height - size.height) * offset)
        case .right: origin = CGPoint(x: visible.maxX - size.width, y: visible.minY + (visible.height - size.height) * offset)
        case .top: origin = CGPoint(x: visible.minX + (visible.width - size.width) * offset, y: visible.maxY - size.height)
        case .bottom: origin = CGPoint(x: visible.minX + (visible.width - size.width) * offset, y: visible.minY)
        }
        let frame = CGRect(origin: origin, size: size).integral
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Dragging the dock

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    /// Snaps to the nearest edge, or hides the dock when dropped near the middle of the screen.
    /// Returns false when the pointer barely moved, so the caller can treat it as a click.
    @discardableResult
    func dragEnded() -> Bool {
        let start = dragStart
        dragStart = nil
        guard let panel else { return false }
        if let start, hypot(NSEvent.mouseLocation.x - start.mouse.x, NSEvent.mouseLocation.y - start.mouse.y) < 3 {
            layout(animated: false)
            return false
        }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? self.screen
        guard let visible = screen?.visibleFrame else { return true }
        let settings = AppSettings.shared

        let middle = visible.insetBy(dx: visible.width * 0.3, dy: visible.height * 0.3)
        if middle.contains(center) {
            settings.showDock = false
            return true
        }
        let distances: [(DockEdge, CGFloat)] = [
            (.left, center.x - visible.minX), (.right, visible.maxX - center.x),
            (.bottom, center.y - visible.minY), (.top, visible.maxY - center.y),
        ]
        let edge = distances.min { $0.1 < $1.1 }!.0
        if edge != settings.dockEdge { settings.dockEdge = edge }
        let size = panel.frame.size
        if edge.isVertical {
            settings.dockOffset = ((panel.frame.minY - visible.minY) / max(1, visible.height - size.height)).clamped01
        } else {
            settings.dockOffset = ((panel.frame.minX - visible.minX) / max(1, visible.width - size.width)).clamped01
        }
        // Let SwiftUI re-lay out for a new orientation before snapping.
        DispatchQueue.main.async { self.layout(animated: true) }
        return true
    }
}

final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
}

struct DockView: View {
    let controller: ColorDockController
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var handleHovered = false

    static let swatch: CGFloat = 24
    static let spacing: CGFloat = 6
    static var pitch: CGFloat { swatch + spacing }

    private var vertical: Bool { settings.dockEdge.isVertical }

    /// The palettes to show: the ones marked for the dock, or recent history when there are none.
    private var groups: [(id: String, title: String, items: [ColorItem], source: ColorSource)] {
        let palettes = library.dockPalettes
        if palettes.isEmpty {
            return [("history", "History", Array(library.history.prefix(controller.maxPerLine)), .history)]
        }
        return palettes.map { ($0.id.uuidString, $0.name, $0.colors, .palette($0.id)) }
    }

    var body: some View {
        let outer = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        outer {
            handle
            if !settings.dockCollapsed {
                let across = vertical ? AnyLayout(HStackLayout(alignment: .top, spacing: 10)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                across {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            // A hairline between palettes.
                            Capsule().fill(.primary.opacity(0.12))
                                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
                                .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
                        }
                        groupView(group)
                    }
                }
            }
        }
        .padding(8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(6)
        .fixedSize()
    }

    private var handle: some View {
        ZStack {
            Capsule().fill(.primary.opacity(handleHovered ? 0.45 : 0.25))
                .frame(width: vertical ? 22 : 5, height: vertical ? 5 : 22)
        }
        .frame(width: vertical ? Self.swatch : 14, height: vertical ? 14 : Self.swatch)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { handleHovered = hovering } }
        .pointerStyle(.grabIdle)
        .accessibilityLabel("Color Dock handle")
        .accessibilityHint(settings.dockCollapsed ? "Expands the dock" : "Collapses the dock")
        .help("Click to \(settings.dockCollapsed ? "expand" : "collapse"). Drag to move; drop in the middle of the screen to hide.")
        // One gesture for both, since the panel moves under the pointer and a separate tap would fire after every drag.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in
                    if !controller.dragEnded() {
                        withAnimation(.snappy) { settings.dockCollapsed.toggle() }
                    }
                }
        )
        .contextMenu {
            Button("Open Library") { AppCoordinator.shared?.showLibrary() }
            Button("Pick a Color") { AppCoordinator.shared?.pick() }
            Divider()
            Button("Hide Color Dock") { settings.showDock = false }
        }
    }

    @ViewBuilder
    private func groupView(_ group: (id: String, title: String, items: [ColorItem], source: ColorSource)) -> some View {
        let lines = group.items.chunked(controller.maxPerLine)
        let along = vertical ? AnyLayout(HStackLayout(alignment: .top, spacing: Self.spacing)) : AnyLayout(VStackLayout(alignment: .leading, spacing: Self.spacing))
        along {
            if lines.isEmpty {
                Image(systemName: "plus")
                    .frame(width: Self.swatch, height: Self.swatch)
                    .foregroundStyle(.secondary)
                    .help("\(group.title) is empty")
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let stack = vertical ? AnyLayout(VStackLayout(spacing: Self.spacing)) : AnyLayout(HStackLayout(spacing: Self.spacing))
                stack {
                    ForEach(line) { item in
                        DockSwatch(item: item, source: group.source, title: group.title)
                    }
                }
            }
        }
    }
}

struct DockSwatch: View {
    let item: ColorItem
    let source: ColorSource
    let title: String
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(item.color.color)
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .frame(width: DockView.swatch, height: DockView.swatch)
            .scaleEffect(hovering ? 1.18 : 1)
            .animation(.snappy(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .help("\(item.displayName)  \(settings.string(item.color))\n\(title)")
            .accessibilityElement()
            .accessibilityLabel("\(item.displayName), \(item.color.hexString)")
            .accessibilityAddTraits(.isButton)
            .onTapGesture { AppCoordinator.shared?.copy(item.color) }
            .onDrag { ColorDrag.provider(for: [item], from: source) }
            .contextMenu { ColorActions(item: item, source: source) }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
