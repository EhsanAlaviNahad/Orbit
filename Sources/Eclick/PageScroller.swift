import CoreGraphics

enum PageScroller {
    static func scroll(
        _ direction: ScrollDirection,
        at location: CGPoint,
        speedMultiplier: Double
    ) {
        guard let event = makeEvent(
            direction,
            at: location,
            speedMultiplier: speedMultiplier
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    static func makeEvent(
        _ direction: ScrollDirection,
        at location: CGPoint,
        speedMultiplier: Double
    ) -> CGEvent? {
        let pixelDistance = ScrollSpeedMetrics.pixelDistance(for: speedMultiplier)
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
