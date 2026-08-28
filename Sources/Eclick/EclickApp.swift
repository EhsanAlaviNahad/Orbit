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
    private let scanner = TargetScanner()
    private let hotKey = HotKeyRegistrar()
    private let overlay = HintOverlayController()
    private let input = HintInputMonitor()
    private let preferences = PreferencesModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let systemCommands: SystemCommandCoordinator

    private var settingsWindow: NSWindow?
    private var scanTask: Task<Void, Never>?
    private var scanID: UUID?
    private var arrangementTask: Task<Void, Never>?
    private var arrangementID: UUID?
    private var systemCommandTask: Task<Void, Never>?
    private var systemCommandID: UUID?
    private var scrollRefreshTask: Task<Void, Never>?
    private var scrollRefreshID: UUID?
    private var activateMenuItem: NSMenuItem?
    private var lastTargetPID: pid_t?
    private var activeTargetPID: pid_t?
    private var activeWindowFrame: CGRect?
    private var pendingActivation: (target: ClickTarget, kind: TargetActivator.Kind)?
    private var activatedDuringSession = false
    private var lastPresentation: (result: ScanResult, dockTargets: [ClickTarget])?
    private var overlaySessionSnapshot: OverlaySessionSnapshot?

    private struct OverlaySessionSnapshot {
        let record: ScanSnapshotRecord
        let result: ScanResult
        let dockTargets: [ClickTarget]
    }

    init(systemCommandExecutor: any SystemCommandExecuting = NativeSystemCommandExecutor()) {
        systemCommands = SystemCommandCoordinator(executor: systemCommandExecutor)
        super.init()
        configureStatusItem()
        configureShortcut()
        input.cancelShortcut = preferences.shortcut
        input.onInput = { [weak self] value in self?.handle(value) }
        overlay.updateHintStyle(
            fontSize: CGFloat(preferences.hintLabelSize),
            appearance: preferences.hintLabelAppearance,
            customColor: preferences.hintLabelCustomColor
        )
        preferences.onHintLabelStyleChange = { [weak self] fontSize, appearance, customColor in
            self?.overlay.updateHintStyle(
                fontSize: fontSize,
                appearance: appearance,
                customColor: customColor
            )
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastTargetPID = application.processIdentifier
        }
    }

    func shutdown() {
        cancelHintMode()
        input.shutdown()
        arrangementTask?.cancel()
        arrangementTask = nil
        arrangementID = nil
        systemCommandTask?.cancel()
        systemCommandTask = nil
        systemCommandID = nil
        scrollRefreshTask?.cancel()
        scrollRefreshTask = nil
        scrollRefreshID = nil
        hotKey.shutdown()
        preferences.shutdown()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        settingsWindow?.close()
        settingsWindow = nil
    }

    func refreshPreferences() {
        preferences.refresh()
    }

    @objc private func frontmostApplicationDidChange(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        if application.processIdentifier != lastTargetPID {
            cancelHintMode(discardOverlay: true)
            arrangementTask?.cancel()
            arrangementTask = nil
            arrangementID = nil
        }
        lastTargetPID = application.processIdentifier
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
        window.title = "Orbit Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 540))
        window.contentMinSize = NSSize(width: 500, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func runWindowArrangement(_ arrangement: WindowArrangement, pid: pid_t) {
        cancelHintMode(discardOverlay: true)
        arrangementTask?.cancel()
        let id = UUID()
        arrangementID = id
        arrangementTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.arrangementID == id {
                    self.arrangementTask = nil
                    self.arrangementID = nil
                }
            }
            do {
                try await WindowArranger.arrangeFocusedWindow(pid: pid, arrangement: arrangement)
            } catch is CancellationError {
                return
            } catch {
                NSSound.beep()
                self.preferences.message = error.localizedDescription
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.4.0"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Orbit",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: "Keyboard-driven search and clicking with Accessibility and on-device OCR."
            )
        ])
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = MenuIcon.makeIdleIcon()
            button.toolTip = "Orbit — keyboard hints for clickable controls"
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
            title: "About Orbit",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Orbit",
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
            preferences.message = "Remove any old Orbit entry in Accessibility, add the installed Orbit.app, enable it, then relaunch Orbit."
            showSettings()
            return
        }
        guard let targetPID = targetApplicationPID() else {
            NSSound.beep()
            return
        }

        systemCommands.cancel()
        pendingActivation = nil

        let id = UUID()
        scanID = id
        statusItem.button?.image = MenuIcon.makeScanningIcon()
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.scanID == id {
                    self.scanTask = nil
                    self.scanID = nil
                    self.restoreStatusIcon()
                }
            }
            var paintedFromCache = false
            do {
                async let dockTargets = self.scanner.scanDockTargets()
                // A fresh read-only session snapshot may be validated with a
                // cheap frame probe while the full scan runs in parallel.
                let snapshotCandidate = self.overlaySessionSnapshot
                let cacheProbe: Task<CGRect?, Never>?
                if let snapshot = snapshotCandidate, snapshot.record.endedReadOnly {
                    let pidForProbe = targetPID
                    cacheProbe = Task.detached(priority: .userInitiated) {
                        await self.scanner.probeFocusedWindowFrame(pid: pidForProbe)
                    }
                } else {
                    cacheProbe = nil
                }
                async let scanPromise = self.scanner.beginFocusedWindowScan(pid: targetPID)

                if let cacheProbe {
                    let probedFrame = await cacheProbe.value
                    if !Task.isCancelled,
                       self.scanID == id,
                       !self.overlay.isPresented,
                       let snapshot = snapshotCandidate,
                       let probedFrame,
                       ScanRecencyPolicy.canInstantlyPresent(
                        record: snapshot.record,
                        pid: targetPID,
                        currentFrame: probedFrame,
                        now: .now
                       ) {
                        self.present(
                            snapshot.result,
                            dockTargets: snapshot.dockTargets,
                            targetPID: targetPID
                        )
                        paintedFromCache = self.overlay.isPresented
                    }
                }

                // Present accessibility hints as soon as the tree scan lands;
                // OCR supplements merge in later without blocking first paint.
                let scan = try await scanPromise
                guard !Task.isCancelled, self.scanID == id else {
                    scan.cancelSupplement()
                    return
                }
                let immediate = ScanResult(
                    windowFrame: scan.windowFrame,
                    targets: scan.accessibilityTargets,
                    isComplete: scan.accessibilityIsComplete
                )
                let resolvedDock = await dockTargets

                if paintedFromCache {
                    self.replacePresentedTargets(immediate, dockTargets: resolvedDock)
                } else {
                    self.present(immediate, dockTargets: resolvedDock, targetPID: targetPID)
                }

                let mergedTargets = await withTaskCancellationHandler {
                    await scan.mergedTargetsTask.value
                } onCancel: {
                    scan.cancelSupplement()
                }
                try Task.checkCancellation()
                guard self.scanID == id,
                      self.overlay.isPresented,
                      mergedTargets.count != scan.accessibilityTargets.count else {
                    return
                }
                self.replacePresentedTargets(
                    ScanResult(
                        windowFrame: scan.windowFrame,
                        targets: mergedTargets,
                        isComplete: scan.accessibilityIsComplete
                    ),
                    dockTargets: resolvedDock
                )
            } catch let error as ScanError {
                guard !Task.isCancelled else { return }
                if paintedFromCache {
                    // Cache paint already showed a validated overlay; a scan
                    // failure right after (e.g., window vanished mid-race)
                    // should not error-beep over live hints.
                    self.cancelHintMode(discardOverlay: true)
                    return
                }
                self.preferences.message = error.localizedDescription
                switch error {
                case .accessibilityUnavailable:
                    self.showSettings()
                case .noFocusedWindow:
                    NSSound.beep()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.preferences.message = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    private func handle(_ inputValue: HintInput) {
        switch inputValue {
        case let .text(text):
            mutateSearchQuery { overlay.appendSearchText(text) }
        case .backspace:
            mutateSearchQuery { overlay.backspace() }
        case .selectAll:
            overlay.selectAll()
        case .copy:
            overlay.copy()
        case .paste:
            mutateSearchQuery { overlay.paste() }
        case .enter:
            pendingActivation = nil
            if systemCommands.enterKeyDown(query: overlay.query) {
                overlay.setPendingSystemCommand(systemCommands.pendingCommand)
                return
            }
            if let target = overlay.selectedTarget() {
                pendingActivation = (target, .singleClick)
            }
        case .optionEnter:
            pendingActivation = nil
            guard SystemCommandParser.parse(overlay.query) == nil else {
                systemCommands.cancel()
                overlay.setPendingSystemCommand(nil)
                NSSound.beep()
                return
            }
            if let target = overlay.selectedTarget() {
                pendingActivation = (target, .doubleClick)
            }
        case .shiftEnter:
            pendingActivation = nil
            guard SystemCommandParser.parse(overlay.query) == nil else {
                systemCommands.cancel()
                overlay.setPendingSystemCommand(nil)
                NSSound.beep()
                return
            }
            if let target = overlay.selectedTarget() {
                pendingActivation = (target, .rightClick)
            }
        case let .scroll(direction):
            pendingActivation = nil
            systemCommands.cancel()
            overlay.setPendingSystemCommand(nil)
            guard let activeTargetPID, let activeWindowFrame else { return }
            PageScroller.scroll(
                direction,
                at: CGPoint(
                    x: activeWindowFrame.midX,
                    y: activeWindowFrame.midY
                ),
                speedMultiplier: preferences.scrollSpeedMultiplier
            )
            overlay.showOnlyDockHints()
            scheduleHintRefresh(pid: activeTargetPID)
        case .nextResult:
            overlay.moveSelection(by: 1)
        case .previousResult:
            overlay.moveSelection(by: -1)
        case .keyReleased:
            if let outcome = systemCommands.enterKeyUp() {
                pendingActivation = nil
                switch outcome {
                case let .confirmationRequested(command):
                    overlay.setPendingSystemCommand(command)
                case let .execute(command):
                    executeSystemCommand(command)
                }
            } else if let activation = pendingActivation {
                pendingActivation = nil
                activate(activation.target, kind: activation.kind)
            }
        case .terminalKeyCancelled:
            pendingActivation = nil
            _ = systemCommands.enterKeyUp(isValid: false)
            overlay.setPendingSystemCommand(nil)
            NSSound.beep()
        case .modifierChanged:
            guard pendingActivation != nil || systemCommands.pendingCommand != nil else { return }
            pendingActivation = nil
            systemCommands.modifierDidChange()
            overlay.setPendingSystemCommand(nil)
        case .inputInterrupted:
            pendingActivation = nil
            systemCommands.inputWasInterrupted()
            overlay.setPendingSystemCommand(nil)
        case .escape:
            cancelHintMode()
        }
    }

    private func mutateSearchQuery(_ mutation: () -> Void) {
        let previousQuery = overlay.query
        mutation()
        guard overlay.query != previousQuery else { return }
        pendingActivation = nil
        systemCommands.queryDidChange(to: overlay.query)
        overlay.setPendingSystemCommand(systemCommands.pendingCommand)
    }

    private func executeSystemCommand(_ command: SystemCommand) {
        activatedDuringSession = true
        cancelHintMode(discardOverlay: true)
        systemCommandTask?.cancel()
        let id = UUID()
        systemCommandID = id
        systemCommandTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.systemCommandID == id {
                    self.systemCommandTask = nil
                    self.systemCommandID = nil
                }
            }
            do {
                try await self.systemCommands.execute(command)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                NSSound.beep()
                self.preferences.message = error.localizedDescription
            }
        }
    }

    private func scheduleHintRefresh(pid: pid_t) {
        scrollRefreshTask?.cancel()
        let id = UUID()
        scrollRefreshID = id
        scrollRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.scrollRefreshID == id {
                    self.scrollRefreshTask = nil
                    self.scrollRefreshID = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
                async let dockTargets = self.scanner.scanDockTargets()
                let scan = try await self.scanner.beginFocusedWindowScan(pid: pid)
                let mergedTargets = await withTaskCancellationHandler {
                    await scan.mergedTargetsTask.value
                } onCancel: {
                    scan.cancelSupplement()
                }
                guard !Task.isCancelled,
                      self.scrollRefreshID == id,
                      self.activeTargetPID == pid,
                      self.overlay.isPresented else {
                    return
                }
                self.replacePresentedTargets(
                    ScanResult(
                        windowFrame: scan.windowFrame,
                        targets: mergedTargets,
                        isComplete: scan.accessibilityIsComplete
                    ),
                    dockTargets: await dockTargets
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.scrollRefreshID == id else { return }
                self.preferences.message = error.localizedDescription
            }
        }
    }

    private func replacePresentedTargets(_ result: ScanResult, dockTargets: [ClickTarget]) {
        let elementAssignments = HintGenerator.assign(to: result.targets + dockTargets)
        let commandAssignments = WindowCommandCatalog.targets(windowFrame: result.windowFrame).map {
            HintAssignment(target: $0, code: "")
        }
        activeWindowFrame = result.windowFrame
        lastPresentation = (result, dockTargets)
        overlay.replaceAssignments(
            elementAssignments + commandAssignments,
            windowFrame: result.windowFrame
        )
    }

    private func activate(_ target: ClickTarget, kind: TargetActivator.Kind) {
        activatedDuringSession = true
        if let arrangement = target.windowArrangement,
           let pid = activeTargetPID {
            runWindowArrangement(arrangement, pid: pid)
            return
        }
        cancelHintMode(discardOverlay: true)
        TargetActivator.activate(target, kind: kind)
    }

    private func present(
        _ result: ScanResult,
        dockTargets: [ClickTarget],
        targetPID: pid_t
    ) {
        systemCommands.cancel()
        pendingActivation = nil
        overlay.setPendingSystemCommand(nil)
        let elementAssignments = HintGenerator.assign(to: result.targets + dockTargets)
        let commandAssignments = WindowCommandCatalog.targets(windowFrame: result.windowFrame).map {
            HintAssignment(target: $0, code: "")
        }
        let assignments = elementAssignments + commandAssignments
        overlay.show(assignments: assignments, windowFrame: result.windowFrame)
        guard overlay.isPresented else {
            NSSound.beep()
            return
        }
        activeTargetPID = targetPID
        activeWindowFrame = result.windowFrame
        activatedDuringSession = false
        lastPresentation = (result, dockTargets)
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
        scrollRefreshTask?.cancel()
        scrollRefreshTask = nil
        scrollRefreshID = nil
        input.stop()
        systemCommands.cancel()
        pendingActivation = nil
        overlay.setPendingSystemCommand(nil)
        if overlay.isPresented,
           let pid = activeTargetPID,
           let frame = activeWindowFrame,
           let shown = lastPresentation {
            overlaySessionSnapshot = OverlaySessionSnapshot(
                record: ScanSnapshotRecord(
                    pid: pid,
                    windowFrame: frame,
                    endedReadOnly: !activatedDuringSession,
                    capturedAt: .now
                ),
                result: shown.result,
                dockTargets: shown.dockTargets
            )
        }
        if discardOverlay {
            overlay.dismiss()
        } else {
            overlay.hide()
        }
        activeTargetPID = nil
        activeWindowFrame = nil
        restoreStatusIcon()
    }

    private func targetApplicationPID() -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ownPID {
            lastTargetPID = application.processIdentifier
            return application.processIdentifier
        }
        return lastTargetPID
    }

    private func restoreStatusIcon() {
        statusItem.button?.image = MenuIcon.makeIdleIcon()
    }
}
