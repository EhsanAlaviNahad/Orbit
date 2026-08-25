import ApplicationServices
import CoreGraphics
import Foundation

enum TargetSource: String, Codable, CaseIterable {
    case accessibility
    case dock
    case ocr
    case command

    fileprivate var mergePriority: Int {
        switch self {
        case .accessibility: 1
        case .dock: 3
        case .ocr: 0
        case .command: 2
        }
    }
}

/// Facts about a previously completed overlay session, used to decide whether
/// its scan output can be repainted instantly on the next activation.
struct ScanSnapshotRecord {
    let pid: pid_t
    let windowFrame: CGRect
    let endedReadOnly: Bool
    let capturedAt: ContinuousClock.Instant
}

enum ScanRecencyPolicy {
    static let maximumInstantPaintAge: Duration = .milliseconds(800)
    static let maximumWarmTreeAge: Duration = .milliseconds(1_000)

    /// Strict instant-paint eligibility: same app, identical current window
    /// frame, session closed without any activation, and still fresh.
    static func canInstantlyPresent(
        record: ScanSnapshotRecord?,
        pid: pid_t,
        currentFrame: CGRect?,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard let record else { return false }
        guard record.pid == pid else { return false }
        guard record.endedReadOnly else { return false }
        guard let currentFrame,
              TargetGeometry.isUsable(currentFrame),
              record.windowFrame == currentFrame else {
            return false
        }
        return isFresh(record.capturedAt, until: maximumInstantPaintAge, now: now)
    }

    /// A same-window scan within the last second leaves the accessibility
    /// tree warm; the second breadth-first warm-retry pass can be skipped.
    static func treeRecentlyWarmed(
        pid: pid_t,
        frame: CGRect,
        lastScan: ScanSnapshotRecord?,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard let lastScan else { return false }
        guard lastScan.pid == pid, lastScan.windowFrame == frame else { return false }
        return isFresh(lastScan.capturedAt, until: maximumWarmTreeAge, now: now)
    }

    private static func isFresh(
        _ capturedAt: ContinuousClock.Instant,
        until maximumAge: Duration,
        now: ContinuousClock.Instant
    ) -> Bool {
        capturedAt.duration(to: now) <= maximumAge
    }
}

struct ClickTarget: Identifiable, @unchecked Sendable {
    let id: UUID
    var frame: CGRect
    var label: String
    var source: TargetSource
    var axElement: AXUIElement?
    var axAction: String?
    var searchAliases: [String]
    var windowArrangement: WindowArrangement?

    init(
        id: UUID = UUID(),
        frame: CGRect,
        label: String = "",
        source: TargetSource,
        axElement: AXUIElement? = nil,
        axAction: String? = nil,
        searchAliases: [String] = [],
        windowArrangement: WindowArrangement? = nil
    ) {
        self.id = id
        self.frame = frame.standardized
        self.label = label
        self.source = source
        self.axElement = axElement
        self.axAction = axAction
        self.searchAliases = searchAliases
        self.windowArrangement = windowArrangement
    }

    var clickPoint: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

}

struct KeyboardShortcut: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var displayName: String

    init(keyCode: UInt32, carbonModifiers: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayName = displayName
    }

    /// ANSI E key plus Carbon's `cmdKey` bit.
    static let commandE = KeyboardShortcut(
        keyCode: 14,
        carbonModifiers: 1 << 8,
        displayName: "⌘E"
    )
}

enum ScrollDirection: Equatable, Sendable {
    case up
    case down
}

struct HintColorComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let defaultCustom = HintColorComponents(red: 0.29, green: 0.46, blue: 0.95)!

    init?(red: Double, green: Double, blue: Double) {
        let values = [red, green, blue]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        self.red = red
        self.green = green
        self.blue = blue
    }

    var usesLightForeground: Bool {
        relativeLuminance < 0.179
    }

    private var relativeLuminance: Double {
        func linearized(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }
}

enum HintLabelMetrics {
    static let defaultFontSize = 13.0
    static let minimumFontSize = 10.0
    static let maximumFontSize = 26.0

    static func clampedFontSize(_ size: Double) -> Double {
        min(maximumFontSize, max(minimumFontSize, size))
    }
}

enum OverlayShortcutPolicy {
    static func scrollDirection(keyCode: UInt16, flags: CGEventFlags) -> ScrollDirection? {
        guard flags.contains(.maskControl) else { return nil }
        let incompatible: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
        guard flags.intersection(incompatible).isEmpty else { return nil }
        return switch keyCode {
        case 126: .up
        case 125: .down
        default: nil
        }
    }
}

