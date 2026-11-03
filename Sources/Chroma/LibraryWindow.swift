import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryModel: ObservableObject {
    @Published var source: ColorSource? = .history
    @Published var selection: Set<UUID> = []
    @Published var showInspector = true
    @Published var simulation: VisionSimulation = .normal
    @Published var renaming: UUID?
    @Published var alert: String?

    var library: LibraryStore { .shared }

    var selectedItems: [ColorItem] {
        guard let source else { return [] }
        return library.colors(in: source).filter { selection.contains($0.id) }
    }

    /// The color the inspector shows: the selection, or the first color.
    var focused: ColorItem? {
        guard let source else { return nil }
        let colors = library.colors(in: source)
        return colors.first { selection.contains($0.id) } ?? (selection.isEmpty ? nil : colors.first)
    }

    func select(_ color: RGBColor) {
        if let source, let item = library.colors(in: source).first(where: { $0.color == color.quantized }) {
            selection = [item.id]
            return
        }
        for candidate in [ColorSource.history] + library.palettes.map({ .palette($0.id) }) {
            if let item = library.colors(in: candidate).first(where: { $0.color == color.quantized }) {
                source = candidate
                selection = [item.id]
                return
            }
        }
        // Not in the library yet: put it at the top of History.
        library.recordPick(color)
        source = .history
        selection = Set(library.history.prefix(1).map(\.id))
    }
}

