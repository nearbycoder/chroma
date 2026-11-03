import Foundation

/// A way of writing a color as text: a built-in format or one the user defined with a template.
struct ColorFormat: Identifiable, Hashable {
    let id: String
    var name: String
    var group: String
    var template: String
    var isCustom: Bool = false

    func string(for color: RGBColor, uppercaseHex: Bool = true) -> String {
        FormatTemplate.render(template, color: color, uppercaseHex: uppercaseHex)
    }

    /// Every built-in format, grouped the way the format menu shows them.
    static let builtIn: [ColorFormat] = [
        .init(id: "hex", name: "Hex", group: "Web", template: "#{hex}"),
        .init(id: "hexBare", name: "Hex without #", group: "Web", template: "{hex}"),
        .init(id: "cssRGB", name: "CSS rgb()", group: "Web", template: "{?alpha}rgba({r}, {g}, {b}, {a}){/alpha}{!alpha}rgb({r}, {g}, {b}){/alpha}"),
        .init(id: "cssRGBModern", name: "CSS rgb() space-separated", group: "Web", template: "rgb({r} {g} {b}{?alpha} / {a}{/alpha})"),
        .init(id: "cssHSL", name: "CSS hsl()", group: "Web", template: "{?alpha}hsla({h}, {s}%, {l}%, {a}){/alpha}{!alpha}hsl({h}, {s}%, {l}%){/alpha}"),
        .init(id: "cssOKLCH", name: "CSS oklch()", group: "Web", template: "oklch({okl}% {okc} {okh}{?alpha} / {a}{/alpha})"),
        .init(id: "cssP3", name: "CSS color(display-p3)", group: "Web", template: "color(display-p3 {p3r} {p3g} {p3b}{?alpha} / {a}{/alpha})"),
        .init(id: "cssVar", name: "CSS variable", group: "Web", template: "--{kebab_name}: #{hex};"),
        .init(id: "tailwind", name: "Tailwind (nearest)", group: "Web", template: "{tailwind}"),
        .init(id: "tailwindArbitrary", name: "Tailwind arbitrary value", group: "Web", template: "[#{hex}]"),

        .init(id: "swiftUI", name: "SwiftUI Color", group: "Apple", template: "Color(red: {rf}, green: {gf}, blue: {bf}{?alpha}, opacity: {a}{/alpha})"),
        .init(id: "uiColorRGB", name: "UIColor RGB", group: "Apple", template: "UIColor(red: {rf}, green: {gf}, blue: {bf}, alpha: {a})"),
        .init(id: "uiColorHSB", name: "UIColor HSB", group: "Apple", template: "UIColor(hue: {hf}, saturation: {sbf}, brightness: {bbf}, alpha: {a})"),
        .init(id: "nsColorRGB", name: "NSColor RGB", group: "Apple", template: "NSColor(srgbRed: {rf}, green: {gf}, blue: {bf}, alpha: {a})"),
        .init(id: "nsColorHSB", name: "NSColor HSB", group: "Apple", template: "NSColor(hue: {hf}, saturation: {sbf}, brightness: {bbf}, alpha: {a})"),
        .init(id: "cgColor", name: "CGColor", group: "Apple", template: "CGColor(srgbRed: {rf}, green: {gf}, blue: {bf}, alpha: {a})"),
        .init(id: "objcUIColor", name: "Objective-C UIColor", group: "Apple", template: "[UIColor colorWithRed:{rf} green:{gf} blue:{bf} alpha:{a}]"),
        .init(id: "objcNSColor", name: "Objective-C NSColor", group: "Apple", template: "[NSColor colorWithSRGBRed:{rf} green:{gf} blue:{bf} alpha:{a}]"),

        .init(id: "androidARGB", name: "Android ARGB", group: "Android & cross-platform", template: "#{A}{hex}"),
        .init(id: "androidXML", name: "Android XML", group: "Android & cross-platform", template: "<color name=\"{snake_name}\">#{A}{hex}</color>"),
        .init(id: "compose", name: "Jetpack Compose", group: "Android & cross-platform", template: "Color(0x{A}{hex})"),
        .init(id: "flutter", name: "Flutter", group: "Android & cross-platform", template: "Color(0x{A}{hex})"),
        .init(id: "reactNative", name: "React Native", group: "Android & cross-platform", template: "'#{hex}{?alpha}{A}{/alpha}'"),

        .init(id: "java", name: "Java AWT", group: "Other languages", template: "new Color({r}, {g}, {b}{?alpha}, {a255}{/alpha})"),
        .init(id: "dotNet", name: ".NET", group: "Other languages", template: "Color.FromArgb({a255}, {r}, {g}, {b})"),
        .init(id: "unity", name: "Unity", group: "Other languages", template: "new Color({rf}f, {gf}f, {bf}f, {a}f)"),
        .init(id: "openGL", name: "OpenGL", group: "Other languages", template: "glColor4f({rf}f, {gf}f, {bf}f, {a}f)"),
        .init(id: "hexInt", name: "Hex integer", group: "Other languages", template: "0x{hex}"),

        .init(id: "rgbValues", name: "RGB values", group: "Values", template: "{r}, {g}, {b}"),
        .init(id: "rgbFloats", name: "RGB 0–1 values", group: "Values", template: "{rf}, {gf}, {bf}"),
        .init(id: "hsbValues", name: "HSB values", group: "Values", template: "{h}°, {sb}%, {bb}%"),
        .init(id: "cmyk", name: "CMYK", group: "Values", template: "cmyk({c}%, {m}%, {y}%, {k}%)"),
        .init(id: "name", name: "Color name", group: "Values", template: "{name}"),
    ]

