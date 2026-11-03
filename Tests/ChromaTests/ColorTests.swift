import XCTest
@testable import Chroma

// ApplicationServices has an old QuickDraw type with the same name.
private typealias RGBColor = Chroma.RGBColor

final class ColorTests: XCTestCase {
    func testHexParsing() {
        XCTAssertEqual(RGBColor(hex: "#3B82F6")?.hex6, "3B82F6")
        XCTAssertEqual(RGBColor(hex: "3b82f6")?.hex6, "3B82F6")
        XCTAssertEqual(RGBColor(hex: "#fff")?.hex6, "FFFFFF")
        XCTAssertEqual(RGBColor(hex: "#3B82F680")?.a8, 0x80)
        XCTAssertEqual(RGBColor(hex: "#3B82F680")?.hexString, "#3B82F680")
        XCTAssertNil(RGBColor(hex: "#12345"))
        XCTAssertNil(RGBColor(hex: "nothex"))
        // Fullwidth digits pass isHexDigit but aren't parseable; this used to crash.
        XCTAssertNil(RGBColor(hex: "ＦＦＦ"))
        XCTAssertNil(ColorParser.parse("#１２３４５６"))
    }

    func testHSBAndHSLRoundTrip() {
        let color = RGBColor(hex: "3B82F6")!
        let hsb = color.hsb
        XCTAssertEqual(RGBColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness).hex6, "3B82F6")
        let hsl = color.hsl
        XCTAssertEqual(hsl.hue, 217.2, accuracy: 0.1)
        XCTAssertEqual(RGBColor(hue: hsl.hue, saturation: hsl.saturation, lightness: hsl.lightness).hex6, "3B82F6")
    }

    func testOKLCH() {
        let red = RGBColor(hex: "FF0000")!.oklch
        XCTAssertEqual(red.l, 0.628, accuracy: 0.001)
        XCTAssertEqual(red.c, 0.2577, accuracy: 0.001)
        XCTAssertEqual(red.h, 29.23, accuracy: 0.05)
        let back = RGBColor(oklchL: red.l, c: red.c, h: red.h)
        XCTAssertEqual(back.hex6, "FF0000")
        // Out-of-gamut chroma is reduced instead of clipping the hue.
        let vivid = RGBColor(oklchL: 0.7, c: 0.4, h: 150)
        XCTAssertEqual(vivid.oklch.h, 150, accuracy: 1.5)
    }

    func testContrast() {
        XCTAssertEqual(RGBColor.black.contrastRatio(with: .white), 21, accuracy: 0.001)
        XCTAssertEqual(RGBColor(hex: "777777")!.contrastRatio(with: .white), 4.48, accuracy: 0.01)
        XCTAssertEqual(RGBColor.black.apcaContrast(on: .white), 106.04, accuracy: 0.05)
        XCTAssertEqual(RGBColor.white.apcaContrast(on: .black), -107.88, accuracy: 0.05)
        XCTAssertEqual(RGBColor(hex: "888888")!.apcaContrast(on: RGBColor(hex: "888888")!), 0)
    }

    func testContrastFixerReachesTarget() {
        let background = RGBColor(hex: "FFFFFF")!
        let text = RGBColor(hex: "8AB4F8")!
        let fixed = ContrastFixer.fix(text: text, background: background, target: 4.5)
        XCTAssertNotNil(fixed)
        XCTAssertGreaterThanOrEqual(fixed!.contrastRatio(with: background), 4.5)
        // It keeps the hue.
        XCTAssertEqual(fixed!.oklch.h, text.oklch.h, accuracy: 4)
        // Already passing colors come back unchanged.
        XCTAssertEqual(ContrastFixer.fix(text: .black, background: background, target: 7), .black)
    }

    func testAlphaCompositing() {
        let half = RGBColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        XCTAssertEqual(half.over(.white).r8, 128)
    }

    func testVisionSimulation() {
        let gray = VisionSimulation.achromatopsia.apply(RGBColor(hex: "FF0000")!)
        XCTAssertEqual(gray.r8, gray.g8)
        XCTAssertEqual(gray.g8, gray.b8)
        XCTAssertEqual(VisionSimulation.normal.apply(RGBColor(hex: "123456")!).hex6, "123456")
        // Red and green get hard to tell apart without red cones.
        let red = VisionSimulation.protanopia.apply(RGBColor(hex: "E53935")!)
        let green = VisionSimulation.protanopia.apply(RGBColor(hex: "7CB342")!)
        XCTAssertLessThan(red.distance(to: green), RGBColor(hex: "E53935")!.distance(to: RGBColor(hex: "7CB342")!))
    }

    func testScaleAndHarmonies() {
        let base = RGBColor(hex: "3B82F6")!
        let scale = ColorScale.scale(for: base)
        XCTAssertEqual(scale.count, 11)
        XCTAssertGreaterThan(scale.first!.color.oklch.l, scale.last!.color.oklch.l)
        let complement = Harmony.complementary.colors(for: base)
        XCTAssertEqual(complement.count, 2)
        XCTAssertEqual(complement[0], base)
        let hueDifference = abs(complement[1].oklch.h - base.oklch.h)
        XCTAssertEqual(min(hueDifference, 360 - hueDifference), 180, accuracy: 6)
    }

    func testNames() {
        XCTAssertEqual(ColorNames.shared.name(for: .black), "Black")
        XCTAssertEqual(ColorNames.shared.tailwindName(for: RGBColor(hex: "FB2C36")!).name, "red-500")
        XCTAssertTrue(ColorNames.shared.tailwindName(for: RGBColor(hex: "FB2C36")!).exact)
        XCTAssertEqual("Royal Blue".snakeCased, "royal_blue")
        XCTAssertEqual("Royal Blue".camelCased, "royalBlue")
        XCTAssertEqual("Royal Blue".kebabCased, "royal-blue")
    }
}

