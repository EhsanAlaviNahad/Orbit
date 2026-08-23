import AppKit
import Carbon
import CoreGraphics

enum HintInput {
    case text(String)
    case backspace
    case selectAll
    case copy
    case paste
    case enter
    case optionEnter
    case shiftEnter
    case scroll(ScrollDirection)
    case nextResult
    case previousResult
    case keyReleased
    case terminalKeyCancelled
    case modifierChanged
    case inputInterrupted
    case escape
}

@MainActor
final class HintInputMonitor {
    var onInput: ((HintInput) -> Void)?
    var cancelShortcut: KeyboardShortcut = .commandE

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingTerminalKeyCode: UInt16?
    private var terminalModifierCycle = TerminalModifierCycle()
    private var isActive = false
    private var suppressCancelShortcutUntil: ContinuousClock.Instant?

    func start() -> Bool {
        pendingTerminalKeyCode = nil
        terminalModifierCycle.reset()
        suppressCancelShortcutUntil = .now.advanced(by: .milliseconds(200))
        if let eventTap, CFMachPortIsValid(eventTap) {
            isActive = true
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }
        shutdown()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<HintInputMonitor>.fromOpaque(context).takeUnretainedValue()
                guard monitor.isActive else {
                    return Unmanaged.passUnretained(event)
                }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.cancelPendingTerminalKey()
                    monitor.onInput?(.inputInterrupted)
                    monitor.reenable()
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyUp {
                    return monitor.handleKeyUp(event)
                        ? Unmanaged.passUnretained(event)
                        : nil
                }
                if type == .flagsChanged {
                    monitor.handleFlagsChanged(event)
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                return monitor.handle(event)
            },
            userInfo: context
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        isActive = true
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        isActive = false
        suppressCancelShortcutUntil = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        pendingTerminalKeyCode = nil
        terminalModifierCycle.reset()
    }

    func shutdown() {
        stop()
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if matchesCancelShortcut(keyCode: keyCode, flags: flags) {
            if let deadline = suppressCancelShortcutUntil,
               ContinuousClock.now < deadline {
                return nil
            }
            suppressCancelShortcutUntil = nil
            onInput?(.escape)
            return nil
        }
        if let direction = OverlayShortcutPolicy.scrollDirection(keyCode: keyCode, flags: flags) {
            onInput?(.scroll(direction))
            return nil
        }
        if flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) {
            switch keyCode {
            case 0:
                onInput?(.selectAll)
            case 8:
                onInput?(.copy)
            case 9:
                onInput?(.paste)
            default:
                NSSound.beep()
            }
            return nil
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            if keyCode == 36 || keyCode == 76 {
                onInput?(.terminalKeyCancelled)
                return nil
            }
            NSSound.beep()
            return nil
        }

        switch keyCode {
        case 53:
            onInput?(.escape)
        case 51:
            onInput?(.backspace)
        case 36, 76:
            guard pendingTerminalKeyCode == nil,
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return nil
            }
            pendingTerminalKeyCode = keyCode
            _ = terminalModifierCycle.begin(modifiers: terminalModifiers(in: flags).rawValue)
            if flags.contains(.maskShift) {
                onInput?(.shiftEnter)
            } else if flags.contains(.maskAlternate) {
                onInput?(.optionEnter)
            } else if SystemCommandInputPolicy.isPlainEnter(
                modifiers: terminalModifiers(in: flags).rawValue
            ) {
                onInput?(.enter)
            } else {
                onInput?(.terminalKeyCancelled)
            }
        case 48:
            onInput?(flags.contains(.maskShift) ? .previousResult : .nextResult)
        case 125:
            onInput?(.nextResult)
        case 126:
            onInput?(.previousResult)
        default:
            if let text = printableText(from: event) {
                onInput?(.text(text))
            } else {
                NSSound.beep()
            }
        }
        return nil
    }

    private func handleKeyUp(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let pendingTerminalKeyCode, keyCode == pendingTerminalKeyCode {
            self.pendingTerminalKeyCode = nil
            if terminalModifierCycle.finish(
                modifiers: terminalModifiers(in: event.flags).rawValue
            ) {
                onInput?(.keyReleased)
            } else {
                onInput?(.terminalKeyCancelled)
            }
            return false
        }
        if UInt32(keyCode) == cancelShortcut.keyCode {
            suppressCancelShortcutUntil = nil
            return true
        }
        return false
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        if pendingTerminalKeyCode != nil {
            terminalModifierCycle.observe(modifiers: terminalModifiers(in: event.flags).rawValue)
        }
        onInput?(.modifierChanged)
    }

    private func cancelPendingTerminalKey() {
        guard pendingTerminalKeyCode != nil else { return }
        pendingTerminalKeyCode = nil
        terminalModifierCycle.reset()
        onInput?(.terminalKeyCancelled)
    }

    private func terminalModifiers(in flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([
            .maskCommand,
            .maskControl,
            .maskAlternate,
            .maskShift,
            .maskSecondaryFn
        ])
    }

    private func printableText(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 16)
        buffer.withUnsafeMutableBufferPointer { pointer in
            event.keyboardGetUnicodeString(
                maxStringLength: pointer.count,
                actualStringLength: &length,
                unicodeString: pointer.baseAddress
            )
        }
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: buffer, count: length)
        guard text.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !isPrivateUse(scalar.value)
        }) else {
            return nil
        }
        return text
    }

    private func matchesCancelShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard UInt32(keyCode) == cancelShortcut.keyCode else { return false }
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        return modifiers == cancelShortcut.carbonModifiers
    }

    private func isPrivateUse(_ value: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(value)
            || (0xF0000...0xFFFFD).contains(value)
            || (0x100000...0x10FFFD).contains(value)
    }

    private func reenable() {
        if isActive, let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

}

