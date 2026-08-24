import Foundation
import IOKit
import IOKit.ps

private final class CancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        return true
    }

    func unregister() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

/// Owns the IOKit power assertions that keep the Mac awake: idle-system sleep,
/// display sleep, and — where macOS honors it — closed-lid (clamshell) sleep.
@MainActor
final class KeepAwakeManager {
    static let assertionName = "Eclick Keep Awake"

    enum BatteryLidClosePreventionError: LocalizedError, Sendable {
        case commandFailed(String)
        case verificationFailed
        case verificationUnknown

        var errorDescription: String? {
            switch self {
            case .commandFailed(let message):
                return message.isEmpty
                    ? "macOS could not change the battery sleep setting."
                    : message
            case .verificationFailed:
                return "macOS did not retain the battery sleep setting."
            case .verificationUnknown:
                return "The command completed, but Eclick could not verify the result. The battery sleep setting may be enabled. Check pmset -g or restore the default with: sudo pmset -b disablesleep 0"
            }
        }
    }

    private enum AssertionType {
        // Literal names match the documented IOKit assertion types.
        static let preventSystemSleep = "PreventSystemSleep"
        static let preventUserIdleSystemSleep = "PreventUserIdleSystemSleep"
        static let preventUserIdleDisplaySleep = "PreventUserIdleDisplaySleep"
    }

