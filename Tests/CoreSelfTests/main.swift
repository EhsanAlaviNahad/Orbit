import CoreGraphics
import Foundation

@main
enum CoreSelfTests {
    private static var failures: [String] = []

    @MainActor
    static func main() async {
        let acceptedSystemCommands: [(String, SystemCommand)] = [
            ("restart", .restart),
            ("Restart", .restart),
            ("RESTART", .restart),
            (" restart ", .restart),
            ("shutdown", .shutdown),
            ("Shutdown", .shutdown),
            ("sleep", .sleep),
            ("Sleep", .sleep)
        ]
        for (query, command) in acceptedSystemCommands {
            check(SystemCommandParser.parse(query) == command, "system command exact parse: \(query)")
        }
        for query in [
            "rest", "restart now", "restart button", "shut", "shutdown menu",
            "slee", "sleeping", ""
        ] {
            check(SystemCommandParser.parse(query) == nil, "system command exact rejection: \(query)")
        }

        var confirmation = SystemCommandConfirmationStateMachine()
        check(
            confirmation.enterKeyDown(query: "restart"),
            "first system Enter-down is intercepted"
        )
        check(confirmation.pendingCommand == nil, "confirmation waits for first Enter-up")
        check(
            confirmation.enterKeyDown(query: "restart", isAutoRepeat: true),
            "system Enter auto-repeat is intercepted"
        )
        check(
            confirmation.enterKeyUp() == .confirmationRequested(.restart),
            "first complete Enter requests confirmation"
        )
        check(confirmation.pendingCommand == .restart, "restart confirmation becomes pending")
        confirmation.queryDidChange(to: "Restart")
        check(confirmation.pendingCommand == nil, "raw query casing change cancels confirmation")
        check(confirmation.enterKeyUp() == nil, "cancelled confirmation cannot execute on key-up")

        var modifierChangedConfirmation = SystemCommandConfirmationStateMachine()
        _ = modifierChangedConfirmation.enterKeyDown(query: "restart")
        check(
            modifierChangedConfirmation.enterKeyUp(isValid: false) == nil,
            "modifier change cancels terminal key cycle"
        )
        check(
            modifierChangedConfirmation.pendingCommand == nil,
            "modifier change cannot leave confirmation pending"
        )

        var transientModifierCycle = TerminalModifierCycle()
        check(transientModifierCycle.begin(modifiers: 0), "terminal modifier cycle begins")
        transientModifierCycle.observe(modifiers: 1)
        transientModifierCycle.observe(modifiers: 0)
        check(
            !transientModifierCycle.finish(modifiers: 0),
            "transient modifier round trip invalidates terminal cycle"
        )
        var stableModifierCycle = TerminalModifierCycle()
        _ = stableModifierCycle.begin(modifiers: 2)
        stableModifierCycle.observe(modifiers: 2)
        check(stableModifierCycle.finish(modifiers: 2), "stable terminal modifier cycle remains valid")
        check(SystemCommandInputPolicy.isPlainEnter(modifiers: 0), "unmodified Enter is plain")
        check(!SystemCommandInputPolicy.isPlainEnter(modifiers: 1), "Fn-modified Enter is not plain")

        var interCycleModifierConfirmation = SystemCommandConfirmationStateMachine()
        _ = interCycleModifierConfirmation.enterKeyDown(query: "shutdown")
        _ = interCycleModifierConfirmation.enterKeyUp()
        interCycleModifierConfirmation.modifierDidChange()
        _ = interCycleModifierConfirmation.enterKeyDown(query: "shutdown")
        check(
            interCycleModifierConfirmation.enterKeyUp() == .confirmationRequested(.shutdown),
            "inter-cycle modifier change requires fresh first Enter"
        )

        var interruptedConfirmation = SystemCommandConfirmationStateMachine()
        _ = interruptedConfirmation.enterKeyDown(query: "sleep")
        _ = interruptedConfirmation.enterKeyUp()
        interruptedConfirmation.inputWasInterrupted()
        _ = interruptedConfirmation.enterKeyDown(query: "sleep")
        check(
            interruptedConfirmation.enterKeyUp() == .confirmationRequested(.sleep),
            "event-tap interruption requires fresh first Enter"
        )

        let mockExecutor = MockSystemCommandExecutor()
        let coordinator = SystemCommandCoordinator(executor: mockExecutor)
        check(coordinator.enterKeyDown(query: " shutdown "), "shutdown first Enter-down")
        check(
            coordinator.enterKeyUp() == .confirmationRequested(.shutdown),
            "shutdown first Enter-up confirms"
        )
        let commandsAfterFirstEnter = await mockExecutor.commands()
        check(commandsAfterFirstEnter.isEmpty, "first Enter never calls executor")
        check(coordinator.enterKeyDown(query: " shutdown "), "shutdown second Enter-down")
        let commandsAfterSecondKeyDown = await mockExecutor.commands()
        check(commandsAfterSecondKeyDown.isEmpty, "second Enter-down never calls executor")
        let shutdownOutcome = coordinator.enterKeyUp()
        check(shutdownOutcome == .execute(.shutdown), "second Enter-up arms exact execution")
        if case let .execute(command) = shutdownOutcome {
            do {
                try await coordinator.execute(command)
            } catch {
                check(false, "mock executor unexpectedly failed")
            }
        }
        let executedCommands = await mockExecutor.commands()
        check(executedCommands == [.shutdown], "mock executor called exactly once")
        check(coordinator.pendingCommand == nil, "state resets before executor returns")

        let failingExecutor = MockSystemCommandExecutor(shouldFail: true)
        let failingCoordinator = SystemCommandCoordinator(executor: failingExecutor)
        _ = failingCoordinator.enterKeyDown(query: "sleep")
        _ = failingCoordinator.enterKeyUp()
        _ = failingCoordinator.enterKeyDown(query: "sleep")
        if case let .execute(command) = failingCoordinator.enterKeyUp() {
            do {
                try await failingCoordinator.execute(command)
                check(false, "executor failure reaches caller")
            } catch {
                check(true, "executor failure handled without system action")
            }
        } else {
            check(false, "sleep second Enter-up produces execution")
        }
        check(failingCoordinator.pendingCommand == nil, "executor failure leaves state reset")
        _ = failingCoordinator.enterKeyDown(query: "sleep")
        check(
            failingCoordinator.enterKeyUp() == .confirmationRequested(.sleep),
            "failure cannot bypass next confirmation"
        )
        failingCoordinator.cancel()
        check(failingCoordinator.pendingCommand == nil, "Escape/close/reopen cancellation resets state")

        check(
            OverlayShortcutPolicy.scrollDirection(keyCode: 126, flags: .maskControl) == .up,
            "Control-Up scrolls up"
        )
        check(
            OverlayShortcutPolicy.scrollDirection(keyCode: 125, flags: .maskControl) == .down,
            "Control-Down scrolls down"
        )
        check(
            OverlayShortcutPolicy.scrollDirection(keyCode: 125, flags: []) == nil,
            "plain Down remains result navigation"
        )
        check(
            OverlayShortcutPolicy.scrollDirection(
                keyCode: 125,
                flags: [.maskControl, .maskCommand]
            ) == nil,
            "extra Command modifier rejects scroll shortcut"
        )
        let scrollLocation = CGPoint(x: 320, y: 240)
        let scrollDownEvent = PageScroller.makeEvent(.down, at: scrollLocation)
        check(
            scrollDownEvent?.type == .scrollWheel,
            "scroll-down sends a wheel event"
        )
        check(
            scrollDownEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -36,
            "scroll-down uses a gentle negative pixel delta"
        )
        check(
            PageScroller.makeEvent(.up, at: scrollLocation)?
                .getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 36,
            "scroll-up uses a gentle positive pixel delta"
        )
        check(
            scrollDownEvent?.location == scrollLocation,
            "wheel event targets the active window center"
        )
        check(HintColorComponents(red: 0.2, green: 0.3, blue: 0.4) != nil, "valid custom color accepted")
        check(HintColorComponents(red: .nan, green: 0.3, blue: 0.4) == nil, "invalid custom color rejected")
        check(HintColorComponents(red: 1.2, green: 0.3, blue: 0.4) == nil, "out-of-range custom color rejected")
        check(HintColorComponents(red: 0, green: 0, blue: 0)?.usesLightForeground == true, "dark custom color uses white text")
        check(HintColorComponents(red: 1, green: 1, blue: 1)?.usesLightForeground == false, "light custom color uses black text")
        check(HintLabelMetrics.clampedFontSize(9) == 10, "hint size clamps to desktop minimum")
        check(HintLabelMetrics.clampedFontSize(13) == 13, "hint size preserves default")
        check(HintLabelMetrics.clampedFontSize(30) == 26, "hint size supports up to 200 percent")

        check(
            ActivationActionPolicy.preferredAction(from: ["AXShowMenu"]) == nil,
            "context-menu action is never used for normal click"
        )
        check(
            ActivationActionPolicy.preferredAction(from: ["AXShowMenu", "AXPress"]) == "AXPress",
            "normal press wins over context-menu action"
        )
        check(
            DockTargetPolicy.isEligible(
                role: "AXDockItem",
                subrole: "AXApplicationDockItem",
                actions: ["AXPress", "AXShowMenu"],
                frame: CGRect(x: 20, y: 20, width: 48, height: 48)
            ),
            "pressable application Dock item is eligible"
        )
        check(
            !DockTargetPolicy.isEligible(
                role: "AXDockItem",
                subrole: "AXSeparatorDockItem",
                actions: ["AXPress"],
                frame: CGRect(x: 20, y: 20, width: 8, height: 48)
            ),
            "Dock separator is rejected"
        )
        check(
            !DockTargetPolicy.isEligible(
                role: "AXDockItem",
                subrole: "AXApplicationDockItem",
                actions: ["AXShowMenu"],
                frame: CGRect(x: 20, y: 20, width: 48, height: 48)
            ),
            "Dock item without normal press is rejected"
        )

        check(HintGenerator.codes(count: 0).isEmpty, "zero hints")
        check(HintGenerator.codes(count: 9) == ["A", "S", "D", "F", "G", "H", "J", "K", "L"], "home-row alphabet")
        check(HintGenerator.codes(count: 10).allSatisfy { $0.count == 2 }, "two-key boundary")
        check(HintGenerator.codes(count: 81).last == "LL", "two-key capacity")
        check(HintGenerator.codes(count: 82).allSatisfy { $0.count == 3 }, "three-key boundary")

        for count in [1, 9, 10, 81, 82, 500] {
            let codes = HintGenerator.codes(count: count)
            check(Set(codes).count == count, "unique codes at \(count)")
            check(!codes.enumerated().contains { index, code in
                codes.enumerated().contains { otherIndex, otherCode in
                    index != otherIndex && otherCode.hasPrefix(code)
                }
            }, "prefix-free codes at \(count)")
        }

        let lower = target(x: 0, y: 100, label: "lower")
        let upperRight = target(x: 100, y: 10, label: "upper-right")
        let upperLeft = target(x: 10, y: 10, label: "upper-left")
        check(
            TargetGeometry.sortedTopLeft([lower, upperRight, upperLeft]).map(\.label)
                == ["upper-left", "upper-right", "lower"],
            "target sorting"
        )

        let accessibility = target(x: 20, y: 30, width: 100, height: 40, label: "AX")
        let overlappingOCR = target(x: 20, y: 30, width: 100, height: 40, label: "OCR", source: .ocr)
        let distantOCR = target(x: 300, y: 200, label: "OCR 2", source: .ocr)
        let merged = TargetGeometry.merge(
            accessibility: [accessibility],
            ocr: [overlappingOCR, distantOCR]
        )
        check(merged.map(\.id).contains(accessibility.id), "Accessibility target retained")
        check(!merged.map(\.id).contains(overlappingOCR.id), "overlapping OCR removed")
        check(merged.map(\.id).contains(distantOCR.id), "nonoverlapping OCR retained")
        let genericButton = target(x: 500, y: 20, width: 100, height: 40, label: "button")
        let visibleSettings = target(x: 510, y: 25, width: 80, height: 25, label: "Settings", source: .ocr)
        let mergedVisibleLabel = TargetGeometry.merge(
            accessibility: [genericButton],
            ocr: [visibleSettings]
        )
        check(
            TargetSearch.matches(query: "settings", targets: mergedVisibleLabel).first?.target.id
                == genericButton.id,
            "covered OCR text enriches Accessibility search label"
        )
        let nestedParent = target(x: 450, y: 0, width: 220, height: 120, label: "group")
        let nestedMerge = TargetGeometry.merge(
            accessibility: [nestedParent, genericButton],
            ocr: [visibleSettings]
        )
        check(
            TargetSearch.matches(query: "settings", targets: nestedMerge).first?.target.id
                == genericButton.id,
            "covered OCR text enriches smallest actionable control"
        )

        let parent = target(x: 0, y: 0, width: 400, height: 300, label: "container")
        let child = target(x: 20, y: 20, width: 80, height: 30, label: "button")
        check(
            TargetGeometry.deduplicated([parent, child]).count == 2,
            "nested Accessibility controls remain distinct"
        )
        let sameFrameControl = target(x: 20, y: 20, width: 80, height: 30, label: "second button")
        check(
            TargetGeometry.deduplicated([child, sameFrameControl]).count == 2,
            "distinct same-frame Accessibility controls remain available"
        )
        check(
            TargetGeometry.merge(accessibility: [nestedParent], ocr: [visibleSettings])
                .map(\.id).contains(visibleSettings.id),
            "broad Accessibility container does not absorb OCR target"
        )
        let partialOCR = target(x: 85, y: 20, width: 40, height: 30, label: "partial", source: .ocr)
        check(
            TargetGeometry.merge(accessibility: [child], ocr: [partialOCR]).map(\.id).contains(partialOCR.id),
            "off-center OCR fallback remains available"
        )

        let assignments = HintGenerator.assign(to: (0..<10).map {
            target(x: CGFloat($0 * 20), y: 10, label: "target-\($0)")
        })
        check(HintGenerator.filter(assignments, prefix: "as").map(\.code) == ["AS"], "case-insensitive filtering")
        check(!TargetGeometry.isUsable(.null), "null geometry rejected")
        check(!TargetGeometry.isUsable(CGRect(x: 0, y: 0, width: 0, height: 10)), "empty geometry rejected")

        let searchTargets = [
            target(x: 200, y: 10, label: "Settings"),
            target(x: 20, y: 10, label: "Account Settings"),
            target(x: 20, y: 40, label: "Open Settings Panel"),
            target(x: 20, y: 70, label: "Resetting"),
            target(x: 20, y: 100, label: "System Toggle")
        ]
        check(
            TargetSearch.matches(query: "settings", targets: searchTargets).map(\.rank) == [0, 2, 2],
            "search exact and word-prefix ranks"
        )
        check(
            TargetSearch.matches(query: "set", targets: searchTargets).first?.target.label == "Settings",
            "search label prefix"
        )
        check(
            TargetSearch.matches(query: "count", targets: searchTargets).first?.rank == 3,
            "search substring"
        )
        check(
            TargetSearch.matches(query: "stg", targets: searchTargets).contains(where: {
                $0.target.label == "Settings" && $0.rank == 4
            }),
            "search fuzzy subsequence"
        )
        check(
            TargetSearch.matches(query: "set-", targets: searchTargets).first?.target.label == "Settings",
            "search trailing punctuation"
        )
        check(
            TargetSearch.matches(
                query: "ECOLE",
                targets: [target(x: 0, y: 0, label: "École")]
            ).first?.rank == 0,
            "search ignores case and diacritics"
        )

        let unifiedTargets = [
            target(x: 0, y: 0, label: "Settings"),
            target(x: 20, y: 0, label: "Other")
        ]
        let unifiedAssignments = HintGenerator.assign(to: unifiedTargets)
        check(
            TargetSearch.matches(query: "s", assignments: unifiedAssignments).map(\.target.label)
                == ["Other", "Settings"],
            "exact hint ranks before label match"
        )
        check(
            TargetSearch.matches(query: "settings", assignments: unifiedAssignments).first?.target.label
                == "Settings",
            "continued typing transitions from hint to label search"
        )
        let stableAssignments = HintGenerator.assign(to: (0..<10).map {
            target(x: CGFloat($0 * 20), y: 0, label: $0 == 8 ? "Account" : "Item \($0)")
        })
        check(
            TargetSearch.matches(query: "AS", assignments: stableAssignments).first?.target.id
                == stableAssignments.first(where: { $0.code == "AS" })?.target.id,
            "hint codes stay stable during unified search"
        )
        let hintPrefixMatches = TargetSearch.matches(query: "A", assignments: stableAssignments)
        check(
            hintPrefixMatches.count == 9 && hintPrefixMatches.allSatisfy { $0.rank == -1 },
            "hint prefix returns searchable targets"
        )

        let lowerTie = target(x: 0, y: 100, label: "Settings One")
        let upperRightTie = target(x: 100, y: 10, label: "Settings Two")
        let upperLeftTie = target(x: 10, y: 10, label: "Settings Six")
        check(
            TargetSearch.matches(query: "settings", targets: [lowerTie, upperRightTie, upperLeftTie])
                .map(\.target.id) == [upperLeftTie.id, upperRightTie.id, lowerTie.id],
            "search ties preserve top-left order"
        )
        check(TargetSearch.matches(query: "", targets: searchTargets).isEmpty, "empty search query")
        check(TargetSearch.matches(query: "---", targets: searchTargets).isEmpty, "punctuation-only search query")
        check(
            TargetSearch.matches(query: "settings", targets: [target(x: 0, y: 0, label: "  ")]).isEmpty,
            "blank search label"
        )
        check(TargetSearch.matches(query: "unfindable", targets: searchTargets).isEmpty, "search no match")

        let visibleFrame = CGRect(x: 100, y: 50, width: 1001, height: 801)
        let currentWindow = CGRect(x: 240, y: 160, width: 400, height: 300)
        check(
            WindowGeometry.frame(
                for: .tileLeft,
                currentFrame: currentWindow,
                visibleFrame: visibleFrame
            ) == CGRect(x: 100, y: 50, width: 500, height: 801),
            "left window tile"
        )
        check(
            WindowGeometry.frame(
                for: .tileRight,
                currentFrame: currentWindow,
                visibleFrame: visibleFrame
            ) == CGRect(x: 600, y: 50, width: 501, height: 801),
            "right window tile keeps odd pixel"
        )
        check(
            WindowGeometry.frame(
                for: .tileTop,
                currentFrame: currentWindow,
                visibleFrame: visibleFrame
            ) == CGRect(x: 100, y: 50, width: 1001, height: 400),
            "top window tile"
        )
        check(
            WindowGeometry.frame(
                for: .tileBottom,
                currentFrame: currentWindow,
                visibleFrame: visibleFrame
            ) == CGRect(x: 100, y: 450, width: 1001, height: 401),
            "bottom window tile keeps odd pixel"
        )
        check(
            WindowGeometry.frame(
                for: .center,
                currentFrame: currentWindow,
                visibleFrame: visibleFrame
            ) == CGRect(x: 400.5, y: 300.5, width: 400, height: 300),
            "center window preserves size"
        )
        check(
            WindowGeometry.frame(
                for: .center,
                currentFrame: CGRect(x: 0, y: 0, width: 2_000, height: 1_000),
                visibleFrame: visibleFrame
            ) == visibleFrame,
            "center window clamps oversize frame"
        )
        check(
            WindowGeometry.frame(
                for: .fill,
                currentFrame: currentWindow,
                visibleFrame: visibleFrame
            ) == visibleFrame,
            "fill window"
        )
        check(WindowArrangement.allCases.map(\.displayName) == [
            "Tile Window Left",
            "Tile Window Right",
            "Tile Window Top",
            "Tile Window Bottom",
            "Center Window",
            "Fill Window",
            "Full Screen"
        ], "window action names")
        let windowCommands = WindowCommandCatalog.targets(windowFrame: visibleFrame)
        let commandAssignments = windowCommands.map { HintAssignment(target: $0, code: "") }
        let commandQueries: [(String, WindowArrangement)] = [
            ("left", .tileLeft),
            ("right half", .tileRight),
            ("top", .tileTop),
            ("bottom", .tileBottom),
            ("centre", .center),
            ("maximize", .fill),
            ("full screen", .fullScreen)
        ]
        for (query, arrangement) in commandQueries {
            check(
                TargetSearch.matches(query: query, assignments: commandAssignments)
                    .first?.target.windowArrangement == arrangement,
                "window command search: \(query)"
            )
        }
        let leftElement = target(x: 0, y: 0, label: "Left")
        check(
            TargetSearch.matches(
                query: "left",
                targets: [leftElement] + windowCommands
            ).first?.target.windowArrangement == .tileLeft,
            "exact window command ranks before same-name element"
        )
        check(
            TargetSearch.matches(
                query: "left",
                assignments: [HintAssignment(target: leftElement, code: "A")] + commandAssignments
            ).first?.target.windowArrangement == .tileLeft,
            "window command ranking survives hint assignments"
        )
        check(
            commandAssignments.allSatisfy { $0.code.isEmpty },
            "window commands do not consume visible hint codes"
        )
        check(
            WindowGeometry.accessibilityFrame(
                from: CGRect(x: -1440, y: 100, width: 1440, height: 900),
                primaryScreenTop: 900
            ) == CGRect(x: -1440, y: -100, width: 1440, height: 900),
            "secondary display converts to Accessibility coordinates"
        )
        let leftDisplay = CGRect(x: -100, y: 0, width: 100, height: 100)
        let rightDisplay = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(
            WindowGeometry.bestVisibleFrame(
                for: CGRect(x: -20, y: 20, width: 80, height: 60),
                in: [leftDisplay, rightDisplay]
            ) == rightDisplay,
            "display selection uses greatest overlap"
        )
        check(
            WindowGeometry.bestVisibleFrame(
                for: CGRect(x: -250, y: 20, width: 40, height: 40),
                in: [leftDisplay, rightDisplay]
            ) == leftDisplay,
            "offscreen window selects nearest display"
        )
        check(
            WindowGeometry.bestVisibleFrame(for: currentWindow, in: []) == nil,
            "display selection handles no screens"
        )

        // The indexed search path must produce identical output to the
        // per-call normalization path for arbitrary targets and queries.
        var lcgState: UInt64 = 0x9E3779B97F4A7C15
        func nextRandom(_ bound: Int) -> Int {
            lcgState = lcgState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((lcgState >> 33) % UInt64(bound))
        }
        let vocabulary = [
            "Settings", "Account Overview", "École", "Zoë's Café",
            "Re: Launch Agent", "file / save", "hello   world", "MiXeD CaSe",
            "Über-uns", "naïve tab", "  padded  ", "Control", "日本語ボタン",
            "e-mail settings", "Backup & Sync", "Don't Stop", "42nd street"
        ]
        var corpusTargets: [ClickTarget] = []
        for index in 0..<160 {
            let label = vocabulary[nextRandom(vocabulary.count)]
            var aliases: [String] = []
            for _ in 0..<nextRandom(3) {
                aliases.append(vocabulary[nextRandom(vocabulary.count)])
            }
            if nextRandom(4) == 0 { aliases.append("alias-\(index)") }
            corpusTargets.append(ClickTarget(
                frame: CGRect(
                    x: CGFloat(nextRandom(1_000)),
                    y: CGFloat(nextRandom(800)),
                    width: 30,
                    height: 20
                ),
                label: label,
                source: .accessibility,
                searchAliases: aliases
            ))
        }
        let corpusQueries = [
            "settings", "SET", "eco", "cafe", "zoe", "launch", "save", "world",
            "mixed", "uber", "naive", "padded", "control", "backup", "stop",
            "street", "alias-7", "alias-", "stg", "sttings", "x", "", "---",
            "é c o", "42", "dont"
        ]
        for query in corpusQueries {
            let legacyTargets = TargetSearch.matches(query: query, targets: corpusTargets)
            let index = TargetSearch.searchIndex(for: corpusTargets)
            let legacyAssignments = HintGenerator.assign(to: corpusTargets)
            let legacyUnified = TargetSearch.matches(
                query: query,
                assignments: legacyAssignments
            )
            let indexedUnified = TargetSearch.matches(
                query: query,
                assignments: legacyAssignments,
                searchIndex: index
            )
            struct MatchSignature: Equatable {
                let id: UUID
                let rank: Int
                let score: Int
            }
            func signature(_ matches: [SearchMatch]) -> [MatchSignature] {
                matches.map { MatchSignature(id: $0.target.id, rank: $0.rank, score: $0.score) }
            }
            check(
                signature(indexedUnified) == signature(legacyUnified),
                "indexed search parity for query '\(query)'"
            )
            // With the hint layer neutralized (no valid prefix), the indexed
            // assignment search must equal the plain target search. Assignments
            // are built through HintGenerator.assign so both sides share the
            // same spatial ordering used in production.
            let bareAssignments = HintGenerator.assign(to: corpusTargets).map {
                HintAssignment(target: $0.target, code: "")
            }
            let indexedBare = TargetSearch.matches(
                query: query,
                assignments: bareAssignments,
                searchIndex: index
            )
            check(
                signature(indexedBare) == signature(legacyTargets),
                "indexed bare-search parity for query '\(query)'"
            )
        }

        // Scan recency policy gates instant repaint and warm-tree skipping.
        let baseInstant = ContinuousClock.Instant.now
        let windowFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        func record(
            pid: pid_t = 42,
            frame: CGRect = windowFrame,
            readOnly: Bool = true,
            age: Duration = .zero,
            from now: ContinuousClock.Instant
        ) -> ScanSnapshotRecord {
            ScanSnapshotRecord(
                pid: pid,
                windowFrame: frame,
                endedReadOnly: readOnly,
                capturedAt: now.advanced(by: age * -1)
            )
        }
        check(
            ScanRecencyPolicy.canInstantlyPresent(
                record: record(from: baseInstant),
                pid: 42,
                currentFrame: windowFrame,
                now: baseInstant
            ),
            "fresh read-only same-window snapshot may repaint instantly"
        )
        check(
            !ScanRecencyPolicy.canInstantlyPresent(
                record: record(readOnly: false, from: baseInstant),
                pid: 42,
                currentFrame: windowFrame,
                now: baseInstant
            ),
            "snapshot from activating session never repaints instantly"
        )
        check(
            !ScanRecencyPolicy.canInstantlyPresent(
                record: record(pid: 43, from: baseInstant),
                pid: 42,
                currentFrame: windowFrame,
                now: baseInstant
            ),
            "snapshot from another process never repaints instantly"
        )
        check(
            !ScanRecencyPolicy.canInstantlyPresent(
                record: record(frame: CGRect(x: 0, y: 0, width: 5, height: 5), from: baseInstant),
                pid: 42,
                currentFrame: windowFrame,
                now: baseInstant
            ),
            "changed window frame invalidates instant repaint"
        )
        check(
            !ScanRecencyPolicy.canInstantlyPresent(
                record: record(from: baseInstant),
                pid: 42,
                currentFrame: nil,
                now: baseInstant
            ),
            "missing probed frame blocks instant repaint"
        )
        check(
            !ScanRecencyPolicy.canInstantlyPresent(
                record: record(age: .milliseconds(801), from: baseInstant),
                pid: 42,
                currentFrame: windowFrame,
                now: baseInstant
            ),
            "stale snapshot refuses instant repaint"
        )
        check(
            ScanRecencyPolicy.canInstantlyPresent(
                record: record(age: .milliseconds(800), from: baseInstant),
                pid: 42,
                currentFrame: windowFrame,
                now: baseInstant
            ),
            "snapshot exactly at age limit still repaints instantly"
        )
        check(
            ScanRecencyPolicy.treeRecentlyWarmed(
                pid: 42,
                frame: windowFrame,
                lastScan: record(age: .milliseconds(999), from: baseInstant),
                now: baseInstant
            ),
            "recent same-window scan leaves tree warm"
        )
        check(
            !ScanRecencyPolicy.treeRecentlyWarmed(
                pid: 42,
                frame: windowFrame,
                lastScan: record(age: .milliseconds(1_001), from: baseInstant),
                now: baseInstant
            ),
            "expired scan no longer leaves tree warm"
        )
        check(
            !ScanRecencyPolicy.treeRecentlyWarmed(
                pid: 42,
                frame: CGRect(x: 1, y: 1, width: 9, height: 9),
                lastScan: record(from: baseInstant),
                now: baseInstant
            ),
            "moved window does not reuse warm tree"
        )

        if failures.isEmpty {
            print("Core self-tests passed")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() { failures.append(name) }
    }

    private static func target(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 40,
        height: CGFloat = 20,
        label: String,
        source: TargetSource = .accessibility
    ) -> ClickTarget {
        ClickTarget(
            frame: CGRect(x: x, y: y, width: width, height: height),
            label: label,
            source: source
        )
    }
}

private enum MockSystemCommandError: Error {
    case requestedFailure
}

private actor MockSystemCommandExecutor: SystemCommandExecuting {
    private var recordedCommands: [SystemCommand] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func execute(_ command: SystemCommand) async throws {
        recordedCommands.append(command)
        if shouldFail { throw MockSystemCommandError.requestedFailure }
    }

    func commands() -> [SystemCommand] {
        recordedCommands
    }
}