private struct OverlayScreenConfiguration {
    let screenFrame: CGRect
    let quartzScreenFrame: CGRect
    let assignments: [HintAssignment]
    var showsSearchHUD: Bool
}

@MainActor
final class HintOverlayController {
    private var panels: [NSPanel] = []
    private var overlayViews: [HintOverlayView] = []
    private var allAssignments: [HintAssignment] = []
    private var assignmentsByID: [UUID: HintAssignment] = [:]
    private var rankedTargets: [ClickTarget] = []
    private var selectedIndex = 0
    private var querySelectionIsAll = false
    private var transition = 0
    private var hintFontSize: CGFloat = 13
    private var hintAppearance: HintLabelAppearance = .classic
    private var hintCustomColor: HintColorComponents = .defaultCustom
    private var pendingSystemCommand: SystemCommand?

    private(set) var assignments: [HintAssignment] = []
    private(set) var query = ""
    private(set) var isPresented = false

    func show(assignments: [HintAssignment], windowFrame: CGRect) {
        guard !assignments.isEmpty else {
            dismiss()
            return
        }
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let configurations = screenConfigurations(
            assignments: assignments,
            windowFrame: windowFrame,
            mainScreenHeight: mainScreenHeight
        )
        guard !configurations.isEmpty else {
            dismiss()
            return
        }

        let canReusePanels = panels.count == configurations.count
            && overlayViews.count == configurations.count
            && zip(panels, configurations).allSatisfy { panel, configuration in
                panel.frame == configuration.screenFrame
            }
        if !canReusePanels {
            dismiss()
        }

        allAssignments = assignments
        assignmentsByID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.id, $0) })
        self.assignments = assignments.filter { $0.target.windowArrangement == nil }
        query = ""
        rankedTargets = []
        selectedIndex = 0
        querySelectionIsAll = false
        pendingSystemCommand = nil

        if canReusePanels {
            for (view, configuration) in zip(overlayViews, configurations) {
                configure(
                    view,
                    with: configuration,
                    mainScreenHeight: mainScreenHeight
                )
            }
        } else {
            for configuration in configurations {
                let view = HintOverlayView(
                    frame: CGRect(origin: .zero, size: configuration.screenFrame.size)
                )
                configure(view, with: configuration, mainScreenHeight: mainScreenHeight)

                let panel = NSPanel(
                    contentRect: configuration.screenFrame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.backgroundColor = NSColor.clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.level = NSWindow.Level.statusBar
                panel.collectionBehavior = NSWindow.CollectionBehavior([
                    .canJoinAllSpaces,
                    .fullScreenAuxiliary,
                    .ignoresCycle
                ])
                panel.contentView = view
                panel.alphaValue = 0
                overlayViews.append(view)
                panels.append(panel)
            }
        }

        refreshViews()
        presentPanels()
    }

    func showOnlyDockHints() {
        guard isPresented else { return }
        rankedTargets = []
        selectedIndex = 0
        assignments = allAssignments.filter { $0.target.source == .dock }
        refreshViews()
    }

    func replaceAssignments(_ newAssignments: [HintAssignment], windowFrame: CGRect) {
        guard isPresented, !newAssignments.isEmpty else { return }
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let configurations = screenConfigurations(
            assignments: newAssignments,
            windowFrame: windowFrame,
            mainScreenHeight: mainScreenHeight
        )
        let canReusePanels = panels.count == configurations.count
            && overlayViews.count == configurations.count
            && zip(panels, configurations).allSatisfy { panel, configuration in
                panel.frame == configuration.screenFrame
            }
        guard canReusePanels else {
            show(assignments: newAssignments, windowFrame: windowFrame)
            return
        }

        allAssignments = newAssignments
        assignmentsByID = Dictionary(uniqueKeysWithValues: newAssignments.map { ($0.id, $0) })
        for (view, configuration) in zip(overlayViews, configurations) {
            configure(view, with: configuration, mainScreenHeight: mainScreenHeight)
        }
        selectedIndex = 0
        refreshSearch()
    }

    private func screenConfigurations(
        assignments: [HintAssignment],
        windowFrame: CGRect,
        mainScreenHeight: CGFloat
    ) -> [OverlayScreenConfiguration] {
        var configurations = NSScreen.screens.compactMap { screen -> OverlayScreenConfiguration? in
            let quartzScreenFrame = CGRect(
                x: screen.frame.minX,
                y: mainScreenHeight - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            let screenAssignments = assignments.filter {
                quartzScreenFrame.contains($0.target.clickPoint)
            }
            guard !screenAssignments.isEmpty else { return nil }
            return OverlayScreenConfiguration(
                screenFrame: screen.frame,
                quartzScreenFrame: quartzScreenFrame,
                assignments: screenAssignments,
                showsSearchHUD: false
            )
        }
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let hudIndex = configurations.firstIndex {
            $0.quartzScreenFrame.contains(windowCenter)
        } ?? configurations.indices.first
        if let hudIndex {
            configurations[hudIndex].showsSearchHUD = true
        }
        return configurations
    }

    private func configure(
        _ view: HintOverlayView,
        with configuration: OverlayScreenConfiguration,
        mainScreenHeight: CGFloat
    ) {
        view.updateAssignments(
            configuration.assignments.filter { $0.target.windowArrangement == nil }
        )
        view.desktopOrigin = configuration.screenFrame.origin
        view.mainScreenHeight = mainScreenHeight
        view.quartzScreenFrame = configuration.quartzScreenFrame
        view.hintFontSize = hintFontSize
        view.hintAppearance = hintAppearance
        view.hintCustomColor = hintCustomColor
        view.showsSearchHUD = configuration.showsSearchHUD
    }

    func appendSearchText(_ text: String) {
        query = querySelectionIsAll ? text : query + text
        querySelectionIsAll = false
        selectedIndex = 0
        refreshSearch()
    }

    func updateHintStyle(
        fontSize: CGFloat,
        appearance: HintLabelAppearance,
        customColor: HintColorComponents
    ) {
        hintFontSize = min(20, max(10, fontSize))
        hintAppearance = appearance
        hintCustomColor = customColor
        for view in overlayViews {
            view.hintFontSize = hintFontSize
            view.hintAppearance = hintAppearance
            view.hintCustomColor = hintCustomColor
        }
    }

    func setPendingSystemCommand(_ command: SystemCommand?) {
        guard pendingSystemCommand != command else { return }
        pendingSystemCommand = command
        refreshViews()
    }

    func backspace() {
        guard !query.isEmpty else {
            NSSound.beep()
            return
        }
        if querySelectionIsAll {
            query = ""
        } else {
            query.removeLast()
        }
        querySelectionIsAll = false
        selectedIndex = 0
        refreshSearch()
    }

    func selectAll() {
        guard !query.isEmpty else { return }
        querySelectionIsAll = true
        refreshViews()
    }

    func copy() {
        guard !query.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query, forType: .string)
    }

    func paste() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }
        let flattened = pasted
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let text = String(flattened.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        })
        guard !text.isEmpty else { return }
        query = querySelectionIsAll ? text : query + text
        querySelectionIsAll = false
        selectedIndex = 0
        refreshSearch()
    }

    func moveSelection(by offset: Int) {
        guard !rankedTargets.isEmpty else {
            NSSound.beep()
            return
        }
        selectedIndex = (selectedIndex + offset + rankedTargets.count) % rankedTargets.count
        refreshViews()
    }

    func selectedTarget() -> ClickTarget? {
        guard !query.isEmpty, rankedTargets.indices.contains(selectedIndex) else {
            NSSound.beep()
            return nil
        }
        return rankedTargets[selectedIndex]
    }

    func dismiss() {
        transition += 1
        isPresented = false
        panels.forEach {
            $0.orderOut(nil)
            $0.contentView = nil
        }
        panels = []
        overlayViews = []
        allAssignments = []
        assignmentsByID = [:]
        rankedTargets = []
        assignments = []
        query = ""
        pendingSystemCommand = nil
        querySelectionIsAll = false
        selectedIndex = 0
    }

    func hide() {
        guard isPresented else { return }
        transition += 1
        isPresented = false
        query = ""
        pendingSystemCommand = nil
        rankedTargets = []
        assignments = allAssignments.filter { $0.target.windowArrangement == nil }
        selectedIndex = 0
        querySelectionIsAll = false
        refreshViews()
        panels.forEach {
            $0.alphaValue = 0
            $0.orderOut(nil)
        }
    }

    private func presentPanels() {
        transition += 1
        isPresented = true
        panels.forEach {
            $0.alphaValue = 1
            $0.orderFrontRegardless()
        }
    }

    private func refreshSearch() {
        if query.isEmpty {
            rankedTargets = []
            assignments = allAssignments.filter { $0.target.windowArrangement == nil }
        } else if SystemCommandParser.parse(query) != nil {
            rankedTargets = []
            assignments = []
        } else {
            let matches = TargetSearch.matches(query: query, assignments: allAssignments)
            rankedTargets = matches.map(\.target)
            assignments = rankedTargets.compactMap { assignmentsByID[$0.id] }
        }
        refreshViews()
    }

    private func refreshViews() {
        let selectedTarget = rankedTargets.indices.contains(selectedIndex)
            ? rankedTargets[selectedIndex]
            : nil
        let selectedID = selectedTarget?.id
        let systemCommand = SystemCommandParser.parse(query)
        let hudState = SearchHUDState(
            query: query,
            selectionIsAll: querySelectionIsAll,
            selectedLabel: selectedTarget?.label,
            selectedIsWindowCommand: selectedTarget?.windowArrangement != nil,
            matchCount: rankedTargets.count,
            systemCommand: systemCommand,
            pendingSystemCommand: pendingSystemCommand == systemCommand ? pendingSystemCommand : nil
        )
        for view in overlayViews {
            let visibleAssignments = assignments.filter {
                $0.target.windowArrangement == nil
                    && view.quartzScreenFrame.contains($0.target.clickPoint)
            }
            view.update(
                assignments: visibleAssignments,
                selectedTargetID: selectedID,
                hudState: hudState
            )
        }
    }
}

