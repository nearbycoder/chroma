import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What a pick is for: copying (the shortcut) or handing a color back to a window that asked for one.
enum PickPurpose {
    case copy
    /// Called once: with the color, or nil when picking is cancelled.
    case deliver((RGBColor?) -> Void)

    /// Tells a waiting caller that no color is coming.
    func cancel() {
        if case .deliver(let handler) = self { handler(nil) }
    }
}

/// One round of picking: a frozen copy of every screen with a loupe that follows the pointer, until a click or Esc.
@MainActor
final class PickerSession {
    let purpose: PickPurpose
    /// The app that was frontmost when picking started, for smart formats.
    let sourceApp: NSRunningApplication?
    var onPick: ((RGBColor, _ keepPicking: Bool) -> Void)?
    var onEnd: (() -> Void)?

    private var windows: [PickerWindow] = []
    private var monitors: [Any] = []
    private var cursorHidden = false
    private var settings: AppSettings { .shared }
    private let hint = PickerHintModel()
    private var delivered = false
    private var resignObserver: NSObjectProtocol?

    /// The pointer in global screen coordinates (points). Arrow keys move it by one pixel.
    private(set) var pointer: CGPoint
    /// Format shown in the loupe; Tab cycles through the shown formats.
    private(set) var format: ColorFormat
    private(set) var pickedCount = 0

    init(snapshots: [ScreenSnapshot], purpose: PickPurpose) {
        self.purpose = purpose
        sourceApp = NSWorkspace.shared.frontmostApplication
        pointer = NSEvent.mouseLocation
        format = AppSettings.shared.formatForCopy(app: sourceApp?.bundleIdentifier)
        for snapshot in snapshots {
            let window = PickerWindow(snapshot: snapshot, session: self, hint: hint)
            windows.append(window)
        }
    }

    func show() {
        #if DEBUG
        if let script = Harness.script {
            Harness.run(script, session: self, windows: windows)
            return
        }
        #endif
        for window in windows { window.orderFrontRegardless() }
        NSApp.activate()
        (windowUnderPointer ?? windows.first)?.makeKey()
        NSCursor.hide()
        cursorHidden = true
        installMonitors()
        update()

        let sessions = settings.defaults.integer(forKey: "pickSessions")
        settings.defaults.set(sessions + 1, forKey: "pickSessions")
        if sessions < 6 || !isCopying {
            hint.show(isCopying ? nil : "Pick a color", for: isCopying ? 5 : 30)
        }
    }

    private var isCopying: Bool {
        if case .copy = purpose { return true }
        return false
    }

