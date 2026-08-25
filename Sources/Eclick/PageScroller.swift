import CoreGraphics

enum PageScroller {
    private static let pixelDistance: Int32 = 36

    static func scroll(_ direction: ScrollDirection, at location: CGPoint) {
        guard let event = makeEvent(direction, at: location) else { return }
        event.post(tap: .cghidEventTap)
    }

    static func makeEvent(_ direction: ScrollDirection, at location: CGPoint) -> CGEvent? {
        let delta = direction == .up ? pixelDistance : -pixelDistance
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        event.location = location
        return event
    }
}
