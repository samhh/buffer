import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(preferences: PreferencesStore) {
        let rootView = SettingsView(preferences: preferences)
        let hostingView = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Buffer Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.center()
        window.contentView = hostingView

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct SettingsView: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.25))
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                SettingsSection(title: "General") {
                    SettingsCard {
                        SettingsRow(title: "Toggle hotkey") {
                            ShortcutRecorderField(preferences: preferences)
                                .frame(width: 190)
                        }
                        SettingsDivider()
                        SettingsRow(title: "Appearance") {
                            AppearanceModePicker(selection: $preferences.appearanceMode)
                                .frame(width: 190, alignment: .trailing)
                        }
                    }
                }

                SettingsSection(title: "Startup") {
                    SettingsCard {
                        SettingsRow(title: "Launch at login") {
                            Toggle(isOn: $preferences.launchAtLoginEnabled) {
                                EmptyView()
                            }
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 460, height: 320)
    }
}

private struct AppearanceModePicker: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        Picker("Appearance", selection: $selection) {
            ForEach(AppearanceMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}

private struct ShortcutRecorderField: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var preferences: PreferencesStore
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            HStack {
                Text(isRecording ? "Type shortcut..." : preferences.hotKeyDisplayGlyphs)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Text(isRecording ? "Recording" : "Edit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.thickMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isRecording ? Color.accentColor.opacity(0.95) : chromeBorderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbonModifiers = PreferencesStore.carbonModifiers(from: modifiers)
            guard carbonModifiers != 0 else {
                return nil
            }

            guard let key = KeyboardLayoutMapper.normalizedKey(from: event) else {
                return nil
            }

            preferences.updateHotKey(key: key, eventModifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private var chromeBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 9)
            content
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(chromeMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chromeBorderColor, lineWidth: 1)
                )
        )
    }

    private var chromeMaterial: Material {
        colorScheme == .dark ? .thickMaterial : .regularMaterial
    }

    private var chromeBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.20) : .black.opacity(0.12)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
            HStack(spacing: 12) {
                Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                Spacer()
                trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
