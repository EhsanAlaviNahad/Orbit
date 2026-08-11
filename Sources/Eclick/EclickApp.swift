import AppKit
import SwiftUI

@main
enum EclickMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.refreshPreferences()
    }
}

@MainActor
final class AppController: NSObject {
    private struct CachedScan {
        let pid: pid_t
        let result: ScanResult
        let createdAt: Date
    }

    private static let scanCacheLifetime: TimeInterval = 15

    private let scanner = TargetScanner()
    private let hotKey = HotKeyRegistrar()
    private let overlay = HintOverlayController()
    private let input = HintInputMonitor()
    private let preferences = PreferencesModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private var settingsWindow: NSWindow?
    private var scanTask: Task<Void, Never>?
    private var scanID: UUID?
    private var activateMenuItem: NSMenuItem?
    private var pendingActivation: ClickTarget?
    private var pendingActivationKind: TargetActivator.Kind = .singleClick
    private var singleClickTask: Task<Void, Never>?
    private var enterPressCount = 0
    private var cachedScan: CachedScan?

    override init() {
        super.init()
        configureStatusItem()
        configureShortcut()
        input.cancelShortcut = preferences.shortcut
        input.onInput = { [weak self] value in self?.handle(value) }
        overlay.updateHintStyle(
            fontSize: CGFloat(preferences.hintLabelSize),
            appearance: preferences.hintLabelAppearance
        )
        preferences.onHintLabelStyleChange = { [weak self] fontSize, appearance in
            self?.overlay.updateHintStyle(fontSize: fontSize, appearance: appearance)
        }
        preferences.onShortcutChange = { [weak self] shortcut in
            guard let self else { return }
            do {
                try self.hotKey.register(shortcut)
                self.input.cancelShortcut = shortcut
                self.activateMenuItem?.title = "Show Hints (\(shortcut.displayName))"
            } catch {
                try? self.hotKey.register(self.preferences.shortcut)
                throw error
            }
        }
    }

    func shutdown() {
        cancelHintMode()
        hotKey.shutdown()
        preferences.shutdown()
        settingsWindow?.close()
        settingsWindow = nil
    }

    func refreshPreferences() {
        preferences.refresh()
    }

    @objc private func toggleHintModeFromMenu() {
        toggleHintMode()
    }