    private(set) var isActive = false
    private(set) var batteryLidClosePreventionEnabled: Bool?
    private var assertionIDs: [IOPMAssertionID] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) static var cachedGrantState: Bool?

    enum PowerSource {
        case ac
        case battery
        case unknown
    }

    /// macOS honors the PreventSystemSleep (lid-close) assertion only on AC
    /// power; on battery it force-sleeps regardless of assertions.
    nonisolated static func currentPowerSource() -> PowerSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?
                  .takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            // Literal values match kIOPSACPowerValue / kIOPSBatteryPowerValue.
            if state == "AC Power" { return .ac }
            if state == "Battery Power" { return .battery }
        }
        return .unknown
    }

    /// Invokes `onChange` on the main thread whenever the power source changes.
    func startPowerSourceMonitoring(onChange: @escaping () -> Void) {
        guard powerSourceRunLoopSource == nil else { return }
        final class CallbackBox {
            let handler: () -> Void
            init(handler: @escaping () -> Void) { self.handler = handler }
        }
        let box = CallbackBox(handler: onChange)
        let context = Unmanaged.passRetained(box).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                Unmanaged<CallbackBox>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .handler()
            },
            context
        )?.takeRetainedValue() else {
            Unmanaged<CallbackBox>.passUnretained(box).release()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = source
    }

    func stopPowerSourceMonitoring() {
        guard let powerSourceRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        self.powerSourceRunLoopSource = nil
    }

    /// Creates all keep-awake assertions. Returns false (releasing any partial
    /// assertions) when macOS refuses them entirely.
    func activate() -> Bool {
        guard !isActive else { return true }
        var createdIDs: [IOPMAssertionID] = []
        for type in [
            AssertionType.preventSystemSleep,
            AssertionType.preventUserIdleSystemSleep,
            AssertionType.preventUserIdleDisplaySleep
        ] {
            var assertionID = IOPMAssertionID(0)
            // kIOPMAssertionLevelOn == 255 (C macro not imported to Swift).
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(255),
                Self.assertionName as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                createdIDs.forEach(releaseAssertion)
                return false
            }
            createdIDs.append(assertionID)
        }
        assertionIDs = createdIDs
        isActive = true
        return true
    }

    func deactivate() {
        assertionIDs.forEach(releaseAssertion)
        assertionIDs = []
        isActive = false
    }

    func refreshBatteryLidClosePrevention() async -> Bool? {
        let state = await Task.detached(priority: .utility) {
            Self.readSleepDisabledState()
        }.value
        batteryLidClosePreventionEnabled = state
        return state
    }

    /// Enables lid-close prevention. Without the passwordless grant yet, a
    /// single admin prompt installs the narrow sudoers rule and applies the
    /// setting in one step — matching the one-prompt flow used by comparable
    /// lid-awake utilities.
    func enableBatteryLidClosePrevention() async throws {
        if Self.hasPasswordlessLidGrant() {
            try await setBatterySleepDisabled(true)
        } else {
            try await runPrivilegedBatterySleepChange(Self.grantAndEnableCommand())
            Self.invalidateGrantCache()
        }
        let state = await verifyBatterySleepState(expected: true)
        guard state == true else {
            throw BatteryLidClosePreventionError.verificationFailed
        }
    }

    /// Reverts macOS to stock behavior: closing the lid sleeps the Mac.
    func disableBatteryLidClosePrevention() async throws {
        try await setBatterySleepDisabled(false)
        let state = await verifyBatterySleepState(expected: false)
        guard state == false else {
            throw BatteryLidClosePreventionError.verificationFailed
        }
    }

    /// powerd applies pmset changes synchronously, but re-read once after a
    /// short delay before concluding the setting did not stick.
    private func verifyBatterySleepState(expected: Bool) async -> Bool? {
        var state = await refreshBatteryLidClosePrevention()
        if state != expected {
            try? await Task.sleep(for: .milliseconds(250))
            state = await refreshBatteryLidClosePrevention()
        }
        return state
    }

    private func setBatterySleepDisabled(_ disabled: Bool) async throws {
        let value = disabled ? "1" : "0"
        if Self.hasPasswordlessLidGrant() {
            try await Task.detached(priority: .userInitiated) {
                try Self.runSilentSudo(["/usr/bin/pmset", "-b", "disablesleep", value])
            }.value
        } else {
            try await runPrivilegedBatterySleepChange("/usr/bin/pmset -b disablesleep \(value)")
        }
    }

    /// One admin prompt installs a sudoers rule scoped to this exact user id
    /// permitting only the two pmset invocations, then applies the setting.
    nonisolated private static func grantAndEnableCommand() -> String {
        let rule = "#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset -b disablesleep 1, /usr/bin/pmset -b disablesleep 0"
        return "printf '%s\\n' \"# Eclick battery lid-close management\" \"\(rule)\" > /etc/sudoers.d/eclick-lid && chmod 440 /etc/sudoers.d/eclick-lid && visudo -cf /etc/sudoers.d/eclick-lid && /usr/bin/pmset -b disablesleep 1 || (rm -f /etc/sudoers.d/eclick-lid; exit 1)"
    }

    /// True when the narrow sudoers grant for the two pmset commands exists.
    nonisolated static func hasPasswordlessLidGrant() -> Bool {
        if let cachedGrantState { return cachedGrantState }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-l"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let granted = text.contains("/usr/bin/pmset -b disablesleep 1")
            && text.contains("/usr/bin/pmset -b disablesleep 0")
        cachedGrantState = granted
        return granted
    }

    nonisolated static func invalidateGrantCache() {
        cachedGrantState = nil
    }

    nonisolated private static func runSilentSudo(_ commandArguments: [String]) throws {
        let process = Process()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n"] + commandArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw BatteryLidClosePreventionError.commandFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = errorOutput.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BatteryLidClosePreventionError.commandFailed(message ?? "")
        }
    }

    private func runPrivilegedBatterySleepChange(_ command: String) async throws {
        let cancellableProcess = CancellableProcess()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.runPrivilegedCommand(command, cancellableProcess: cancellableProcess)
            }.value
        } onCancel: {
            cancellableProcess.cancel()
        }
    }

    var lidClosePreventionAvailable: Bool {
        Self.currentPowerSource() == .ac || batteryLidClosePreventionEnabled == true
    }

    nonisolated static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  fields[0].caseInsensitiveCompare("SleepDisabled") == .orderedSame else {
                continue
            }
            if fields[1] == "1" { return true }
            if fields[1] == "0" { return false }
        }
        return nil
    }

    nonisolated private static func readSleepDisabledState() -> Bool? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseSleepDisabled(text)
    }

    nonisolated private static func runPrivilegedCommand(
        _ command: String,
        cancellableProcess: CancellableProcess
    ) throws {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"\(command)\" with administrator privileges"
        ]
        process.standardOutput = output
        process.standardError = errorOutput
        guard cancellableProcess.register(process) else {
            throw CancellationError()
        }
        defer { cancellableProcess.unregister() }
        do {
            try process.run()
            if cancellableProcess.cancelled {
                process.terminate()
            }
            process.waitUntilExit()
        } catch {
            if error is CancellationError || cancellableProcess.cancelled {
                throw CancellationError()
            }
            throw BatteryLidClosePreventionError.commandFailed(error.localizedDescription)
        }
        if cancellableProcess.cancelled {
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BatteryLidClosePreventionError.commandFailed(message ?? fallback ?? "")
        }
    }

    private func releaseAssertion(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}