final class FormatTests: XCTestCase {
    private let blue = RGBColor(hex: "3B82F6")!
    private func render(_ id: String, _ color: RGBColor? = nil, uppercase: Bool = true) -> String {
        ColorFormat.builtIn.first { $0.id == id }!.string(for: color ?? blue, uppercaseHex: uppercase)
    }

    func testBuiltInFormats() {
        XCTAssertEqual(render("hex"), "#3B82F6")
        XCTAssertEqual(render("hex", uppercase: false), "#3b82f6")
        XCTAssertEqual(render("cssRGB"), "rgb(59, 130, 246)")
        XCTAssertEqual(render("cssRGB", blue.withAlpha(0.5)), "rgba(59, 130, 246, 0.5)")
        XCTAssertEqual(render("cssRGBModern"), "rgb(59 130 246)")
        XCTAssertEqual(render("cssHSL"), "hsl(217, 91%, 60%)")
        XCTAssertEqual(render("swiftUI"), "Color(red: 0.231, green: 0.510, blue: 0.965)")
        XCTAssertEqual(render("swiftUI", blue.withAlpha(0.5)), "Color(red: 0.231, green: 0.510, blue: 0.965, opacity: 0.5)")
        XCTAssertEqual(render("androidARGB"), "#FF3B82F6")
        XCTAssertEqual(render("compose"), "Color(0xFF3B82F6)")
        XCTAssertEqual(render("dotNet"), "Color.FromArgb(255, 59, 130, 246)")
        XCTAssertEqual(render("tailwindArbitrary"), "[#3B82F6]")
        XCTAssertTrue(render("cssOKLCH").hasPrefix("oklch(62.3% 0.188 259."))
        XCTAssertEqual(render("cmyk"), "cmyk(76%, 47%, 0%, 4%)")
    }

    func testEveryFormatFillsItsTokens() {
        for format in ColorFormat.builtIn {
            let output = format.string(for: blue.withAlpha(0.4))
            XCTAssertFalse(output.contains("{"), "\(format.id) left a token: \(output)")
        }
    }

    func testCustomTemplate() {
        XCTAssertEqual(FormatTemplate.render("{r}/{g}/{b} {unknown}", color: blue), "59/130/246 {unknown}")
        XCTAssertEqual(FormatTemplate.render("{!alpha}solid{/alpha}{?alpha}see-through{/alpha}", color: blue), "solid")
        XCTAssertEqual(FormatTemplate.render("{!alpha}solid{/alpha}{?alpha}see-through{/alpha}", color: blue.withAlpha(0.2)), "see-through")
    }

