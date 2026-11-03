import AppKit
import SwiftUI

/// An sRGB color with straight alpha, each channel 0…1. Everything in Chroma is stored and compared this way.
struct RGBColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    init(r8: Int, g8: Int, b8: Int, a8: Int = 255) {
        self.init(red: Double(r8) / 255, green: Double(g8) / 255, blue: Double(b8) / 255, alpha: Double(a8) / 255)
    }

    /// Packed 0x__RRGGBB, as read from a screenshot.
    init(packed: UInt32) {
        self.init(r8: Int((packed >> 16) & 0xFF), g8: Int((packed >> 8) & 0xFF), b8: Int(packed & 0xFF))
    }

    /// Accepts `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`, with or without `#`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        // isHexDigit also accepts fullwidth digits, which UInt64(radix:) rejects.
        guard [3, 4, 6, 8].contains(text.count), text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if text.count <= 4 { text = text.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 8 {
            self.init(r8: Int(value >> 24 & 0xFF), g8: Int(value >> 16 & 0xFF), b8: Int(value >> 8 & 0xFF), a8: Int(value & 0xFF))
        } else {
            self.init(r8: Int(value >> 16 & 0xFF), g8: Int(value >> 8 & 0xFF), b8: Int(value & 0xFF))
        }
    }

    static let white = RGBColor(red: 1, green: 1, blue: 1)
    static let black = RGBColor(red: 0, green: 0, blue: 0)

    // MARK: 8-bit

    var r8: Int { Int((red * 255).rounded()) }
    var g8: Int { Int((green * 255).rounded()) }
    var b8: Int { Int((blue * 255).rounded()) }
    var a8: Int { Int((alpha * 255).rounded()) }
    var isOpaque: Bool { a8 == 255 }

    /// `RRGGBB`, uppercase.
    var hex6: String { String(format: "%02X%02X%02X", r8, g8, b8) }
    /// `RRGGBBAA`, uppercase.
    var hex8: String { hex6 + String(format: "%02X", a8) }
    /// `#RRGGBB`, or `#RRGGBBAA` when translucent.
    var hexString: String { "#" + (isOpaque ? hex6 : hex8) }

    /// The same color rounded to 8 bits per channel, which is what gets stored and copied.
    var quantized: RGBColor { RGBColor(r8: r8, g8: g8, b8: b8, a8: a8) }

    func withAlpha(_ alpha: Double) -> RGBColor { RGBColor(red: red, green: green, blue: blue, alpha: alpha) }
    var opaque: RGBColor { withAlpha(1) }

    // MARK: HSB and HSL

    /// Hue 0…360, saturation and brightness 0…1.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue), delta = maxC - minC
        return (hue(maxC: maxC, delta: delta), maxC == 0 ? 0 : delta / maxC, maxC)
    }

    /// Hue 0…360, saturation and lightness 0…1.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue), delta = maxC - minC
        let lightness = (maxC + minC) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        return (hue(maxC: maxC, delta: delta), saturation.clamped01, lightness)
    }

    private func hue(maxC: Double, delta: Double) -> Double {
        guard delta > 0 else { return 0 }
        var h: Double
        if maxC == red {
            h = (green - blue) / delta
        } else if maxC == green {
            h = (blue - red) / delta + 2
        } else {
            h = (red - green) / delta + 4
        }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b) = Self.sector(h, c, x)
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b) = Self.sector(h, c, x)
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    private static func sector(_ h: Double, _ c: Double, _ x: Double) -> (Double, Double, Double) {
        switch h {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
    }

    /// Cyan, magenta, yellow and key, each 0…1 (naive, no ICC profile).
    var cmyk: (c: Double, m: Double, y: Double, k: Double) {
        let k = 1 - max(red, green, blue)
        guard k < 1 else { return (0, 0, 0, 1) }
        return ((1 - red - k) / (1 - k), (1 - green - k) / (1 - k), (1 - blue - k) / (1 - k), k)
    }

    // MARK: Linear light, OKLab and Display P3

    static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    var linear: (r: Double, g: Double, b: Double) {
        (Self.linearize(red), Self.linearize(green), Self.linearize(blue))
    }

    init(linearRed r: Double, green g: Double, blue b: Double, alpha: Double = 1) {
        self.init(red: Self.encode(r.clamped01), green: Self.encode(g.clamped01), blue: Self.encode(b.clamped01), alpha: alpha)
    }

    /// OKLab: L 0…1, a and b roughly −0.4…0.4.
    var oklab: (l: Double, a: Double, b: Double) {
        let (r, g, b) = linear
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// OKLCH: L 0…1, chroma 0…~0.37, hue 0…360.
    var oklch: (l: Double, c: Double, h: Double) {
        let lab = oklab
        let c = hypot(lab.a, lab.b)
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        return (lab.l, c, c < 0.0001 ? 0 : h)
    }

    /// Linear sRGB for an OKLab color, which may fall outside 0…1.
    private static func linearRGB(oklabL L: Double, a: Double, b: Double) -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    init(oklabL L: Double, a: Double, b: Double, alpha: Double = 1) {
        let (r, g, bl) = Self.linearRGB(oklabL: L, a: a, b: b)
        self.init(linearRed: r, green: g, blue: bl, alpha: alpha)
    }

    /// Builds an OKLCH color, lowering chroma until it fits in sRGB so the hue and lightness hold.
    init(oklchL L: Double, c: Double, h: Double, alpha: Double = 1) {
        let radians = h * .pi / 180
        func fits(_ chroma: Double) -> Bool {
            let (r, g, b) = Self.linearRGB(oklabL: L, a: chroma * cos(radians), b: chroma * sin(radians))
            let e = 0.0001
            return r >= -e && r <= 1 + e && g >= -e && g <= 1 + e && b >= -e && b <= 1 + e
        }
        var chroma = max(0, c)
        if !fits(chroma) {
            var lo = 0.0, hi = chroma
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if fits(mid) { lo = mid } else { hi = mid }
            }
            chroma = lo
        }
        self.init(oklabL: L.clamped01, a: chroma * cos(radians), b: chroma * sin(radians), alpha: alpha)
    }

    /// Perceptual distance in OKLab (0 = identical, ~0.02 = barely noticeable).
    func distance(to other: RGBColor) -> Double {
        let a = oklab, b = other.oklab
        return sqrt(pow(a.l - b.l, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2))
    }

    /// The same color in Display P3 coordinates, 0…1.
    var displayP3: (r: Double, g: Double, b: Double) {
        let (r, g, b) = linear
        let pr = 0.8224621 * r + 0.1775380 * g
        let pg = 0.0331941 * r + 0.9668058 * g
        let pb = 0.0170827 * r + 0.0723974 * g + 0.9105199 * b
        return (Self.encode(pr).clamped01, Self.encode(pg).clamped01, Self.encode(pb).clamped01)
    }

    // MARK: Contrast

    /// WCAG 2 relative luminance.
    var luminance: Double {
        let (r, g, b) = linear
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Composites a translucent color over an opaque background.
    func over(_ background: RGBColor) -> RGBColor {
        guard alpha < 1 else { return self }
        let a = alpha
        return RGBColor(
            red: red * a + background.red * (1 - a),
            green: green * a + background.green * (1 - a),
            blue: blue * a + background.blue * (1 - a)
        )
    }

    /// WCAG 2 contrast ratio, 1…21.
    func contrastRatio(with other: RGBColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// APCA lightness contrast (Lc) of this color as text over `background`, about −108…106.
    /// Positive for dark text on light backgrounds, negative for light text on dark ones.
    func apcaContrast(on background: RGBColor) -> Double {
        func y(_ c: RGBColor) -> Double {
            let value = 0.2126729 * pow(c.red, 2.4) + 0.7151522 * pow(c.green, 2.4) + 0.0721750 * pow(c.blue, 2.4)
            return value > 0.022 ? value : value + pow(0.022 - value, 1.414)
        }
        let text = y(self), back = y(background)
        guard abs(back - text) >= 0.0005 else { return 0 }
        if back > text {
            let sapc = (pow(back, 0.56) - pow(text, 0.57)) * 1.14
            return sapc < 0.1 ? 0 : (sapc - 0.027) * 100
        } else {
            let sapc = (pow(back, 0.65) - pow(text, 0.62)) * 1.14
            return sapc > -0.1 ? 0 : (sapc + 0.027) * 100
        }
    }

    /// Black or white, whichever reads better on top of this color.
    var readableInk: RGBColor {
        contrastRatio(with: .white) >= contrastRatio(with: .black) * 0.8 ? .white : .black
    }

    // MARK: Platform

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    init?(nsColor: NSColor) {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }
}

extension RGBColor: Codable {
    /// Stored as `#RRGGBB` or `#RRGGBBAA`, so library files stay readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = RGBColor(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a hex color: \(text)")
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self.isNaN ? 0 : self)) }
}