    func end() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard !windows.isEmpty else { return }
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        if case .deliver(let handler) = purpose, !delivered {
            delivered = true
            handler(nil)
        }
        if let sourceApp, sourceApp.bundleIdentifier != Bundle.main.bundleIdentifier, isCopying {
            sourceApp.activate()
        }
        onEnd?()
    }

    /// The display under the pointer. The top row of a screen sits at exactly `maxY`, which `CGRect.contains` excludes.
    private var windowUnderPointer: PickerWindow? {
        windows.first { window in
            let f = window.snapshot.screen.frame
            return pointer.x >= f.minX && pointer.x < f.maxX && pointer.y > f.minY && pointer.y <= f.maxY
        }
    }

    /// The color under the pointer, averaged over the sample size.
    var currentColor: RGBColor? {
        guard let window = windowUnderPointer else { return nil }
        let (x, y) = window.pixel(at: pointer)
        return window.snapshot.buffer.color(x: x, y: y, sampleSize: settings.sampleSize)
    }

    // MARK: Input

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        } as Any)
        // If another app takes over (⌘-Tab, a notification), the overlay would keep eating clicks.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            moveTo(NSEvent.mouseLocation)
        case .leftMouseDown:
            moveTo(NSEvent.mouseLocation)
            pick(keepPicking: event.modifierFlags.contains(.shift))
        case .rightMouseDown:
            end()
        case .scrollWheel:
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
            if abs(delta) >= 0.5 {
                if event.modifierFlags.contains(.option) {
                    resize(by: delta > 0 ? 12 : -12)
                } else {
                    zoom(in: delta > 0)
                }
            }
        case .keyDown:
            return handleKey(event)
        default:
            return false
        }
        return true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        let step: CGFloat = shift ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Escape: end()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: pick(keepPicking: shift)
        case kVK_LeftArrow: nudge(dx: -step, dy: 0)
        case kVK_RightArrow: nudge(dx: step, dy: 0)
        case kVK_UpArrow: nudge(dx: 0, dy: step)
        case kVK_DownArrow: nudge(dx: 0, dy: -step)
        case kVK_Tab: cycleFormat(backwards: shift)
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: option ? zoom(in: true) : resize(by: 16)
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: option ? zoom(in: false) : resize(by: -16)
        case kVK_ANSI_G:
            settings.showGrid.toggle()
            update()
        case kVK_ANSI_S:
            settings.sampleSize = settings.sampleSize >= 5 ? 1 : settings.sampleSize + 2
            hint.show("Sample \(settings.sampleSize) × \(settings.sampleSize)", for: 1.2)
            update()
        case kVK_ANSI_Slash:
            showControls()
        default:
            // Swallow everything else, so menu shortcuts don't open windows under the overlay.
            break
        }
        return true
    }

    /// Shows the list of picker controls along the bottom of the screen.
    func showControls(for seconds: Double = 8) {
        hint.show(nil, for: seconds)
    }

    func moveTo(_ point: CGPoint) {
        pointer = point
        update()
    }

    /// Moves by whole device pixels on the current display.
    func nudge(dx: CGFloat, dy: CGFloat) {
        let scale = windowUnderPointer?.snapshot.scale ?? 2
        var next = CGPoint(x: pointer.x + dx / scale, y: pointer.y + dy / scale)
        let union = windows.reduce(CGRect.null) { $0.union($1.snapshot.screen.frame) }
        next.x = min(max(next.x, union.minX), union.maxX - 0.01)
        next.y = min(max(next.y, union.minY), union.maxY - 0.01)
        pointer = next
        if !AppCoordinator.isHarness {
            // Keep the real cursor with the loupe, so the next mouse move continues from here.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: next.x, y: mainHeight - next.y))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        update()
    }

    func zoom(in zoomIn: Bool) {
        let range = AppSettings.loupeZoomRange
        let next = settings.loupeZoom + (zoomIn ? -2 : 2)
        settings.loupeZoom = min(max(next, range.lowerBound), range.upperBound)
        update()
    }

    func resize(by delta: Double) {
        let range = AppSettings.loupeSizeRange
        settings.loupeSize = min(max(settings.loupeSize + delta, range.lowerBound), range.upperBound)
        update()
    }

    func cycleFormat(backwards: Bool = false) {
        let formats = settings.shownFormats
        guard !formats.isEmpty else { return }
        let index = formats.firstIndex(where: { $0.id == format.id }) ?? -1
        let next = backwards ? (index - 1 + formats.count) % formats.count : (index + 1) % formats.count
        format = formats[next]
        hint.show(format.name, for: 1.2)
        update()
    }

    func pick(keepPicking: Bool) {
        guard let color = currentColor else { return }
        switch purpose {
        case .copy:
            pickedCount += 1
            onPick?(color, keepPicking)
            if keepPicking {
                windowUnderPointer?.loupe.flash()
                hint.show(pickedCount == 1 ? "Picked 1 color. Keep clicking, or press Esc" : "Picked \(pickedCount) colors", for: 2)
            } else {
                end()
            }
        case .deliver(let handler):
            delivered = true
            end()
            handler(color)
        }
    }

    func update() {
        for window in windows {
            window.update(pointer: pointer, format: format, isActive: window === windowUnderPointer)
        }
    }
}

// MARK: - Window

final class PickerWindow: NSWindow {
    let snapshot: ScreenSnapshot
    let loupe: LoupeView
    private let hintView: NSHostingView<PickerHint>