    static let fallback = builtIn[0]
}

/// Fills `{token}` placeholders in a format template.
///
/// Tokens: `{hex}` RRGGBB, `{hex8}` RRGGBBAA, `{A}` alpha as two hex digits, `{r} {g} {b}` 0–255,
/// `{rf} {gf} {bf}` 0–1, `{a}` alpha 0–1, `{a255}` alpha 0–255, `{h}` hue in degrees, `{hf}` hue 0–1,
/// `{s} {l}` HSL percentages, `{sb} {bb}` HSB percentages, `{sbf} {bbf}` HSB 0–1, `{okl} {okc} {okh}` OKLCH,
/// `{p3r} {p3g} {p3b}` Display P3, `{c} {m} {y} {k}` CMYK percentages, `{name} {snake_name} {camelName}
/// {kebab_name}` the nearest color name, `{tailwind}` the nearest Tailwind swatch.
/// `{?alpha}…{/alpha}` keeps its contents only for translucent colors, `{!alpha}…{/alpha}` only for opaque ones.
enum FormatTemplate {
    static let tokenHelp: [(token: String, meaning: String)] = [
        ("{hex}", "RRGGBB"), ("{hex8}", "RRGGBBAA"), ("{A}", "Alpha as 2 hex digits"),
        ("{r} {g} {b}", "0–255"), ("{rf} {gf} {bf}", "0–1"), ("{a}", "Alpha 0–1"), ("{a255}", "Alpha 0–255"),
        ("{h} {s} {l}", "HSL"), ("{sb} {bb}", "HSB percentages"), ("{hf} {sbf} {bbf}", "HSB 0–1"),
        ("{okl} {okc} {okh}", "OKLCH"), ("{p3r} {p3g} {p3b}", "Display P3"), ("{c} {m} {y} {k}", "CMYK"),
        ("{name}", "Nearest name"), ("{snake_name} {camelName} {kebab_name}", "Name in code"),
        ("{tailwind}", "Nearest Tailwind swatch"), ("{?alpha}…{/alpha}", "Only when translucent"),
    ]

