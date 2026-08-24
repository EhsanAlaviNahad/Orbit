import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

enum ScanError: LocalizedError {
    case accessibilityUnavailable
    case noFocusedWindow

    var errorDescription: String? {
        switch self {
        case .accessibilityUnavailable:
            return "Accessibility permission is required before Eclick can scan controls."
        case .noFocusedWindow:
            return "No focused window was found."
        }
    }
}

struct ScanResult {
    let windowFrame: CGRect
    let targets: [ClickTarget]
    let isComplete: Bool
}

/// Two-stage focused-window scan. The accessibility stage resolves first and
/// is safe to present immediately; the merged stage folds in OCR targets once
/// the speculatively captured screenshot has been recognized.
struct FocusedWindowScan {
    let windowFrame: CGRect
    let accessibilityTargets: [ClickTarget]
    let accessibilityIsComplete: Bool
    /// Resolves to the full merged target list (accessibility + OCR). Always
    /// await through a cancellation handler that cancels this task.
    let mergedTargetsTask: Task<[ClickTarget], Never>

    func cancelSupplement() {
        mergedTargetsTask.cancel()
    }
}

final class TargetScanner: Sendable {
    private static let ocrFallbackTargetThreshold = 48

    private struct WindowContext: @unchecked Sendable {
        let pid: pid_t
        let title: String
        let frame: CGRect
        let element: AXUIElement
        let windowNumber: CGWindowID?
        let needsWarmRetry: Bool
    }

    private struct ElementSnapshot {
        let children: [AXUIElement]
        let role: String
        let enabled: Bool
        let hidden: Bool
        let frame: CGRect?
        let labelValues: [String]
        let value: String?
        let isReliable: Bool
    }

    private struct AccessibilityScan {
        let targets: [ClickTarget]
        let isComplete: Bool
    }

    private enum TraversalOrder: Equatable {
        case depthFirst
        case breadthFirst
    }

    func beginFocusedWindowScan(pid: pid_t) async throws -> FocusedWindowScan {
        guard PermissionCenter.accessibilityGranted else {
            throw ScanError.accessibilityUnavailable
        }

        let contextTask = Task.detached(priority: .userInitiated) {
            guard let context = Self.focusedWindow(pid: pid) else {
                throw ScanError.noFocusedWindow
            }
            return context
        }
        let context = try await withTaskCancellationHandler {
            try await contextTask.value
        } onCancel: {
            contextTask.cancel()
        }
        try Task.checkCancellation()

        let accessibilityTask = Task.detached(priority: .userInitiated) {
            Self.resilientAccessibilityTargets(
                in: context,
                skipWarmRetry: Self.recentlyWarmedTree(pid: pid, frame: context.frame)
            )
        }
        // The screenshot pipeline (shareable-content lookup, window matching,
        // capture) is slow and does not depend on accessibility results, so it
        // overlaps the AX traversal instead of running after it.
        let captureTask = Task.detached(priority: .userInitiated) { () -> CapturedWindow? in
            guard PermissionCenter.screenRecordingGranted else { return nil }
            return await Self.captureFocusedWindowImage(in: context)
        }
        return try await withTaskCancellationHandler {
            let accessibilityScan = await accessibilityTask.value
            Self.recordAccessibilityScanCompletion(pid: context.pid, frame: context.frame)
            try Task.checkCancellation()
            let mergedTargetsTask = Task.detached(priority: .userInitiated) { () -> [ClickTarget] in
                let ocrEligible = PermissionCenter.screenRecordingGranted
                    && (!accessibilityScan.isComplete
                        || accessibilityScan.targets.count < Self.ocrFallbackTargetThreshold)
                let ocrTargets: [ClickTarget]
                if ocrEligible {
                    ocrTargets = await Self.recognizeOCRTargets(
                        captureTask: captureTask,
                        in: context,
                        accurate: accessibilityScan.targets.isEmpty
                    )
                } else {
                    captureTask.cancel()
                    ocrTargets = []
                }
                if Task.isCancelled {
                    return accessibilityScan.targets
                }
                return TargetGeometry.merge(
                    accessibility: accessibilityScan.targets,
                    ocr: ocrTargets
                )
            }
            return FocusedWindowScan(
                windowFrame: context.frame,
                accessibilityTargets: accessibilityScan.targets,
                accessibilityIsComplete: accessibilityScan.isComplete,
                mergedTargetsTask: mergedTargetsTask
            )
        } onCancel: {
            accessibilityTask.cancel()
            captureTask.cancel()
        }
    }