    init(snapshot: ScreenSnapshot, session: PickerSession, hint: PickerHintModel) {
        self.snapshot = snapshot
        loupe = LoupeView(snapshot: snapshot)
        hintView = NSHostingView(rootView: PickerHint(model: hint))
        super.init(contentRect: snapshot.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(snapshot.screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        // The frozen screen, so what you see is exactly what gets sampled.
        let backdrop = NSView(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))
        backdrop.wantsLayer = true
        backdrop.layer?.contents = snapshot.image
        backdrop.layer?.contentsGravity = .resize
        backdrop.layer?.magnificationFilter = .nearest
        backdrop.addSubview(loupe)
        hintView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hintView)
        NSLayoutConstraint.activate([
            hintView.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            hintView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -56),
        ])
        contentView = backdrop
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The device pixel under a global point, clamped to this display.
    func pixel(at point: CGPoint) -> (Int, Int) {
        let frame = snapshot.screen.frame
        let scale = snapshot.scale
        let x = Int(((point.x - frame.minX) * scale).rounded(.down))
        let y = Int(((frame.maxY - point.y) * scale).rounded(.down))
        return (min(max(x, 0), snapshot.buffer.width - 1), min(max(y, 0), snapshot.buffer.height - 1))
    }

    func update(pointer: CGPoint, format: ColorFormat, isActive: Bool) {
        hintView.isHidden = !isActive
        guard isActive else {
            loupe.isHidden = true
            return
        }
        let (x, y) = pixel(at: pointer)
        let local = CGPoint(x: pointer.x - frame.minX, y: pointer.y - frame.minY)
        loupe.isHidden = false
        loupe.configure(pixelX: x, pixelY: y, format: format)
        loupe.place(at: local, in: frame.size)
        if !isKeyWindow, NSApp.isActive { makeKey() }
    }
}

// MARK: - Loupe

/// The magnifier: a circle of enlarged pixels with the sampled one outlined, and the value below it.
final class LoupeView: NSView {
    private let snapshot: ScreenSnapshot
    private var pixelX = 0
    private var pixelY = 0
    private var format = ColorFormat.fallback
    private var flashAmount: CGFloat = 0
    private var settings: AppSettings { .shared }

    private static let labelHeight: CGFloat = 30
    private static let labelGap: CGFloat = 10
    private static let margin: CGFloat = 24
    private var labelBelow = true

    init(snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    private var diameter: CGFloat { CGFloat(settings.loupeSize) }
    private var cells: Int { max(3, settings.loupeZoom | 1) }

    private var color: RGBColor {
        snapshot.buffer.color(x: pixelX, y: pixelY, sampleSize: settings.sampleSize) ?? .black
    }

    func configure(pixelX: Int, pixelY: Int, format: ColorFormat) {
        self.pixelX = pixelX
        self.pixelY = pixelY
        self.format = format
        needsDisplay = true
    }

    /// Centers the loupe on the pointer, with the label below (or above, near the bottom of the screen).
    func place(at point: CGPoint, in screen: CGSize) {
        let width = max(diameter, 440) + Self.margin * 2
        let height = diameter + Self.labelGap + Self.labelHeight + Self.margin * 2
        labelBelow = point.y - diameter / 2 - Self.labelGap - Self.labelHeight > 8
        let loupeCenterY = labelBelow ? height - Self.margin - diameter / 2 : Self.margin + diameter / 2
        let origin = CGPoint(x: (point.x - width / 2).rounded(), y: (point.y - loupeCenterY).rounded())
        let newFrame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        if frame != newFrame { frame = newFrame }
    }

    func flash() {
        flashAmount = 1
        needsDisplay = true
        Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.flashAmount -= 0.08
                if self.flashAmount <= 0 {
                    self.flashAmount = 0
                    timer.invalidate()
                }
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let d = diameter
        let n = cells
        let cell = d / CGFloat(n)
        let center = CGPoint(x: bounds.midX, y: labelBelow ? bounds.height - Self.margin - d / 2 : Self.margin + d / 2)
        let circle = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        let picked = color
        let buffer = snapshot.buffer

        // Shadow under the lens.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.fillEllipse(in: circle)
        context.restoreGState()

        // Enlarged pixels.
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.fill(circle)
        let half = n / 2
        let originX = center.x - cell * (CGFloat(half) + 0.5)
        let originY = center.y + cell * (CGFloat(half) + 0.5)
        for row in 0..<n {
            let py = pixelY - half + row
            for column in 0..<n {
                let px = pixelX - half + column
                guard buffer.contains(x: px, y: py) else { continue }
                let p = buffer.packed(x: px, y: py)
                context.setFillColor(red: CGFloat((p >> 16) & 0xFF) / 255, green: CGFloat((p >> 8) & 0xFF) / 255, blue: CGFloat(p & 0xFF) / 255, alpha: 1)
                // Overlap by a hair so there are no seams between cells.
                context.fill(CGRect(x: originX + CGFloat(column) * cell, y: originY - CGFloat(row + 1) * cell, width: cell + 0.5, height: cell + 0.5))
            }
        }
        if settings.showGrid && cell >= 5 {
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.14).cgColor)
            context.setLineWidth(1 / (window?.backingScaleFactor ?? 2))
            for i in 0...n {
                let x = originX + CGFloat(i) * cell
                context.move(to: CGPoint(x: x, y: circle.minY)); context.addLine(to: CGPoint(x: x, y: circle.maxY))
                let y = originY - CGFloat(i) * cell
                context.move(to: CGPoint(x: circle.minX, y: y)); context.addLine(to: CGPoint(x: circle.maxX, y: y))
            }
            context.strokePath()
        }
        // The sampled pixel (or square, when averaging).
        let sample = CGFloat(settings.sampleSize)
        let target = CGRect(x: center.x - cell * sample / 2, y: center.y - cell * sample / 2, width: cell * sample, height: cell * sample)
        context.setLineWidth(2.5)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.stroke(target.insetBy(dx: -1.5, dy: -1.5))
        context.setLineWidth(1.5)
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(target.insetBy(dx: -0.5, dy: -0.5))
        context.restoreGState()