    static func render(_ template: String, color: RGBColor, uppercaseHex: Bool = true) -> String {
        let text = conditionals(template, translucent: !color.isOpaque)
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "{", let close = text[index...].firstIndex(of: "}") {
                let token = String(text[text.index(after: index)..<close])
                if let value = value(for: token, color: color, uppercaseHex: uppercaseHex) {
                    output += value
                    index = text.index(after: close)
                    continue
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    private static func conditionals(_ text: String, translucent: Bool) -> String {
        var result = text
        for (open, keep) in [("{?alpha}", translucent), ("{!alpha}", !translucent)] {
            while let start = result.range(of: open),
                  let end = result.range(of: "{/alpha}", range: start.upperBound..<result.endIndex) {
                let inner = keep ? String(result[start.upperBound..<end.lowerBound]) : ""
                result.replaceSubrange(start.lowerBound..<end.upperBound, with: inner)
            }
        }
        return result
    }

    private static func fixed(_ value: Double, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", value)
    }

    /// Up to `digits` decimals, without trailing zeros: 0.5, 0.231, 1.
    private static func trimmed(_ value: Double, _ digits: Int = 3) -> String {
        var text = String(format: "%.\(digits)f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func value(for token: String, color c: RGBColor, uppercaseHex: Bool) -> String? {
        let hexCase: (String) -> String = { uppercaseHex ? $0 : $0.lowercased() }
        switch token {
        case "hex": return hexCase(c.hex6)
        case "hex8": return hexCase(c.hex8)
        case "A": return hexCase(String(format: "%02X", c.a8))
        case "r": return "\(c.r8)"
        case "g": return "\(c.g8)"
        case "b": return "\(c.b8)"
        case "rf": return fixed(c.red)
        case "gf": return fixed(c.green)
        case "bf": return fixed(c.blue)
        case "a": return trimmed(c.alpha, 2)
        case "a255": return "\(c.a8)"
        case "h": return "\(Int(c.hsl.hue.rounded()) % 360)"
        case "hf": return fixed(c.hsb.hue / 360)
        case "s": return "\(Int((c.hsl.saturation * 100).rounded()))"
        case "l": return "\(Int((c.hsl.lightness * 100).rounded()))"
        case "sb": return "\(Int((c.hsb.saturation * 100).rounded()))"
        case "bb": return "\(Int((c.hsb.brightness * 100).rounded()))"
        case "sbf": return fixed(c.hsb.saturation)
        case "bbf": return fixed(c.hsb.brightness)
        case "okl": return trimmed(c.oklch.l * 100, 1)
        case "okc": return trimmed(c.oklch.c, 3)
        case "okh": return trimmed(c.oklch.h, 1)
        case "p3r": return trimmed(c.displayP3.r, 4)
        case "p3g": return trimmed(c.displayP3.g, 4)
        case "p3b": return trimmed(c.displayP3.b, 4)
        case "c": return "\(Int((c.cmyk.c * 100).rounded()))"
        case "m": return "\(Int((c.cmyk.m * 100).rounded()))"
        case "y": return "\(Int((c.cmyk.y * 100).rounded()))"
        case "k": return "\(Int((c.cmyk.k * 100).rounded()))"
        case "name": return ColorNames.shared.name(for: c)
        case "snake_name": return ColorNames.shared.name(for: c).snakeCased
        case "camelName": return ColorNames.shared.name(for: c).camelCased
        case "kebab_name": return ColorNames.shared.name(for: c).kebabCased
        case "tailwind": return ColorNames.shared.tailwindName(for: c).name
        default: return nil
        }
    }
}

/// Reads colors out of text: hex codes, `rgb()`, `hsl()`, `0xAARRGGBB` and bare `r, g, b` triples.
enum ColorParser {
    static func parse(_ input: String) -> RGBColor? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";'\"")))
        if text.isEmpty { return nil }
        if let color = RGBColor(hex: text) { return color }
        let lower = text.lowercased()

        if lower.hasPrefix("0x") {
            let digits = String(text.dropFirst(2))
            if digits.count == 8, let value = UInt64(digits, radix: 16) {
                // Android / Flutter order: AARRGGBB.
                return RGBColor(r8: Int(value >> 16 & 0xFF), g8: Int(value >> 8 & 0xFF), b8: Int(value & 0xFF), a8: Int(value >> 24 & 0xFF))
            }
            return RGBColor(hex: digits)
        }

        let numbers = numbers(in: lower)
        if lower.hasPrefix("rgb"), numbers.count >= 3 {
            let alpha = numbers.count >= 4 ? alphaValue(numbers[3]) : 1
            return RGBColor(r8: Int(numbers[0].value.rounded()), g8: Int(numbers[1].value.rounded()), b8: Int(numbers[2].value.rounded()), a8: Int((alpha * 255).rounded()))
        }
        if lower.hasPrefix("hsl"), numbers.count >= 3 {
            let alpha = numbers.count >= 4 ? alphaValue(numbers[3]) : 1
            return RGBColor(hue: numbers[0].value, saturation: numbers[1].value / 100, lightness: numbers[2].value / 100, alpha: alpha)
        }
        if lower.hasPrefix("oklch"), numbers.count >= 3 {
            let l = numbers[0].percent ? numbers[0].value / 100 : numbers[0].value
            let alpha = numbers.count >= 4 ? alphaValue(numbers[3]) : 1
            return RGBColor(oklchL: l, c: numbers[1].value, h: numbers[2].value, alpha: alpha).quantized
        }
        // A bare list like "59, 130, 246" or "0.23 0.51 0.96".
        if numbers.count == 3 || numbers.count == 4, lower.allSatisfy({ "0123456789., %/".contains($0) }) {
            let floats = numbers.allSatisfy { $0.value <= 1 } && numbers.contains { $0.value > 0 && $0.value < 1 }
            let scale = floats ? 1.0 : 255.0
            let alpha = numbers.count == 4 ? alphaValue(numbers[3]) : 1
            return RGBColor(red: numbers[0].value / scale, green: numbers[1].value / scale, blue: numbers[2].value / scale, alpha: alpha)
        }
        return nil
    }

    /// Every hex code and CSS color function in a block of text, in order, without duplicates.
    static func extractAll(from text: String) -> [RGBColor] {
        let pattern = #"(#[0-9a-fA-F]{8}\b|#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b|(?:rgba?|hsla?|oklch)\([^)]*\)|0x[0-9a-fA-F]{8}\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var colors: [RGBColor] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text), let color = parse(String(text[r])) else { continue }
            if seen.insert(color.hexString).inserted { colors.append(color) }
        }
        return colors
    }

    private struct Number { var value: Double; var percent: Bool }

    private static func numbers(in text: String) -> [Number] {
        guard let regex = try? NSRegularExpression(pattern: #"-?\d*\.?\d+%?"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            var token = String(text[r])
            let percent = token.hasSuffix("%")
            if percent { token.removeLast() }
            return Double(token).map { Number(value: $0, percent: percent) }
        }
    }

    private static func alphaValue(_ number: Number) -> Double {
        number.percent ? number.value / 100 : number.value
    }
}
