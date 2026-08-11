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
}

final class TargetScanner: Sendable {
    private struct WindowContext: @unchecked Sendable {
        let pid: pid_t
        let title: String
        let frame: CGRect
        let element: AXUIElement
        let windowNumber: CGWindowID?
    }

    func scanFocusedWindow(pid: pid_t) async throws -> ScanResult {
        guard PermissionCenter.accessibilityGranted else {
            throw ScanError.accessibilityUnavailable
        }

        let context = try await Task.detached(priority: .userInitiated) {
            guard let context = Self.focusedWindow(pid: pid) else {
                throw ScanError.noFocusedWindow
            }
            return context
        }.value

        let accessibilityTask = Task.detached(priority: .userInitiated) {
            Self.accessibilityTargets(in: context)
        }
        let ocrTask = Task(priority: .userInitiated) {
            guard PermissionCenter.screenRecordingGranted else { return [ClickTarget]() }
            return (try? await Self.ocrTargets(in: context)) ?? []
        }
        return try await withTaskCancellationHandler {
            let accessibilityTargets = await accessibilityTask.value
            let ocrTargets = await ocrTask.value
            try Task.checkCancellation()
            return ScanResult(
                windowFrame: context.frame,
                targets: TargetGeometry.merge(
                    accessibility: accessibilityTargets,
                    ocr: ocrTargets
                )
            )
        } onCancel: {
            accessibilityTask.cancel()
            ocrTask.cancel()
        }
    }

    private static func focusedWindow(pid: pid_t) -> WindowContext? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let window: AXUIElement = attribute(kAXFocusedWindowAttribute, from: appElement),
              let frame = elementFrame(window),
              frame.width > 1,
              frame.height > 1 else {
            return nil
        }
        let title: String = attribute(kAXTitleAttribute, from: window) ?? ""
        let windowNumber: Int? = attribute("AXWindowNumber", from: window)
        AXUIElementSetMessagingTimeout(window, 0.25)
        return WindowContext(
            pid: pid,
            title: title,
            frame: frame,
            element: window,
            windowNumber: windowNumber.map(CGWindowID.init)
        )
    }

    private static func accessibilityTargets(in context: WindowContext) -> [ClickTarget] {
        let maximumNodeCount = 12_000
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var queue: [AXUIElement] = [context.element]
        var cursor = 0
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var enqueued: [CFHashCode: [AXUIElement]] = [:]
        var targets: [ClickTarget] = []
        _ = insertIdentity(context.element, into: &enqueued)

        while cursor < queue.count,
              cursor < maximumNodeCount,
              ContinuousClock.now < deadline,
              !Task.isCancelled {
            let element = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.20)
            guard insertIdentity(element, into: &visited) else { continue }

            for relationship in childRelationshipAttributes {
                guard ContinuousClock.now < deadline else { break }
                guard let children: [AXUIElement] = attribute(relationship, from: element) else {
                    continue
                }
                for child in children where queue.count < maximumNodeCount {
                    if insertIdentity(child, into: &enqueued) {
                        queue.append(child)
                    }
                }
            }

            guard ContinuousClock.now < deadline else { break }
            let actions = actionNames(element)
            guard ContinuousClock.now < deadline else { break }
            guard isEnabled(element) else { continue }
            guard ContinuousClock.now < deadline else { break }
            guard !isHidden(element) else { continue }
            guard ContinuousClock.now < deadline else { break }
            guard let frame = elementFrame(element, deadline: deadline),
                  frame.width >= 4,
                  frame.height >= 4,
                  frame.intersects(context.frame) else {
                continue
            }
            guard ContinuousClock.now < deadline else { break }
            guard isInteractive(element, actions: actions) else { continue }
            guard ContinuousClock.now < deadline else { break }
            let label = elementLabel(element, deadline: deadline)
            guard ContinuousClock.now < deadline else { break }

            targets.append(ClickTarget(
                id: UUID(),
                frame: frame.intersection(context.frame),
                label: label,
                source: .accessibility,
                axElement: element,
                axAction: preferredAction(from: actions)
            ))
        }

        return TargetGeometry.deduplicated(targets)
    }

    private static func ocrTargets(in context: WindowContext) async throws -> [ClickTarget] {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let candidates = content.windows.filter { $0.owningApplication?.processID == context.pid }
        let exactWindow = context.windowNumber.flatMap { number in
            candidates.first(where: { $0.windowID == number })
        }
        guard let window = exactWindow ?? candidates.max(by: {
            windowMatchScore($0, context: context) < windowMatchScore($1, context: context)
        }), window.frame.intersects(context.frame) else {
            return []
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * 2))
        configuration.height = max(1, Int(window.frame.height * 2))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        try Task.checkCancellation()

        return (request.results ?? []).compactMap { observation in
            guard observation.confidence >= 0.55,
                  let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let box = observation.boundingBox
            let frame = CGRect(
                x: window.frame.minX + box.minX * window.frame.width,
                y: window.frame.minY + (1 - box.maxY) * window.frame.height,
                width: box.width * window.frame.width,
                height: box.height * window.frame.height
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
        if actions.contains(where: actionableActions.contains) {
            return true
        }
        let role: String = attribute(kAXRoleAttribute, from: element) ?? ""
        return interactiveRoles.contains(role)
    }

    private static func preferredAction(from actions: [String]) -> String? {
        let preference = [
            kAXPressAction as String,
            kAXConfirmAction as String,
            "AXPick",
            "AXOpen"
        ]
        return preference.first(where: actions.contains)
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success else { return [] }
        return value as? [String] ?? []
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

    private static let actionableActions: Set<String> = [
        kAXPressAction as String,
        kAXConfirmAction as String,
        "AXPick",
        "AXShowMenu",
        "AXOpen"
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
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
                AXUIElementSetMessagingTimeout(element, 0.25)
                if AXUIElementPerformAction(element, action as CFString) == .success {
                    return
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
