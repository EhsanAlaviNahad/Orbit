import AppKit
import ApplicationServices
import CoreGraphics

// Benchmarks the accessibility read strategies Orbit relies on, so scan cost on
// the current macOS release is measured instead of assumed.

let batchKeys = [
    kAXChildrenAttribute as String,
    kAXRoleAttribute as String,
    kAXEnabledAttribute as String,
    kAXHiddenAttribute as String,
    kAXPositionAttribute as String,
    kAXSizeAttribute as String,
    kAXTitleAttribute as String,
    kAXDescriptionAttribute as String,
    kAXHelpAttribute as String,
    "AXIdentifier",
    "AXPlaceholderValue",
    kAXRoleDescriptionAttribute as String,
    kAXValueAttribute as String,
]

struct Stats {
    var elements = 0
    var batchSuccess = 0
    var batchFailureByError: [Int: Int] = [:]
    var individualFallbacks = 0
    var batchNanos: UInt64 = 0
    var individualNanos: UInt64 = 0
    var actionNameFailures = 0
    var actionNameCalls = 0
    var targets = 0
    var treeDepthLimited = false
}

func axErrorName(_ code: Int) -> String {
    switch code {
    case 0: "success"
    case -25200: "failure"
    case -25201: "illegalFunctionArgument"
    case -25202: "illegalOption"
    case -25204: "cannotComplete"
    case -25205: "cannotConvert"
    case -25206: "actionUnsupported"
    case -25208: "notificationUnregistered"
    case -25209: "apiDisabled"
    case -25210: "noValue"
    case -25211: "attributeUnsupported"
    case -25212: "notImplemented"
    case -25213: "notFound"
    default: "axError(\(code))"
    }
}

func focusedWindow(of pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.40)
    func copy(_ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    func copyList(_ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, name as CFString, &value) == .success else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
    }
    let window = copy(kAXFocusedWindowAttribute as String)
        ?? copy(kAXMainWindowAttribute as String)
        ?? copyList(kAXWindowsAttribute as String).first
    if let window {
        AXUIElementSetMessagingTimeout(window, 0.20)
    }
    return window
}

func individualRead(
    _ element: AXUIElement,
    keys: [String],
    stats: inout Stats
) -> UInt64 {
    let start = ContinuousClock.now
    for key in keys {
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, key as CFString, &value)
    }
    var actions: CFArray?
    stats.actionNameCalls += 1
    if AXUIElementCopyActionNames(element, &actions) != .success {
        stats.actionNameFailures += 1
    }
    return UInt64(max(0, start.duration(to: ContinuousClock.now).components.attoseconds / 1_000_000_000))
}

func walk(
    root: AXUIElement,
    limit: Int,
    stats: inout Stats,
    deadline: ContinuousClock.Instant
) {
    var pending = [root]
    var visited: [CFHashCode: [AXUIElement]] = [:]
    while let element = pending.popLast(), stats.elements < limit, ContinuousClock.now < deadline {
        AXUIElementSetMessagingTimeout(element, 0.15)
        let hash = CFHash(element)
        if visited[hash]?.contains(where: { CFEqual($0, element) }) == true { continue }
        visited[hash, default: []].append(element)
        stats.elements += 1

        var raw: CFArray?
        let batchStart = ContinuousClock.now
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            batchKeys as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &raw
        )
        let batchElapsed = UInt64(max(0, batchStart.duration(to: ContinuousClock.now)
            .components.attoseconds / 1_000_000_000))
        stats.batchNanos += batchElapsed

        if status == .success, let values = raw as? [Any], values.count == batchKeys.count {
            stats.batchSuccess += 1
            if let children = values[0] as? [AXUIElement] {
                pending.append(contentsOf: children.reversed())
            }
        } else {
            stats.batchFailureByError[Int(status.rawValue), default: 0] += 1
            stats.individualFallbacks += 1
            stats.individualNanos += individualRead(element, keys: batchKeys, stats: &stats)
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &children
            ) == .success, let kids = children as? [AXUIElement] {
                pending.append(contentsOf: kids.reversed())
            }
        }
        stats.actionNameCalls += 1
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) != .success {
            stats.actionNameFailures += 1
        }
    }
    if stats.elements == limit { stats.treeDepthLimited = true }
}

func nanoseconds(_ d: Duration) -> UInt64 { UInt64(max(0, d.components.attoseconds / 1_000_000_000)) }

func runningApplication(_ bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}

