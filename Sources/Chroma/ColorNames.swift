import Foundation

/// Human names for colors: the nearest entry in Name That Color, and the nearest Tailwind palette swatch.
final class ColorNames: @unchecked Sendable {
    static let shared = ColorNames()

    struct Entry {
        let name: String
        let color: RGBColor
        let lab: (l: Double, a: Double, b: Double)
    }

    private(set) lazy var names: [Entry] = Self.load("color-names")
    private(set) lazy var tailwind: [Entry] = Self.load("tailwind")
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    /// The closest named color, like "Royal Blue".
    func name(for color: RGBColor) -> String {
        let key = color.hex6
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let name = nearest(color, in: names)?.name ?? key
        cache[key] = name
        return name
    }

    /// The closest Tailwind palette swatch, like `blue-500`, and whether it's an exact match.
    func tailwindName(for color: RGBColor) -> (name: String, exact: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = nearest(color, in: tailwind) else { return ("[\(color.hexString)]", false) }
        return (entry.name, entry.color.hex6 == color.hex6)
    }

    private func nearest(_ color: RGBColor, in entries: [Entry]) -> Entry? {
        let lab = color.oklab
        var best: Entry?
        var bestDistance = Double.infinity
        for entry in entries {
            let d = pow(lab.l - entry.lab.l, 2) + pow(lab.a - entry.lab.a, 2) + pow(lab.b - entry.lab.b, 2)
            if d < bestDistance {
                bestDistance = d
                best = entry
            }
        }
        return best
    }

    /// Reads `RRGGBB name` lines from Resources/Data.
    private static func load(_ resource: String) -> [Entry] {
        let bundle = Bundle(for: ColorNames.self)
        guard let url = bundle.url(forResource: resource, withExtension: "txt", subdirectory: "Data")
            ?? bundle.url(forResource: resource, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#"), let space = line.firstIndex(of: " "),
                  let color = RGBColor(hex: String(line[..<space]))
            else { return nil }
            return Entry(name: String(line[line.index(after: space)...]), color: color, lab: color.oklab)
        }
    }
}

extension String {
    /// "Royal Blue" → "royal_blue"
    var snakeCased: String {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    /// "Royal Blue" → "royalBlue"
    var camelCased: String {
        let words = components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard let first = words.first else { return self }
        return first.lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
    }

    /// "Royal Blue" → "royal-blue"
    var kebabCased: String { snakeCased.replacingOccurrences(of: "_", with: "-") }
}