enum ActivationActionPolicy {
    static let preferredActions = [
        kAXPressAction as String,
        kAXConfirmAction as String,
        "AXPick",
        "AXOpen"
    ]

    static let supportedActions = Set(preferredActions)

    static func preferredAction(from actions: [String]) -> String? {
        preferredActions.first(where: actions.contains)
    }
}

enum DockTargetPolicy {
    static func isEligible(
        role: String,
        subrole: String,
        actions: [String],
        frame: CGRect
    ) -> Bool {
        (role == "AXDockItem" || subrole.hasSuffix("DockItem"))
            && subrole != "AXSeparatorDockItem"
            && actions.contains(kAXPressAction as String)
            && frame.width >= 8
            && frame.height >= 8
    }
}

enum WindowArrangement: Int, CaseIterable, Sendable {
    case tileLeft
    case tileRight
    case tileTop
    case tileBottom
    case center
    case fill
    case fullScreen

    var displayName: String {
        switch self {
        case .tileLeft: "Tile Window Left"
        case .tileRight: "Tile Window Right"
        case .tileTop: "Tile Window Top"
        case .tileBottom: "Tile Window Bottom"
        case .center: "Center Window"
        case .fill: "Fill Window"
        case .fullScreen: "Full Screen"
        }
    }

    var searchAliases: [String] {
        switch self {
        case .tileLeft:
            ["left", "tile left", "left half", "window left", "move window left"]
        case .tileRight:
            ["right", "tile right", "right half", "window right", "move window right"]
        case .tileTop:
            ["top", "tile top", "top half", "window top", "move window up"]
        case .tileBottom:
            ["bottom", "tile bottom", "bottom half", "window bottom", "move window down"]
        case .center:
            ["center", "centre", "center window", "centre window"]
        case .fill:
            ["fill", "fill window", "maximize", "maximise", "maximize window"]
        case .fullScreen:
            ["fullscreen", "full screen", "enter fullscreen", "enter full screen"]
        }
    }
}

enum WindowCommandCatalog {
    static func targets(windowFrame: CGRect) -> [ClickTarget] {
        let commandFrame = CGRect(
            x: windowFrame.midX,
            y: windowFrame.midY,
            width: 1,
            height: 1
        )
        return WindowArrangement.allCases.map { arrangement in
            ClickTarget(
                frame: commandFrame,
                label: arrangement.displayName,
                source: .command,
                searchAliases: arrangement.searchAliases,
                windowArrangement: arrangement
            )
        }
    }
}

enum WindowGeometry {
    static func accessibilityFrame(from appKitFrame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(
            x: appKitFrame.minX,
            y: primaryScreenTop - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }

    static func frame(
        for arrangement: WindowArrangement,
        currentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let visible = visibleFrame.standardized
        guard TargetGeometry.isUsable(visible) else { return currentFrame.standardized }

        let halfWidth = floor(visible.width / 2)
        let halfHeight = floor(visible.height / 2)
        switch arrangement {
        case .tileLeft:
            return CGRect(
                x: visible.minX,
                y: visible.minY,
                width: halfWidth,
                height: visible.height
            )
        case .tileRight:
            return CGRect(
                x: visible.minX + halfWidth,
                y: visible.minY,
                width: visible.width - halfWidth,
                height: visible.height
            )
        case .tileTop:
            return CGRect(
                x: visible.minX,
                y: visible.minY,
                width: visible.width,
                height: halfHeight
            )
        case .tileBottom:
            return CGRect(
                x: visible.minX,
                y: visible.minY + halfHeight,
                width: visible.width,
                height: visible.height - halfHeight
            )
        case .center:
            let usableCurrent = TargetGeometry.isUsable(currentFrame)
                ? currentFrame.standardized
                : visible
            let width = min(usableCurrent.width, visible.width)
            let height = min(usableCurrent.height, visible.height)
            return CGRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            )
        case .fill, .fullScreen:
            return visible
        }
    }

