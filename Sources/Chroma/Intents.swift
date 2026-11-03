import AppIntents

/// Shortcuts and Spotlight actions.
struct PickColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Pick Color"
    static let description = IntentDescription("Shows Chroma's loupe and returns the color you click, in your chosen format.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let coordinator = AppCoordinator.shared, let color = await coordinator.pickColor() else {
            throw ChromaIntentError.cancelled
        }
        return .result(value: AppSettings.shared.string(color))
    }
}

struct LastColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Picked Color"
    static let description = IntentDescription("Returns the most recent color in Chroma's history.")

    @Parameter(title: "Format", default: .hex)
    var format: IntentFormat

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let color = LibraryStore.shared.latest else { throw ChromaIntentError.noHistory }
        return .result(value: AppSettings.shared.string(color, format: format.format))
    }
}

struct ConvertColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Color"
    static let description = IntentDescription("Converts a hex, rgb(), hsl() or oklch() color into another format.")

    @Parameter(title: "Color", description: "Like #3B82F6 or rgb(59, 130, 246)")
    var color: String

    @Parameter(title: "Format", default: .swiftUI)
    var format: IntentFormat

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let parsed = ColorParser.parse(color) else { throw ChromaIntentError.unreadable(color) }
        return .result(value: AppSettings.shared.string(parsed, format: format.format))
    }
}

struct AddColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Color to Palette"
    static let description = IntentDescription("Adds a color to a Chroma palette, creating the palette if needed.")

    @Parameter(title: "Color")
    var color: String

    @Parameter(title: "Palette")
    var palette: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let parsed = ColorParser.parse(color) else { throw ChromaIntentError.unreadable(color) }
        let library = LibraryStore.shared
        let id = library.palettes.first { $0.name.localizedCaseInsensitiveCompare(palette) == .orderedSame }?.id ?? library.createPalette(name: palette)
        library.add([parsed], to: .palette(id))
        return .result()
    }
}

enum IntentFormat: String, AppEnum {
    case hex, cssRGB, cssHSL, cssOKLCH, tailwind, swiftUI, uiColorRGB, nsColorRGB, compose, flutter, androidXML, name

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Color Format"
    static let caseDisplayRepresentations: [IntentFormat: DisplayRepresentation] = [
        .hex: "Hex", .cssRGB: "CSS rgb()", .cssHSL: "CSS hsl()", .cssOKLCH: "CSS oklch()", .tailwind: "Tailwind",
        .swiftUI: "SwiftUI", .uiColorRGB: "UIColor", .nsColorRGB: "NSColor", .compose: "Jetpack Compose",
        .flutter: "Flutter", .androidXML: "Android XML", .name: "Color name",
    ]

    var format: ColorFormat { ColorFormat.builtIn.first { $0.id == rawValue } ?? .fallback }
}

enum ChromaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case cancelled, noHistory, unreadable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .cancelled: "Picking was cancelled."
        case .noHistory: "Chroma hasn't picked any colors yet."
        case .unreadable(let text): "“\(text)” isn't a color Chroma understands."
        }
    }
}

struct ChromaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PickColorIntent(), phrases: ["Pick a color with \(.applicationName)"], shortTitle: "Pick Color", systemImageName: "eyedropper")
        AppShortcut(intent: LastColorIntent(), phrases: ["Get the last color from \(.applicationName)"], shortTitle: "Last Color", systemImageName: "clock")
        AppShortcut(intent: ConvertColorIntent(), phrases: ["Convert a color with \(.applicationName)"], shortTitle: "Convert Color", systemImageName: "arrow.left.arrow.right")
    }
}