func describe(_ stats: Stats) -> String {
    let perBatch = stats.batchSuccess > 0
        ? Double(stats.batchNanos) / Double(stats.batchSuccess) / 1_000_000
        : 0
    let perFallback = stats.individualFallbacks > 0
        ? Double(stats.individualNanos) / Double(stats.individualFallbacks) / 1_000_000
        : 0
    let failures = stats.batchFailureByError.values.reduce(0, +)
    var lines: [String] = []
    lines.append("  elements visited: \(stats.elements)")
    lines.append("  batch reads: \(stats.batchSuccess) ok, \(failures) failed")
    for (code, count) in stats.batchFailureByError.sorted(by: { $0.key < $1.key }) {
        lines.append("    fail \(axErrorName(code)): \(count)")
    }
    lines.append("  avg batch read: \(String(format: "%.3f", perBatch)) ms")
    if stats.individualFallbacks > 0 {
        lines.append("  avg \(batchKeys.count)-attribute fallback: \(String(format: "%.3f", perFallback)) ms")
    }
    lines.append("  action-name reads: \(stats.actionNameCalls) calls, \(stats.actionNameFailures) failed")
    return lines.joined(separator: "\n")
}

_ = NSApplication.shared
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("ax trusted=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess())")

let bundleIDs = Array(CommandLine.arguments.dropFirst()).isEmpty
    ? ["com.apple.finder", "com.apple.Safari", "com.apple.dock"]
    : Array(CommandLine.arguments.dropFirst())

for bundleID in bundleIDs {
    guard let app = runningApplication(bundleID) else {
        print("\n\(bundleID): not running")
        continue
    }
    let pid = app.processIdentifier
    print("\n=== \(bundleID) (pid \(pid)) ===")

    // Strategy cost on the same tree, twice: cold pass then warm pass.
    for pass in 1...2 {
        guard let window = focusedWindow(of: pid) else {
            print("  no focused window")
            break
        }
        var stats = Stats()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1_250))
        let start = ContinuousClock.now
        walk(root: window, limit: 12_000, stats: &stats, deadline: deadline)
        let wall = nanoseconds(start.duration(to: ContinuousClock.now))
        print("  pass \(pass) raw walk wall: \(String(format: "%.1f", Double(wall) / 1_000_000)) ms")
        print(describe(stats))
    }

    // End-to-end cost through the code Orbit actually ships.
    let scanner = TargetScanner()
    for attempt in 1...3 {
        let start = ContinuousClock.now
        do {
            let scan = try await scanner.beginFocusedWindowScan(pid: pid)
            let axWall = nanoseconds(start.duration(to: ContinuousClock.now))
            let mergedStart = ContinuousClock.now
            let merged = await scan.mergedTargetsTask.value
            let mergedWall = nanoseconds(mergedStart.duration(to: ContinuousClock.now))
            print("  orbit scan attempt \(attempt): ax \(String(format: "%.1f", Double(axWall) / 1_000_000)) ms"
                + " (\(scan.accessibilityTargets.count) targets, complete=\(scan.accessibilityIsComplete))"
                + " | merge \(String(format: "%.1f", Double(mergedWall) / 1_000_000)) ms -> \(merged.count) targets")
        } catch {
            print("  orbit scan attempt \(attempt) failed: \(error.localizedDescription)")
            break
        }
    }
}

// MARK: - Diagnosis of the two suspects

func readAttribute(_ element: AXUIElement, _ name: String) -> String {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard status == .success, let value else { return "err(\(status.rawValue))" }
    if CFGetTypeID(value) == AXUIElementGetTypeID() { return "element" }
    return String(describing: value)
}

func cpuSeconds(_ pid: pid_t) -> Double { -1 }

/// Replicates TargetScanner.elementSnapshot's reliability rule so the cost of a
/// misclassified tree can be attributed to a specific cause.
func classifyTree(pid: pid_t, limit: Int = 4_000) -> [String: Int] {
    guard let window = focusedWindow(of: pid) else { return [:] }
    let alternateRoles: Set<String> = [
        "AXWindow", "AXWebArea", "AXGroup", "AXScrollArea", "AXList", "AXBrowser",
        "AXRow", "AXTable", "AXOutline", "AXToolbar", "AXTabGroup", "AXSplitGroup",
        "AXSheet", "AXPopover",
    ]
    var pending = [window]
    var visited: [CFHashCode: [AXUIElement]] = [:]
    var counts: [String: Int] = [:]
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while let element = pending.popLast(), counts.values.reduce(0, +) < limit,
          ContinuousClock.now < deadline {
        AXUIElementSetMessagingTimeout(element, 0.15)
        let hash = CFHash(element)
        if visited[hash]?.contains(where: { CFEqual($0, element) }) == true { continue }
        visited[hash, default: []].append(element)
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element, batchKeys as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
        )
        guard status == .success, let values = raw as? [Any], values.count == batchKeys.count else {
            counts["batchFailed"] = (counts["batchFailed"] ?? 0) + 1
            continue
        }
        let role = values[1] as? String ?? ""
        if role.isEmpty { counts["emptyRole"] = (counts["emptyRole"] ?? 0) + 1 }
        let isAlternate = alternateRoles.contains(role)
        if isAlternate, !(values[0] is [AXUIElement]) {
            counts["childrenCastFailed:\(role)"] = (counts["childrenCastFailed:\(role)"] ?? 0) + 1
        }
        if let children = values[0] as? [AXUIElement] {
            pending.append(contentsOf: children.reversed())
        }
    }
    counts["total"] = visited.values.reduce(0) { $0 + $1.count }
    return counts
}