    func scanDockTargets() async -> [ClickTarget] {
        guard PermissionCenter.accessibilityGranted,
              let pid = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.dock"
              ).first?.processIdentifier else {
            return []
        }
        let task = Task.detached(priority: .userInitiated) {
            Self.dockTargets(pid: pid)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Lightweight focused-window frame probe used to validate a cached
    /// overlay snapshot without running a full scan.
    func probeFocusedWindowFrame(pid: pid_t) async -> CGRect? {
        let task = Task.detached(priority: .userInitiated) {
            Self.quickFocusedWindowFrame(pid: pid)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func quickFocusedWindowFrame(pid: pid_t) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        let window: AXUIElement? =
            attribute(kAXFocusedWindowAttribute, from: appElement)
            ?? attribute(kAXMainWindowAttribute, from: appElement)
        guard let window else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.15)
        return elementFrame(window)
    }

    private static let recencyStateLock = NSLock()
    private nonisolated(unsafe) static var recentAccessibilityScanByPID:
        [pid_t: ScanSnapshotRecord] = [:]

    private static func recordAccessibilityScanCompletion(pid: pid_t, frame: CGRect) {
        recencyStateLock.lock()
        defer { recencyStateLock.unlock() }
        recentAccessibilityScanByPID[pid] = ScanSnapshotRecord(
            pid: pid,
            windowFrame: frame,
            endedReadOnly: false,
            capturedAt: .now
        )
    }

    private static func recentlyWarmedTree(pid: pid_t, frame: CGRect) -> Bool {
        recencyStateLock.lock()
        let lastScan = recentAccessibilityScanByPID[pid]
        recencyStateLock.unlock()
        return ScanRecencyPolicy.treeRecentlyWarmed(
            pid: pid,
            frame: frame,
            lastScan: lastScan,
            now: .now
        )
    }

    private static func dockTargets(pid: pid_t) -> [ClickTarget] {
        let root = AXUIElementCreateApplication(pid)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
        var pending = [root]
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var targets: [ClickTarget] = []
        var visitedCount = 0

        while let element = pending.popLast(),
              visitedCount < 1_000,
              ContinuousClock.now < deadline,
              !Task.isCancelled {
            AXUIElementSetMessagingTimeout(element, 0.10)
            guard insertIdentity(element, into: &visited) else { continue }
            visitedCount += 1
            for relationship in childRelationshipAttributes {
                let children: [AXUIElement] = attribute(relationship, from: element) ?? []
                pending.append(contentsOf: children)
            }

            let role: String = attribute(kAXRoleAttribute, from: element) ?? ""
            let subrole: String = attribute(kAXSubroleAttribute, from: element) ?? ""
            guard let frame = elementFrame(element) else { continue }
            let actions = actionNames(element).names
            guard DockTargetPolicy.isEligible(
                role: role,
                subrole: subrole,
                actions: actions,
                frame: frame
            ) else {
                continue
            }
            targets.append(ClickTarget(
                frame: frame,
                label: elementLabel(element),
                source: .dock,
                axElement: element,
                axAction: ActivationActionPolicy.preferredAction(from: actions)
            ))
        }
        return TargetGeometry.sortedTopLeft(TargetGeometry.deduplicated(targets))
    }

    private static func focusedWindow(pid: pid_t) -> WindowContext? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.40)
        let manuallyEnabled = enableEnhancedAccessibility(for: appElement)
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let needsWarmRetry = manuallyEnabled || warmRetryBundleIdentifiers.contains(bundleIdentifier)

