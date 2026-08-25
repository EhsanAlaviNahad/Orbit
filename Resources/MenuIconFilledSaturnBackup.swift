// BACKUP: Filled Saturn menu bar icon used before the refined outline version.
// Saved 2026-08-25. This file is not compiled into Eclick.

import AppKit

enum MenuIconFilledSaturnBackup {
    static func draw(in cg: CGContext) {
        let ink = NSColor.black.cgColor
        let planetCenter = CGPoint(x: 50, y: 48)
        let ringCenter = CGPoint(x: 50, y: 52)
        let ringRotation = -18 * CGFloat.pi / 180

        var ringTransform = CGAffineTransform.identity
        ringTransform = ringTransform.translatedBy(x: ringCenter.x, y: ringCenter.y)
        ringTransform = ringTransform.rotated(by: ringRotation)
        ringTransform = ringTransform.translatedBy(x: -ringCenter.x, y: -ringCenter.y)
        let fullRing = CGPath(
            ellipseIn: CGRect(x: 3, y: 34, width: 94, height: 36),
            transform: &ringTransform
        )

        cg.setStrokeColor(ink)
        cg.setLineWidth(6)
        cg.setLineCap(.round)
        cg.addPath(fullRing)
        cg.strokePath()

        cg.setFillColor(ink)
        cg.fillEllipse(in: CGRect(x: 26, y: 24, width: 48, height: 48))

        let frontRing = ellipseArc(
            center: ringCenter,
            radiusX: 47,
            radiusY: 18,
            rotation: ringRotation
        )
        cg.setBlendMode(.clear)
        cg.setLineWidth(11)
        cg.addPath(frontRing)
        cg.strokePath()

        cg.setBlendMode(.normal)
        cg.setStrokeColor(ink)
        cg.setLineWidth(5.5)
        cg.addPath(frontRing)
        cg.strokePath()
    }

    private static func ellipseArc(
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotation: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let steps = 32
        for index in 0...steps {
            let angle = .pi * CGFloat(index) / CGFloat(steps)
            let x = radiusX * cos(angle)
            let y = radiusY * sin(angle)
            let point = CGPoint(
                x: center.x + x * cos(rotation) - y * sin(rotation),
                y: center.y + x * sin(rotation) + y * cos(rotation)
            )
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}