private struct SearchHUDState: Equatable {
    var query: String
    var selectionIsAll: Bool
    var selectedLabel: String?
    var selectedIsWindowCommand: Bool
    var matchCount: Int
    var systemCommand: SystemCommand?
    var pendingSystemCommand: SystemCommand?

    static let empty = SearchHUDState(
        query: "",
        selectionIsAll: false,
        selectedLabel: nil,
        selectedIsWindowCommand: false,
        matchCount: 0,
        systemCommand: nil,
        pendingSystemCommand: nil
    )
}

private struct AssignmentRenderKey: Equatable {
    let id: UUID
    let code: String
    let frame: CGRect
}

private final class HintOverlayView: NSView {
    private(set) var assignments: [HintAssignment] = []
    private var assignmentRenderKeys: [AssignmentRenderKey] = []
    private var selectedTargetID: UUID?
    var showsSearchHUD = false {
        didSet {
            guard oldValue != showsSearchHUD else { return }
            searchHUD.isHidden = !showsSearchHUD
            needsLayout = true
        }
    }
    var desktopOrigin = CGPoint.zero
    var mainScreenHeight: CGFloat = 0
    var quartzScreenFrame = CGRect.zero
    var hintFontSize: CGFloat = 13 {
        didSet { if oldValue != hintFontSize { needsDisplay = true } }
    }
    var hintAppearance: HintLabelAppearance = .classic {
        didSet { if oldValue != hintAppearance { needsDisplay = true } }
    }
    var hintCustomColor: HintColorComponents = .defaultCustom {
        didSet { if oldValue != hintCustomColor { needsDisplay = true } }
    }
    private let searchHUD = SearchHUDView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        searchHUD.isHidden = true
        addSubview(searchHUD)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateAssignments(_ assignments: [HintAssignment]) {
        let renderKeys = assignments.map {
            AssignmentRenderKey(id: $0.id, code: $0.code, frame: $0.target.frame)
        }
        guard renderKeys != assignmentRenderKeys else { return }
        self.assignments = assignments
        assignmentRenderKeys = renderKeys
        needsDisplay = true
    }

