import AppKit
import Combine

struct ColorItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var color: RGBColor
    /// A name the user typed; otherwise the nearest named color is shown.
    var name: String?
    var note: String?
    var added = Date()

    init(color: RGBColor, name: String? = nil, note: String? = nil) {
        self.color = color.quantized
        self.name = name
        self.note = note
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return ColorNames.shared.name(for: color)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        color = try c.decode(RGBColor.self, forKey: .color)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
    }
}

struct Palette: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var note: String = ""
    var colors: [ColorItem] = []
    var isLocked = false
    var inDock = false

    init(name: String, colors: [ColorItem] = [], note: String = "") {
        self.name = name
        self.colors = colors
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Palette"
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        colors = try c.decodeIfPresent([ColorItem].self, forKey: .colors) ?? []
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        inDock = try c.decodeIfPresent(Bool.self, forKey: .inDock) ?? false
    }
}

/// What's on disk: `Library.json` in the library folder.
struct LibraryFile: Codable {
    var app = "Chroma"
    var version = 1
    var history: [ColorItem] = []
    var palettes: [Palette] = []

    init(history: [ColorItem] = [], palettes: [Palette] = []) {
        self.history = history
        self.palettes = palettes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        history = try c.decodeIfPresent([ColorItem].self, forKey: .history) ?? []
        palettes = try c.decodeIfPresent([Palette].self, forKey: .palettes) ?? []
    }
}

/// History or one palette: the two places colors live.
enum ColorSource: Hashable {
    case history
    case palette(UUID)
}

enum PaletteSort: String, CaseIterable, Identifiable {
    case hue, lightness, saturation, name, added
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hue: "Hue"
        case .lightness: "Lightness"
        case .saturation: "Saturation"
        case .name: "Name"
        case .added: "Date Added"
        }
    }
}

