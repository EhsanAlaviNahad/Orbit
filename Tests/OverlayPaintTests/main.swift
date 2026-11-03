import AppKit

// Proves the overlay's incremental repaint path paints exactly what a full
// repaint would: after a selection move or a filter keystroke, the frame built
// from the region the view chose to invalidate must be byte-identical to a
// fresh full frame. A too-tight damage rect leaves a stale chip on screen, and
// a too-loose one is what makes typing feel sluggish, so both halves matter.
@main
enum OverlayPaintTests {
    static func main() {
        _ = NSApplication.shared
        let canvas = NSSize(width: 1440, height: 900)
        let full = CGRect(origin: .zero, size: canvas)
        let view = HintOverlayView(frame: CGRect(origin: .zero, size: canvas))
        view.desktopOrigin = .zero
        view.mainScreenHeight = canvas.height
        view.quartzScreenFrame = full

        var failures = 0

        // The skip test in draw(_:) is only sound while every hint's ink stays
        // inside damageBound(): AppKit clips a repaint to the dirty rect, so ink
        // that escapes the bound is clipped away and never repainted.
        let containment = makeAssignments(count: 200)
        view.update(assignments: [], selectedTargetID: nil, hudState: .empty)
        for assignment in containment {
            view.update(assignments: [assignment], selectedTargetID: nil, hudState: .empty)
            let bound = view.damageBound(for: assignment)
            let clipped = makeRep(size: canvas)
            paint(view, into: clipped, dirty: bound)
            let complete = makeRep(size: canvas)
            paint(view, into: complete, dirty: full)
            if let region = staleRegion(clipped, complete) {
                failures += 1
                print("FAIL ink escape code=\(assignment.code) bound=\(bound) leaked at view \(region)")
            }
        }

        // Every hint at a small size: the damage bound is arithmetic (one fixed
        // advance per character), so a code whose measured width differs from
        // that estimate would leave a stale pixel the sampled cases could miss.
        let sweep = containment
        var frame = present(view: view, assignments: sweep, selectedTargetID: sweep[0].id, canvas: canvas, full: full)
        for index in 1..<sweep.count {
            let result = step(
                view: view,
                before: frame,
                assignments: sweep,
                selectedTargetID: sweep[index].id,
                canvas: canvas,
                full: full
            )
            frame = result.frame
            if let stale = result.stale {
                failures += 1
                print("FAIL sweep \(index - 1)->\(index): stale pixels at view \(stale)")
            }
        }
        print(failures == 0 ? "PASS ink containment and 199 chained selection moves" : "")

        for count in [600, 1200] {
            let assignments = makeAssignments(count: count)
            let cases: [(String, UUID?, UUID?)] = [
                ("mid-grid", assignments[count / 3].id, assignments[count * 2 / 3].id),
                ("first-to-last", assignments[0].id, assignments[count - 1].id),
                ("nil-to-first", nil, assignments[0].id),
                ("adjacent", assignments[12].id, assignments[13].id),
            ]
            for (name, fromID, toID) in cases {
                let before = present(view: view, assignments: assignments, selectedTargetID: fromID, canvas: canvas, full: full)
                let result = step(
                    view: view,
                    before: before,
                    assignments: assignments,
                    selectedTargetID: toID,
                    canvas: canvas,
                    full: full
                )
                if let stale = result.stale {
                    failures += 1
                    print("FAIL n=\(count) select \(name): stale pixels at view \(stale)")
                } else {
                    print("PASS n=\(count) select \(name): repainted \(result.damage ?? full)")
                }
            }

            // Typing in the search HUD rewrites the match list, which used to
            // force a whole-screen repaint on every keystroke.
            func every(_ step: Int, offset: Int = 0) -> [HintAssignment] {
                assignments.enumerated().filter { $0.offset % step == offset }.map(\.element)
            }
            let narrow = every(7)
            let filterCases: [(String, [HintAssignment], [HintAssignment])] = [
                ("narrow", assignments, narrow),
                ("swap matches", narrow, every(7, offset: 3)),
                ("widen", every(11), assignments),
                ("recoded", assignments, assignments.withCodes(HintGenerator.codes(count: count * 2))),
                ("single match", assignments, [assignments[count - 1]]),
                ("cleared", assignments, []),
            ]
            for (name, from, to) in filterCases {
                let before = present(view: view, assignments: from, selectedTargetID: from.first?.id, canvas: canvas, full: full)
                let result = step(
                    view: view,
                    before: before,
                    assignments: to,
                    selectedTargetID: to.first?.id,
                    canvas: canvas,
                    full: full
                )
                if let stale = result.stale {
                    failures += 1
                    print("FAIL n=\(count) filter \(name): stale pixels at view \(stale)")
                } else {
                    print("PASS n=\(count) filter \(name): repainted"
                        + " \(result.damage.map { "\($0)" } ?? "whole screen")")
                }
            }

            let timingRep = makeRep(size: canvas)
            view.update(assignments: assignments, selectedTargetID: assignments[0].id, hudState: .empty)
            paint(view, into: timingRep, dirty: full)
            let fullStart = ContinuousClock.now
            paint(view, into: timingRep, dirty: full)
            let fullMS = elapsed(fullStart)

            func timed(_ block: () -> CGRect?) -> Double {
                let damage = block()
                let start = ContinuousClock.now
                paint(view, into: timingRep, dirty: damage ?? full)
                return elapsed(start)
            }
            // Arrow-key moves land on the next hint; a first-to-last jump unions
            // two far-apart rects and legitimately repaints a wide band.
            let adjacentMS = min(
                timed { view.update(assignments: assignments, selectedTargetID: assignments[1].id, hudState: .empty) },
                timed { view.update(assignments: assignments, selectedTargetID: assignments[0].id, hudState: .empty) }
            )
            let farMS = timed {
                view.update(assignments: assignments, selectedTargetID: assignments[count - 1].id, hudState: .empty)
            }
            let filterMS = timed {
                view.update(assignments: narrow, selectedTargetID: narrow.first?.id, hudState: .empty)
            }
            view.update(assignments: assignments, selectedTargetID: assignments[0].id, hudState: .empty)
            print("TIMING n=\(count): full repaint \(ms(fullMS)) ms"
                + " | adjacent move \(ms(adjacentMS)) ms"
                + " | far jump \(ms(farMS)) ms"
                + " | narrowed list \(ms(filterMS)) ms")
            if adjacentMS > fullMS / 4 {
                failures += 1
                print("FAIL n=\(count): adjacent selection move is not substantially cheaper than a full repaint")
            }
        }

        if failures > 0 {
            print("Overlay paint tests failed: \(failures)")
            exit(1)
        }
        print("Overlay paint tests passed")
    }

