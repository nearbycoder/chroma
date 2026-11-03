import SwiftUI

/// Edits a color with a saturation/brightness field, hue and opacity sliders, and numeric fields.
struct ColorEditor: View {
    @Binding var color: RGBColor
    var showsAlpha = true

    enum Mode: String, CaseIterable, Identifiable {
        case rgb = "RGB", hsb = "HSB", hsl = "HSL", oklch = "OKLCH"
        var id: String { rawValue }
    }

    @AppStorage("editorMode") private var mode: Mode = .rgb
    // Kept separately so hue survives grays and saturation survives black.
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0
    @State private var lastEmitted: RGBColor?

    var body: some View {
        VStack(spacing: 10) {
            SaturationBrightnessField(hue: hue, saturation: $saturation, brightness: $brightness) { emit() }
                .frame(height: 140)
            GradientSlider(value: Binding(get: { hue / 360 }, set: { hue = $0 * 360; emit() }), gradient: Self.hueGradient)
            if showsAlpha {
                GradientSlider(value: Binding(get: { color.alpha }, set: { color = color.withAlpha($0).quantized; lastEmitted = color }),
                               gradient: Gradient(colors: [color.withAlpha(0).color, color.opaque.color]), checkered: true)
            }
            HStack(spacing: 8) {
                ColorTextField(color: $color)
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            channels
        }
        .onAppear { sync(from: color) }
        .onChange(of: color) { _, new in
            if new != lastEmitted { sync(from: new) }
        }
    }

    private func sync(from color: RGBColor) {
        let hsb = color.hsb
        if hsb.saturation > 0.001 && hsb.brightness > 0.001 { hue = hsb.hue }
        if hsb.brightness > 0.001 { saturation = hsb.saturation }
        brightness = hsb.brightness
        lastEmitted = color
    }

    private func emit() {
        let next = RGBColor(hue: hue, saturation: saturation, brightness: brightness, alpha: color.alpha).quantized
        lastEmitted = next
        color = next
    }

    static let hueGradient = Gradient(colors: stride(from: 0.0, through: 360, by: 30).map { RGBColor(hue: $0, saturation: 1, brightness: 1).color })

    @ViewBuilder
    private var channels: some View {
        let c = color
        HStack(spacing: 6) {
            switch mode {
            case .rgb:
                channel("R", Double(c.r8), 0...255) { color = RGBColor(r8: Int($0), g8: c.g8, b8: c.b8, a8: c.a8) }
                channel("G", Double(c.g8), 0...255) { color = RGBColor(r8: c.r8, g8: Int($0), b8: c.b8, a8: c.a8) }
                channel("B", Double(c.b8), 0...255) { color = RGBColor(r8: c.r8, g8: c.g8, b8: Int($0), a8: c.a8) }
            case .hsb:
                channel("H", hue.rounded(), 0...360) { hue = $0; emit() }
                channel("S", (saturation * 100).rounded(), 0...100) { saturation = $0 / 100; emit() }
                channel("B", (brightness * 100).rounded(), 0...100) { brightness = $0 / 100; emit() }
            case .hsl:
                let hsl = c.hsl
                channel("H", hsl.hue.rounded(), 0...360) { color = RGBColor(hue: $0, saturation: hsl.saturation, lightness: hsl.lightness, alpha: c.alpha).quantized }
                channel("S", (hsl.saturation * 100).rounded(), 0...100) { color = RGBColor(hue: hsl.hue, saturation: $0 / 100, lightness: hsl.lightness, alpha: c.alpha).quantized }
                channel("L", (hsl.lightness * 100).rounded(), 0...100) { color = RGBColor(hue: hsl.hue, saturation: hsl.saturation, lightness: $0 / 100, alpha: c.alpha).quantized }
            case .oklch:
                let lch = c.oklch
                channel("L", (lch.l * 100).rounded(), 0...100) { color = RGBColor(oklchL: $0 / 100, c: lch.c, h: lch.h, alpha: c.alpha).quantized }
                channel("C", (lch.c * 1000).rounded() / 1000, 0...0.37, decimals: 3) { color = RGBColor(oklchL: lch.l, c: $0, h: lch.h, alpha: c.alpha).quantized }
                channel("H", lch.h.rounded(), 0...360) { color = RGBColor(oklchL: lch.l, c: lch.c, h: $0, alpha: c.alpha).quantized }
            }
            if showsAlpha {
                channel("A", (c.alpha * 100).rounded(), 0...100) { color = c.withAlpha($0 / 100).quantized }
            }
        }
    }

    private func channel(_ label: String, _ value: Double, _ range: ClosedRange<Double>, decimals: Int = 0, set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 2) {
            NumberField(value: value, range: range, decimals: decimals, set: set)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// A number box that commits on Return or when focus leaves, clamped to `range`.
struct NumberField: View {
    let value: Double
    let range: ClosedRange<Double>
    var decimals = 0
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(.system(size: 12).monospacedDigit())
            .focused($focused)
            .onAppear { text = formatted }
            .onChange(of: value) { if !focused { text = formatted } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
    }

    private var formatted: String { String(format: "%.\(decimals)f", value) }

    private func commit() {
        guard let number = Double(text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }) else {
            text = formatted
            return
        }
        set(min(max(number, range.lowerBound), range.upperBound))
        DispatchQueue.main.async { text = formatted }
    }
}

/// A text field that accepts any color notation Chroma understands: hex, rgb(), hsl(), oklch()…
struct ColorTextField: View {
    @Binding var color: RGBColor
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Hex or CSS color", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .focused($focused)
            .overlay(alignment: .trailing) {
                if invalid {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).padding(.trailing, 6)
                }
            }
            .onAppear { text = color.hexString }
            .onChange(of: color) { if !focused { text = color.hexString } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if let parsed = ColorParser.parse(text) {
            color = parsed.quantized
            invalid = false
            text = color.hexString
        } else {
            invalid = !text.isEmpty
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { invalid = false; text = color.hexString }
        }
    }
}

struct SaturationBrightnessField: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    let changed: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Rectangle().fill(RGBColor(hue: hue, saturation: 1, brightness: 1).color)
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            .overlay(alignment: .topLeading) {
                Circle()
                    .strokeBorder(.white, lineWidth: 2.5)
                    .background(Circle().fill(RGBColor(hue: hue, saturation: saturation, brightness: brightness).color))
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .frame(width: 16, height: 16)
                    .offset(x: saturation * size.width - 8, y: (1 - brightness) * size.height - 8)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                saturation = (drag.location.x / size.width).clamped01
                brightness = (1 - drag.location.y / size.height).clamped01
                changed()
            })
        }
    }
}

struct GradientSlider: View {
    @Binding var value: Double
    let gradient: Gradient
    var checkered = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                if checkered { Checkerboard(square: 5).clipShape(Capsule()) }
                Capsule().fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                Capsule().strokeBorder(.primary.opacity(0.12))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: 16, height: 16)
                    .offset(x: value.clamped01 * (width - 16))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = ((drag.location.x - 8) / (width - 16)).clamped01
            })
        }
        .frame(height: 16)
    }
}

extension CGFloat {
    var clamped01: Double { Double(self).clamped01 }
}