    static func bestVisibleFrame(for window: CGRect, in screens: [CGRect]) -> CGRect? {
        screens.max { left, right in
            let leftArea = intersectionArea(window, left)
            let rightArea = intersectionArea(window, right)
            if leftArea != rightArea { return leftArea < rightArea }
            let leftDistance = hypot(window.midX - left.midX, window.midY - left.midY)
            let rightDistance = hypot(window.midX - right.midX, window.midY - right.midY)
            return leftDistance > rightDistance
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

struct HintAssignment: Identifiable {
    var target: ClickTarget
    var code: String

    var id: UUID { target.id }
}

struct SearchMatch: Identifiable {
    var target: ClickTarget
    var rank: Int
    var score: Int

    var id: UUID { target.id }
}

enum TargetSearch {
    private enum MatchRank: Int {
        case exact
        case labelPrefix
        case wordPrefix
        case substring
        case fuzzySubsequence
    }

    static func matches(query: String, targets: [ClickTarget]) -> [SearchMatch] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let rankedMatches: [(match: SearchMatch, spatialIndex: Int)] = TargetGeometry.sortedTopLeft(targets)
            .enumerated().compactMap { entry -> (match: SearchMatch, spatialIndex: Int)? in
            let (spatialIndex, target) = entry
            let relevance = bestRelevance(query: normalizedQuery, target: target)
            guard let relevance else { return nil }

            return (
                SearchMatch(target: target, rank: relevance.rank.rawValue, score: relevance.score),
                spatialIndex
            )
        }
        return rankedMatches.sorted { lhs, rhs in
            if lhs.match.rank != rhs.match.rank { return lhs.match.rank < rhs.match.rank }
            if lhs.match.score != rhs.match.score { return lhs.match.score < rhs.match.score }
            if (lhs.match.target.windowArrangement != nil)
                != (rhs.match.target.windowArrangement != nil) {
                return lhs.match.target.windowArrangement != nil
            }
            return lhs.spatialIndex < rhs.spatialIndex
        }.map(\.match)
    }

    /// Precomputes the normalized search terms (label first, then aliases) for
    /// each target so per-keystroke searches skip repeated Unicode folding.
    static func searchIndex(for targets: [ClickTarget]) -> [UUID: [String]] {
        var index: [UUID: [String]] = Dictionary(minimumCapacity: targets.count)
        for target in targets {
            var terms: [String] = []
            terms.reserveCapacity(1 + target.searchAliases.count)
            appendNormalized(target.label, to: &terms)
            for alias in target.searchAliases {
                appendNormalized(alias, to: &terms)
            }
            index[target.id] = terms
        }
        return index
    }

    /// Same ranking as `matches(query:assignments:)` but reads precomputed
    /// terms from `searchIndex` instead of re-normalizing on every keystroke,
    /// and skips the redundant spatial re-sort of the target list.
    static func matches(
        query: String,
        assignments: [HintAssignment],
        searchIndex: [UUID: [String]]
    ) -> [SearchMatch] {
        let normalizedQuery = normalize(query)
        let labelMatches: [UUID: SearchMatch]
        if normalizedQuery.isEmpty {
            labelMatches = [:]
        } else {
            var matchesByID: [UUID: SearchMatch] = Dictionary(
                minimumCapacity: assignments.count
            )
            for assignment in assignments {
                let id = assignment.target.id
                guard matchesByID[id] == nil else { continue }
                guard let relevance = bestRelevance(
                    query: normalizedQuery,
                    terms: searchIndex[id] ?? []
                ) else { continue }
                matchesByID[id] = SearchMatch(
                    target: assignment.target,
                    rank: relevance.rank.rawValue,
                    score: relevance.score
                )
            }
            labelMatches = matchesByID
        }

        let hintQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let canMatchHint = HintGenerator.isValidInput(hintQuery)

        return assignments.enumerated().compactMap { index, assignment -> (SearchMatch, Int)? in
            if canMatchHint, assignment.code == hintQuery {
                return (SearchMatch(target: assignment.target, rank: -2, score: 0), index)
            }
            if canMatchHint, assignment.code.hasPrefix(hintQuery) {
                return (
                    SearchMatch(
                        target: assignment.target,
                        rank: -1,
                        score: assignment.code.count - hintQuery.count
                    ),
                    index
                )
            }
            guard let match = labelMatches[assignment.target.id] else { return nil }
            return (match, index)
        }.sorted { lhs, rhs in
            if lhs.0.rank != rhs.0.rank { return lhs.0.rank < rhs.0.rank }
            if lhs.0.score != rhs.0.score { return lhs.0.score < rhs.0.score }
            if (lhs.0.target.windowArrangement != nil)
                != (rhs.0.target.windowArrangement != nil) {
                return lhs.0.target.windowArrangement != nil
            }
            return lhs.1 < rhs.1
        }.map(\.0)
    }

    private static func appendNormalized(_ term: String, to terms: inout [String]) {
        let normalizedTerm = normalize(term)
        guard !normalizedTerm.isEmpty else { return }
        terms.append(normalizedTerm)
    }

    static func matches(query: String, assignments: [HintAssignment]) -> [SearchMatch] {
        let labelMatches = Dictionary(
            uniqueKeysWithValues: matches(
                query: query,
                targets: assignments.map(\.target)
            ).map { ($0.target.id, $0) }
        )
        let hintQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let canMatchHint = HintGenerator.isValidInput(hintQuery)

        return assignments.enumerated().compactMap { index, assignment in
            if canMatchHint, assignment.code == hintQuery {
                return (SearchMatch(target: assignment.target, rank: -2, score: 0), index)
            }
            if canMatchHint, assignment.code.hasPrefix(hintQuery) {
                return (
                    SearchMatch(
                        target: assignment.target,
                        rank: -1,
                        score: assignment.code.count - hintQuery.count
                    ),
                    index
                )
            }
            guard let match = labelMatches[assignment.target.id] else { return nil }
            return (match, index)
        }.sorted { lhs, rhs in
            if lhs.0.rank != rhs.0.rank { return lhs.0.rank < rhs.0.rank }
            if lhs.0.score != rhs.0.score { return lhs.0.score < rhs.0.score }
            if (lhs.0.target.windowArrangement != nil)
                != (rhs.0.target.windowArrangement != nil) {
                return lhs.0.target.windowArrangement != nil
            }
            return lhs.1 < rhs.1
        }.map(\.0)
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let punctuationAsSpaces = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.punctuationCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        return String(punctuationAsSpaces)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func relevance(query: String, label: String) -> (rank: MatchRank, score: Int)? {
        if label == query {
            return (.exact, 0)
        }
        if label.hasPrefix(query) {
            return (.labelPrefix, label.count - query.count)
        }

        let words = label.split(separator: " ")
        if let wordIndex = words.firstIndex(where: { $0.hasPrefix(query) }) {
            return (.wordPrefix, wordIndex * 1_000 + words[wordIndex].count - query.count)
        }
        if let range = label.range(of: query) {
            let offset = label.distance(from: label.startIndex, to: range.lowerBound)
            return (.substring, offset * 1_000 + label.count - query.count)
        }
        if let score = fuzzyScore(query: query, label: label) {
            return (.fuzzySubsequence, score)
        }
        return nil
    }

    private static func bestRelevance(
        query: String,
        target: ClickTarget
    ) -> (rank: MatchRank, score: Int)? {
        var terms: [String] = []
        terms.reserveCapacity(1 + target.searchAliases.count)
        appendNormalized(target.label, to: &terms)
        for alias in target.searchAliases {
            appendNormalized(alias, to: &terms)
        }
        return bestRelevance(query: query, terms: terms)
    }

    private static func bestRelevance(
        query: String,
        terms: [String]
    ) -> (rank: MatchRank, score: Int)? {
        var best: (rank: MatchRank, score: Int)?
        for term in terms where !term.isEmpty {
            guard let candidate = relevance(query: query, label: term) else {
                continue
            }
            if let current = best,
               current.rank.rawValue < candidate.rank.rawValue
                    || (current.rank == candidate.rank && current.score <= candidate.score) {
                continue
            }
            best = candidate
        }
        return best
    }

    private static func fuzzyScore(query: String, label: String) -> Int? {
        let queryCharacters = Array(query)
        let labelCharacters = Array(label)
        guard !queryCharacters.isEmpty else { return nil }

        var queryIndex = 0
        var firstMatch = 0
        var previousMatch = -1
        var gapCount = 0

        for (labelIndex, character) in labelCharacters.enumerated()
        where queryIndex < queryCharacters.count && character == queryCharacters[queryIndex] {
            if queryIndex == 0 {
                firstMatch = labelIndex
            } else {
                gapCount += labelIndex - previousMatch - 1
            }
            previousMatch = labelIndex
            queryIndex += 1
        }

        guard queryIndex == queryCharacters.count else { return nil }
        return firstMatch * 10_000 + gapCount * 100 + labelCharacters.count - queryCharacters.count
    }
}

enum HintGenerator {
    static let alphabet = Array("ASDFGHJKL")

    static func codes(count: Int) -> [String] {
        guard count > 0 else { return [] }

        let length = requiredCodeLength(for: count)
        return (0..<count).map { encoded($0, length: length) }
    }

    static func assign(to targets: [ClickTarget]) -> [HintAssignment] {
        let orderedTargets = TargetGeometry.sortedTopLeft(targets)
        return zip(orderedTargets, codes(count: orderedTargets.count)).map {
            HintAssignment(target: $0.0, code: $0.1)
        }
    }

    static func filter(_ assignments: [HintAssignment], prefix: String) -> [HintAssignment] {
        let normalizedPrefix = prefix.uppercased()
        guard !normalizedPrefix.isEmpty else { return assignments }
        return assignments.filter { $0.code.hasPrefix(normalizedPrefix) }
    }

    static func isValidInput(_ input: String) -> Bool {
        !input.isEmpty && input.uppercased().allSatisfy(alphabet.contains)
    }

    private static func requiredCodeLength(for count: Int) -> Int {
        var length = 1
        var capacity = alphabet.count

        while capacity < count {
            if capacity > Int.max / alphabet.count {
                return length + 1
            }
            capacity *= alphabet.count
            length += 1
        }
        return length
    }

    private static func encoded(_ value: Int, length: Int) -> String {
        var remainder = value
        var characters = Array(repeating: alphabet[0], count: length)

        for index in stride(from: length - 1, through: 0, by: -1) {
            characters[index] = alphabet[remainder % alphabet.count]
            remainder /= alphabet.count
        }
        return String(characters)
    }
}

struct GeometryMergePolicy {
    var minimumIntersectionOverUnion: CGFloat = 0.60
    var minimumSmallerRectCoverage: CGFloat = 0.80
    var minimumOCRCoverage: CGFloat = 0.35
    var maximumAXToOCRAreaRatio: CGFloat = 12
    var maximumCenterDistance: CGFloat = 4
    var minimumSizeSimilarity: CGFloat = 0.85

    static let `default` = GeometryMergePolicy()
}

enum TargetGeometry {
    static func sortedTopLeft(_ targets: [ClickTarget]) -> [ClickTarget] {
        targets.enumerated().sorted { lhs, rhs in
            let left = lhs.element.frame
            let right = rhs.element.frame

            if left.minY != right.minY { return left.minY < right.minY }
            if left.minX != right.minX { return left.minX < right.minX }
            if left.width != right.width { return left.width < right.width }
            if left.height != right.height { return left.height < right.height }
            if lhs.element.label != rhs.element.label {
                return lhs.element.label.localizedStandardCompare(rhs.element.label) == .orderedAscending
            }
            if lhs.element.source != rhs.element.source {
                return lhs.element.source.mergePriority > rhs.element.source.mergePriority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func isUsable(_ frame: CGRect) -> Bool {
        !frame.isNull
            && !frame.isInfinite
            && !frame.isEmpty
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        guard isUsable(lhs), isUsable(rhs) else { return 0 }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = area(lhs) + area(rhs) - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    static func smallerRectCoverage(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        guard isUsable(lhs), isUsable(rhs) else { return 0 }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let smallerArea = min(area(lhs), area(rhs))
        return smallerArea > 0 ? area(intersection) / smallerArea : 0
    }

    static func areDuplicates(
        _ lhs: CGRect,
        _ rhs: CGRect,
        policy: GeometryMergePolicy = .default
    ) -> Bool {
        if intersectionOverUnion(lhs, rhs) >= policy.minimumIntersectionOverUnion {
            return true
        }
        if smallerRectCoverage(lhs, rhs) >= policy.minimumSmallerRectCoverage,
           sizeSimilarity(lhs.size, rhs.size) >= policy.minimumSizeSimilarity {
            return true
        }

        let centerDistance = hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
        return centerDistance <= policy.maximumCenterDistance
            && sizeSimilarity(lhs.size, rhs.size) >= policy.minimumSizeSimilarity
    }

    static func deduplicated(
        _ targets: [ClickTarget],
        policy: GeometryMergePolicy = .default
    ) -> [ClickTarget] {
        var result: [ClickTarget] = []
        var accessibilityIndicesByHash: [CFHashCode: [Int]] = [:]
        var geometryCandidateIndices: [Int] = []

        for candidate in sortedTopLeft(targets).filter({ isUsable($0.frame) }) {
            let duplicateIndex: Int?
            if candidate.source == .accessibility, let element = candidate.axElement {
                duplicateIndex = accessibilityIndicesByHash[CFHash(element)]?.first(where: { index in
                    guard let existingElement = result[index].axElement else { return false }
                    return CFEqual(existingElement, element)
                        && areDuplicates(result[index].frame, candidate.frame, policy: policy)
                })
            } else {
                duplicateIndex = geometryCandidateIndices.first(where: { index in
                    mayRepresentSameTarget(result[index], candidate)
                        && areDuplicates(result[index].frame, candidate.frame, policy: policy)
                })
            }

            guard let duplicateIndex else {
                let index = result.count
                result.append(candidate)
                if candidate.source == .accessibility, let element = candidate.axElement {
                    accessibilityIndicesByHash[CFHash(element), default: []].append(index)
                } else {
                    geometryCandidateIndices.append(index)
                }
                continue
            }

            if candidate.source.mergePriority > result[duplicateIndex].source.mergePriority {
                result[duplicateIndex] = candidate
            }
        }
        return sortedTopLeft(result)
    }

    static func merge(
        accessibility: [ClickTarget],
        ocr: [ClickTarget],
        policy: GeometryMergePolicy = .default
    ) -> [ClickTarget] {
        var accessibilityTargets = deduplicated(
            accessibility.map { target in
                var copy = target
                copy.source = .accessibility
                return copy
            },
            policy: policy
        )

        let ocrTargets = deduplicated(
            ocr.map { target in
                var copy = target
                copy.source = .ocr
                return copy
            },
            policy: policy
        )
        var uncoveredOCRTargets: [ClickTarget] = []
        for candidate in ocrTargets {
            let coveredIndices = accessibilityTargets.indices.filter { index in
                let frame = accessibilityTargets[index].frame
                let frameArea = area(frame)
                let candidateArea = area(candidate.frame)
                let areaRatio = max(frameArea, candidateArea) / max(min(frameArea, candidateArea), 1)
                return areDuplicates(frame, candidate.frame, policy: policy)
                    || (frame.contains(candidate.clickPoint)
                        && smallerRectCoverage(frame, candidate.frame) >= policy.minimumOCRCoverage
                        && areaRatio <= policy.maximumAXToOCRAreaRatio)
            }
            let coveredIndex = coveredIndices.min { lhs, rhs in
                let leftFrame = accessibilityTargets[lhs].frame
                let rightFrame = accessibilityTargets[rhs].frame
                let leftDuplicate = areDuplicates(leftFrame, candidate.frame, policy: policy)
                let rightDuplicate = areDuplicates(rightFrame, candidate.frame, policy: policy)
                if leftDuplicate != rightDuplicate { return leftDuplicate }
                let leftContains = leftFrame.contains(candidate.clickPoint)
                let rightContains = rightFrame.contains(candidate.clickPoint)
                if leftContains != rightContains { return leftContains }
                if leftContains, rightContains, area(leftFrame) != area(rightFrame) {
                    return area(leftFrame) < area(rightFrame)
                }
                return smallerRectCoverage(leftFrame, candidate.frame)
                    > smallerRectCoverage(rightFrame, candidate.frame)
            }
            if let coveredIndex {
                let visibleText = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !visibleText.isEmpty,
                   accessibilityTargets[coveredIndex].label.range(
                       of: visibleText,
                       options: [.caseInsensitive, .diacriticInsensitive]
                   ) == nil {
                    accessibilityTargets[coveredIndex].label += " \(visibleText)"
                }
            } else {
                uncoveredOCRTargets.append(candidate)
            }
        }

        return sortedTopLeft(accessibilityTargets + uncoveredOCRTargets)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func mayRepresentSameTarget(_ lhs: ClickTarget, _ rhs: ClickTarget) -> Bool {
        guard lhs.source == .accessibility, rhs.source == .accessibility else { return true }
        if let leftElement = lhs.axElement, let rightElement = rhs.axElement {
            return CFEqual(leftElement, rightElement)
        }
        return lhs.label.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(
                rhs.label.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }

    private static func sizeSimilarity(_ lhs: CGSize, _ rhs: CGSize) -> CGFloat {
        let largerWidth = max(lhs.width, rhs.width)
        let largerHeight = max(lhs.height, rhs.height)
        guard largerWidth > 0, largerHeight > 0 else { return 0 }
        return min(lhs.width, rhs.width) / largerWidth
            * min(lhs.height, rhs.height) / largerHeight
    }
}