    /// Paints a state from scratch, which is what the overlay does when a panel
    /// is first shown.
    static func present(
        view: HintOverlayView,
        assignments: [HintAssignment],
        selectedTargetID: UUID?,
        canvas: NSSize,
        full: CGRect
    ) -> NSBitmapImageRep {
        let rep = makeRep(size: canvas)
        view.update(assignments: assignments, selectedTargetID: selectedTargetID, hudState: .empty)
        paint(view, into: rep, dirty: full)
        return rep
    }

    /// Applies one change through the region the view itself decides to
    /// invalidate, and compares the result against a fresh full repaint. The
    /// incremental frame is returned so a chain of moves can be checked too.
    static func step(
        view: HintOverlayView,
        before: NSBitmapImageRep,
        assignments: [HintAssignment],
        selectedTargetID: UUID?,
        canvas: NSSize,
        full: CGRect
    ) -> (damage: CGRect?, stale: CGRect?, frame: NSBitmapImageRep) {
        let damage = view.update(
            assignments: assignments,
            selectedTargetID: selectedTargetID,
            hudState: .empty
        )
        let incremental = clone(before)
        paint(view, into: incremental, dirty: damage ?? full)
        let reference = makeRep(size: canvas)
        paint(view, into: reference, dirty: full)
        return (damage, staleRegion(incremental, reference), incremental)
    }

    static func staleRegion(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep) -> CGRect? {
        guard let a = left.bitmapData, let b = right.bitmapData else {
            fatalError("paint buffers have no backing data")
        }
        let bytesPerRow = min(left.bytesPerRow, right.bytesPerRow)
        let height = min(left.pixelsHigh, right.pixelsHigh)
        let width = min(left.pixelsWide, right.pixelsWide)
        var box: CGRect?
        for row in 0..<height {
            let base = row * bytesPerRow
            for column in 0..<width {
                let offset = base + column * 4
                guard a[offset] != b[offset] || a[offset + 1] != b[offset + 1]
                    || a[offset + 2] != b[offset + 2] || a[offset + 3] != b[offset + 3] else { continue }
                // Buffer rows run top-down; the view's coordinate system starts at
                // the lower-left, so flip the y before reporting a location.
                let y = CGFloat(height - row - 1)
                box = box.map { $0.union(CGRect(x: CGFloat(column), y: y, width: 1, height: 1)) }
                    ?? CGRect(x: CGFloat(column), y: y, width: 1, height: 1)
            }
        }
        return box
    }

    static func makeAssignments(count: Int) -> [HintAssignment] {
        let codes = HintGenerator.codes(count: count)
        return (0..<count).map { index in
            // Quartz-style desktop coordinates: 40 columns, wrapped rows.
            let frame = CGRect(
                x: 20 + CGFloat(index % 40) * 34,
                y: 900 - (40 + CGFloat(index / 40) * 40) - 22,
                width: 26,
                height: 22
            )
            return HintAssignment(
                target: ClickTarget(frame: frame, label: "control \(index)", source: .accessibility),
                code: codes[index]
            )
        }
    }

    static func paint(_ view: HintOverlayView, into rep: NSBitmapImageRep, dirty: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        guard let context = NSGraphicsContext.current?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            fatalError("no graphics context for paint buffer")
        }
        // AppKit erases the invalidated region, clips drawing to it, and only then
        // calls draw(_:). Skipping either step would compare something the real
        // overlay never does: unclipped repaints leak semi-transparent ink past
        // the dirty rect and double-composite the neighbouring hints. The rect is
        // snapped outward first, because AppKit invalidates whole device pixels.
        let aligned = dirty.integral
        context.clear(aligned)
        context.clip(to: aligned)
        view.draw(aligned)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func makeRep(size: NSSize) -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            fatalError("could not allocate paint comparison buffer")
        }
        return rep
    }

    static func clone(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
        guard let copy = rep.copy() as? NSBitmapImageRep else {
            fatalError("could not clone paint buffer")
        }
        return copy
    }

    static func elapsed(_ from: ContinuousClock.Instant) -> Double {
        let duration = from.duration(to: .now)
        return Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000
    }

    static func ms(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

extension [HintAssignment] {
    /// The same hints with different codes, which is what a re-rank does when a
    /// query changes how the alphabet is handed out.
    func withCodes(_ codes: [String]) -> [HintAssignment] {
        enumerated().map { index, assignment in
            HintAssignment(target: assignment.target, code: codes[index % codes.count])
        }
    }
}
