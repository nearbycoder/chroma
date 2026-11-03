import AppKit
import UniformTypeIdentifiers

/// Palette file formats Chroma can write.
enum ExportFormat: String, CaseIterable, Identifiable {
    case chroma, ase, clr, gpl, css, scss, tailwind, swiftUI, androidXML, png, text
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chroma: "Chroma Palette (.json)"
        case .ase: "Adobe Swatch Exchange (.ase)"
        case .clr: "Apple Color List (.clr)"
        case .gpl: "GIMP / Inkscape / Krita (.gpl)"
        case .css: "CSS Custom Properties (.css)"
        case .scss: "SCSS Variables (.scss)"
        case .tailwind: "Tailwind CSS v4 Theme (.css)"
        case .swiftUI: "SwiftUI Color Extension (.swift)"
        case .androidXML: "Android colors.xml (.xml)"
        case .png: "Swatch Image (.png)"
        case .text: "Plain Text (.txt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .chroma: "json"
        case .ase: "ase"
        case .clr: "clr"
        case .gpl: "gpl"
        case .css, .tailwind: "css"
        case .scss: "scss"
        case .swiftUI: "swift"
        case .androidXML: "xml"
        case .png: "png"
        case .text: "txt"
        }
    }

    var isText: Bool { ![.ase, .clr, .png].contains(self) }
}

