import ApplicationServices
import Foundation

/// Orbit asks target apps to expose their complete accessibility tree, because
/// Chromium-based and lazily-instrumented apps otherwise hide their controls.
/// That mode is expensive for the target — the app keeps the whole tree
/// materialised for as long as it is on — so the request is revoked after a hint
/// session ends instead of being left set for the app's lifetime.
enum AccessibilityModeLease {
    private static let gracePeriod: Duration = .seconds(3)
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var pendingRelease: [pid_t: Task<Void, Never>] = [:]
    private nonisolated(unsafe) static var activeSessions: Set<pid_t> = []

    /// - Returns: whether the app honors `AXManualAccessibility`, which Chromium
    ///   and Electron apps do and AppKit apps generally do not.
    @discardableResult
    static func enable(application: AXUIElement, pid: pid_t) -> Bool {
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
        stateLock.lock()
        let inSession = activeSessions.contains(pid)
        stateLock.unlock()
        if !inSession {
            scheduleRelease(pid: pid)
        }
        return manualStatus == .success
    }

    /// A live overlay keeps its cached elements actionable, so the tree stays
    /// warm until the session closes.
    static func beginSession(pid: pid_t) {
        stateLock.lock()
        activeSessions.insert(pid)
        pendingRelease[pid]?.cancel()
        pendingRelease[pid] = nil
        stateLock.unlock()
    }

    static func endSession(pid: pid_t) {
        stateLock.lock()
        activeSessions.remove(pid)
        stateLock.unlock()
        scheduleRelease(pid: pid)
    }

    static func releaseAll() {
        stateLock.lock()
        let pids = Set(activeSessions).union(Set(pendingRelease.keys))
        activeSessions.removeAll()
        for task in pendingRelease.values {
            task.cancel()
        }
        pendingRelease.removeAll()
        stateLock.unlock()
        pids.forEach(revoke)
    }

    private static func scheduleRelease(pid: pid_t) {
        let task = Task.detached(priority: .utility) {
            try? await Task.sleep(for: gracePeriod)
            guard !Task.isCancelled else { return }
            revoke(pid: pid)
            clearPendingRelease(pid: pid)
        }
        stateLock.lock()
        pendingRelease[pid]?.cancel()
        pendingRelease[pid] = task
        stateLock.unlock()
    }

    /// Swift 6 forbids `NSLock` calls directly in async contexts, so the locked
    /// bookkeeping stays in synchronous helpers.
    private static func clearPendingRelease(pid: pid_t) {
        stateLock.lock()
        pendingRelease[pid] = nil
        stateLock.unlock()
    }

    private static func revoke(pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.10)
        for attributeName in enhancedAccessibilityAttributes {
            _ = AXUIElementSetAttributeValue(application, attributeName as CFString, kCFBooleanFalse)
        }
    }

    private static let enhancedAccessibilityAttributes = [
        "AXManualAccessibility",
        "AXEnhancedUserInterface"
    ]
}
