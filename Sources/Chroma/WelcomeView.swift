import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private var timer: Timer?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView(onFinish: { [weak self] in self?.finish() }))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.title = "Welcome to Chroma"
            self.window = window
        }
        AppState.shared.refreshPermission()
        window?.center()
        if AppCoordinator.isHarness {
            window?.orderBack(nil) // screenshots without stealing focus
        } else {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }

        // Pick up the permission as soon as it's granted in System Settings.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                AppState.shared.refreshPermission()
                if self?.window?.isVisible != true { self?.timer?.invalidate() }
            }
        }
    }

    private func finish() {
        AppSettings.shared.hasOnboarded = true
        window?.close()
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AppCoordinator.shared?.pick()
        }
    }
}

struct WelcomeView: View {
    let onFinish: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var state = AppState.shared
    @State private var askedForPermission = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .padding(.bottom, 6)
                Text("Welcome to Chroma")
                    .font(.title2.weight(.semibold))
                Text("Press a shortcut from any app, click a color, and paste it anywhere.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.horizontal, 24)

            Form {
                Section {
                    LabeledContent {
                        permissionControl
                    } label: {
                        Text("Screen Recording")
                        Text("Used to read the color under the pointer. Nothing leaves your Mac.")
                    }
                    LabeledContent {
                        ShortcutRecorder(
                            shortcut: Binding(get: { settings.shortcut(.pick) }, set: { settings.setShortcut($0, for: .pick) }),
                            isUnavailable: state.unavailableShortcuts.contains(.pick)
                        )
                    } label: {
                        Text("Pick shortcut")
                        Text("Esc cancels. The menu bar icon works too.")
                    }
                    LabeledContent {
                        FormatMenu(label: "").labelsHidden().fixedSize()
                    } label: {
                        Text("Copy as")
                        Text("Change it any time, or press Tab while picking.")
                    }
                    Toggle(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 })) {
                        Text("Launch at login")
                        Text("Chroma lives in the menu bar.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Button(action: onFinish) {
                Text(state.hasScreenPermission ? "Pick a Color" : "Allow Screen Recording to Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!state.hasScreenPermission && !DemoSnapshot.isEnabled)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var permissionControl: some View {
        if state.hasScreenPermission {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if askedForPermission {
            HStack {
                Button("Open Settings") { ScreenPermission.openSystemSettings() }
                Button("Relaunch") { ScreenPermission.relaunch() }
                    .help("macOS applies the permission after Chroma restarts")
            }
        } else {
            Button("Allow…") {
                askedForPermission = true
                ScreenPermission.request()
            }
        }
    }
}