@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    let model = LibraryModel()

    func show(select color: RGBColor? = nil, source: ColorSource? = nil) {
        if window == nil {
            let hosting = NSHostingController(rootView: LibraryView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Chroma"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1040, height: 660))
            window.minSize = NSSize(width: 760, height: 460)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ChromaLibrary")
            window.delegate = self
            self.window = window
            if !window.setFrameUsingName("ChromaLibrary") { window.center() }
        }
        if let source { model.source = source; model.selection = [] }
        if let color { model.select(color) }
        if AppCoordinator.isHarness {
            window?.orderBack(nil)
        } else {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func newPalette() {
        AppCoordinator.shared?.showLibrary()
        let id = LibraryStore.shared.createPalette()
        model.source = .palette(id)
        model.renaming = id
    }

    func importPalettes() {
        AppCoordinator.shared?.showLibrary()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PaletteIO.importableTypes
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose palettes to import: .ase, .clr, .gpl, .json, .sketchpalette, or any text with color codes."
        guard let window, panel.runModal() == .OK else { return }
        _ = window
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        var imported: UUID?
        var failures: [String] = []
        for url in urls {
            do {
                for palette in try PaletteIO.palettes(from: url) {
                    imported = LibraryStore.shared.createPalette(name: LibraryStore.shared.uniqueName(palette.name), colors: palette.colors, note: palette.note)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if let imported { model.source = .palette(imported) }
        if !failures.isEmpty { model.alert = failures.joined(separator: "\n") }
    }

    func export(_ palette: Palette, as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = palette.name + "." + format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PaletteIO.data(for: palette, as: format).write(to: url, options: .atomic)
        } catch {
            model.alert = "Couldn't export “\(palette.name)”: \(error.localizedDescription)"
        }
    }
}

// MARK: - Root

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            if let source = model.source {
                PaletteDetail(model: model, source: source)
                    .id(source)
            } else {
                ContentUnavailableView("No Palette Selected", systemImage: "swatchpalette", description: Text("Choose History or a palette in the sidebar."))
            }
        }
        .inspector(isPresented: $model.showInspector) {
            Group {
                if let source = model.source, let item = model.focused {
                    ColorInspector(model: model, item: item, source: source)
                } else {
                    ContentUnavailableView("No Color Selected", systemImage: "eyedropper", description: Text("Select a color to see its values, edit it and check its contrast."))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 310, max: 400)
        }
        .onChange(of: model.source) { _, source in
            // Keep a selection made together with the source (Show in Library), drop the rest.
            let ids = Set(source.map { library.colors(in: $0).map(\.id) } ?? [])
            model.selection.formIntersection(ids)
        }
        .alert("Chroma", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .frame(minWidth: 760, minHeight: 460)
    }
}

// MARK: - Sidebar

struct LibrarySidebar: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var library = LibraryStore.shared
    @State private var confirmDelete: Palette?

    var body: some View {
        List(selection: $model.source) {
            Label {
                HStack {
                    Text("History")
                    Spacer()
                    Text("\(library.history.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .tag(ColorSource.history)
            .dropDestination(for: String.self) { strings, _ in
                defer { ColorDrag.reset() }
                return library.add(ColorDrag.colors(from: strings), to: .history) > 0
            }

            Section("Palettes") {
                ForEach(library.palettes) { palette in
                    PaletteRow(model: model, palette: palette, confirmDelete: $confirmDelete)
                        .tag(ColorSource.palette(palette.id))
                }
                .onMove { library.movePalettes(from: $0, to: $1) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 4) {
                Button {
                    AppCoordinator.shared?.libraryWindow.newPalette()
                } label: {
                    Label("New Palette", systemImage: "plus")
                }
                .help("New palette (⌘N)")
                Spacer()
                Menu {
                    Button("Import Palettes…") { AppCoordinator.shared?.libraryWindow.importPalettes() }
                    Button("New Palette from Clipboard") {
                        let colors = Clipboard.colors()
                        guard !colors.isEmpty else { model.alert = "The clipboard has no color codes in it."; return }
                        let id = library.createPalette(name: library.uniqueName("Pasted Colors"), colors: colors.map { ColorItem(color: $0) })
                        model.source = .palette(id)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import")
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Palette", role: .destructive) {
                if let palette = confirmDelete {
                    if model.source == .palette(palette.id) { model.source = .history }
                    library.deletePalette(palette.id)
                }
                confirmDelete = nil
            }
        } message: {
            Text("Its \(confirmDelete?.colors.count ?? 0) colors will be removed. This can't be undone.")
        }
    }
}

struct PaletteRow: View {
    @ObservedObject var model: LibraryModel
    let palette: Palette
    @Binding var confirmDelete: Palette?
    @ObservedObject private var library = LibraryStore.shared
    @State private var name = ""
    @FocusState private var editing: Bool
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            strip
            if model.renaming == palette.id {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .onAppear {
                        name = palette.name
                        DispatchQueue.main.async { editing = true }
                    }
                    .onSubmit(finishRename)
                    .onChange(of: editing) { _, isEditing in if !isEditing { finishRename() } }
            } else {
                Text(palette.name).lineLimit(1)
            }
            Spacer(minLength: 2)
            if library.activePaletteID == palette.id {
                Image(systemName: "eyedropper").font(.caption).foregroundStyle(.tint).help("New picks are added here")
            }
            if palette.inDock {
                Image(systemName: "dock.rectangle").font(.caption).foregroundStyle(.secondary).help("In the Color Dock")
            }
            if palette.isLocked {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Locked")
            }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).opacity(targeted ? 1 : 0))
        .dropDestination(for: String.self) { strings, _ in
            defer { ColorDrag.reset() }
            return library.add(ColorDrag.colors(from: strings), to: .palette(palette.id)) > 0
        } isTargeted: { targeted = $0 && !palette.isLocked }
        .contextMenu { PaletteMenu(model: model, palette: palette, confirmDelete: $confirmDelete) }
    }

    /// The palette's first colors as a little stack of stripes.
    private var strip: some View {
        HStack(spacing: 0) {
            let colors = Array(palette.colors.prefix(5))
            if colors.isEmpty {
                Rectangle().fill(.quaternary)
            } else {
                ForEach(colors) { Rectangle().fill($0.color.color) }
            }
        }
        .frame(width: 22, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.15)))
    }

    private func finishRename() {
        guard model.renaming == palette.id else { return }
        library.rename(palette.id, to: name)
        model.renaming = nil
    }
}

/// Everything you can do to a palette, shared by its context menu and the detail toolbar.
struct PaletteMenu: View {
    @ObservedObject var model: LibraryModel
    let palette: Palette
    @Binding var confirmDelete: Palette?
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        Button("Rename") { model.renaming = palette.id }
        Button(library.activePaletteID == palette.id ? "Stop Adding Picks Here" : "Add New Picks Here") {
            library.activePaletteID = library.activePaletteID == palette.id ? nil : palette.id
        }
        Button(palette.inDock ? "Remove from Color Dock" : "Show in Color Dock") {
            library.updatePalette(palette.id) { $0.inDock.toggle() }
            if !palette.inDock { AppSettings.shared.showDock = true }
        }
        Button(palette.isLocked ? "Unlock" : "Lock") { library.updatePalette(palette.id) { $0.isLocked.toggle() } }
        Divider()
        Button("Duplicate") {
            if let id = library.duplicate(palette.id) { model.source = .palette(id) }
        }
        Menu("Merge With") {
            ForEach(library.palettes.filter { $0.id != palette.id }) { other in
                Button(other.name) {
                    if let id = library.merge([palette.id, other.id]) { model.source = .palette(id) }
                }
            }
        }
        Menu("Export As") {
            ForEach(ExportFormat.allCases) { format in
                Button(format.title) { AppCoordinator.shared?.libraryWindow.export(palette, as: format) }
            }
        }
        Button("Copy as CSS Variables") { Clipboard.copy(PaletteIO.text(for: palette, as: .css)) }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = palette }
    }
}

// MARK: - Detail

struct PaletteDetail: View {
    @ObservedObject var model: LibraryModel
    let source: ColorSource
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var dropTarget: UUID?
    @State private var confirmDelete: Palette?
    @State private var addingColor = false
    @State private var newColor = RGBColor(red: 0.2, green: 0.5, blue: 0.95)

    private var items: [ColorItem] { library.colors(in: source) }
    private var palette: Palette? {
        if case .palette(let id) = source { return library.palette(id) }
        return nil
    }
    private var locked: Bool { library.isLocked(source) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if items.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            // Clicking empty space clears the selection.
            Color.clear.contentShape(Rectangle()).onTapGesture { model.selection = [] }
        }
        .dropDestination(for: String.self) { strings, _ in
            defer { ColorDrag.reset() }
            return library.add(ColorDrag.colors(from: strings), to: source) > 0
        }
        .onDeleteCommand {
            guard !locked else { return }
            library.remove(model.selection, from: source)
            model.selection = []
        }
        .onCopyCommand {
            let text = model.selectedItems.map { settings.string($0.color) }.joined(separator: "\n")
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
        .onPasteCommand(of: [.plainText, .utf8PlainText]) { _ in pasteColors() }
        .navigationTitle(library.title(of: source))
        .navigationSubtitle("\(items.count) color\(items.count == 1 ? "" : "s")")
        .toolbar { toolbar }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Palette", role: .destructive) {
                if let palette = confirmDelete {
                    model.source = .history
                    library.deletePalette(palette.id)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let palette {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Description", text: Binding(get: { palette.note }, set: { value in library.updatePalette(palette.id) { $0.note = value } }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(locked)
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { library.activePaletteID == palette.id }, set: { library.activePaletteID = $0 ? palette.id : nil })) {
                        Label("Add new picks", systemImage: "eyedropper")
                    }
                    Toggle(isOn: Binding(get: { palette.inDock }, set: { value in
                        library.updatePalette(palette.id) { $0.inDock = value }
                        if value { settings.showDock = true }
                    })) {
                        Label("In Color Dock", systemImage: "dock.rectangle")
                    }
                    Toggle(isOn: Binding(get: { palette.isLocked }, set: { value in library.updatePalette(palette.id) { $0.isLocked = value } })) {
                        Label(palette.isLocked ? "Locked" : "Lock", systemImage: palette.isLocked ? "lock.fill" : "lock.open")
                    }
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
        } else {
            Text("Every color you pick lands here, newest first. Drag colors onto a palette in the sidebar to keep them.")
                .foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "eyedropper.halffull").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(source == .history ? "No colors picked yet" : "This palette is empty").font(.headline)
            Text("Pick from the screen, add one with +, paste color codes, or drag colors here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Pick a Color") { pickIntoSource() }
                .disabled(locked)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 14)], alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                SwatchCell(item: item, selected: model.selection.contains(item.id), simulation: model.simulation, dropTarget: dropTarget == item.id)
                    .onTapGesture(count: 2) { AppCoordinator.shared?.copy(item.color) }
                    .onTapGesture { click(item) }
                    .onDrag {
                        let dragged = model.selection.contains(item.id) ? items.filter { model.selection.contains($0.id) } : [item]
                        return ColorDrag.provider(for: dragged, from: source)
                    }
                    .dropDestination(for: String.self) { strings, _ in
                        dropTarget = nil
                        return drop(strings, before: item)
                    } isTargeted: { dropTarget = $0 ? item.id : (dropTarget == item.id ? nil : dropTarget) }
                    .contextMenu {
                        ColorActions(item: item, source: source)
                    }
            }
        }
    }

    /// Reorders when the drag came from this palette, otherwise adds the colors before `item`.
    private func drop(_ strings: [String], before item: ColorItem) -> Bool {
        defer { ColorDrag.reset() }
        let colors = ColorDrag.colors(from: strings)
        guard let index = items.firstIndex(of: item) else { return false }
        if ColorDrag.source == source, ColorDrag.isOurs(strings) {
            library.move(ColorDrag.items.map(\.id), in: source, to: index)
            return true
        }
        return library.add(colors, to: source, at: index) > 0
    }

    /// ⌘-click toggles, ⇧-click extends, a plain click selects just this color.
    private func click(_ item: ColorItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
        } else if flags.contains(.shift) {
            extendSelection(to: item)
        } else {
            model.selection = [item.id]
        }
    }

    private func extendSelection(to item: ColorItem) {
        guard let anchor = items.firstIndex(where: { model.selection.contains($0.id) }), let end = items.firstIndex(of: item) else {
            model.selection = [item.id]
            return
        }
        model.selection = Set(items[min(anchor, end)...max(anchor, end)].map(\.id))
    }

    private func pasteColors() {
        let colors = Clipboard.colors()
        guard !colors.isEmpty else { return }
        library.add(colors, to: source)
    }

    private func pickIntoSource() {
        let source = source
        AppCoordinator.shared?.pick(.deliver { color in
            guard let color else { return }
            LibraryStore.shared.recordPick(color)
            LibraryStore.shared.add([color], to: source)
            AppCoordinator.shared?.libraryWindow.show(select: color)
        })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                pickIntoSource()
            } label: {
                Label("Pick", systemImage: "eyedropper")
            }
            .help("Pick a color from the screen into \(library.title(of: source))")
            .disabled(locked)

            Button {
                newColor = model.focused?.color ?? library.latest ?? newColor
                addingColor = true
            } label: {
                Label("Add Color", systemImage: "plus")
            }
            .help("Add a color")
            .disabled(locked)
            .popover(isPresented: $addingColor) {
                VStack(spacing: 12) {
                    ColorEditor(color: $newColor)
                    HStack {
                        Button("Cancel") { addingColor = false }
                        Spacer()
                        Button("Add") {
                            library.add([newColor], to: source)
                            model.select(newColor)
                            addingColor = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(width: 280)
            }
        }
        ToolbarItemGroup {
            Menu {
                ForEach(PaletteSort.allCases) { order in
                    Button(order.title) { library.sort(source, by: order) }
                }
                Divider()
                Button("Remove Duplicates") { library.removeDuplicates(in: source) }
                if source == .history {
                    Divider()
                    Button("Clear History", role: .destructive) { library.clearHistory() }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort")
            .disabled(locked)

            Menu {
                Picker("Simulate", selection: $model.simulation) {
                    ForEach(VisionSimulation.allCases) { sim in
                        Text("\(sim.title) (\(sim.detail))").tag(sim)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Color Vision", systemImage: model.simulation == .normal ? "eye" : "eye.trianglebadge.exclamationmark")
            }
            .help("Simulate color blindness")

            if let palette {
                Menu {
                    PaletteMenu(model: model, palette: palette, confirmDelete: $confirmDelete)
                } label: {
                    Label("Palette", systemImage: "ellipsis.circle")
                }
                .help("Palette actions")
            } else {
                Menu {
                    Button("Save History as Palette") {
                        let id = library.createPalette(name: library.uniqueName("Saved Colors"), colors: library.history)
                        model.source = .palette(id)
                    }
                    Menu("Export As") {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.title) { AppCoordinator.shared?.libraryWindow.export(Palette(name: "History", colors: library.history), as: format) }
                        }
                    }
                } label: {
                    Label("History", systemImage: "ellipsis.circle")
                }
            }

            Button {
                model.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }
}

struct SwatchCell: View {
    let item: ColorItem
    let selected: Bool
    let simulation: VisionSimulation
    let dropTarget: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Swatch(color: item.color, cornerRadius: 12, simulation: simulation)
                .aspectRatio(1.25, contentMode: .fit)
                .overlay(alignment: .leading) {
                    if dropTarget {
                        Capsule().fill(Color.accentColor).frame(width: 4).offset(x: -9)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .padding(-4)
                        .opacity(selected ? 1 : 0)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(settings.string(item.color, format: settings.format(id: "hex")))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .help(item.note ?? item.displayName)
    }
}

// MARK: - Inspector

struct ColorInspector: View {
    @ObservedObject var model: LibraryModel
    let item: ColorItem
    let source: ColorSource
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared

    private var locked: Bool { library.isLocked(source) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                section("Edit") {
                    ColorEditor(color: Binding(get: { item.color }, set: { value in
                        var updated = item
                        updated.color = value
                        library.update(updated, in: source)
                    }))
                    .disabled(locked)
                }
                section("Formats") {
                    VStack(spacing: 4) {
                        ForEach(settings.shownFormats) { format in
                            FormatRow(color: item.color, format: format)
                            if format.id != settings.shownFormats.last?.id { Divider() }
                        }
                    }
                }
                section("Contrast") { contrast }
                section("Tints and Shades") { scale }
                section("Harmonies") { harmonies }
                section("Color Vision") { vision }
            }
            .padding(16)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Swatch(color: item.color, cornerRadius: 14, simulation: model.simulation)
                .frame(height: 110)
                .overlay(alignment: .bottomLeading) {
                    Text(item.color.hexString)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.color.over(.white).readableInk.color)
                        .padding(12)
                }
                .onDrag { ColorDrag.provider(for: [item], from: source) }
            TextField(ColorNames.shared.name(for: item.color), text: Binding(get: { item.name ?? "" }, set: { value in
                var updated = item
                updated.name = value.isEmpty ? nil : value
                library.update(updated, in: source)
            }))
            .textFieldStyle(.plain)
            .font(.title3.weight(.semibold))
            .disabled(locked)
            TextField("Notes", text: Binding(get: { item.note ?? "" }, set: { value in
                var updated = item
                updated.note = value.isEmpty ? nil : value
                library.update(updated, in: source)
            }), axis: .vertical)
            .textFieldStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(locked)
            HStack {
                Button("Copy \(settings.copyFormat.name)") { AppCoordinator.shared?.copy(item.color) }
                Spacer()
                Text("Tailwind \(ColorNames.shared.tailwindName(for: item.color).name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private var contrast: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([("On white", RGBColor.white), ("On black", RGBColor.black)], id: \.0) { label, background in
                let ratio = item.color.over(background).contrastRatio(with: background)
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(background.color)
                        Text("Aa").font(.system(size: 14, weight: .bold)).foregroundStyle(item.color.color)
                    }
                    .frame(width: 40, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f:1", ratio)).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    ContrastBadge(label: "AA", passes: ratio >= 4.5)
                    ContrastBadge(label: "AAA", passes: ratio >= 7)
                }
            }
            Button("Open Contrast Checker") { AppCoordinator.shared?.showContrast(text: item.color, background: .white) }
                .controlSize(.small)
        }
    }

    private var scale: some View {
        VStack(alignment: .leading, spacing: 6) {
            let steps = ColorScale.scale(for: item.color)
            HStack(spacing: 3) {
                ForEach(steps, id: \.label) { step in
                    Swatch(color: step.color, cornerRadius: 4, simulation: model.simulation, outline: false)
                        .frame(height: 30)
                        .help("\(step.label)  \(step.color.hexString)")
                        .onTapGesture { AppCoordinator.shared?.copy(step.color) }
                        .onDrag { ColorDrag.provider(for: [ColorItem(color: step.color)], from: nil) }
                }
            }
            Button("New Palette from Scale") {
                let base = item.displayName
                let id = library.createPalette(name: library.uniqueName(base + " Scale"), colors: steps.map { ColorItem(color: $0.color, name: "\(base) \($0.label)") })
                model.source = .palette(id)
            }
            .controlSize(.small)
        }
    }

    private var harmonies: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Harmony.allCases) { harmony in
                HStack(spacing: 6) {
                    Text(harmony.title).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    ForEach(Array(harmony.colors(for: item.color).enumerated()), id: \.offset) { _, color in
                        Swatch(color: color, cornerRadius: 5, simulation: model.simulation)
                            .frame(width: 26, height: 26)
                            .help(color.hexString)
                            .onTapGesture { AppCoordinator.shared?.copy(color) }
                            .onDrag { ColorDrag.provider(for: [ColorItem(color: color)], from: nil) }
                    }
                    Spacer(minLength: 0)
                    Button {
                        library.add(harmony.colors(for: item.color), to: source)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(locked)
                    .help("Add these to \(library.title(of: source))")
                }
            }
        }
    }

    private var vision: some View {
        HStack(spacing: 6) {
            ForEach(VisionSimulation.allCases) { sim in
                VStack(spacing: 3) {
                    Swatch(color: item.color, cornerRadius: 5, simulation: sim)
                        .frame(height: 26)
                    Text(sim == .normal ? "Normal" : String(sim.title.prefix(5)) + ".")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(sim.title)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}

struct ContrastBadge: View {
    let label: String
    let passes: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: passes ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold))
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(passes ? Color.green : Color.red)
        .background((passes ? Color.green : Color.red).opacity(0.14), in: Capsule())
        .accessibilityLabel("\(label) \(passes ? "passes" : "fails")")
    }
}
