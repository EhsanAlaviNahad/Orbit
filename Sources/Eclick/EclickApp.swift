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
    private let keepAwake = KeepAwakeManager()
    private let statusMenu = NSMenu()
    private var keepAwakeMenuItem: NSMenuItem?
    private var restoreBatterySleepMenuItem: NSMenuItem?
    private var enableLidPreventionMenuItem: NSMenuItem?
    private var isScanningStatusBar = false
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
    private var keepAwakeConfigurationTask: Task<Void, Never>?
    private var isBatteryLidCloseAuthorizationInFlight = false
    private var requiresBatteryLidCloseSettlement = false
    private static let lidGrantDeclinedKey = "keepAwake.lidGrantDeclined"
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
        // Restore remembered keep-awake state from the previous session.
        if preferences.keepAwakePreferred {
            _ = keepAwake.activate()
            updateStatusIcon()
        }
        keepAwake.startPowerSourceMonitoring { [weak self] in
            self?.refreshBatteryLidClosePrevention()
        }
        refreshBatteryLidClosePrevention(staleRevertCheck: true)
    }

    func shutdown() {
        cancelHintMode()
        input.shutdown()
        keepAwake.stopPowerSourceMonitoring()
        keepAwake.deactivate()
        keepAwakeConfigurationTask?.cancel()
        keepAwakeConfigurationTask = nil
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
        window.title = "Eclick Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
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
            // Left click toggles keep-awake; right click opens the menu.
            button.target = self
            button.action = #selector(statusItemButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let activate = NSMenuItem(
            title: "Show Hints (\(preferences.shortcut.displayName))",
            action: #selector(toggleHintModeFromMenu),
            keyEquivalent: ""
        )
        activate.target = self
        activateMenuItem = activate
        statusMenu.addItem(activate)
        statusMenu.addItem(.separator())

        let keepAwakeItem = NSMenuItem(
            title: "Keep Awake",
            action: #selector(toggleKeepAwakeFromMenu),
            keyEquivalent: ""
        )
        keepAwakeItem.target = self
        keepAwakeMenuItem = keepAwakeItem
        refreshKeepAwakeMenuItem()
        statusMenu.addItem(keepAwakeItem)

        let restoreBatterySleepItem = NSMenuItem(
            title: "Restore Default Battery Sleep",
            action: #selector(restoreDefaultBatterySleepFromMenu),
            keyEquivalent: ""
        )
        restoreBatterySleepItem.target = self
        restoreBatterySleepItem.isHidden = true
        restoreBatterySleepMenuItem = restoreBatterySleepItem
        statusMenu.addItem(restoreBatterySleepItem)

        let enableLidPreventionItem = NSMenuItem(
            title: "Enable Lid-Closed Awake on Battery…",
            action: #selector(enableLidPreventionFromMenu),
            keyEquivalent: ""
        )
        enableLidPreventionItem.target = self
        enableLidPreventionItem.isHidden = true
        enableLidPreventionMenuItem = enableLidPreventionItem
        statusMenu.addItem(enableLidPreventionItem)
        statusMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        statusMenu.addItem(settings)

        let about = NSMenuItem(
            title: "About Eclick",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        statusMenu.addItem(about)
        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Eclick",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
        updateStatusIcon()
    }

    @objc private func statusItemButtonClicked() {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp else {
            toggleKeepAwake()
            return
        }
        showStatusMenu()
    }

    private func showStatusMenu() {
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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
        guard let targetPID = targetApplicationPID() else {
            NSSound.beep()
            return
        }

        systemCommands.cancel()
        pendingActivation = nil

        let id = UUID()
        scanID = id
        isScanningStatusBar = true
        updateStatusIcon()
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
            PageScroller.scroll(direction, at: CGPoint(
                x: activeWindowFrame.midX,
                y: activeWindowFrame.midY
            ))
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

    @objc private func toggleKeepAwakeFromMenu() {
        toggleKeepAwake()
    }

    func toggleKeepAwake() {
        setKeepAwake(!keepAwake.isActive)
    }

    private func setKeepAwake(_ enabled: Bool) {
        guard enabled != keepAwake.isActive else { return }
        if enabled {
            guard keepAwake.activate() else {
                NSSound.beep()
                preferences.message = "macOS refused the keep-awake power assertions."
                return
            }
        } else {
            keepAwake.deactivate()
        }
        preferences.setKeepAwakePreferred(enabled)
        updateStatusIcon()
        if enabled {
            configureBatteryLidForActiveSession()
        } else {
            settleBatteryLidClosePreventionAfterCancellation()
            revertBatteryLidAfterToggleOff()
        }
    }

    private func refreshBatteryLidClosePrevention(staleRevertCheck: Bool = false) {
        if isBatteryLidCloseAuthorizationInFlight {
            requiresBatteryLidCloseSettlement = true
        }
        let previousTask = keepAwakeConfigurationTask
        previousTask?.cancel()
        keepAwakeConfigurationTask = Task { [weak self, previousTask] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            let state = await self.keepAwake.refreshBatteryLidClosePrevention()
            guard !Task.isCancelled else { return }
            self.reconcileBatteryLidClosePrevention(state)
            if staleRevertCheck {
                // A previous session may have enabled the persistent setting
                // and then crashed or been killed before reverting it. Heal
                // silently when the one-time grant allows it.
                guard !self.keepAwake.isActive,
                      !self.preferences.keepAwakePreferred,
                      state == true else {
                    return
                }
                if KeepAwakeManager.hasPasswordlessLidGrant() {
                    try? await self.keepAwake.disableBatteryLidClosePrevention()
                }
                self.updateStatusIcon()
            }
        }
    }

    private func settleBatteryLidClosePreventionAfterCancellation() {
        if isBatteryLidCloseAuthorizationInFlight {
            requiresBatteryLidCloseSettlement = true
        }
        let previousTask = keepAwakeConfigurationTask
        previousTask?.cancel()
        keepAwakeConfigurationTask = Task { [weak self, previousTask] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            let state = await self.keepAwake.refreshBatteryLidClosePrevention()
            guard !Task.isCancelled else { return }
            self.reconcileBatteryLidClosePrevention(state)
        }
    }

    private func reconcileBatteryLidClosePrevention(_ state: Bool?) {
        updateStatusIcon()
        guard requiresBatteryLidCloseSettlement else { return }
        guard state != nil else {
            presentBatteryLidCloseError(
                title: "Could Not Verify Battery Sleep Setting",
                message: "A pending change was cancelled, but Eclick could not verify the result. The battery sleep setting may be enabled. Check pmset -g or restore the default with: sudo pmset -b disablesleep 0"
            )
            return
        }
        requiresBatteryLidCloseSettlement = false
    }

    private func configureBatteryLidForActiveSession() {
        guard keepAwake.isActive,
              KeepAwakeManager.currentPowerSource() == .battery else { return }
        let previousTask = keepAwakeConfigurationTask
        previousTask?.cancel()
        keepAwakeConfigurationTask = Task { [weak self, previousTask] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            let state = await self.keepAwake.refreshBatteryLidClosePrevention()
            guard !Task.isCancelled else { return }
            self.reconcileBatteryLidClosePrevention(state)
            guard self.keepAwake.isActive, state == false else {
                self.updateStatusIcon()
                return
            }
            // Without the grant the OS admin sheet itself is the one-time
            // consent (same flow as comparable lid-awake utilities). If the
            // user cancels it, never nag again — a menu row stays available.
            if !KeepAwakeManager.hasPasswordlessLidGrant(),
               UserDefaults.standard.bool(forKey: Self.lidGrantDeclinedKey) {
                self.updateStatusIcon()
                return
            }
            do {
                try await self.keepAwake.enableBatteryLidClosePrevention()
                UserDefaults.standard.set(false, forKey: Self.lidGrantDeclinedKey)
            } catch is CancellationError {
                UserDefaults.standard.set(true, forKey: Self.lidGrantDeclinedKey)
            } catch {
                self.presentBatteryLidCloseError(
                    title: "Could Not Enable Lid-Closed Keep Awake",
                    message: error.localizedDescription
                )
            }
            self.updateStatusIcon()
        }
    }

    private func revertBatteryLidAfterToggleOff() {
        let previousTask = keepAwakeConfigurationTask
        previousTask?.cancel()
        keepAwakeConfigurationTask = Task { [weak self, previousTask] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            let state = await self.keepAwake.refreshBatteryLidClosePrevention()
            guard !Task.isCancelled else { return }
            self.reconcileBatteryLidClosePrevention(state)
            guard !self.keepAwake.isActive, state == true else {
                self.updateStatusIcon()
                return
            }
            // Silent with the one-time grant; otherwise a single password prompt.
            do {
                try await self.keepAwake.disableBatteryLidClosePrevention()
            } catch is CancellationError {
                return
            } catch {
                self.presentBatteryLidCloseError(
                    title: "Could Not Restore Battery Sleep",
                    message: error.localizedDescription
                )
            }
            self.updateStatusIcon()
        }
    }

    @objc private func restoreDefaultBatterySleepFromMenu() {
        revertBatteryLidAfterToggleOff()
    }

    @objc private func enableLidPreventionFromMenu() {
        UserDefaults.standard.set(false, forKey: Self.lidGrantDeclinedKey)
        configureBatteryLidForActiveSession()
    }

    private func presentBatteryLidCloseError(title: String, message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func refreshKeepAwakeMenuItem() {
        guard let keepAwakeMenuItem else { return }
        keepAwakeMenuItem.state = keepAwake.isActive ? .on : .off
        let staleLidState = keepAwake.batteryLidClosePreventionEnabled == true
            && !keepAwake.isActive
            && !preferences.keepAwakePreferred
        restoreBatterySleepMenuItem?.isHidden = !staleLidState
        let canOfferLidSetup = keepAwake.isActive
            && KeepAwakeManager.currentPowerSource() == .battery
            && keepAwake.batteryLidClosePreventionEnabled == false
            && !KeepAwakeManager.hasPasswordlessLidGrant()
        enableLidPreventionMenuItem?.isHidden = !canOfferLidSetup
        if !keepAwake.isActive,
           keepAwake.batteryLidClosePreventionEnabled == true {
            keepAwakeMenuItem.subtitle = "Battery lid-close sleep disabled system-wide"
        } else if keepAwake.isActive, !keepAwake.lidClosePreventionAvailable {
            keepAwakeMenuItem.subtitle = "Lid close still sleeps on battery"
        } else if keepAwake.isActive,
                  KeepAwakeManager.currentPowerSource() == .battery {
            keepAwakeMenuItem.subtitle = "Lid-closed battery mode enabled — keep out of bags"
        } else {
            keepAwakeMenuItem.subtitle = nil
        }
    }

    private func updateStatusIcon() {
        refreshKeepAwakeMenuItem()
        guard let button = statusItem.button else { return }
        if isScanningStatusBar {
            button.image = NSImage(
                systemSymbolName: "viewfinder",
                accessibilityDescription: "Eclick is scanning"
            )
            button.toolTip = "Eclick — scanning focused window"
        } else if keepAwake.isActive {
            let lidSupported = keepAwake.lidClosePreventionAvailable
            button.image = NSImage(
                systemSymbolName: lidSupported ? "cup.and.saucer.fill" : "cup.and.saucer",
                accessibilityDescription: lidSupported
                    ? "Eclick is keeping your Mac awake"
                    : "Eclick is keeping your Mac awake — connect power for lid-close prevention"
            )
            button.toolTip = lidSupported
                ? "Eclick — keeping Mac awake, lid close included. Keep out of bags. Click to stop."
                : "Eclick — keeping Mac awake. Lid close still sleeps on battery. Click to stop."
        } else {
            button.image = NSImage(
                systemSymbolName: "cursorarrow.click",
                accessibilityDescription: "Eclick"
            )
            if keepAwake.batteryLidClosePreventionEnabled == true {
                button.toolTip = "Eclick — battery lid-close sleep is disabled system-wide. Keep out of bags."
            } else {
                button.toolTip = "Eclick — keyboard hints for clickable controls"
            }
        }
    }

    private func restoreStatusIcon() {
        isScanningStatusBar = false
        updateStatusIcon()
    }
}
