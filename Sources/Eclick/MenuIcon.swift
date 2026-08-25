import AppKit

enum MenuIcon {
    static func makeIdleIcon() -> NSImage {
        templateImage(accessibilityDescription: "Eclick") { context in
            drawSaturn(in: context)
        }
    }

    static func makeScanningIcon() -> NSImage {
        templateImage(accessibilityDescription: "Eclick is scanning") { context in
            drawViewfinder(in: context)
        }
    }

    // MARK: - Canvas

    private static let designSide: CGFloat = 100

    private static func templateImage(
        accessibilityDescription: String,
        drawing: @escaping (CGContext) -> Void
    ) -> NSImage {
        let side = CGFloat(22)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.saveGState()
            // Design space is 100x100 with a top-left origin, so icon geometry
            // can be authored like a designer would read it.
            cg.translateBy(x: 0, y: rect.height)
            cg.scaleBy(x: rect.width / designSide, y: -rect.height / designSide)
            drawing(cg)
            cg.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static var ink: CGColor { NSColor.black.cgColor }

    // MARK: - Idle: Saturn

    private static func drawSaturn(in cg: CGContext) {
        let planetCenter = CGPoint(x: 50, y: 48)
        let ringCenter = CGPoint(x: 50, y: 52)
        let ringRotation = -24 * CGFloat.pi / 180

        var ringTransform = CGAffineTransform.identity
        ringTransform = ringTransform.translatedBy(x: ringCenter.x, y: ringCenter.y)
        ringTransform = ringTransform.rotated(by: ringRotation)
        ringTransform = ringTransform.translatedBy(x: -ringCenter.x, y: -ringCenter.y)
        let completeRing = CGPath(
            ellipseIn: CGRect(x: 3, y: 36, width: 94, height: 32),
            transform: &ringTransform
        )

        // Complete rear ring establishes the Saturn silhouette.
        cg.setStrokeColor(ink)
        cg.setLineWidth(6.5)
        cg.setLineCap(.round)
        cg.addPath(completeRing)
        cg.strokePath()

        let planetRect = CGRect(
            x: planetCenter.x - 23,
            y: planetCenter.y - 23,
            width: 46,
            height: 46
        )

        // Large solid planet hides rear ring cleanly.
        cg.setFillColor(ink)
        cg.fillEllipse(in: planetRect)

        // Lower half crosses planet in front, separated by negative space.
        let frontRing = ellipseArc(
            center: ringCenter,
            radiusX: 47,
            radiusY: 16,
            rotation: ringRotation,
            startAngle: 0,
            endAngle: .pi
        )
        cg.setBlendMode(.clear)
        cg.setLineWidth(12)
        cg.addPath(frontRing)
        cg.strokePath()

        cg.setBlendMode(.normal)
        cg.setStrokeColor(ink)
        cg.setLineWidth(6)
        cg.addPath(frontRing)
        cg.strokePath()

        // Single cutout highlight adds depth without tiny planetary detail.
        let highlight = CGMutablePath()
        highlight.move(to: CGPoint(x: 37, y: 36))
        highlight.addCurve(
            to: CGPoint(x: 57, y: 31),
            control1: CGPoint(x: 43, y: 32),
            control2: CGPoint(x: 51, y: 30)
        )
        cg.setBlendMode(.clear)
        cg.setLineWidth(3.5)
        cg.setLineCap(.round)
        cg.addPath(highlight)
        cg.strokePath()
        cg.setBlendMode(.normal)
    }

    private static func ellipseArc(
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotation: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let steps = 40
        for index in 0...steps {
            let progress = CGFloat(index) / CGFloat(steps)
            let angle = startAngle + (endAngle - startAngle) * progress
            let x = radiusX * cos(angle)
            let y = radiusY * sin(angle)
            let point = CGPoint(
                x: center.x + x * cos(rotation) - y * sin(rotation),
                y: center.y + x * sin(rotation) + y * cos(rotation)
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    // MARK: - Scanning: viewfinder

    private static func drawViewfinder(in cg: CGContext) {
        let inset: CGFloat = 14
        let arm: CGFloat = 24
        let min = inset
        let max = designSide - inset

        let corners = [
            // top-left
            [CGPoint(x: min, y: min + arm), CGPoint(x: min, y: min), CGPoint(x: min + arm, y: min)],
            // top-right
            [CGPoint(x: max - arm, y: min), CGPoint(x: max, y: min), CGPoint(x: max, y: min + arm)],
            // bottom-right
            [CGPoint(x: max, y: max - arm), CGPoint(x: max, y: max), CGPoint(x: max - arm, y: max)],
            // bottom-left
            [CGPoint(x: min + arm, y: max), CGPoint(x: min, y: max), CGPoint(x: min, y: max - arm)]
        ]

        cg.setStrokeColor(ink)
        cg.setLineWidth(9)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for corner in corners {
            let path = CGMutablePath()
            path.move(to: corner[0])
            path.addLine(to: corner[1])
            path.addLine(to: corner[2])
            cg.addPath(path)
            cg.strokePath()
        }

        let center = CGPoint(x: designSide / 2, y: designSide / 2)
        cg.setFillColor(ink)
        cg.fillEllipse(in: CGRect(
            x: center.x - 8.5,
            y: center.y - 8.5,
            width: 17,
            height: 17
        ))
    }
}