    func update(
        assignments: [HintAssignment],
        selectedTargetID: UUID?,
        hudState: SearchHUDState
    ) {
        updateAssignments(assignments)
        if self.selectedTargetID != selectedTargetID {
            self.selectedTargetID = selectedTargetID
            needsDisplay = true
        }
        searchHUD.state = hudState
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let width = min(560, bounds.width - 40)
        guard width > 220 else {
            searchHUD.isHidden = true
            return
        }
        let height: CGFloat = 88
        let preferredY = bounds.minY + bounds.height * 0.68
        let y = min(bounds.maxY - height - 72, max(bounds.minY + 40, preferredY))
        searchHUD.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: y,
            width: width,
            height: height
        )
        searchHUD.isHidden = !showsSearchHUD
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for assignment in assignments {
            draw(assignment)
        }
    }

    func animateSearchHUDIn() {
        guard showsSearchHUD else { return }
        searchHUD.animateIn()
    }

    func animateSearchHUDOut() {
        guard showsSearchHUD else { return }
        searchHUD.animateOut()
    }

    private func draw(_ assignment: HintAssignment) {
        let targetFrame = localFrame(for: assignment.target.frame)
        let selected = assignment.target.id == selectedTargetID
        if selected {
            let highlight = targetFrame.insetBy(dx: -3, dy: -3).intersection(bounds)
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 7, yRadius: 7).fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(roundedRect: highlight, xRadius: 7, yRadius: 7)
            outline.lineWidth = 3
            outline.stroke()
        }

        let colors = hintColors(selected: selected)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: hintFontSize, weight: .bold),
            .foregroundColor: colors.foreground
        ]
        let text = assignment.code as NSString
        let textSize = text.size(withAttributes: attributes)
        let horizontalPadding = max(10, hintFontSize * 0.76)
        let verticalPadding = max(5, hintFontSize * 0.38)
        let labelSize = CGSize(
            width: textSize.width + horizontalPadding,
            height: textSize.height + verticalPadding
        )
        var labelRect = CGRect(
            x: targetFrame.minX,
            y: targetFrame.maxY - labelSize.height,
            width: labelSize.width,
            height: labelSize.height
        )
        labelRect.origin.x = min(max(labelRect.minX, bounds.minX), bounds.maxX - labelRect.width)
        labelRect.origin.y = min(max(labelRect.minY, bounds.minY), bounds.maxY - labelRect.height)

        colors.fill.setFill()
        let cornerRadius = max(4, hintFontSize * 0.32)
        NSBezierPath(roundedRect: labelRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        colors.border.setStroke()
        NSBezierPath(roundedRect: labelRect, xRadius: cornerRadius, yRadius: cornerRadius).stroke()
        text.draw(
            at: CGPoint(
                x: labelRect.minX + horizontalPadding / 2,
                y: labelRect.minY + verticalPadding / 2
            ),
            withAttributes: attributes
        )
    }

    private func hintColors(selected: Bool) -> (fill: NSColor, foreground: NSColor, border: NSColor) {
        if selected {
            return (
                NSColor.controlAccentColor.withAlphaComponent(0.98),
                .white,
                NSColor.white.withAlphaComponent(0.35)
            )
        }
        switch hintAppearance {
        case .classic:
            return (
                NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.16, alpha: 0.96),
                .black,
                NSColor.black.withAlphaComponent(0.35)
            )
        case .glass:
            return (
                NSColor.black.withAlphaComponent(0.76),
                .white,
                NSColor.white.withAlphaComponent(0.28)
            )
        case .accent:
            return (
                NSColor.controlAccentColor.withAlphaComponent(0.94),
                .white,
                NSColor.white.withAlphaComponent(0.28)
            )
        case .white:
            return (
                NSColor.white.withAlphaComponent(0.96),
                .black,
                NSColor.black.withAlphaComponent(0.22)
            )
        case .custom:
            let foreground: NSColor = hintCustomColor.usesLightForeground ? .white : .black
            return (
                NSColor(
                    srgbRed: hintCustomColor.red,
                    green: hintCustomColor.green,
                    blue: hintCustomColor.blue,
                    alpha: 0.98
                ),
                foreground,
                foreground.withAlphaComponent(0.3)
            )
        }
    }

    private func localFrame(for quartzFrame: CGRect) -> CGRect {
        CGRect(
            x: quartzFrame.minX - desktopOrigin.x,
            y: mainScreenHeight - quartzFrame.maxY - desktopOrigin.y,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

@available(macOS 26.0, *)
private final class SearchHUDView: NSGlassEffectView {
    private let icon = NSImageView()
    private let searchLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let content = NSView()

    var state = SearchHUDState.empty {
        didSet {
            guard oldValue != state else { return }
            refresh()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = 22
        tintColor = NSColor.controlBackgroundColor.withAlphaComponent(0.12)
        effectIsInteractive = false
        contentView = content

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)

        searchLabel.font = .systemFont(ofSize: 21, weight: .medium)
        searchLabel.textColor = .labelColor
        searchLabel.lineBreakMode = .byTruncatingHead
        searchLabel.maximumNumberOfLines = 1

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        content.addSubview(icon)
        content.addSubview(searchLabel)
        content.addSubview(detailLabel)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func animateIn() {
        guard let layer else { return }
        layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.16
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(opacity, forKey: "apple-opacity-in")

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.965
        scale.toValue = 1
        scale.mass = 1
        scale.stiffness = 330
        scale.damping = 26
        scale.initialVelocity = 0.4
        scale.duration = scale.settlingDuration
        layer.add(scale, forKey: "apple-scale-in")

        let position = CASpringAnimation(keyPath: "transform.translation.y")
        position.fromValue = 8
        position.toValue = 0
        position.mass = 1
        position.stiffness = 320
        position.damping = 28
        position.initialVelocity = 0
        position.duration = position.settlingDuration
        layer.add(position, forKey: "apple-position-in")
    }

    func animateOut() {
        guard let layer else { return }
        layer.removeAllAnimations()

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = layer.presentation()?.opacity ?? 1
        opacity.toValue = 0
        opacity.duration = 0.10
        opacity.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(opacity, forKey: "apple-opacity-out")

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.985
        scale.duration = 0.12
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(scale, forKey: "apple-scale-out")
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        icon.frame = CGRect(x: 20, y: 44, width: 24, height: 24)
        searchLabel.frame = CGRect(x: 56, y: 43, width: bounds.width - 76, height: 29)
        detailLabel.frame = CGRect(x: 56, y: 17, width: bounds.width - 76, height: 18)
    }

    private func refresh() {
        if let command = state.systemCommand {
            icon.image = NSImage(
                systemSymbolName: command.symbolName,
                accessibilityDescription: command.displayName
            )
            icon.contentTintColor = state.pendingSystemCommand == command
                ? .systemOrange
                : .secondaryLabelColor
        } else {
            icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
            icon.contentTintColor = .secondaryLabelColor
        }

        if state.query.isEmpty {
            searchLabel.attributedStringValue = NSAttributedString(
                string: "Search",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 21, weight: .medium),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
            )
            detailLabel.stringValue = "Type an element, window command, or system command"
        } else {
            if state.selectionIsAll {
                searchLabel.attributedStringValue = NSAttributedString(
                    string: state.query,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 21, weight: .medium),
                        .foregroundColor: NSColor.white,
                        .backgroundColor: NSColor.systemBlue
                    ]
                )
            } else {
                searchLabel.attributedStringValue = NSAttributedString(
                    string: state.query,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 21, weight: .medium),
                        .foregroundColor: NSColor.labelColor
                    ]
                )
            }
            if let command = state.systemCommand {
                if state.pendingSystemCommand == command {
                    detailLabel.stringValue = command.confirmationPrompt
                } else {
                    detailLabel.stringValue = "\(command.displayName)  •  Return: confirm  •  Esc to close"
                }
            } else if state.matchCount == 0 {
                detailLabel.stringValue = "No results  •  Delete to edit  •  Esc to close"
            } else if state.selectedIsWindowCommand, let selectedLabel = state.selectedLabel {
                detailLabel.stringValue = "\(selectedLabel)  •  Return: run command  •  Tab/↑/↓: choose"
            } else if let selectedLabel = state.selectedLabel {
                detailLabel.stringValue = "\(selectedLabel)  •  Return: click  •  Tab/↑/↓: choose"
            } else {
                detailLabel.stringValue = "\(state.matchCount) result\(state.matchCount == 1 ? "" : "s")"
            }
        }
        needsLayout = true
    }

}