    @objc private func showSettings() {
        preferences.refresh()
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: SettingsView(model: preferences))
        let window = NSWindow(contentViewController: controller)
        window.title = "Eclick Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.3.0"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Eclick",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: "Keyboard-driven search and clicking with Accessibility and on-device OCR."
            )
        ])
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "cursorarrow.click",
                accessibilityDescription: "Eclick"
            )
            button.toolTip = "Eclick — keyboard hints for clickable controls"
        }

        let menu = NSMenu()
        let activate = NSMenuItem(
            title: "Show Hints (\(preferences.shortcut.displayName))",
            action: #selector(toggleHintModeFromMenu),
            keyEquivalent: ""
        )
        activate.target = self
        activateMenuItem = activate
        menu.addItem(activate)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(
            title: "About Eclick",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Eclick",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func configureShortcut() {
        hotKey.onPressed = { [weak self] in self?.toggleHintMode() }
        do {
            try hotKey.register(preferences.shortcut)
        } catch {
            preferences.message = error.localizedDescription
        }
    }

    private func toggleHintMode() {
        if overlay.isPresented {
            cancelHintMode()
            return
        }
        // A second shortcut press can arrive while the initial scan is still
        // producing the overlay. Keep that scan alive instead of turning the
        // user's retry into a cancellation that requires a third press.
        if scanTask != nil {
            return
        }
        guard PermissionCenter.accessibilityGranted else {
            preferences.refresh()
            preferences.message = "Remove any old Eclick entry in Accessibility, add the installed Eclick.app, enable it, then relaunch Eclick."
            showSettings()
            return
        }
        guard let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            NSSound.beep()
            return
        }

        if let cachedScan,
           cachedScan.pid == targetPID,
           Date().timeIntervalSince(cachedScan.createdAt) <= Self.scanCacheLifetime {
            present(cachedScan.result)
            return
        }

        let id = UUID()
        scanID = id
        statusItem.button?.image = NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: "Eclick is scanning"
        )
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.scanID == id {
                    self.scanTask = nil
                    self.scanID = nil
                    self.restoreStatusIcon()
                }
            }
            do {
                let result = try await self.scanner.scanFocusedWindow(pid: targetPID)
                guard !Task.isCancelled, self.scanID == id else { return }
                self.cachedScan = CachedScan(pid: targetPID, result: result, createdAt: Date())
                self.present(result)
            } catch {
                guard !Task.isCancelled else { return }
                self.preferences.message = error.localizedDescription
                if error is ScanError { self.showSettings() }
            }
        }
    }

    private func handle(_ inputValue: HintInput) {
        if pendingActivation != nil {
            if case .enter = inputValue, pendingActivationKind == .singleClick {
                enterPressCount += 1
                if enterPressCount == 2 {
                    singleClickTask?.cancel()
                    singleClickTask = nil
                    pendingActivationKind = .doubleClick
                }
                return
            }
            if case .keyReleased = inputValue {
                if pendingActivationKind != .singleClick || enterPressCount == 2 {
                    finishPendingActivation()
                } else {
                    scheduleSingleClick()
                }
            }
            return
        }
        switch inputValue {
        case let .text(text):
            overlay.appendSearchText(text)
        case .backspace:
            overlay.backspace()
        case .selectAll:
            overlay.selectAll()
        case .copy:
            overlay.copy()
        case .paste:
            overlay.paste()
        case .enter:
            if let target = overlay.selectedTarget() {
                pendingActivation = target
                pendingActivationKind = .singleClick
                enterPressCount = 1
            }
        case .shiftEnter:
            if let target = overlay.selectedTarget() {
                pendingActivation = target
                pendingActivationKind = .rightClick
                enterPressCount = 0
            }
        case .nextResult:
            overlay.moveSelection(by: 1)
        case .previousResult:
            overlay.moveSelection(by: -1)
        case .keyReleased:
            break
        case .escape:
            cancelHintMode()
        }
    }

    private func scheduleSingleClick() {
        guard singleClickTask == nil else { return }
        singleClickTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.finishPendingActivation()
        }
    }

    private func finishPendingActivation() {
        guard let target = pendingActivation else { return }
        let kind = pendingActivationKind
        singleClickTask?.cancel()
        singleClickTask = nil
        pendingActivation = nil
        pendingActivationKind = .singleClick
        enterPressCount = 0
        cachedScan = nil
        cancelHintMode(discardOverlay: true)
        TargetActivator.activate(target, kind: kind)
    }

    private func present(_ result: ScanResult) {
        let assignments = HintGenerator.assign(to: result.targets)
        guard !assignments.isEmpty else {
            NSSound.beep()
            return
        }
        overlay.show(assignments: assignments, windowFrame: result.windowFrame)
        guard overlay.isPresented else {
            NSSound.beep()
            return
        }
        guard input.start() else {
            overlay.dismiss()
            preferences.message = "Keyboard monitoring could not start. Recheck Accessibility permission."
            showSettings()
            return
        }
    }

    private func cancelHintMode(discardOverlay: Bool = false) {
        scanTask?.cancel()
        scanTask = nil
        scanID = nil
        pendingActivation = nil
        singleClickTask?.cancel()
        singleClickTask = nil
        pendingActivationKind = .singleClick
        enterPressCount = 0
        input.stop()
        if discardOverlay {
            overlay.dismiss()
        } else {
            overlay.hide()
        }
        restoreStatusIcon()
    }

    private func restoreStatusIcon() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "cursorarrow.click",
            accessibilityDescription: "Eclick"
        )
    }
}