        // Rim in the picked color, with hairlines so it stands out on any background.
        let rimWidth: CGFloat = 5 + flashAmount * 5
        context.setLineWidth(rimWidth)
        context.setStrokeColor(picked.cgColor)
        context.strokeEllipse(in: circle.insetBy(dx: rimWidth / 2, dy: rimWidth / 2))
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.strokeEllipse(in: circle.insetBy(dx: rimWidth + 0.5, dy: rimWidth + 0.5))
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))

        drawLabel(color: picked, center: center, diameter: d)
    }

    private func drawLabel(color: RGBColor, center: CGPoint, diameter d: CGFloat) {
        let text = settings.string(color, format: format)
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let maxTextWidth = bounds.width - 60
        let string = NSAttributedString(string: text, attributes: attributes)
        let textWidth = min(ceil(string.size().width), maxTextWidth)
        let swatch: CGFloat = 14
        let width = textWidth + swatch + 30
        let y = labelBelow ? center.y - d / 2 - Self.labelGap - Self.labelHeight : center.y + d / 2 + Self.labelGap
        let rect = CGRect(x: (center.x - width / 2).rounded(), y: y, width: width, height: Self.labelHeight)

        let capsule = NSBezierPath(roundedRect: rect, xRadius: Self.labelHeight / 2, yRadius: Self.labelHeight / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor(white: 0.08, alpha: 0.88).setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        let dot = NSBezierPath(ovalIn: CGRect(x: rect.minX + 9, y: rect.midY - swatch / 2, width: swatch, height: swatch))
        color.nsColor.setFill()
        dot.fill()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        dot.stroke()

        let textRect = CGRect(x: rect.minX + swatch + 17, y: rect.midY - string.size().height / 2, width: textWidth, height: string.size().height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: text, attributes: attributes.merging([.paragraphStyle: paragraph]) { $1 }).draw(in: textRect)
    }
}

// MARK: - Hint

@MainActor
final class PickerHintModel: ObservableObject {
    @Published var message: String?
    @Published var visible = false
    private var hideWork: DispatchWorkItem?

    /// Shows `message`, or the list of controls when it's nil.
    func show(_ message: String?, for seconds: Double) {
        self.message = message
        withAnimation(.easeOut(duration: 0.2)) { visible = true }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) { self?.visible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

struct PickerHint: View {
    @ObservedObject var model: PickerHintModel

    var body: some View {
        Group {
            if model.visible {
                content
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(minWidth: 10, minHeight: 40)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.message {
            Text(message).font(.system(size: 13, weight: .medium))
        } else {
            HStack(spacing: 16) {
                key("Click", "copy")
                key("⇧ Click", "keep picking")
                key("Arrows", "nudge")
                key("Scroll", "zoom")
                key("Tab", "format")
                key("Esc", "cancel")
            }
        }
    }

    private func key(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 12, weight: .semibold))
            Text(action).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
