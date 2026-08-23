import Foundation

enum SystemCommand: String, CaseIterable, Equatable, Sendable {
    case restart
    case shutdown
    case sleep

    var displayName: String {
        switch self {
        case .restart: "Restart Mac"
        case .shutdown: "Shut Down Mac"
        case .sleep: "Sleep Mac"
        }
    }

    var confirmationPrompt: String {
        switch self {
        case .restart:
            "Restart this Mac? Press Enter again to confirm. Esc to cancel."
        case .shutdown:
            "Shut down this Mac? Press Enter again to confirm. Esc to cancel."
        case .sleep:
            "Put this Mac to sleep? Press Enter again to confirm. Esc to cancel."
        }
    }

    var symbolName: String {
        switch self {
        case .restart: "arrow.clockwise"
        case .shutdown: "power"
        case .sleep: "moon.zzz"
        }
    }
}

enum SystemCommandParser {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func parse(_ rawQuery: String) -> SystemCommand? {
        let exactQuery = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: locale)
        return SystemCommand(rawValue: exactQuery)
    }
}

protocol SystemCommandExecuting: Sendable {
    func execute(_ command: SystemCommand) async throws
}

enum SystemCommandInputPolicy {
    static func isPlainEnter(modifiers: UInt64) -> Bool {
        modifiers == 0
    }
}

struct TerminalModifierCycle {
    private var initialModifiers: UInt64?
    private var remainedStable = false

    var isActive: Bool { initialModifiers != nil }

    @discardableResult
    mutating func begin(modifiers: UInt64) -> Bool {
        guard initialModifiers == nil else { return false }
        initialModifiers = modifiers
        remainedStable = true
        return true
    }

    mutating func observe(modifiers: UInt64) {
        guard let initialModifiers, modifiers != initialModifiers else { return }
        remainedStable = false
    }

    mutating func finish(modifiers: UInt64) -> Bool {
        guard let initialModifiers else { return false }
        let isValid = remainedStable && modifiers == initialModifiers
        reset()
        return isValid
    }

    mutating func reset() {
        initialModifiers = nil
        remainedStable = false
    }
}

enum SystemCommandKeyUpOutcome: Equatable {
    case confirmationRequested(SystemCommand)
    case execute(SystemCommand)
}

struct SystemCommandConfirmationStateMachine {
    private struct Pending: Equatable {
        let command: SystemCommand
        let rawQuery: String
    }

    private enum State: Equatable {
        case idle
        case waitingForFirstRelease(Pending)
        case awaitingConfirmation(Pending)
        case waitingForSecondRelease(Pending)
    }

    private var state: State = .idle

    var pendingCommand: SystemCommand? {
        switch state {
        case let .awaitingConfirmation(pending), let .waitingForSecondRelease(pending):
            pending.command
        case .idle, .waitingForFirstRelease:
            nil
        }
    }

    mutating func queryDidChange(to rawQuery: String) {
        guard pendingRawQuery != rawQuery else { return }
        cancel()
    }

    @discardableResult
    mutating func enterKeyDown(query rawQuery: String, isAutoRepeat: Bool = false) -> Bool {
        guard let command = SystemCommandParser.parse(rawQuery) else {
            cancel()
            return false
        }
        guard !isAutoRepeat else { return true }

        let pending = Pending(command: command, rawQuery: rawQuery)
        switch state {
        case .idle:
            state = .waitingForFirstRelease(pending)
        case let .awaitingConfirmation(existing) where existing == pending:
            state = .waitingForSecondRelease(pending)
        case .waitingForFirstRelease, .waitingForSecondRelease:
            break
        case .awaitingConfirmation:
            state = .waitingForFirstRelease(pending)
        }
        return true
    }

    mutating func enterKeyUp(isValid: Bool = true) -> SystemCommandKeyUpOutcome? {
        guard isValid else {
            cancel()
            return nil
        }
        switch state {
        case let .waitingForFirstRelease(pending):
            state = .awaitingConfirmation(pending)
            return .confirmationRequested(pending.command)
        case let .waitingForSecondRelease(pending):
            state = .idle
            return .execute(pending.command)
        case .idle, .awaitingConfirmation:
            return nil
        }
    }

    mutating func cancel() {
        state = .idle
    }

    mutating func modifierDidChange() {
        cancel()
    }

    mutating func inputWasInterrupted() {
        cancel()
    }

    private var pendingRawQuery: String? {
        switch state {
        case .idle:
            nil
        case let .waitingForFirstRelease(pending),
             let .awaitingConfirmation(pending),
             let .waitingForSecondRelease(pending):
            pending.rawQuery
        }
    }
}

@MainActor
final class SystemCommandCoordinator {
    private var confirmation = SystemCommandConfirmationStateMachine()
    private let executor: any SystemCommandExecuting

    init(executor: any SystemCommandExecuting) {
        self.executor = executor
    }

    var pendingCommand: SystemCommand? { confirmation.pendingCommand }

    func queryDidChange(to rawQuery: String) {
        confirmation.queryDidChange(to: rawQuery)
    }

    @discardableResult
    func enterKeyDown(query rawQuery: String, isAutoRepeat: Bool = false) -> Bool {
        confirmation.enterKeyDown(query: rawQuery, isAutoRepeat: isAutoRepeat)
    }

    func enterKeyUp(isValid: Bool = true) -> SystemCommandKeyUpOutcome? {
        confirmation.enterKeyUp(isValid: isValid)
    }

    func cancel() {
        confirmation.cancel()
    }

    func modifierDidChange() {
        confirmation.modifierDidChange()
    }

    func inputWasInterrupted() {
        confirmation.inputWasInterrupted()
    }

    func execute(_ command: SystemCommand) async throws {
        try await executor.execute(command)
    }
}