/// Colors and palettes, saved as JSON. Everything the UI shows comes from here.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var history: [ColorItem] = []
    @Published private(set) var palettes: [Palette] = []
    /// New picks also go into this palette.
    @Published var activePaletteID: UUID? {
        didSet { defaults.set(activePaletteID?.uuidString, forKey: "activePaletteID") }
    }
    /// The color the menu, the inspector and the contrast checker start from.
    var latest: RGBColor? { history.first?.color }

    private var defaults: UserDefaults { AppSettings.shared.defaults }
    private var saveWork: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var lastWrite: Date?
    private var activeObserver: NSObjectProtocol?
    private(set) var fileURL: URL

    private init() {
        fileURL = Self.fileURL(in: AppSettings.shared.libraryFolder)
        activePaletteID = AppSettings.shared.defaults.string(forKey: "activePaletteID").flatMap(UUID.init)
        load()
        if palettes.isEmpty && history.isEmpty && !FileManager.default.fileExists(atPath: fileURL.path) {
            palettes = Self.starterPalettes()
            save(immediately: true)
        }
        watch()
    }

    static func fileURL(in folder: URL) -> URL { folder.appendingPathComponent("Library.json") }

    // MARK: Reading

    func colors(in source: ColorSource) -> [ColorItem] {
        switch source {
        case .history: history
        case .palette(let id): palettes.first { $0.id == id }?.colors ?? []
        }
    }

    func palette(_ id: UUID) -> Palette? { palettes.first { $0.id == id } }

    var activePalette: Palette? { activePaletteID.flatMap(palette) }

    func isLocked(_ source: ColorSource) -> Bool {
        if case .palette(let id) = source { return palette(id)?.isLocked ?? false }
        return false
    }

    func title(of source: ColorSource) -> String {
        switch source {
        case .history: "History"
        case .palette(let id): palette(id)?.name ?? "Palette"
        }
    }

    // MARK: Picking

    /// Records a picked color: first in History, and in the active palette if there is one.
    func recordPick(_ color: RGBColor) {
        let item = ColorItem(color: color)
        history.removeAll { $0.color == item.color }
        history.insert(item, at: 0)
        let limit = AppSettings.shared.historyLimit
        if history.count > limit { history.removeLast(history.count - limit) }
        if let id = activePaletteID, let index = palettes.firstIndex(where: { $0.id == id }), !palettes[index].isLocked,
           !palettes[index].colors.contains(where: { $0.color == item.color }) {
            palettes[index].colors.append(ColorItem(color: color))
        }
        save()
    }

    // MARK: Editing colors

    /// Adds colors to a palette (or History), skipping ones it already has. Returns how many were added.
    @discardableResult
    func add(_ items: [ColorItem], to source: ColorSource, at position: Int? = nil) -> Int {
        guard !isLocked(source) else { return 0 }
        var existing = Set(colors(in: source).map(\.color))
        let fresh = items.compactMap { item -> ColorItem? in
            guard existing.insert(item.color).inserted else { return nil }
            var copy = item
            copy.id = UUID()
            return copy
        }
        guard !fresh.isEmpty else { return 0 }
        mutate(source) { colors in
            let index = min(position ?? colors.count, colors.count)
            colors.insert(contentsOf: fresh, at: index)
        }
        return fresh.count
    }

    @discardableResult
    func add(_ colors: [RGBColor], to source: ColorSource) -> Int {
        add(colors.map { ColorItem(color: $0) }, to: source)
    }

    func remove(_ ids: Set<UUID>, from source: ColorSource) {
        guard !isLocked(source) else { return }
        mutate(source) { $0.removeAll { ids.contains($0.id) } }
    }

    func update(_ item: ColorItem, in source: ColorSource) {
        guard !isLocked(source) else { return }
        mutate(source) { colors in
            guard let index = colors.firstIndex(where: { $0.id == item.id }) else { return }
            var updated = item
            updated.color = item.color.quantized
            colors[index] = updated
        }
    }

    /// Moves colors (keeping their order) to sit before the color at `index`.
    func move(_ ids: [UUID], in source: ColorSource, to index: Int) {
        guard !isLocked(source) else { return }
        mutate(source) { colors in
            let moving = colors.filter { ids.contains($0.id) }
            let before = colors[..<min(index, colors.count)].filter { ids.contains($0.id) }.count
            colors.removeAll { ids.contains($0.id) }
            colors.insert(contentsOf: moving, at: max(0, min(index - before, colors.count)))
        }
    }

    func sort(_ source: ColorSource, by order: PaletteSort) {
        guard !isLocked(source) else { return }
        mutate(source) { colors in
            switch order {
            case .hue:
                // Grays last, then by hue.
                colors.sort { a, b in
                    let la = a.color.oklch, lb = b.color.oklch
                    let ga = la.c < 0.02, gb = lb.c < 0.02
                    if ga != gb { return !ga }
                    return ga ? la.l > lb.l : la.h < lb.h
                }
            case .lightness: colors.sort { $0.color.oklch.l > $1.color.oklch.l }
            case .saturation: colors.sort { $0.color.oklch.c > $1.color.oklch.c }
            case .name: colors.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            case .added: colors.sort { $0.added > $1.added }
            }
        }
    }

    func removeDuplicates(in source: ColorSource) {
        guard !isLocked(source) else { return }
        mutate(source) { colors in
            var seen = Set<RGBColor>()
            colors = colors.filter { seen.insert($0.color).inserted }
        }
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    private func mutate(_ source: ColorSource, _ change: (inout [ColorItem]) -> Void) {
        switch source {
        case .history:
            change(&history)
        case .palette(let id):
            guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
            change(&palettes[index].colors)
        }
        save()
    }

    // MARK: Palettes

    @discardableResult
    func createPalette(name: String? = nil, colors: [ColorItem] = [], note: String = "") -> UUID {
        let palette = Palette(name: name ?? uniqueName("New Palette"), colors: colors, note: note)
        palettes.append(palette)
        save()
        return palette.id
    }

    func updatePalette(_ id: UUID, _ change: (inout Palette) -> Void) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        change(&palettes[index])
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updatePalette(id) { $0.name = trimmed }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = palettes[index]
        copy.id = UUID()
        copy.name = uniqueName(copy.name + " Copy")
        copy.isLocked = false
        copy.colors = copy.colors.map { var c = $0; c.id = UUID(); return c }
        palettes.insert(copy, at: index + 1)
        save()
        return copy.id
    }

    func deletePalette(_ id: UUID) {
        palettes.removeAll { $0.id == id }
        if activePaletteID == id { activePaletteID = nil }
        save()
    }

    func movePalettes(from offsets: IndexSet, to destination: Int) {
        palettes.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    /// Combines palettes into a new one, without duplicate colors.
    @discardableResult
    func merge(_ ids: [UUID]) -> UUID? {
        let chosen = palettes.filter { ids.contains($0.id) }
        guard chosen.count > 1 else { return nil }
        var seen = Set<RGBColor>()
        let colors = chosen.flatMap(\.colors).filter { seen.insert($0.color).inserted }.map { var c = $0; c.id = UUID(); return c }
        return createPalette(name: uniqueName(chosen.map(\.name).joined(separator: " + ")), colors: colors)
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(palettes.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    var dockPalettes: [Palette] { palettes.filter(\.inDock) }

    // MARK: Disk

    func save(immediately: Bool = false) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write() }
        saveWork = work
        if immediately {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func write() {
        saveWork = nil
        let file = LibraryFile(history: history, palettes: palettes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: fileURL, options: .atomic)
            lastWrite = modificationDate()
        } catch {
            NSLog("Chroma: couldn't save the library: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(LibraryFile.self, from: data)
            history = file.history
            palettes = file.palettes
            lastWrite = modificationDate()
        } catch {
            // Keep a copy of a file we can't read rather than overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            NSLog("Chroma: couldn't read the library (\(error)); kept a copy at \(backup.path)")
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// Reloads when another Mac (through iCloud Drive, Dropbox…) or another tool changes the file.
    private func watch() {
        watcher?.cancel()
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        // The folder watcher misses in-place edits to the file; check again whenever Chroma comes forward.
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadIfChanged() }
            }
        }
    }

    private func reloadIfChanged() {
        guard let date = modificationDate(), date != lastWrite else { return }
        if saveWork != nil {
            // A pending save of local edits wins; it'll overwrite the file in a moment anyway.
            NSLog("Chroma: Library.json changed elsewhere while local edits were pending; keeping the local edits")
            return
        }
        load()
    }

    /// Points the library at a new folder. Uses the library already there, or writes this one into it.
    func moveLibrary(to folder: URL) {
        // Flush pending edits to the old file, and make sure the queued save doesn't run again later.
        if let work = saveWork {
            work.cancel()
            write()
        }
        let target = Self.fileURL(in: folder)
        fileURL = target
        if FileManager.default.fileExists(atPath: target.path) {
            load()
        } else {
            save(immediately: true)
        }
        watch()
    }

    /// Replaces everything (used by the debug harness for screenshots).
    func replaceAll(history: [ColorItem], palettes: [Palette]) {
        self.history = history
        self.palettes = palettes
    }

    // MARK: Starter content

    private static func starterPalettes() -> [Palette] {
        func palette(_ name: String, _ hexes: [String], note: String, dock: Bool = false) -> Palette {
            var p = Palette(name: name, colors: hexes.compactMap { RGBColor(hex: $0) }.map { ColorItem(color: $0) }, note: note)
            p.inDock = dock
            return p
        }
        return [
            palette("Apple System", ["FF3B30", "FF9500", "FFCC00", "34C759", "00C7BE", "30B0C7", "32ADE6", "007AFF", "5856D6", "AF52DE", "FF2D55", "A2845E", "8E8E93"],
                    note: "The light-mode system colors from Apple's Human Interface Guidelines.", dock: true),
            palette("Sunset", ["2B2D42", "5C3C66", "A44A6F", "E26D5C", "F6AE6B", "FAD6A5"], note: "A warm example palette. Rename it, edit it or delete it."),
        ]
    }
}
