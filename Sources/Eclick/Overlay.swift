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
    case shiftEnter
    case nextResult
    case previousResult
    case keyReleased
    case escape
}

@MainActor
final class HintInputMonitor {
    var onInput: ((HintInput) -> Void)?
    var cancelShortcut: KeyboardShortcut = .commandE

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingTerminalKeyCode: UInt16?

    func start() -> Bool {
        stop()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
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
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenable()
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyUp {
                    monitor.handleKeyUp(event)
                    return nil
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
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        pendingTerminalKeyCode = nil
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if matchesCancelShortcut(keyCode: keyCode, flags: flags) {
            onInput?(.escape)
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
            NSSound.beep()
            return nil
        }

        switch keyCode {
        case 53:
            onInput?(.escape)
        case 51:
            onInput?(.backspace)
        case 36, 76:
            pendingTerminalKeyCode = keyCode
            onInput?(flags.contains(.maskShift) ? .shiftEnter : .enter)
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

    private func handleKeyUp(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == pendingTerminalKeyCode else { return }
        pendingTerminalKeyCode = nil
        onInput?(.keyReleased)
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
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

}

@MainActor
final class HintOverlayController {
    private var panels: [NSPanel] = []
    private var overlayViews: [HintOverlayView] = []
    private var allAssignments: [HintAssignment] = []
    private var rankedTargets: [ClickTarget] = []
    private var selectedIndex = 0
    private var querySelectionIsAll = false
    private var transition = 0
    private var hintFontSize: CGFloat = 13
    private var hintAppearance: HintLabelAppearance = .classic

    private(set) var assignments: [HintAssignment] = []
    private(set) var query = ""
    private(set) var isPresented = false

    func show(assignments: [HintAssignment], windowFrame: CGRect) {
        if !panels.isEmpty,
           allAssignments.map(\.id) == assignments.map(\.id) {
            allAssignments = assignments
            self.assignments = assignments
            query = ""
            rankedTargets = []
            selectedIndex = 0
            querySelectionIsAll = false
            refreshViews()
            presentPanels()
            return
        }
        dismiss()
        guard !assignments.isEmpty else { return }

        allAssignments = assignments
        self.assignments = assignments
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        var hudAssigned = false

        for screen in NSScreen.screens {
            let quartzScreenFrame = CGRect(
                x: screen.frame.minX,
                y: mainScreenHeight - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            guard quartzScreenFrame.intersects(windowFrame) else { continue }
            let screenAssignments = assignments.filter {
                quartzScreenFrame.contains($0.target.clickPoint)
            }
            guard !screenAssignments.isEmpty else { continue }

            let view = HintOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.assignments = screenAssignments
            view.desktopOrigin = screen.frame.origin
            view.mainScreenHeight = mainScreenHeight
            view.quartzScreenFrame = quartzScreenFrame
            view.hintFontSize = hintFontSize
            view.hintAppearance = hintAppearance
            if !hudAssigned, quartzScreenFrame.contains(CGPoint(x: windowFrame.midX, y: windowFrame.midY)) {
                view.showsSearchHUD = true
                hudAssigned = true
            }

            let panel = NSPanel(
                contentRect: screen.frame,
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

        if !hudAssigned {
            overlayViews.first?.showsSearchHUD = true
        }
        refreshViews()
        presentPanels()
    }

    func appendSearchText(_ text: String) {
        query = querySelectionIsAll ? text : query + text
        querySelectionIsAll = false
        selectedIndex = 0
        refreshSearch()
    }

    func updateHintStyle(fontSize: CGFloat, appearance: HintLabelAppearance) {
        hintFontSize = min(20, max(10, fontSize))
        hintAppearance = appearance
        for view in overlayViews {
            view.hintFontSize = hintFontSize
            view.hintAppearance = hintAppearance
        }
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
        rankedTargets = []
        assignments = []
        query = ""
        querySelectionIsAll = false
        selectedIndex = 0
    }

    func hide() {
        guard isPresented else { return }
        transition += 1
        let currentTransition = transition
        isPresented = false
        query = ""
        rankedTargets = []
        assignments = allAssignments
        selectedIndex = 0
        querySelectionIsAll = false
        refreshViews()
        overlayViews.forEach { $0.animateSearchHUDOut() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panels.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.transition == currentTransition else { return }
                self.panels.forEach { $0.orderOut(nil) }
            }
        }
    }

    private func presentPanels() {
        transition += 1
        isPresented = true
        panels.forEach { $0.orderFrontRegardless() }
        overlayViews.forEach { $0.animateSearchHUDIn() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panels.forEach { $0.animator().alphaValue = 1 }
        }
    }

    private func refreshSearch() {
        if query.isEmpty {
            rankedTargets = []
            assignments = allAssignments
        } else {
            let matches = TargetSearch.matches(query: query, assignments: allAssignments)
            rankedTargets = matches.map(\.target)
            let assignmentsByID = Dictionary(uniqueKeysWithValues: allAssignments.map { ($0.id, $0) })
            assignments = rankedTargets.compactMap { assignmentsByID[$0.id] }
        }
        refreshViews()
    }

    private func refreshViews() {
        let selectedID = rankedTargets.indices.contains(selectedIndex)
            ? rankedTargets[selectedIndex].id
            : nil
        for view in overlayViews {
            view.assignments = assignments.filter {
                view.quartzScreenFrame.contains($0.target.clickPoint)
            }
            view.query = query
            view.querySelectionIsAll = querySelectionIsAll
            view.selectedTargetID = selectedID
            view.matchCount = rankedTargets.count
        }
    }
}

private final class HintOverlayView: NSView {
    var assignments: [HintAssignment] = [] { didSet { needsDisplay = true } }
    var query = "" {
        didSet {
            searchHUD.query = query
            needsDisplay = true
        }
    }
    var selectedTargetID: UUID? { didSet { needsDisplay = true } }
    var matchCount = 0 {
        didSet {
            searchHUD.matchCount = matchCount
            needsDisplay = true
        }
    }
    var querySelectionIsAll = false { didSet { searchHUD.selectionIsAll = querySelectionIsAll } }
    var showsSearchHUD = false {
        didSet {
            searchHUD.isHidden = !showsSearchHUD
            needsLayout = true
        }
    }
    var desktopOrigin = CGPoint.zero
    var mainScreenHeight: CGFloat = 0
    var quartzScreenFrame = CGRect.zero
    var hintFontSize: CGFloat = 13 { didSet { needsDisplay = true } }
    var hintAppearance: HintLabelAppearance = .classic { didSet { needsDisplay = true } }
    private let searchHUD = SearchHUDView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        searchHUD.isHidden = true
        addSubview(searchHUD)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    var query = "" { didSet { refresh() } }
    var matchCount = 0 { didSet { refresh() } }
    var selectionIsAll = false { didSet { refresh() } }

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
        if query.isEmpty {
            searchLabel.attributedStringValue = NSAttributedString(
                string: "Search",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 21, weight: .medium),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
            )
            detailLabel.stringValue = "Return: click  •  Return twice: double-click  •  ⇧Return: right-click"
        } else {
            if selectionIsAll {
                searchLabel.attributedStringValue = NSAttributedString(
                    string: query,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 21, weight: .medium),
                        .foregroundColor: NSColor.white,
                        .backgroundColor: NSColor.systemBlue
                    ]
                )
            } else {
                searchLabel.attributedStringValue = NSAttributedString(
                    string: query,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 21, weight: .medium),
                        .foregroundColor: NSColor.labelColor
                    ]
                )
            }
            detailLabel.stringValue = matchCount == 0
                ? "No results  •  Delete to edit  •  Esc to close"
                : "\(matchCount) result\(matchCount == 1 ? "" : "s")  •  Return twice: double-click  •  ⇧Return: right-click"
        }
        needsLayout = true
    }

}