enum PaletteIO {
    enum Failure: LocalizedError {
        case unreadable(String)
        case noColors(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let file): "Chroma couldn't read “\(file)”."
            case .noColors(let file): "“\(file)” doesn't contain any colors Chroma recognizes."
            }
        }
    }

    // MARK: Export

    static func data(for palette: Palette, as format: ExportFormat) throws -> Data {
        switch format {
        case .ase: return ase(palette)
        case .clr: return try clr(palette)
        case .png: return png(palette)
        default: return Data(text(for: palette, as: format).utf8)
        }
    }

    /// Unique, code-friendly names for each color: the user's name or the nearest named color.
    static func variableNames(_ palette: Palette) -> [String] {
        var used: [String: Int] = [:]
        return palette.colors.map { item in
            let base = item.displayName.kebabCased.isEmpty ? "color" : item.displayName.kebabCased
            let count = used[base, default: 0] + 1
            used[base] = count
            return count == 1 ? base : "\(base)-\(count)"
        }
    }

    static func text(for palette: Palette, as format: ExportFormat) -> String {
        let names = variableNames(palette)
        let prefix = palette.name.kebabCased
        let colors = palette.colors
        func hex(_ c: RGBColor) -> String { c.hexString.lowercased() }

        switch format {
        case .chroma:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let file = LibraryFile(palettes: [palette])
            return String(decoding: (try? encoder.encode(file)) ?? Data(), as: UTF8.self)
        case .gpl:
            var lines = ["GIMP Palette", "Name: \(palette.name)", "Columns: 0", "#"]
            for (item, name) in zip(colors, names) {
                lines.append(String(format: "%3d %3d %3d\t%@", item.color.r8, item.color.g8, item.color.b8, item.name ?? name))
            }
            return lines.joined(separator: "\n") + "\n"
        case .css:
            let body = zip(colors, names).map { "  --\(prefix)-\($1): \(hex($0.color));" }
            return "/* \(palette.name), exported from Chroma */\n:root {\n" + body.joined(separator: "\n") + "\n}\n"
        case .scss:
            let body = zip(colors, names).map { "$\(prefix)-\($1): \(hex($0.color));" }
            return "// \(palette.name), exported from Chroma\n" + body.joined(separator: "\n") + "\n"
        case .tailwind:
            let body = zip(colors, names).map { "  --color-\(prefix)-\($1): \(hex($0.color));" }
            return "/* \(palette.name), exported from Chroma. Use as bg-\(prefix)-\(names.first ?? "name") */\n@theme {\n" + body.joined(separator: "\n") + "\n}\n"
        case .swiftUI:
            let type = palette.name.camelCased.prefix(1).uppercased() + palette.name.camelCased.dropFirst()
            let body = zip(colors, names).map { item, name in
                let c = item.color
                let alpha = c.isOpaque ? "" : String(format: ", opacity: %.3f", c.alpha)
                return String(format: "    static let %@ = Color(red: %.3f, green: %.3f, blue: %.3f%@)", name.camelCased, c.red, c.green, c.blue, alpha)
            }
            return "import SwiftUI\n\n/// \(palette.name), exported from Chroma.\nextension Color {\n    enum \(type.isEmpty ? "Palette" : type) {\n" + body.map { "    " + $0 }.joined(separator: "\n") + "\n    }\n}\n"
        case .androidXML:
            let body = zip(colors, names).map { item, name in
                "    <color name=\"\(prefix.snakeCased)_\(name.snakeCased)\">#\(String(format: "%02X", item.color.a8))\(item.color.hex6)</color>"
            }
            return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!-- \(palette.name), exported from Chroma -->\n<resources>\n" + body.joined(separator: "\n") + "\n</resources>\n"
        case .text:
            return colors.map { $0.color.hexString }.joined(separator: "\n") + "\n"
        case .ase, .clr, .png:
            return ""
        }
    }

    /// Adobe Swatch Exchange 1.0: a named group of RGB swatches, big-endian.
    static func ase(_ palette: Palette) -> Data {
        var blocks = Data()
        var blockCount: UInt32 = 0

        func utf16Name(_ name: String) -> Data {
            var data = Data()
            let units = Array(name.utf16) + [0]
            data.appendBE(UInt16(units.count))
            for unit in units { data.appendBE(unit) }
            return data
        }
        func block(_ type: UInt16, _ body: Data) {
            blocks.appendBE(type)
            blocks.appendBE(UInt32(body.count))
            blocks.append(body)
            blockCount += 1
        }

        block(0xC001, utf16Name(palette.name))
        for item in palette.colors {
            var body = utf16Name(item.displayName)
            body.append(contentsOf: Array("RGB ".utf8))
            for value in [item.color.red, item.color.green, item.color.blue] {
                body.appendBE(Float32(value).bitPattern)
            }
            body.appendBE(UInt16(2)) // normal (not global or spot)
            block(0x0001, body)
        }
        block(0xC002, Data())

        var data = Data("ASEF".utf8)
        data.appendBE(UInt16(1))
        data.appendBE(UInt16(0))
        data.appendBE(blockCount)
        data.append(blocks)
        return data
    }

    static func clr(_ palette: Palette) throws -> Data {
        let list = NSColorList(name: palette.name)
        for (item, name) in zip(palette.colors, uniqueDisplayNames(palette)) {
            list.setColor(item.color.nsColor, forKey: name)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".clr")
        defer { try? FileManager.default.removeItem(at: url) }
        try list.write(to: url)
        return try Data(contentsOf: url)
    }

    private static func uniqueDisplayNames(_ palette: Palette) -> [String] {
        var used: [String: Int] = [:]
        return palette.colors.map { item in
            let count = used[item.displayName, default: 0] + 1
            used[item.displayName] = count
            return count == 1 ? item.displayName : "\(item.displayName) \(count)"
        }
    }

    /// A strip of swatches with their hex values, for sharing.
    static func png(_ palette: Palette) -> Data {
        let columns = min(max(palette.colors.count, 1), 8)
        let rows = max(1, Int(ceil(Double(palette.colors.count) / Double(columns))))
        let cell = CGSize(width: 160, height: 200)
        let padding: CGFloat = 32
        let title: CGFloat = 56
        let size = CGSize(width: padding * 2 + CGFloat(columns) * cell.width, height: padding * 2 + title + CGFloat(rows) * cell.height)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()

        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor(white: 0.1, alpha: 1)]
        drawFlipped(palette.name, at: CGPoint(x: padding + 8, y: padding), attributes: titleAttributes)

        for (index, item) in palette.colors.enumerated() {
            let x = padding + CGFloat(index % columns) * cell.width + 8
            let y = padding + title + CGFloat(index / columns) * cell.height
            let rect = CGRect(x: x, y: y, width: cell.width - 16, height: cell.width - 16)
            item.color.nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            NSColor(white: 0, alpha: 0.08).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14).stroke()
            drawFlipped(item.color.hexString, at: CGPoint(x: x + 2, y: rect.maxY + 8), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
            drawFlipped(item.displayName, at: CGPoint(x: x + 2, y: rect.maxY + 28), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.45, alpha: 1)], width: rect.width)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func drawFlipped(_ text: String, at point: CGPoint, attributes: [NSAttributedString.Key: Any], width: CGFloat = 1000) {
        let string = NSAttributedString(string: text, attributes: attributes)
        let height = string.size().height
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: point.x, yBy: point.y + height)
        t.scaleX(by: 1, yBy: -1)
        t.concat()
        string.draw(with: CGRect(x: 0, y: 0, width: width, height: height), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Import

    /// Reads one or more palettes from a file, choosing the parser by extension and content.
    static func palettes(from url: URL) throws -> [Palette] {
        let name = url.deletingPathExtension().lastPathComponent
        let file = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "clr":
            guard let list = NSColorList(name: name, fromFile: url.path) else { throw Failure.unreadable(file) }
            let items = list.allKeys.compactMap { key in
                list.color(withKey: key).flatMap(RGBColor.init(nsColor:)).map { ColorItem(color: $0, name: key) }
            }
            guard !items.isEmpty else { throw Failure.noColors(file) }
            return [Palette(name: name, colors: items)]
        default:
            guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(file) }
            return try palettes(from: data, name: name, file: file)
        }
    }

    static func palettes(from data: Data, name: String, file: String) throws -> [Palette] {
        if data.starts(with: Array("ASEF".utf8)) {
            let palettes = try readASE(data, fallbackName: name)
            guard palettes.contains(where: { !$0.colors.isEmpty }) else { throw Failure.noColors(file) }
            return palettes
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw Failure.unreadable(file)
        }
        if text.hasPrefix("GIMP Palette") {
            return try [readGPL(text, fallbackName: name)].filter { !$0.colors.isEmpty }.nonEmpty(or: Failure.noColors(file))
        }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let palettes = readJSON(json, data: data, fallbackName: name), !palettes.isEmpty { return palettes }
        }
        // Anything else: every color code in the text (CSS, Swift, a list of hex codes…).
        let colors = ColorParser.extractAll(from: text)
        guard !colors.isEmpty else { throw Failure.noColors(file) }
        return [Palette(name: name, colors: colors.map { ColorItem(color: $0) })]
    }

    static func readASE(_ data: Data, fallbackName: String) throws -> [Palette] {
        var reader = BigEndianReader(data: data)
        guard reader.bytes(4) == Data("ASEF".utf8), let _ = reader.u16(), let _ = reader.u16(), let count = reader.u32() else {
            throw Failure.unreadable(fallbackName)
        }
        var palettes: [Palette] = []
        var loose = Palette(name: fallbackName)
        var current: Palette?
        for _ in 0..<count {
            guard let type = reader.u16(), let length = reader.u32(), let body = reader.bytes(Int(length)) else { break }
            var block = BigEndianReader(data: body)
            switch type {
            case 0xC001:
                current = Palette(name: block.utf16Name() ?? fallbackName)
            case 0xC002:
                if let group = current { palettes.append(group) }
                current = nil
            case 0x0001:
                let name = block.utf16Name()
                guard let model = block.bytes(4).map({ String(decoding: $0, as: UTF8.self) }) else { continue }
                var color: RGBColor?
                switch model {
                case "RGB ":
                    if let r = block.f32(), let g = block.f32(), let b = block.f32() { color = RGBColor(red: Double(r), green: Double(g), blue: Double(b)) }
                case "CMYK":
                    if let c = block.f32(), let m = block.f32(), let y = block.f32(), let k = block.f32() {
                        color = RGBColor(red: Double((1 - c) * (1 - k)), green: Double((1 - m) * (1 - k)), blue: Double((1 - y) * (1 - k)))
                    }
                case "Gray":
                    if let g = block.f32() { color = RGBColor(red: Double(g), green: Double(g), blue: Double(g)) }
                case "LAB ":
                    if let l = block.f32(), let a = block.f32(), let b = block.f32() { color = labToRGB(l: Double(l) * 100, a: Double(a), b: Double(b)) }
                default: break
                }
                guard let color else { continue }
                let item = ColorItem(color: color, name: name?.isEmpty == false ? name : nil)
                if current != nil { current!.colors.append(item) } else { loose.colors.append(item) }
            default:
                continue
            }
        }
        if let group = current { palettes.append(group) }
        if !loose.colors.isEmpty { palettes.insert(loose, at: 0) }
        return palettes
    }

    static func readGPL(_ text: String, fallbackName: String) -> Palette {
        var palette = Palette(name: fallbackName)
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Name:") {
                palette.name = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                continue
            }
            let parts = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3, let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]) else { continue }
            let name = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespaces) : nil
            palette.colors.append(ColorItem(color: RGBColor(r8: r, g8: g, b8: b), name: name == "Untitled" ? nil : name))
        }
        return palette
    }

    /// Chroma's own files, Sketch palettes (`.sketchpalette`), and JSON arrays or maps of color strings.
    private static func readJSON(_ json: Any, data: Data, fallbackName: String) -> [Palette]? {
        if let dictionary = json as? [String: Any], dictionary["palettes"] != nil {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(LibraryFile.self, from: data) {
                return file.palettes.map { var p = $0; p.id = UUID(); p.inDock = false; return p }
            }
        }
        if let dictionary = json as? [String: Any], let colors = dictionary["colors"] as? [[String: Any]] {
            let items = colors.compactMap { entry -> ColorItem? in
                if let r = entry["red"] as? Double, let g = entry["green"] as? Double, let b = entry["blue"] as? Double {
                    return ColorItem(color: RGBColor(red: r, green: g, blue: b, alpha: entry["alpha"] as? Double ?? 1), name: entry["name"] as? String)
                }
                if let value = (entry["hex"] ?? entry["value"] ?? entry["color"]) as? String, let color = ColorParser.parse(value) {
                    return ColorItem(color: color, name: entry["name"] as? String)
                }
                return nil
            }
            return [Palette(name: dictionary["name"] as? String ?? fallbackName, colors: items)]
        }
        if let map = json as? [String: String] {
            let items = map.sorted { $0.key < $1.key }.compactMap { key, value in ColorParser.parse(value).map { ColorItem(color: $0, name: key) } }
            return items.isEmpty ? nil : [Palette(name: fallbackName, colors: items)]
        }
        if let array = json as? [String] {
            let items = array.compactMap(ColorParser.parse).map { ColorItem(color: $0) }
            return items.isEmpty ? nil : [Palette(name: fallbackName, colors: items)]
        }
        return nil
    }

    /// CIE L*a*b* (D50, as ASE uses) to sRGB.
    static func labToRGB(l: Double, a: Double, b: Double) -> RGBColor {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func f(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16 / 116) / 7.787 }
        let x = 0.96422 * f(fx), y = 1.0 * f(fy), z = 0.82521 * f(fz)
        // Bradford D50 → D65, then XYZ → linear sRGB.
        let x65 = 0.9555766 * x - 0.0230393 * y + 0.0631636 * z
        let y65 = -0.0282895 * x + 1.0099416 * y + 0.0210077 * z
        let z65 = 0.0122982 * x - 0.0204830 * y + 1.3299098 * z
        return RGBColor(
            linearRed: 3.2404542 * x65 - 1.5371385 * y65 - 0.4985314 * z65,
            green: -0.9692660 * x65 + 1.8760108 * y65 + 0.0415560 * z65,
            blue: 0.0556434 * x65 - 0.2040259 * y65 + 1.0572252 * z65
        )
    }

    static var importableTypes: [UTType] {
        [.json, .plainText, .text, .xml, .adobeSwatchExchange, .appleColorList, .gimpPalette, UTType(filenameExtension: "css") ?? .text, UTType(filenameExtension: "sketchpalette") ?? .json]
    }
}

private extension Array {
    func nonEmpty(or error: Error) throws -> [Element] {
        if isEmpty { throw error }
        return self
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

struct BigEndianReader {
    let data: Data
    private var offset = 0

    init(data: Data) { self.data = Data(data) }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func u16() -> UInt16? { bytes(2).map { $0.reduce(0) { $0 << 8 | UInt16($1) } } }
    mutating func u32() -> UInt32? { bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } } }
    mutating func f32() -> Float32? { u32().map(Float32.init(bitPattern:)) }

    /// A UInt16 length (in UTF-16 units, including the terminator) followed by big-endian UTF-16.
    mutating func utf16Name() -> String? {
        guard let length = u16(), let raw = bytes(Int(length) * 2) else { return nil }
        var units: [UInt16] = []
        var reader = BigEndianReader(data: raw)
        while let unit = reader.u16() { units.append(unit) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}