        for attempt in 0..<3 {
            if let window = focusedWindowElement(for: appElement),
               let frame = elementFrame(window),
               frame.width > 1,
               frame.height > 1 {
                let title: String = attribute(kAXTitleAttribute, from: window) ?? ""
                let windowNumber: Int? = attribute("AXWindowNumber", from: window)
                AXUIElementSetMessagingTimeout(window, 0.20)
                return WindowContext(
                    pid: pid,
                    title: title,
                    frame: frame,
                    element: window,
                    windowNumber: windowNumber.map(CGWindowID.init),
                    needsWarmRetry: needsWarmRetry
                )
            }
            guard attempt < 2, !Task.isCancelled else { break }
            usleep(50_000)
        }
        return nil
    }

    private static func focusedWindowElement(for application: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = attribute(kAXFocusedWindowAttribute, from: application) {
            return focused
        }
        if let main: AXUIElement = attribute(kAXMainWindowAttribute, from: application) {
            return main
        }
        if let focusedElement: AXUIElement = attribute(
            kAXFocusedUIElementAttribute,
            from: application
        ), let containingWindow: AXUIElement = attribute("AXWindow", from: focusedElement) {
            return containingWindow
        }
        let windows: [AXUIElement] = attribute(kAXWindowsAttribute, from: application) ?? []
        return windows.first(where: { elementFrame($0).map(TargetGeometry.isUsable) == true })
    }

    private static func enableEnhancedAccessibility(for application: AXUIElement) -> Bool {
        let manualStatus = AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            application,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        return manualStatus == .success
    }

    private static func resilientAccessibilityTargets(
        in context: WindowContext,
        skipWarmRetry: Bool
    ) -> AccessibilityScan {
        let first = accessibilityTargets(in: context, order: .depthFirst)
        guard !Task.isCancelled else { return first }
        guard !skipWarmRetry,
              context.needsWarmRetry || !first.isComplete || first.targets.count < 12 else {
            return first
        }

        // Electron, Safari, and Finder can expose a cold or lazy tree on the
        // first request. A differently ordered second pass both warms the tree
        // and covers branches the first time budget may not have reached.
        let second = accessibilityTargets(in: context, order: .breadthFirst)
        return AccessibilityScan(
            targets: TargetGeometry.deduplicated(first.targets + second.targets),
            isComplete: second.isComplete
        )
    }

    private static func accessibilityTargets(
        in context: WindowContext,
        order: TraversalOrder
    ) -> AccessibilityScan {
        let maximumNodeCount = 12_000
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1_250))
        var pending: [AXUIElement] = [context.element]
        var cursor = 0
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var enqueued: [CFHashCode: [AXUIElement]] = [:]
        var targets: [ClickTarget] = []
        var enqueuedCount = 1
        var hitNodeLimit = false
        var encounteredReadFailure = false
        _ = insertIdentity(context.element, into: &enqueued)

        while ContinuousClock.now < deadline, !Task.isCancelled {
            let nextElement: AXUIElement?
            switch order {
            case .depthFirst:
                nextElement = pending.popLast()
            case .breadthFirst:
                if cursor < pending.count {
                    nextElement = pending[cursor]
                    cursor += 1
                } else {
                    nextElement = nil
                }
            }
            guard let element = nextElement else { break }
            AXUIElementSetMessagingTimeout(element, 0.15)
            guard insertIdentity(element, into: &visited) else { continue }

            let snapshot = elementSnapshot(element, deadline: deadline)
            if !snapshot.isReliable { encounteredReadFailure = true }

            var children = snapshot.children
            if alternateChildRelationshipRoles.contains(snapshot.role) {
                // Finder, Safari, and Electron may expose useful rows or visible
                // controls alongside AXChildren rather than instead of it.
                for relationship in childRelationshipAttributes.dropFirst() {
                    guard ContinuousClock.now < deadline else { break }
                    let relationshipRead: (value: [AXUIElement]?, transientFailure: Bool) =
                        attributeResult(relationship, from: element)
                    if relationshipRead.transientFailure { encounteredReadFailure = true }
                    guard let relatedChildren = relationshipRead.value else {
                        continue
                    }
                    children.append(contentsOf: relatedChildren)
                }
            }
            let orderedChildren = order == .depthFirst ? Array(children.reversed()) : children
            for child in orderedChildren {
                guard enqueuedCount < maximumNodeCount else {
                    hitNodeLimit = true
                    break
                }
                if insertIdentity(child, into: &enqueued) {
                    pending.append(child)
                    enqueuedCount += 1
                }
            }

            guard ContinuousClock.now < deadline else { break }
            guard snapshot.enabled, !snapshot.hidden else { continue }
            guard let frame = snapshot.frame,
                  frame.width >= 4,
                  frame.height >= 4,
                  frame.intersects(context.frame) else {
                continue
            }
            let roleIsInteractive = interactiveRoles.contains(snapshot.role)
            let actionRead = actionNames(element)
            if actionRead.transientFailure { encounteredReadFailure = true }
            guard ContinuousClock.now < deadline else { break }
            guard roleIsInteractive
                    || actionRead.names.contains(where: ActivationActionPolicy.supportedActions.contains) else {
                continue
            }
            let label = elementLabel(from: snapshot)

            targets.append(ClickTarget(
                id: UUID(),
                frame: frame.intersection(context.frame),
                label: label,
                source: .accessibility,
                axElement: element,
                axAction: ActivationActionPolicy.preferredAction(from: actionRead.names)
            ))
        }

        let exhausted: Bool
        switch order {
        case .depthFirst:
            exhausted = pending.isEmpty
        case .breadthFirst:
            exhausted = cursor >= pending.count
        }
        return AccessibilityScan(
            targets: TargetGeometry.deduplicated(targets),
            isComplete: exhausted
                && !hitNodeLimit
                && !encounteredReadFailure
                && ContinuousClock.now < deadline
                && !Task.isCancelled
        )
    }

    private static func elementSnapshot(
        _ element: AXUIElement,
        deadline: ContinuousClock.Instant
    ) -> ElementSnapshot {
        let keys = snapshotAttributeKeys
        var rawValues: CFArray?
        var status = AXError.failure
        for attempt in 0..<2 where ContinuousClock.now < deadline {
            status = AXUIElementCopyMultipleAttributeValues(
                element,
                keys as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0),
                &rawValues
            )
            if status == .success { break }
            guard status == .cannotComplete, attempt == 0 else { break }
            usleep(5_000)
        }
        guard status == .success,
              let values = rawValues as? [Any],
              values.count == keys.count else {
            return individualElementSnapshot(
                element,
                deadline: deadline,
                initiallyReliable: status != .cannotComplete
            )
        }

        let children = values[0] as? [AXUIElement] ?? []
        let role = values[1] as? String ?? ""
        let position = axValue(values[4])
        let size = axValue(values[5])
        return ElementSnapshot(
            children: children,
            role: role,
            enabled: values[2] as? Bool ?? true,
            hidden: values[3] as? Bool ?? false,
            frame: frame(position: position, size: size),
            labelValues: values[6...11].compactMap { $0 as? String },
            value: values[12] as? String,
            isReliable: !role.isEmpty
                && (!alternateChildRelationshipRoles.contains(role)
                    || values[0] is [AXUIElement])
        )
    }

    private static func individualElementSnapshot(
        _ element: AXUIElement,
        deadline: ContinuousClock.Instant,
        initiallyReliable: Bool
    ) -> ElementSnapshot {
        var isReliable = initiallyReliable
        func read<T>(_ name: String) -> T? {
            guard ContinuousClock.now < deadline else { return nil }
            let result: (value: T?, transientFailure: Bool) = attributeResult(name, from: element)
            if result.transientFailure { isReliable = false }
            return result.value
        }
        let position: AXValue? = read(kAXPositionAttribute as String)
        let size: AXValue? = read(kAXSizeAttribute as String)
        return ElementSnapshot(
            children: read(kAXChildrenAttribute as String) ?? [],
            role: read(kAXRoleAttribute as String) ?? "",
            enabled: read(kAXEnabledAttribute as String) ?? true,
            hidden: read(kAXHiddenAttribute as String) ?? false,
            frame: frame(position: position, size: size),
            labelValues: snapshotLabelKeys.compactMap { key in
                read(key) as String?
            },
            value: read(kAXValueAttribute as String),
            isReliable: isReliable
        )
    }

    private static func frame(position: AXValue?, size: AXValue?) -> CGRect? {
        guard let position, let size else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else {
            return nil
        }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func axValue(_ value: Any) -> AXValue? {
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(object, to: AXValue.self)
    }

    private static func elementLabel(from snapshot: ElementSnapshot) -> String {
        var components: [String] = []
        for value in snapshot.labelValues {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               trimmed.count <= 200,
               !components.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                components.append(trimmed)
            }
        }
        if !["AXTextArea", "AXTextField", "AXSearchField"].contains(snapshot.role),
           let value = snapshot.value {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               trimmed.count <= 200,
               !components.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                components.append(trimmed)
            }
        }
        return components.isEmpty ? "Control" : components.joined(separator: " ")
    }

    private static let snapshotLabelKeys = [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXHelpAttribute as String,
        "AXIdentifier",
        "AXPlaceholderValue",
        kAXRoleDescriptionAttribute as String
    ]

    private static let snapshotAttributeKeys = [
        kAXChildrenAttribute as String,
        kAXRoleAttribute as String,
        kAXEnabledAttribute as String,
        kAXHiddenAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String
    ] + snapshotLabelKeys + [kAXValueAttribute as String]

    private struct CapturedWindow {
        let image: CGImage
        let frame: CGRect
    }

    /// Slow capture half of OCR: shareable-content lookup, window matching,
    /// and the screenshot itself. No Vision work happens here.
    private static func captureFocusedWindowImage(
        in context: WindowContext
    ) async -> CapturedWindow? {
        guard !Task.isCancelled else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else {
            return nil
        }
        let candidates = content.windows.filter { $0.owningApplication?.processID == context.pid }
        let exactWindow = context.windowNumber.flatMap { number in
            candidates.first(where: { $0.windowID == number })
        }
        guard let window = exactWindow ?? candidates.max(by: {
            windowMatchScore($0, context: context) < windowMatchScore($1, context: context)
        }), window.frame.intersects(context.frame) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let sourceArea = max(1, window.frame.width * window.frame.height)
        let maximumPixelArea: CGFloat = 8_000_000
        let captureScale = min(2, sqrt(maximumPixelArea / sourceArea))
        configuration.width = max(1, Int(window.frame.width * captureScale))
        configuration.height = max(1, Int(window.frame.height * captureScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else { return nil }
        return CapturedWindow(image: image, frame: window.frame)
    }

    /// Fast recognition half of OCR: awaits the speculatively captured image,
    /// then runs Vision text recognition over it.
    private static func recognizeOCRTargets(
        captureTask: Task<CapturedWindow?, Never>,
        in context: WindowContext,
        accurate: Bool
    ) async -> [ClickTarget] {
        let capture = await captureTask.value
        guard !Task.isCancelled, let capture else { return [] }
        let windowFrame = capture.frame

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        let handler = VNImageRequestHandler(cgImage: capture.image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard !Task.isCancelled else { return [] }

        return (request.results ?? [])
            .sorted(by: { $0.confidence > $1.confidence })
            .prefix(250)
            .compactMap { observation in
            guard observation.confidence >= 0.55,
                  let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let box = observation.boundingBox
            let frame = CGRect(
                x: windowFrame.minX + box.minX * windowFrame.width,
                y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
                width: box.width * windowFrame.width,
                height: box.height * windowFrame.height
            ).intersection(context.frame)
            guard frame.width >= 8, frame.height >= 6 else { return nil }
            return ClickTarget(
                id: UUID(),
                frame: frame,
                label: candidate.string,
                source: .ocr,
                axElement: nil,
                axAction: nil
            )
        }
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        let enabled: Bool? = attribute(kAXEnabledAttribute, from: element)
        return enabled ?? true
    }

    private static func isHidden(_ element: AXUIElement) -> Bool {
        let hidden: Bool? = attribute(kAXHiddenAttribute, from: element)
        return hidden ?? false
    }

    private static func isInteractive(_ element: AXUIElement, actions: [String]) -> Bool {
        if actions.contains(where: ActivationActionPolicy.supportedActions.contains) {
            return true
        }
        let role: String = attribute(kAXRoleAttribute, from: element) ?? ""
        return interactiveRoles.contains(role)
    }

    private static func actionNames(
        _ element: AXUIElement
    ) -> (names: [String], transientFailure: Bool) {
        for attempt in 0..<2 {
            var value: CFArray?
            let status = AXUIElementCopyActionNames(element, &value)
            if status == .success { return (value as? [String] ?? [], false) }
            guard status == .cannotComplete, attempt == 0 else {
                return ([], status == .cannotComplete)
            }
            usleep(5_000)
        }
        return ([], true)
    }

    private static let childRelationshipAttributes = [
        kAXChildrenAttribute as String,
        "AXVisibleChildren",
        "AXContents",
        "AXRows",
        "AXColumns",
        "AXTabs",
        "AXChildrenInNavigationOrder"
    ]

    private static let warmRetryBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.Safari",
        "com.hnc.Discord",
        "ph.telegra.Telegraph",
        "ru.keepcoder.Telegram"
    ]

    private static let alternateChildRelationshipRoles: Set<String> = [
        "AXWindow",
        "AXWebArea",
        "AXGroup",
        "AXScrollArea",
        "AXList",
        "AXBrowser",
        "AXRow",
        "AXTable",
        "AXOutline",
        "AXToolbar",
        "AXTabGroup",
        "AXSplitGroup",
        "AXSheet",
        "AXPopover"
    ]

    private static let interactiveRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXCheckBox",
        "AXRadioButton",
        "AXMenuButton",
        "AXPopUpButton",
        "AXMenuItem",
        "AXDisclosureTriangle",
        "AXTab",
        "AXCell",
        "AXRow",
        "AXListItem",
        "AXOutlineRow",
        "AXTableRow",
        "AXToolbarItem",
        "AXScrollBar",
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox",
        "AXSlider",
        "AXIncrementor",
        "AXColorWell",
        "AXDateField",
        "AXSwitch",
        "AXToggle"
    ]

    private static func elementLabel(
        _ element: AXUIElement,
        deadline: ContinuousClock.Instant? = nil
    ) -> String {
        let keys = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            "AXIdentifier",
            "AXPlaceholderValue",
            kAXRoleDescriptionAttribute as String
        ]
        var components: [String] = []
        for key in keys {
            guard deadline.map({ ContinuousClock.now < $0 }) ?? true else { break }
            if let value: String = attribute(key, from: element) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty,
                   trimmed.count <= 200,
                   !components.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    components.append(trimmed)
                }
            }
        }
        let role: String
        if deadline.map({ ContinuousClock.now < $0 }) ?? true {
            role = attribute(kAXRoleAttribute, from: element) ?? ""
        } else {
            role = ""
        }
        if deadline.map({ ContinuousClock.now < $0 }) ?? true,
           !["AXTextArea", "AXTextField", "AXSearchField"].contains(role),
           let value: String = attribute(kAXValueAttribute, from: element) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               trimmed.count <= 200,
               !components.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                components.append(trimmed)
            }
        }
        return components.isEmpty ? "Control" : components.joined(separator: " ")
    }

    private static func elementFrame(
        _ element: AXUIElement,
        deadline: ContinuousClock.Instant? = nil
    ) -> CGRect? {
        guard deadline.map({ ContinuousClock.now < $0 }) ?? true,
              let positionValue: AXValue = attribute(kAXPositionAttribute, from: element),
              deadline.map({ ContinuousClock.now < $0 }) ?? true,
              let sizeValue: AXValue = attribute(kAXSizeAttribute, from: element) else {
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
        let result: (value: T?, transientFailure: Bool) = attributeResult(name, from: element)
        return result.value
    }

    private static func attributeResult<T>(
        _ name: String,
        from element: AXUIElement
    ) -> (value: T?, transientFailure: Bool) {
        for attempt in 0..<2 {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if status == .success { return (value as? T, false) }
            guard status == .cannotComplete, attempt == 0 else {
                return (nil, status == .cannotComplete)
            }
            usleep(5_000)
        }
        return (nil, true)
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

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func windowMatchScore(_ window: SCWindow, context: WindowContext) -> CGFloat {
        let intersection = intersectionArea(window.frame, context.frame)
        let union = window.frame.width * window.frame.height
            + context.frame.width * context.frame.height
            - intersection
        let overlapScore = union > 0 ? intersection / union : 0
        let titleScore: CGFloat = !context.title.isEmpty && window.title == context.title ? 2 : 0
        let frameDelta = abs(window.frame.minX - context.frame.minX)
            + abs(window.frame.minY - context.frame.minY)
            + abs(window.frame.width - context.frame.width)
            + abs(window.frame.height - context.frame.height)
        return titleScore + overlapScore - min(frameDelta / 10_000, 1)
    }
}

enum TargetActivator {
    enum Kind {
        case singleClick
        case doubleClick
        case rightClick
    }

    static func activate(_ target: ClickTarget, kind: Kind = .singleClick) {
        Task.detached(priority: .userInitiated) {
            if kind == .singleClick,
               let element = target.axElement,
               let action = target.axAction {
                AXUIElementSetMessagingTimeout(element, 0.20)
                for attempt in 0..<2 {
                    let status = AXUIElementPerformAction(element, action as CFString)
                    if status == .success { return }
                    guard status == .cannotComplete, attempt == 0 else { break }
                    usleep(10_000)
                }
            }

            let point = target.clickPoint
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            switch kind {
            case .singleClick:
                postClick(at: point, button: .left, down: .leftMouseDown, up: .leftMouseUp)
            case .doubleClick:
                postClick(at: point, button: .left, down: .leftMouseDown, up: .leftMouseUp, count: 1)
                postClick(at: point, button: .left, down: .leftMouseDown, up: .leftMouseUp, count: 2)
            case .rightClick:
                postClick(at: point, button: .right, down: .rightMouseDown, up: .rightMouseUp)
            }
        }
    }

    private static func postClick(
        at point: CGPoint,
        button: CGMouseButton,
        down: CGEventType,
        up: CGEventType,
        count: Int64 = 1
    ) {
        let downEvent = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)
        downEvent?.setIntegerValueField(.mouseEventClickState, value: count)
        downEvent?.post(tap: .cghidEventTap)
        let upEvent = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)
        upEvent?.setIntegerValueField(.mouseEventClickState, value: count)
        upEvent?.post(tap: .cghidEventTap)
    }
}
