import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// A standard Settings window: toolbar tabs, each a grouped form.
@MainActor
final class SettingsWindowController {
    private(set) var window: NSWindow?
    private var tabs: NSTabViewController?

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = [.crossfade, .allowUserInteraction]
            for tab in SettingsTab.allCases {
                let hosting = NSHostingController(rootView: SettingsPane(tab: tab))
                hosting.sizingOptions = [.preferredContentSize]
                hosting.title = tab.title // shown as the window title
                let item = NSTabViewItem(viewController: hosting)
                item.label = tab.title
                item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            self.tabs = tabs
            self.window = window
        }
        AppState.shared.refreshPermission()
        tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: AppState.shared.settingsTab) ?? 0
        window?.center()
        if AppCoordinator.isHarness {
            window?.orderBack(nil) // screenshots without stealing focus
        } else {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, picker, formats, shortcuts, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .picker: "Picker"
        case .formats: "Formats"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .picker: "eyedropper"
        case .formats: "curlybraces"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }
}

struct SettingsPane: View {
    let tab: SettingsTab
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        if tab == .formats {
            FormatsPane()
                .frame(width: 560, height: 620)
        } else {
            Form {
                switch tab {
                case .general: general
                case .picker: picker
                case .shortcuts: shortcuts
                case .about: about
                case .formats: EmptyView()
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var general: some View {
        if !state.hasScreenPermission {
            Section {
                PermissionRow()
            }
        }
        Section {
            Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            Picker("Clicking the menu bar icon", selection: $settings.menuBarClick) {
                ForEach(MenuBarClick.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Fill the menu bar icon with the last color", isOn: $settings.tintMenuBarIcon)
            Toggle("Show the Color Dock", isOn: $settings.showDock)
        } footer: {
            Text("Right-click the menu bar icon for the other action.")
        }

        Section {
            Picker("Keep in History", selection: $settings.historyLimit) {
                ForEach([50, 100, 200, 500, 1000], id: \.self) { Text("\($0) colors").tag($0) }
            }
            LabeledContent("Library folder") {
                HStack {
                    Text((settings.libraryFolder.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                }
            }
            LabeledContent("Library file") {
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.shared.fileURL]) }
                    if settings.libraryFolder != AppSettings.defaultLibraryFolder {
                        Button("Use Default") { moveLibrary(to: AppSettings.defaultLibraryFolder) }
                    }
                }
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Choose a folder in iCloud Drive or Dropbox to sync your palettes between Macs. Chroma picks up changes made on another Mac automatically.")
        }

        Section {
            LabeledContent("Reset all settings") {
                Button("Reset", action: settings.resetToDefaults)
            }
        }
    }

    @ViewBuilder
    private var picker: some View {
        Section {
            LabeledContent("Loupe size") {
                HStack {
                    Slider(value: $settings.loupeSize, in: AppSettings.loupeSizeRange, step: 4).frame(width: 200)
                    Text("\(Int(settings.loupeSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            LabeledContent("Magnification") {
                HStack {
                    Slider(value: Binding(get: { Double(settings.loupeZoom) }, set: { settings.loupeZoom = Int($0) | 1 }),
                           in: Double(AppSettings.loupeZoomRange.lowerBound)...Double(AppSettings.loupeZoomRange.upperBound), step: 2)
                        .frame(width: 200)
                    Text("\(settings.loupeZoom) px").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            Toggle("Show pixel grid", isOn: $settings.showGrid)
            Picker("Sample", selection: $settings.sampleSize) {
                Text("Single pixel").tag(1)
                Text("3 × 3 average").tag(3)
                Text("5 × 5 average").tag(5)
            }
        } header: {
            Text("Loupe")
        } footer: {
            Text("While picking: + and − resize the loupe, ⌥+ and ⌥− (or scrolling) change the magnification, G toggles the grid and S changes the sample.")
        }

        Section("After picking") {
            Toggle("Copy to the clipboard", isOn: $settings.copyOnPick)
            Toggle("Show a confirmation", isOn: $settings.showPickToast)
            Toggle("Play a sound", isOn: $settings.playSound)
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        Section {
            ForEach(ShortcutAction.allCases) { action in
                LabeledContent(action.title) {
                    ShortcutRecorder(
                        shortcut: Binding(get: { settings.shortcut(action) }, set: { settings.setShortcut($0, for: action) }),
                        isUnavailable: state.unavailableShortcuts.contains(action)
                    )
                }
            }
        } footer: {
            Text("These work from any app. Click one and type a new combination; Delete clears it.")
        }
        Section("While picking") {
            ForEach(Self.pickerKeys, id: \.0) { key, action in
                LabeledContent(action) {
                    Text(key).font(.system(.body, design: .rounded).weight(.medium))
                }
            }
        }
    }

    static let pickerKeys: [(String, String)] = [
        ("Click or Return", "Pick and copy"),
        ("⇧ Click", "Pick and keep picking"),
        ("← → ↑ ↓", "Move 1 px (⇧ for 10)"),
        ("Scroll, ⌥+ ⌥−", "Magnification"),
        ("+ −", "Loupe size"),
        ("Tab", "Next format"),
        ("G / S", "Grid / sample size"),
        ("Esc", "Cancel"),
    ]

    @ViewBuilder
    private var about: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chroma").font(.title3.weight(.semibold))
                    Text("Version \(Bundle.main.shortVersion)").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            Text("A free, open source color picker for macOS. Made by Josh Hamilton and released under the MIT License. Inspired by Sip.")
                .foregroundStyle(.secondary)
            Text("Color names come from Name That Color by Chirag Mehta (CC BY 2.5). Tailwind swatches are from Tailwind CSS (MIT).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section {
            Link("Website", destination: StatusBarController.websiteURL)
            Link("Source code on GitHub", destination: StatusBarController.repositoryURL)
            Link("Report an issue", destination: StatusBarController.repositoryURL.appendingPathComponent("issues"))
            Button("Show welcome window") { AppCoordinator.shared?.showWelcome() }
                .buttonStyle(.link)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.libraryFolder
        panel.prompt = "Use Folder"
        panel.message = "Chroma keeps Library.json in this folder. If the folder already has one, Chroma switches to it."
        if panel.runModal() == .OK, let url = panel.url {
            moveLibrary(to: url)
        }
    }

    private func moveLibrary(to folder: URL) {
        settings.libraryFolder = folder
        LibraryStore.shared.moveLibrary(to: folder)
    }
}

// MARK: - Formats

struct FormatsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var editing: CustomFormat?
    @State private var addingRule = false

    var body: some View {
        Form {
            Section {
                FormatMenu(label: "Copy as")
                Toggle("Uppercase hex", isOn: $settings.uppercaseHex)
                if let sample = LibraryStore.shared.latest {
                    LabeledContent("Example") {
                        Text(settings.string(sample)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } footer: {
                Text("Tab cycles through the formats checked below while you pick.")
            }

            Section {
                Toggle("Use a different format for some apps", isOn: $settings.smartFormats)
                if settings.smartFormats {
                    ForEach($settings.appRules) { $rule in
                        HStack {
                            AppIcon(bundleID: rule.bundleID)
                            Text(rule.appName)
                            Spacer()
                            Picker("", selection: $rule.formatID) {
                                ForEach(settings.allFormats) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                            Button {
                                settings.appRules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add App…", action: addApp)
                }
            } header: {
                Text("Smart formats")
            } footer: {
                Text("Picks made while one of these apps is in front are copied in its format.")
            }

            Section("Shown formats") {
                ForEach(settings.allFormats) { format in
                    HStack {
                        Toggle(isOn: Binding(get: { settings.shownFormatIDs.contains(format.id) }, set: { show in
                            if show {
                                settings.shownFormatIDs.append(format.id)
                            } else {
                                settings.shownFormatIDs.removeAll { $0 == format.id }
                            }
                        })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(format.name)
                                Text(FormatTemplate.render(format.template, color: Self.sample, uppercaseHex: settings.uppercaseHex))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if format.isCustom, let custom = settings.customFormats.first(where: { $0.format.id == format.id }) {
                            Spacer()
                            Button("Edit") { editing = custom }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                Button("New Custom Format…") {
                    editing = CustomFormat(name: "My Format", template: "#{hex}")
                }
            } footer: {
                Text("Write a template with tokens like {hex}, {r}, {g}, {b}, {a} or {name}.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { format in
            CustomFormatEditor(format: format) { saved in
                if let saved {
                    if let index = settings.customFormats.firstIndex(where: { $0.id == saved.id }) {
                        settings.customFormats[index] = saved
                    } else {
                        settings.customFormats.append(saved)
                        settings.shownFormatIDs.append(saved.format.id)
                    }
                }
                editing = nil
            } onDelete: {
                settings.customFormats.removeAll { $0.id == format.id }
                settings.shownFormatIDs.removeAll { $0 == format.format.id }
                if settings.copyFormatID == format.format.id { settings.copyFormatID = "hex" }
                editing = nil
            }
        }
    }

    static let sample = RGBColor(hex: "3B82F6")!

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        settings.appRules.removeAll { $0.bundleID == id }
        settings.appRules.append(AppFormatRule(bundleID: id, appName: name, formatID: settings.copyFormatID))
    }
}

struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed").frame(width: 20, height: 20)
        }
    }
}

struct CustomFormatEditor: View {
    @State var format: CustomFormat
    let onFinish: (CustomFormat?) -> Void
    let onDelete: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom Format").font(.headline)
            Form {
                TextField("Name", text: $format.name)
                TextField("Template", text: $format.template, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Preview") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(FormatTemplate.render(format.template, color: FormatsPane.sample, uppercaseHex: settings.uppercaseHex))
                        Text(FormatTemplate.render(format.template, color: FormatsPane.sample.withAlpha(0.5), uppercaseHex: settings.uppercaseHex))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(FormatTemplate.tokenHelp, id: \.token) { token, meaning in
                        GridRow {
                            Button(token) { format.template += token.components(separatedBy: " ").first ?? token }
                                .buttonStyle(.borderless)
                                .font(.system(.callout, design: .monospaced))
                            Text(meaning).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 170)

            HStack {
                if settings.customFormats.contains(where: { $0.id == format.id }) {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onFinish(format) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(format.name.isEmpty || format.template.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}

struct PermissionRow: View {
    var body: some View {
        LabeledContent {
            Button("Allow…") { ScreenPermission.request() }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording is off")
                    Text("Chroma reads the pixels on screen to pick colors. Nothing leaves your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    var isUnavailable = false

    @StateObject private var recorder = ShortcutRecorderModel()

    var body: some View {
        HStack(spacing: 6) {
            if isUnavailable && !recorder.isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This shortcut is already used by another app")
            }
            Button(action: toggleRecording) {
                Text(label)
                    .foregroundStyle(recorder.isRecording || shortcut == nil ? .secondary : .primary)
                    .frame(minWidth: 96)
            }
            if shortcut != nil && !recorder.isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear { recorder.stop() }
    }

    private var label: String {
        if recorder.isRecording { return "Type shortcut…" }
        return shortcut?.displayString ?? "Record Shortcut"
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            recorder.start { shortcut = $0 }
        }
    }
}

/// Captures the next key combo typed while the settings window is focused.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?

    func start(onRecord: @escaping (Shortcut?) -> Void) {
        stop()
        isRecording = true
        AppState.shared.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event, onRecord: onRecord)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if isRecording {
            isRecording = false
            AppState.shared.isRecordingShortcut = false
        }
    }

    private func handle(_ event: NSEvent, onRecord: (Shortcut?) -> Void) {
        let modifiers = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let keyCode = Int(event.keyCode)

        if keyCode == kVK_Escape && modifiers.isEmpty {
            stop()
            return
        }
        if (keyCode == kVK_Delete || keyCode == kVK_ForwardDelete) && modifiers.isEmpty {
            onRecord(nil)
            stop()
            return
        }
        // Require a real modifier (not just Shift) unless it's a function key.
        guard !modifiers.subtracting(.shift).isEmpty || Shortcut.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }
        onRecord(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        stop()
    }
}
