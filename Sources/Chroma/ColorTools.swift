import Foundation

/// Related colors worked out in OKLCH, so steps look even to the eye.
enum Harmony: String, CaseIterable, Identifiable {
    case complementary, analogous, triadic, splitComplementary, tetradic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .complementary: "Complementary"
        case .analogous: "Analogous"
        case .triadic: "Triadic"
        case .splitComplementary: "Split complementary"
        case .tetradic: "Tetradic"
        }
    }

    private var offsets: [Double] {
        switch self {
        case .complementary: [0, 180]
        case .analogous: [-30, 0, 30]
        case .triadic: [0, 120, 240]
        case .splitComplementary: [0, 150, 210]
        case .tetradic: [0, 90, 180, 270]
        }
    }

    func colors(for base: RGBColor) -> [RGBColor] {
        let lch = base.oklch
        return offsets.map { offset in
            offset == 0 ? base : RGBColor(oklchL: lch.l, c: lch.c, h: lch.h + offset, alpha: base.alpha).quantized
        }
    }
}

enum ColorScale {
    /// Lightness stops for 50, 100, 200 … 900, 950, in the spirit of Tailwind's scales.
    static let stops: [(label: String, lightness: Double)] = [
        ("50", 0.975), ("100", 0.94), ("200", 0.88), ("300", 0.80), ("400", 0.70), ("500", 0.62),
        ("600", 0.53), ("700", 0.45), ("800", 0.37), ("900", 0.30), ("950", 0.22),
    ]

    /// Eleven tints and shades of `base` with its hue, chroma eased toward the light and dark ends.
    static func scale(for base: RGBColor) -> [(label: String, color: RGBColor)] {
        let lch = base.oklch
        return stops.map { stop in
            // Very light and very dark colors can't hold much chroma; taper it so they stay clean.
            let taper = 1 - pow(abs(stop.lightness - 0.6) / 0.45, 2) * 0.6
            return (stop.label, RGBColor(oklchL: stop.lightness, c: lch.c * max(0.2, taper), h: lch.h).quantized)
        }
    }

    /// `count` steps from `base` toward white (tints) or black (shades), mixed in OKLab.
    static func mix(_ base: RGBColor, toward target: RGBColor, steps count: Int) -> [RGBColor] {
        let a = base.oklab, b = target.oklab
        return (1...count).map { i in
            let t = Double(i) / Double(count + 1)
            return RGBColor(oklabL: a.l + (b.l - a.l) * t, a: a.a + (b.a - a.a) * t, b: a.b + (b.b - a.b) * t).quantized
        }
    }
}

/// How a color looks with a color vision deficiency (Machado, Oliveira and Fernandes 2009, full severity).
enum VisionSimulation: String, CaseIterable, Identifiable {
    case normal, protanopia, deuteranopia, tritanopia, achromatopsia
    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal vision"
        case .protanopia: "Protanopia"
        case .deuteranopia: "Deuteranopia"
        case .tritanopia: "Tritanopia"
        case .achromatopsia: "Achromatopsia"
        }
    }

    var detail: String {
        switch self {
        case .normal: "No simulation"
        case .protanopia: "No red cones"
        case .deuteranopia: "No green cones"
        case .tritanopia: "No blue cones"
        case .achromatopsia: "No color"
        }
    }

    private var matrix: [Double]? {
        switch self {
        case .normal, .achromatopsia: nil
        case .protanopia: [0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998]
        case .deuteranopia: [0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881]
        case .tritanopia: [1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900]
        }
    }

    func apply(_ color: RGBColor) -> RGBColor {
        switch self {
        case .normal:
            return color
        case .achromatopsia:
            let y = color.luminance
            return RGBColor(linearRed: y, green: y, blue: y, alpha: color.alpha)
        default:
            let m = matrix!
            let (r, g, b) = color.linear
            return RGBColor(
                linearRed: m[0] * r + m[1] * g + m[2] * b,
                green: m[3] * r + m[4] * g + m[5] * b,
                blue: m[6] * r + m[7] * g + m[8] * b,
                alpha: color.alpha
            )
        }
    }
}

/// WCAG 2 thresholds for text and interface parts.
enum ContrastLevel: String, CaseIterable, Identifiable {
    case aaLarge, aa, aaaLarge, aaa
    var id: String { rawValue }

    var minimum: Double {
        switch self {
        case .aaLarge: 3
        case .aa: 4.5
        case .aaaLarge: 4.5
        case .aaa: 7
        }
    }

    var title: String {
        switch self {
        case .aaLarge: "AA large text"
        case .aa: "AA"
        case .aaaLarge: "AAA large text"
        case .aaa: "AAA"
        }
    }
}

enum ContrastFixer {
    /// The closest color to `text` (same hue and chroma, different OKLCH lightness) that reaches `target`
    /// against `background`. Returns nil when even black or white can't get there.
    static func fix(text: RGBColor, background: RGBColor, target: Double) -> RGBColor? {
        let back = background.opaque
        let original = text.over(back)
        if original.contrastRatio(with: back) >= target { return text }
        let lch = text.oklch

        func candidate(_ l: Double) -> RGBColor {
            RGBColor(oklchL: l, c: lch.c, h: lch.h, alpha: text.alpha).quantized
        }
        func passes(_ l: Double) -> Bool {
            candidate(l).over(back).contrastRatio(with: back) >= target
        }

        // Search lighter and darker; pick whichever reaches the target with the smaller change.
        var results: [(color: RGBColor, change: Double)] = []
        for end in [0.0, 1.0] where passes(end) {
            var near = lch.l, far = end
            for _ in 0..<30 {
                let mid = (near + far) / 2
                if passes(mid) { far = mid } else { near = mid }
            }
            results.append((candidate(far), abs(far - lch.l)))
        }
        return results.min { $0.change < $1.change }?.color
    }

    /// A rough reading of an APCA Lc value, after the APCA "bronze" guidance.
    static func apcaGuidance(_ lc: Double) -> String {
        switch abs(lc) {
        case 90...: "Excellent: works for any text"
        case 75..<90: "Good for body text"
        case 60..<75: "OK for larger body text and labels"
        case 45..<60: "Headlines and large text only"
        case 30..<45: "Spot text and non-text UI only"
        case 15..<30: "Too low for text"
        default: "Not readable"
        }
    }
}
