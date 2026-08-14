import CoreGraphics
import Foundation

@main
enum CoreSelfTests {
    private static var failures: [String] = []

    static func main() {
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