    func testParser() {
        XCTAssertEqual(ColorParser.parse("rgb(59, 130, 246)")?.hex6, "3B82F6")
        XCTAssertEqual(ColorParser.parse("rgb(59 130 246 / 50%)")?.a8, 128)
        XCTAssertEqual(ColorParser.parse("hsl(217, 91%, 60%)")?.hex6, "3C83F6")
        XCTAssertEqual(ColorParser.parse("0x803B82F6")?.a8, 0x80)
        XCTAssertEqual(ColorParser.parse("0x803B82F6")?.hex6, "3B82F6")
        XCTAssertEqual(ColorParser.parse("59, 130, 246")?.hex6, "3B82F6")
        XCTAssertEqual(ColorParser.parse("  #3b82f6; ")?.hex6, "3B82F6")
        XCTAssertNil(ColorParser.parse("hello"))
        let found = ColorParser.extractAll(from: ":root { --a: #ff0000; --b: rgb(0, 255, 0); --c: #FF0000; }")
        XCTAssertEqual(found.map(\.hex6), ["FF0000", "00FF00"])
    }
}

final class PaletteIOTests: XCTestCase {
    private let palette = Palette(name: "Test", colors: [
        ColorItem(color: RGBColor(hex: "FF4D6D")!, name: "Rose"),
        ColorItem(color: RGBColor(hex: "2BD9A8")!),
        ColorItem(color: RGBColor(hex: "4C6FFF")!),
    ])

    func testASERoundTrip() throws {
        let data = PaletteIO.ase(palette)
        XCTAssertTrue(data.starts(with: Array("ASEF".utf8)))
        let read = try PaletteIO.palettes(from: data, name: "x", file: "x.ase")
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].name, "Test")
        XCTAssertEqual(read[0].colors.map(\.color.hex6), ["FF4D6D", "2BD9A8", "4C6FFF"])
        XCTAssertEqual(read[0].colors[0].name, "Rose")
    }

    func testGPLRoundTrip() throws {
        let text = PaletteIO.text(for: palette, as: .gpl)
        let read = try PaletteIO.palettes(from: Data(text.utf8), name: "x", file: "x.gpl")
        XCTAssertEqual(read.first?.name, "Test")
        XCTAssertEqual(read.first?.colors.map(\.color.hex6), ["FF4D6D", "2BD9A8", "4C6FFF"])
    }

    func testChromaJSONRoundTrip() throws {
        let text = PaletteIO.text(for: palette, as: .chroma)
        let read = try PaletteIO.palettes(from: Data(text.utf8), name: "x", file: "x.json")
        XCTAssertEqual(read.first?.colors.map(\.color.hex6), ["FF4D6D", "2BD9A8", "4C6FFF"])
        XCTAssertNotEqual(read.first?.id, palette.id)
    }

    func testSketchPalette() throws {
        let json = #"{"compatibleVersion":"2.0","colors":[{"red":1,"green":0,"blue":0,"alpha":1},{"red":0,"green":0,"blue":1,"alpha":0.5}]}"#
        let read = try PaletteIO.palettes(from: Data(json.utf8), name: "Sketchy", file: "x.sketchpalette")
        XCTAssertEqual(read.first?.colors.map(\.color.hexString), ["#FF0000", "#0000FF80"])
    }

    func testTextFallbackAndCSSExport() throws {
        let read = try PaletteIO.palettes(from: Data("a #123456 and rgb(1,2,3)".utf8), name: "Notes", file: "notes.txt")
        XCTAssertEqual(read.first?.colors.count, 2)
        let css = PaletteIO.text(for: palette, as: .css)
        XCTAssertTrue(css.contains("--test-rose: #ff4d6d;"))
        XCTAssertThrowsError(try PaletteIO.palettes(from: Data("no colors".utf8), name: "x", file: "x.txt"))
    }

    func testCLRExport() throws {
        let data = try PaletteIO.clr(palette)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chroma-test.clr")
        try data.write(to: url)
        let read = try PaletteIO.palettes(from: url)
        XCTAssertEqual(Set(read.first?.colors.map(\.color.hex6) ?? []), ["FF4D6D", "2BD9A8", "4C6FFF"])
    }
}