func diagnoseFlags(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    print("  AXEnhancedUserInterface=\(readAttribute(app, "AXEnhancedUserInterface"))"
        + " AXManualAccessibility=\(readAttribute(app, "AXManualAccessibility"))")
}

func abScan(pid: pid_t, label: String) async {
    // A focused window only exists for the frontmost app, so bring the target
    // forward before scanning it, exactly like a real ⌘E activation does.
    NSRunningApplication(processIdentifier: pid)?.activate()
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    var focused: CFTypeRef?
    var waited = ContinuousClock.now
    while (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) != .success
            || NSWorkspace.shared.frontmostApplication?.processIdentifier != pid),
          ContinuousClock.now - waited < .seconds(2) {
        NSRunningApplication(processIdentifier: pid)?.activate()
        usleep(50_000)
    }
    let scanner = TargetScanner()
    let start = ContinuousClock.now
    do {
        let scan = try await scanner.beginFocusedWindowScan(pid: pid)
        let ax = Double(nanoseconds(start.duration(to: ContinuousClock.now))) / 1_000_000
        let mergedStart = ContinuousClock.now
        let merged = await scan.mergedTargetsTask.value
        let merge = Double(nanoseconds(mergedStart.duration(to: ContinuousClock.now))) / 1_000_000
        print("  [\(label)] ax \(String(format: "%.0f", ax)) ms"
            + " (\(scan.accessibilityTargets.count) targets complete=\(scan.accessibilityIsComplete))"
            + " | merge \(String(format: "%.0f", merge)) ms -> \(merged.count)")
    } catch {
        print("  [\(label)] failed: \(error.localizedDescription)")
    }
}

print("\n########## diagnosis ##########")
let diagnoseTargets = bundleIDs.isEmpty
    ? ["com.apple.finder", "com.apple.Safari", "com.qoder.app", "ai.storyteller.artcraft-launcher"]
    : bundleIDs
for bundleID in diagnoseTargets {
    guard let app = runningApplication(bundleID) else {
        print("\n\(bundleID): not running")
        continue
    }
    let pid = app.processIdentifier
    print("\n=== \(bundleID) pid=\(pid) cpu=\(String(format: "%.1f", cpuSeconds(pid)))s ===")
    diagnoseFlags(pid: pid)
    let counts = classifyTree(pid: pid)
    for (key, value) in counts.sorted(by: { $0.key < $1.key }) {
        print("  \(key)=\(value)")
    }
    await abScan(pid: pid, label: "as-is")
    // Clear the enhanced-accessibility flags Orbit leaves set, then re-scan.
    let appElement = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanFalse)
    diagnoseFlags(pid: pid)
    await abScan(pid: pid, label: "flags-cleared")
}

print("\n########## per-activation CPU cost ##########")
func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> String {
    String(format: "%.2f", Double(nanoseconds(from.duration(to: to))) / 1_000_000)
}

let dockStart = ContinuousClock.now
let dockTargets = await TargetScanner().scanDockTargets()
print("  dock scan: \(milliseconds(dockStart, ContinuousClock.now)) ms -> \(dockTargets.count) targets")

func syntheticTargets(_ count: Int) -> [ClickTarget] {
    let words = ["file", "view", "edit", "window", "help", "search", "reload", "bookmark"]
    return (0..<count).map { index in
        ClickTarget(
            frame: CGRect(x: CGFloat(index % 40) * 24, y: CGFloat(index / 40) * 28, width: 22, height: 20),
            label: "\(words[index % words.count]) item \(index)",
            source: .accessibility
        )
    }
}

for count in [120, 500, 1200] {
    let targets = syntheticTargets(count)
    let assignStart = ContinuousClock.now
    let assignments = HintGenerator.assign(to: targets)
    let indexStart = ContinuousClock.now
    let index = TargetSearch.searchIndex(for: assignments.map(\.target))
    let searchStart = ContinuousClock.now
    var hits = 0
    for query in ["a", "as", "asd", "asdf"] {
        hits += TargetSearch.matches(query: query, assignments: assignments, searchIndex: index).count
    }
    print("  n=\(count) assign \(milliseconds(assignStart, indexStart)) ms"
        + " | index \(milliseconds(indexStart, searchStart)) ms"
        + " | 4 keystrokes \(milliseconds(searchStart, ContinuousClock.now)) ms (hits=\(hits))")
}

// The lease release fires seconds after the scan; a short-lived bench would
// otherwise leave every diagnosed app in expensive enhanced-accessibility mode.
AccessibilityModeLease.releaseAll()
