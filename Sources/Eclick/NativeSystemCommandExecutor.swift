import ApplicationServices
import Foundation
import IOKit.pwr_mgt

enum SystemCommandExecutionError: LocalizedError {
    case couldNotCreateAppleEvent(SystemCommand)
    case appleEventFailed(SystemCommand, OSStatus)
    case powerManagementUnavailable
    case sleepFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case let .couldNotCreateAppleEvent(command):
            "macOS could not prepare the \(command.displayName.lowercased()) request."
        case let .appleEventFailed(command, status):
            "macOS rejected the \(command.displayName.lowercased()) request (error \(status))."
        case .powerManagementUnavailable:
            "macOS power management is unavailable."
        case let .sleepFailed(status):
            "macOS rejected the sleep request (error \(status))."
        }
    }
}

final class NativeSystemCommandExecutor: SystemCommandExecuting {
    func execute(_ command: SystemCommand) async throws {
        try Task.checkCancellation()
        switch command {
        case .restart:
            try sendLoginWindowEvent(AEEventID(kAEShowRestartDialog), command: command)
        case .shutdown:
            try sendLoginWindowEvent(AEEventID(kAEShowShutdownDialog), command: command)
        case .sleep:
            try requestSleep()
        }
    }

    private func sendLoginWindowEvent(
        _ eventID: AEEventID,
        command: SystemCommand
    ) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: eventID,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        guard let descriptor = event.aeDesc else {
            throw SystemCommandExecutionError.couldNotCreateAppleEvent(command)
        }

        let options = AESendMode(kAENoReply | kAECanInteract | kAECanSwitchLayer)
        let status = AESendMessage(descriptor, nil, options, kAEDefaultTimeout)
        guard status == noErr else {
            throw SystemCommandExecutionError.appleEventFailed(command, status)
        }
    }

    private func requestSleep() throws {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != IO_OBJECT_NULL else {
            throw SystemCommandExecutionError.powerManagementUnavailable
        }
        defer { IOServiceClose(connection) }

        let status = IOPMSleepSystem(connection)
        guard status == kIOReturnSuccess else {
            throw SystemCommandExecutionError.sleepFailed(status)
        }
    }
}
