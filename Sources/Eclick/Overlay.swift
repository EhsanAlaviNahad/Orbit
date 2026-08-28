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
    private var searchIndex: [UUID: [String]] = [:]
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
        searchIndex = TargetSearch.searchIndex(for: allAssignments.map(\.target))
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
        searchIndex = TargetSearch.searchIndex(for: allAssignments.map(\.target))
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
        hintFontSize = CGFloat(HintLabelMetrics.clampedFontSize(Double(fontSize)))
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
        searchIndex = [:]
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
            let matches = TargetSearch.matches(
                query: query,
                assignments: allAssignments,
                searchIndex: searchIndex
            )
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
        didSet {
            guard oldValue != hintFontSize else { return }
            invalidateStyleCaches()
            needsDisplay = true
        }
    }
    var hintAppearance: HintLabelAppearance = .classic {
        didSet {
            guard oldValue != hintAppearance else { return }
            invalidateStyleCaches()
            needsDisplay = true
        }
    }
    var hintCustomColor: HintColorComponents = .defaultCustom {
        didSet {
            guard oldValue != hintCustomColor else { return }
            invalidateStyleCaches()
            needsDisplay = true
        }
    }
    private let searchHUD = SearchHUDView()
    private var cachedHintFont: NSFont?
    private var labelTextSizeCache: [String: CGSize] = [:]
    private var cachedUnselectedColors: (fill: NSColor, foreground: NSColor, border: NSColor)?
    private var cachedSelectedColors: (fill: NSColor, foreground: NSColor, border: NSColor)?

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
        let width = min(600, bounds.width - 48)
        guard width > 220 else {
            searchHUD.isHidden = true
            return
        }
        let height: CGFloat = 82
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
        let font = hintFont()
        let unselected = unselectedColors()
        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: unselected.foreground
        ]
        for assignment in assignments {
            draw(assignment, font: font, normalAttributes: normalAttributes)
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

    private func invalidateStyleCaches() {
        cachedHintFont = nil
        labelTextSizeCache.removeAll()
        cachedUnselectedColors = nil
        cachedSelectedColors = nil
    }

    private func hintFont() -> NSFont {
        if let cachedHintFont { return cachedHintFont }
        let font = NSFont.monospacedSystemFont(ofSize: hintFontSize, weight: .bold)
        cachedHintFont = font
        return font
    }

    private func textSize(for code: String, font: NSFont) -> CGSize {
        if let cached = labelTextSizeCache[code] { return cached }
        let size = (code as NSString).size(withAttributes: [.font: font])
        labelTextSizeCache[code] = size
        return size
    }

    private func draw(
        _ assignment: HintAssignment,
        font: NSFont,
        normalAttributes: [NSAttributedString.Key: Any]
    ) {
        let targetFrame = localFrame(for: assignment.target.frame)
        let selected = assignment.target.id == selectedTargetID
        if selected {
            let highlight = targetFrame.insetBy(dx: -3, dy: -3).intersection(bounds)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 7, yRadius: 7).fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: highlight, xRadius: 7, yRadius: 7)
            outline.lineWidth = 3
            outline.stroke()
        }

        let colors = selected ? selectedColors() : unselectedColors()
        let attributes = selected
            ? [
                NSAttributedString.Key.font: font,
                NSAttributedString.Key.foregroundColor: colors.foreground
            ]
            : normalAttributes
        let text = assignment.code as NSString
        let textSize = textSize(for: assignment.code, font: font)
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

    private func selectedColors() -> (fill: NSColor, foreground: NSColor, border: NSColor) {
        if let cachedSelectedColors { return cachedSelectedColors }
        let foreground = accessibleForeground(for: .controlAccentColor)
        let colors = (
            fill: NSColor.controlAccentColor.withAlphaComponent(0.98),
            foreground: foreground,
            border: foreground.withAlphaComponent(
                NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.35
            )
        )
        cachedSelectedColors = colors
        return colors
    }

    private func unselectedColors() -> (fill: NSColor, foreground: NSColor, border: NSColor) {
        if let cachedUnselectedColors { return cachedUnselectedColors }
        let colors: (fill: NSColor, foreground: NSColor, border: NSColor)
        switch hintAppearance {
        case .classic:
            colors = (
                NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.16, alpha: 0.96),
                .black,
                NSColor.black.withAlphaComponent(0.35)
            )
        case .glass:
            colors = (
                NSColor.black.withAlphaComponent(0.76),
                .white,
                NSColor.white.withAlphaComponent(0.28)
            )
        case .accent:
            let foreground = accessibleForeground(for: .controlAccentColor)
            colors = (
                NSColor.controlAccentColor.withAlphaComponent(0.94),
                foreground,
                foreground.withAlphaComponent(
                    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.28
                )
            )
        case .white:
            colors = (
                NSColor.white.withAlphaComponent(0.96),
                .black,
                NSColor.black.withAlphaComponent(0.22)
            )
        case .custom:
            let foreground: NSColor = hintCustomColor.usesLightForeground ? .white : .black
            colors = (
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
        cachedUnselectedColors = colors
        return colors
    }

    private func accessibleForeground(for background: NSColor) -> NSColor {
        guard let color = background.usingColorSpace(.sRGB),
              let components = HintColorComponents(
                  red: color.redComponent,
                  green: color.greenComponent,
                  blue: color.blueComponent
              ) else {
            return .white
        }
        return components.usesLightForeground ? .white : .black
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
    private let resultLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
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
        cornerRadius = 20
        effectIsInteractive = false
        contentView = content

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Orbit search")

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        icon.imageScaling = .scaleProportionallyDown

        searchLabel.font = .systemFont(ofSize: 22, weight: .regular)
        searchLabel.textColor = .labelColor
        searchLabel.lineBreakMode = .byTruncatingHead
        searchLabel.maximumNumberOfLines = 1

        detailLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        resultLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        resultLabel.textColor = .tertiaryLabelColor
        resultLabel.alignment = .right
        resultLabel.lineBreakMode = .byTruncatingTail
        resultLabel.maximumNumberOfLines = 1

        separator.boxType = .separator
        separator.titlePosition = .noTitle
        separator.setAccessibilityElement(false)

        content.addSubview(icon)
        content.addSubview(searchLabel)
        content.addSubview(detailLabel)
        content.addSubview(resultLabel)
        content.addSubview(separator)
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
        let horizontalInset: CGFloat = 20
        let resultWidth: CGFloat = resultLabel.isHidden ? 0 : 96
        icon.frame = CGRect(x: horizontalInset, y: 43, width: 24, height: 24)
        searchLabel.frame = CGRect(
            x: 56,
            y: 41,
            width: bounds.width - 76 - resultWidth,
            height: 29
        )
        resultLabel.frame = CGRect(
            x: bounds.width - horizontalInset - resultWidth,
            y: 45,
            width: resultWidth,
            height: 18
        )
        separator.frame = CGRect(
            x: horizontalInset,
            y: 33,
            width: bounds.width - horizontalInset * 2,
            height: 1
        )
        detailLabel.frame = CGRect(
            x: horizontalInset,
            y: 9,
            width: bounds.width - horizontalInset * 2,
            height: 18
        )
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
        } else if state.matchCount == 0, !state.query.isEmpty {
            icon.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: "No results"
            )
            icon.contentTintColor = .tertiaryLabelColor
        } else if state.selectedIsWindowCommand {
            icon.image = NSImage(
                systemSymbolName: "macwindow",
                accessibilityDescription: "Window command"
            )
            icon.contentTintColor = .secondaryLabelColor
        } else {
            icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
            icon.contentTintColor = .secondaryLabelColor
        }

        if state.query.isEmpty {
            searchLabel.attributedStringValue = NSAttributedString(
                string: "Search",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 22, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            detailLabel.stringValue = "Search controls, hints, and commands"
            resultLabel.stringValue = ""
            resultLabel.isHidden = true
        } else {
            if state.selectionIsAll {
                searchLabel.attributedStringValue = NSAttributedString(
                    string: state.query,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 22, weight: .regular),
                        .foregroundColor: NSColor.selectedTextColor,
                        .backgroundColor: NSColor.selectedTextBackgroundColor
                    ]
                )
            } else {
                searchLabel.attributedStringValue = NSAttributedString(
                    string: state.query,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 22, weight: .regular),
                        .foregroundColor: NSColor.labelColor
                    ]
                )
            }
            if let command = state.systemCommand {
                resultLabel.stringValue = ""
                resultLabel.isHidden = true
                if state.pendingSystemCommand == command {
                    detailLabel.stringValue = command.confirmationPrompt
                } else {
                    detailLabel.stringValue = "\(command.displayName)  ·  ↩ Confirm  ·  esc Close"
                }
            } else if state.matchCount == 0 {
                detailLabel.stringValue = "No results  ·  Delete to edit  ·  esc Close"
                resultLabel.stringValue = ""
                resultLabel.isHidden = true
            } else if state.selectedIsWindowCommand, let selectedLabel = state.selectedLabel {
                detailLabel.stringValue = "\(selectedLabel)  ·  ↩ Run  ·  ↑↓ Choose"
                updateResultLabel()
            } else if let selectedLabel = state.selectedLabel {
                detailLabel.stringValue = "\(selectedLabel)  ·  ↩ Click  ·  ⇧↩ Right-click  ·  ↑↓ Choose"
                updateResultLabel()
            } else {
                detailLabel.stringValue = "↑↓ Choose  ·  ↩ Open  ·  esc Close"
                updateResultLabel()
            }
        }
        setAccessibilityValue(state.query.isEmpty ? "Empty" : state.query)
        setAccessibilityHelp(detailLabel.stringValue)
        needsLayout = true
    }

    private func updateResultLabel() {
        resultLabel.stringValue = "\(state.matchCount) result\(state.matchCount == 1 ? "" : "s")"
        resultLabel.isHidden = false
    }

}
