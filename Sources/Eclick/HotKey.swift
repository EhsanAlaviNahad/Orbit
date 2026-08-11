import Carbon
import Foundation

@MainActor
final class HotKeyRegistrar {
    enum RegistrationError: LocalizedError {
        case unavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unavailable(status):
                return "The shortcut could not be registered (OSStatus \(status)). It may already be in use."
            }
        }
    }

    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let identifier = EventHotKeyID(signature: fourCharacterCode("ECLK"), id: 1)

    init() {
        installHandler()
    }

    func shutdown() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    func register(_ shortcut: KeyboardShortcut) throws {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        var newReference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &newReference
        )
        guard status == noErr, let newReference else {
            throw RegistrationError.unavailable(status)
        }
        hotKeyRef = newReference
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard status == noErr,
                      receivedID.signature == fourCharacterCode("ECLK"),
                      receivedID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<HotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                registrar.onPressed?()
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandlerRef
        )
    }
}

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
}
