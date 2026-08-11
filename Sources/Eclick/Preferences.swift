import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

enum HintLabelAppearance: String, CaseIterable, Identifiable {
    case classic
    case glass
    case accent
    case white

    var id: Self { self }

    var displayName: String {
        switch self {
        case .classic: "Classic Yellow"
        case .glass: "Dark Glass"
        case .accent: "Accent Color"
        case .white: "White"
        }
    }
}

@MainActor
final class PreferencesModel: ObservableObject {
    @Published private(set) var shortcut: KeyboardShortcut
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published var isRecordingShortcut = false
    @Published var message: String?
    @Published private(set) var hintLabelSize: Double
    @Published private(set) var hintLabelAppearance: HintLabelAppearance

    var onShortcutChange: ((KeyboardShortcut) throws -> Void)?
    var onHintLabelStyleChange: ((CGFloat, HintLabelAppearance) -> Void)?

    private var keyMonitor: Any?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hintLabelSize = defaults.object(forKey: "hints.fontSize") == nil
            ? 13
            : min(20, max(10, defaults.double(forKey: "hints.fontSize")))
        hintLabelAppearance = HintLabelAppearance(
            rawValue: defaults.string(forKey: "hints.appearance") == "monochrome"
                ? "white"
                : defaults.string(forKey: "hints.appearance") ?? "classic"
        ) ?? .classic
        if defaults.object(forKey: "shortcut.keyCode") != nil {
            shortcut = KeyboardShortcut(
                keyCode: UInt32(defaults.integer(forKey: "shortcut.keyCode")),
                carbonModifiers: UInt32(defaults.integer(forKey: "shortcut.modifiers")),
                displayName: defaults.string(forKey: "shortcut.displayName") ?? "⌘E"
            )
        } else {
            shortcut = .commandE
        }
        refresh()
    }

    func shutdown() {
        stopShortcutRecording()
    }

    func refresh() {
        accessibilityGranted = PermissionCenter.accessibilityGranted
        screenRecordingGranted = PermissionCenter.screenRecordingGranted
        let loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled
        launchAtLoginRequiresApproval = loginStatus == .requiresApproval
    }

    func requestAccessibility() {
        PermissionCenter.requestAccessibility()
        refreshSoon()
    }

    func requestScreenRecording() {
        PermissionCenter.requestScreenRecording()
        refreshSoon()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    func setHintLabelSize(_ size: Double) {
        hintLabelSize = min(20, max(10, size))
        defaults.set(hintLabelSize, forKey: "hints.fontSize")
        onHintLabelStyleChange?(CGFloat(hintLabelSize), hintLabelAppearance)
    }

    func setHintLabelAppearance(_ appearance: HintLabelAppearance) {
        hintLabelAppearance = appearance
        defaults.set(appearance.rawValue, forKey: "hints.appearance")
        onHintLabelStyleChange?(CGFloat(hintLabelSize), appearance)
    }

    func beginShortcutRecording() {
        guard keyMonitor == nil else { return }
        isRecordingShortcut = true
        message = "Press a shortcut containing Command, Control, or Option."
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in self.capture(event) }
            return nil
        }
    }

    func cancelShortcutRecording() {
        stopShortcutRecording()
        message = nil
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            cancelShortcutRecording()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let normalized = flags.intersection(allowed)
        guard !normalized.intersection([.command, .control, .option]).isEmpty else {
            message = "Include Command, Control, or Option."
            return
        }

        let name = (event.charactersIgnoringModifiers ?? "?").uppercased()
        let candidate = KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: normalized.carbonFlags,
            displayName: normalized.glyphs + name
        )
        do {
            try onShortcutChange?(candidate)
            shortcut = candidate
            defaults.set(Int(candidate.keyCode), forKey: "shortcut.keyCode")
            defaults.set(Int(candidate.carbonModifiers), forKey: "shortcut.modifiers")
            defaults.set(candidate.displayName, forKey: "shortcut.displayName")
            message = nil
            stopShortcutRecording()
        } catch {
            message = error.localizedDescription
        }
    }

    private func stopShortcutRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isRecordingShortcut = false
    }

    private func refreshSoon() {
        refresh()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.refresh()
        }
    }
}

private extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var glyphs: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

struct SettingsView: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Section("Activation") {
                LabeledContent("Shortcut") {
                    Button(model.isRecordingShortcut ? "Press keys…" : model.shortcut.displayName) {
                        if model.isRecordingShortcut {
                            model.cancelShortcutRecording()
                        } else {
                            model.beginShortcutRecording()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }

            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    granted: model.accessibilityGranted,
                    requestTitle: "Open Settings",
                    request: PermissionCenter.openAccessibilitySettings,
                    settings: PermissionCenter.openAccessibilitySettings
                )
                permissionRow(
                    title: "Screen Recording (OCR)",
                    granted: model.screenRecordingGranted,
                    requestTitle: "Grant",
                    request: model.requestScreenRecording,
                    settings: PermissionCenter.openScreenRecordingSettings
                )
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: model.setLaunchAtLogin
                ))
                if model.launchAtLoginRequiresApproval {
                    LabeledContent("Login item") {
                        Text("Approval required")
                            .foregroundStyle(.orange)
                        Button("Open Settings") {
                            PermissionCenter.openLoginItemsSettings()
                        }
                    }
                }
            }

            Section("Hint Labels") {
                LabeledContent("Size") {
                    Slider(
                        value: Binding(
                            get: { model.hintLabelSize },
                            set: model.setHintLabelSize
                        ),
                        in: 10...20,
                        step: 1
                    )
                    .frame(width: 180)
                    Text("\(Int(model.hintLabelSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }

                Picker(
                    "Appearance",
                    selection: Binding(
                        get: { model.hintLabelAppearance },
                        set: model.setHintLabelAppearance
                    )
                ) {
                    ForEach(HintLabelAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }

                HStack {
                    Text("Preview")
                    Spacer()
                    HintLabelPreview(
                        size: model.hintLabelSize,
                        appearance: model.hintLabelAppearance
                    )
                }
            }

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 500)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        requestTitle: String,
        request: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            Text(granted ? "Granted" : "Required")
                .foregroundStyle(granted ? .green : .orange)
            Button(granted ? "Settings" : requestTitle) {
                granted ? settings() : request()
            }
        }
    }
}

private struct HintLabelPreview: View {
    let size: Double
    let appearance: HintLabelAppearance

    var body: some View {
        Text("AS")
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, max(5, size * 0.38))
            .padding(.vertical, max(3, size * 0.18))
            .background(background, in: RoundedRectangle(cornerRadius: max(4, size * 0.32)))
            .overlay {
                RoundedRectangle(cornerRadius: max(4, size * 0.32))
                    .stroke(border, lineWidth: 0.75)
            }
    }

    private var foreground: Color {
        switch appearance {
        case .classic: .black
        case .glass, .accent: .white
        case .white: .black
        }
    }

    private var background: Color {
        switch appearance {
        case .classic: Color(red: 1, green: 0.82, blue: 0.16)
        case .glass: .black.opacity(0.76)
        case .accent: .accentColor
        case .white: .white.opacity(0.96)
        }
    }

    private var border: Color {
        switch appearance {
        case .classic: .black.opacity(0.35)
        case .glass, .accent: .white.opacity(0.28)
        case .white: .black.opacity(0.22)
        }
    }
}
