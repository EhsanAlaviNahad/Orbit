import AppKit
import ApplicationServices

enum WindowArrangementError: LocalizedError {
    case accessibilityUnavailable
    case noFocusedWindow
    case noScreen
    case operationFailed
    case fullScreenUnavailable
    case fullScreenExitFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityUnavailable:
            "Accessibility permission is required before Orbit can arrange windows."
        case .noFocusedWindow:
            "No focused window was found to arrange."
        case .noScreen:
            "No display was found for the focused window."
        case .operationFailed:
            "The focused app did not allow Orbit to move or resize its window."
        case .fullScreenUnavailable:
            "The focused app does not support macOS full screen through Accessibility."
        case .fullScreenExitFailed:
            "The focused app did not finish leaving full screen. Try the arrangement again."
        }
    }
}

enum WindowArranger {
    @MainActor
    static func arrangeFocusedWindow(pid: pid_t, arrangement: WindowArrangement) async throws {
        guard PermissionCenter.accessibilityGranted else {
            throw WindowArrangementError.accessibilityUnavailable
        }

        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else {
            throw WindowArrangementError.noScreen
        }
        let primaryTop = primaryScreen.frame.maxY
        let visibleFrames = screens.map { screen in
            WindowGeometry.accessibilityFrame(
                from: screen.visibleFrame,
                primaryScreenTop: primaryTop
            )
        }

        let task = Task.detached(priority: .userInitiated) {
            try apply(pid: pid, arrangement: arrangement, visibleFrames: visibleFrames)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func apply(
        pid: pid_t,
        arrangement: WindowArrangement,
        visibleFrames: [CGRect]
    ) throws {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.40)
        enableEnhancedAccessibility(for: application)
        guard let window = focusedWindow(for: application) else {
            throw WindowArrangementError.noFocusedWindow
        }
        AXUIElementSetMessagingTimeout(window, 0.40)
        try Task.checkCancellation()

        // Prefer macOS Window menu commands. They honor system tiling gaps,
        // Stage Manager, display rules, and app-specific size constraints.
        if performNativeMenuCommand(application: application, arrangement: arrangement) {
            return
        }

        if arrangement == .fullScreen {
            guard enterFullScreen(window) else {
                throw WindowArrangementError.fullScreenUnavailable
            }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }

        try leaveFullScreenIfNeeded(window)
        try Task.checkCancellation()

        let currentFrame = elementFrame(window) ?? visibleFrames[0]
        guard let visibleFrame = WindowGeometry.bestVisibleFrame(
            for: currentFrame,
            in: visibleFrames
        ) else {
            throw WindowArrangementError.noScreen
        }
        let targetFrame = WindowGeometry.frame(
            for: arrangement,
            currentFrame: currentFrame,
            visibleFrame: visibleFrame
        )

        var size = targetFrame.size
        var position = targetFrame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else {
            throw WindowArrangementError.operationFailed
        }

        let sizeStatus = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue
        )
        let positionStatus = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        guard sizeStatus == .success, positionStatus == .success else {
            throw WindowArrangementError.operationFailed
        }

        // Some apps shift a window while applying size constraints. Reassert
        // the requested position after the resize has settled.
        _ = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func performNativeMenuCommand(
        application: AXUIElement,
        arrangement: WindowArrangement
    ) -> Bool {
        guard let menuBar: AXUIElement = attribute("AXMenuBar", from: application),
              let windowMenu = descendant(
                  titled: "Window",
                  roles: ["AXMenuBarItem"],
                  under: menuBar,
                  maximumDepth: 2
              ) else {
            return false
        }

        for title in nativeMenuTitles(for: arrangement) {
            guard let item = descendant(
                titled: title,
                roles: ["AXMenuItem"],
                under: windowMenu,
                maximumDepth: 5
            ) else {
                continue
            }
            let enabled: Bool = attribute(kAXEnabledAttribute as String, from: item) ?? true
            guard enabled else { continue }
            AXUIElementSetMessagingTimeout(item, 0.40)
            if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return false
    }

    private static func nativeMenuTitles(for arrangement: WindowArrangement) -> [String] {
        switch arrangement {
        case .tileLeft: ["Left"]
        case .tileRight: ["Right"]
        case .tileTop: ["Top"]
        case .tileBottom: ["Bottom"]
        case .center: ["Center", "Centre"]
        case .fill: ["Fill", "Maximize", "Maximise"]
        case .fullScreen: ["Enter Full Screen", "Full Screen", "Full Screen Tile"]
        }
    }

    private static func descendant(
        titled title: String,
        roles: Set<String>,
        under root: AXUIElement,
        maximumDepth: Int
    ) -> AXUIElement? {
        var pending: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var cursor = 0
        var visited: [CFHashCode: [AXUIElement]] = [:]

        while cursor < pending.count, pending.count <= 300 {
            let entry = pending[cursor]
            cursor += 1
            guard insertIdentity(entry.element, into: &visited) else { continue }

            let role: String = attribute(kAXRoleAttribute as String, from: entry.element) ?? ""
            let elementTitle: String = attribute(kAXTitleAttribute as String, from: entry.element) ?? ""
            if roles.contains(role), elementTitle == title {
                return entry.element
            }
            guard entry.depth < maximumDepth else { continue }
            let children: [AXUIElement] = attribute(kAXChildrenAttribute as String, from: entry.element) ?? []
            pending.append(contentsOf: children.map { ($0, entry.depth + 1) })
        }
        return nil
    }

    private static func insertIdentity(
        _ element: AXUIElement,
        into buckets: inout [CFHashCode: [AXUIElement]]
    ) -> Bool {
        let hash = CFHash(element)
        if buckets[hash]?.contains(where: { CFEqual($0, element) }) == true {
            return false
        }
        buckets[hash, default: []].append(element)
        return true
    }

    private static func enterFullScreen(_ window: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(
            window,
            "AXFullScreen" as CFString,
            kCFBooleanTrue
        ) == .success {
            return true
        }
        guard let button: AXUIElement = attribute("AXFullScreenButton", from: window) else {
            return false
        }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private static func leaveFullScreenIfNeeded(_ window: AXUIElement) throws {
        guard let isFullScreen: Bool = attribute("AXFullScreen", from: window),
              isFullScreen else {
            return
        }
        guard AXUIElementSetAttributeValue(
            window,
            "AXFullScreen" as CFString,
            kCFBooleanFalse
        ) == .success else {
            throw WindowArrangementError.fullScreenExitFailed
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if attribute("AXFullScreen", from: window) as Bool? == false {
                usleep(100_000)
                return
            }
            usleep(50_000)
        }
        throw WindowArrangementError.fullScreenExitFailed
    }

    private static func enableEnhancedAccessibility(for application: AXUIElement) {
        for attributeName in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            _ = AXUIElementSetAttributeValue(
                application,
                attributeName as CFString,
                kCFBooleanTrue
            )
        }
    }

    private static func focusedWindow(for application: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = attribute(kAXFocusedWindowAttribute as String, from: application) {
            return focused
        }
        if let main: AXUIElement = attribute(kAXMainWindowAttribute as String, from: application) {
            return main
        }
        if let focusedElement: AXUIElement = attribute(
            kAXFocusedUIElementAttribute as String,
            from: application
        ), let containingWindow: AXUIElement = attribute("AXWindow", from: focusedElement) {
            return containingWindow
        }
        let windows: [AXUIElement] = attribute(kAXWindowsAttribute as String, from: application) ?? []
        return windows.first(where: { elementFrame($0).map(TargetGeometry.isUsable) == true })
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(kAXPositionAttribute as String, from: element),
              let sizeValue: AXValue = attribute(kAXSizeAttribute as String, from: element) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        for attempt in 0..<2 {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if status == .success { return value as? T }
            guard status == .cannotComplete, attempt == 0 else { return nil }
            usleep(10_000)
        }
        return nil
    }
}
