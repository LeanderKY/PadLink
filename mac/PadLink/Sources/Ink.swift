import Foundation
import CoreVideo

/// Bookkeeping for the pad's "local ink" (the pad draws the stroke itself, instantly, and removes it as soon
/// as the real picture from the Mac shows it).
///
/// The Mac's job: for every captured picture, say up to which pen sample the screen already contains the
/// stroke ("inkSeq"), and measure what the stroke looks like (colour, width) so the pad's ink matches.
/// Nothing is predicted — the pad only ever draws samples the pen really produced.
final class InkTracker {
    private struct Sample {
        let seq: UInt32; let t: UInt64; let x: Float; let y: Float; let p: Float; let down: Bool
        /// Colour of the picture at this spot just *before* the stroke reached it (the paper).
        var bg: (UInt8, UInt8, UInt8)?
    }

    private let lock = NSLock()
    private var log: [Sample] = []          // last ~1 s of pen samples
    private(set) var lastSeq: UInt32 = 0

    /// An app needs time to draw after it gets a pen event (event → next frame → compositor).
    /// Only samples at least this old count as "on screen" in a captured picture.
    static let appRenderMargin: UInt64 = 60_000_000

    func record(_ e: PenEvent, at t: UInt64) {
        guard e.seq != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        log.append(Sample(seq: e.seq, t: t, x: e.x, y: e.y, p: e.pressure, down: e.isDown))
        lastSeq = max(lastSeq, e.seq)
        if log.count > 600 { log.removeFirst(log.count - 400) }
    }

    /// Highest sample the screen captured at `captureNs` must already show.
    func confirmedSeq(at captureNs: UInt64) -> UInt32 {
        let limit = captureNs &- Self.appRenderMargin
        lock.lock(); defer { lock.unlock() }
        return log.last(where: { $0.t <= limit })?.seq ?? 0
    }

    var newestSampleTime: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return log.last?.t ?? 0
    }

    /// A recent pen-down point that is surely drawn in the picture captured at `captureNs`
    /// (60–250 ms old), to read the stroke's colour and width from.
    func probePoint(at captureNs: UInt64) -> (x: Float, y: Float, pressure: Float)? {
        probePoints(at: captureNs, count: 1).first.map { ($0.x, $0.y, $0.pressure) }
    }

    /// The newest pen sample, if it is so fresh that the app can't have painted it yet in a picture taken at
    /// `captureNs` — the colour there is the paper.
    func freshSample(at captureNs: UInt64) -> (seq: UInt32, x: Float, y: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard let s = log.last, s.t <= captureNs &+ 2_000_000, captureNs &- s.t < 20_000_000 || s.t > captureNs else { return nil }
        return (s.seq, s.x, s.y)
    }

    func setBackground(seq: UInt32, _ c: (UInt8, UInt8, UInt8)) {
        lock.lock(); defer { lock.unlock() }
        if let i = log.lastIndex(where: { $0.seq == seq }), log[i].bg == nil { log[i].bg = c }
    }

    /// Up to `count` pen-down points from the same stroke, all 80–300 ms old (surely drawn by now, even if the
    /// app is slow while she draws fast) and spread apart along the stroke.
    func probePoints(at captureNs: UInt64, count: Int, minAge: UInt64 = 80_000_000) -> [(x: Float, y: Float, pressure: Float, bg: (UInt8, UInt8, UInt8)?)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(x: Float, y: Float, pressure: Float, bg: (UInt8, UInt8, UInt8)?)] = []
        var lastT: UInt64 = .max
        for s in log.reversed() {
            let age = captureNs &- s.t
            if s.t > captureNs || age < minAge { continue }
            if age > 400_000_000 || !s.down { if out.isEmpty { continue } else { break } } // stay in one stroke
            guard s.bg != nil else { continue } // only spots whose paper colour we know
            if lastT == .max || lastT &- s.t >= 25_000_000 {
                out.append((s.x, s.y, s.p, s.bg))
                lastT = s.t
                if out.count == count { break }
            }
        }
        return out
    }
}

/// What the stroke under the pen looks like on the Mac screen.
struct InkStyle: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    /// Stroke width as a fraction of the picture width.
    var width: Float
    /// false = nothing is being drawn under the pen (selection, hand tool …) → the pad shows no ink.
    var visible: Bool
    /// The brush gets thicker with pen pressure (Photoshop "pressure for size"): `width` is then the width at
    /// full pressure and the pad draws every piece of ink at `width × pressure` — like the real stroke.
    var pressureScaled = false

    func payload() -> Data {
        var w = ByteWriter()
        w.u8(r); w.u8(g); w.u8(b); w.f32(width); w.u8(visible ? 1 : 0); w.u8(pressureScaled ? 1 : 0)
        return w.data
    }

    func agrees(with o: InkStyle) -> Bool {
        visible == o.visible && abs(Int(r) - Int(o.r)) + abs(Int(g) - Int(o.g)) + abs(Int(b) - Int(o.b)) <= 36
            && abs(width - o.width) <= max(0.0008, max(width, o.width) * 0.35)
    }

    func differs(from o: InkStyle) -> Bool {
        visible != o.visible || pressureScaled != o.pressureScaled || abs(Int(r) - Int(o.r)) + abs(Int(g) - Int(o.g)) + abs(Int(b) - Int(o.b)) > 24
            || abs(width - o.width) > max(0.0006, o.width * 0.2)
    }

    /// Colour (sRGB) of one spot of the picture, averaged over 3×3 pixels.
    static func color(_ pb: CVPixelBuffer, x: Float, y: Float) -> (UInt8, UInt8, UInt8)? {
        guard let st = measure(pb, x: x, y: y) else { return nil }
        return (st.r, st.g, st.b)
    }

    /// Reads colour and width of the stroke at (x, y) from an NV12 (video range) picture.
    /// Width = the shortest run of "same colour" through the point (horizontal, vertical, two diagonals),
    /// which is the stroke's thickness however it is oriented. If the point looks like its surroundings
    /// further away, nothing was drawn there.
    static func measure(_ pb: CVPixelBuffer, x: Float, y: Float) -> InkStyle? {
        guard CVPixelBufferGetPlaneCount(pb) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        guard w > 8, h > 8,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)

        func px(_ i: Int, _ j: Int) -> (Int, Int, Int) {
            let ci = min(max(i, 0), w - 1), cj = min(max(j, 0), h - 1)
            let Y = Int(yBase[cj * yStride + ci])
            let c = (cj / 2) * cStride + (ci / 2) * 2
            return (Y, Int(cBase[c]), Int(cBase[c + 1]))
        }
        func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
            abs(a.0 - b.0) < 20 && abs(a.1 - b.1) < 14 && abs(a.2 - b.2) < 14
        }

        let cx = Int(x * Float(w - 1)), cy = Int(y * Float(h - 1))
        let center = px(cx, cy)
        let maxRun = max(w, h) / 30
        var thinnest = Int.max
        var outside: [(Int, Int, Int)] = []
        for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
            var run = 1
            for sign in [1, -1] {
                var k = 1
                while k < maxRun, near(px(cx + sign * dx * k, cy + sign * dy * k), center) { k += 1 }
                run += k - 1
                outside.append(px(cx + sign * dx * (k + 2), cy + sign * dy * (k + 2)))
            }
            // A diagonal step is √2 long: n steps across the stroke = n·√2 of thickness.
            let len = (dx != 0 && dy != 0) ? Int((Double(run) * 2.0.squareRoot()).rounded()) : run
            thinnest = min(thinnest, len)
        }
        // Drawn stroke = the point differs from what's around it in most directions.
        let differing = outside.filter { !near($0, center) }.count
        let visible = thinnest < maxRun && differing >= 4

        // BT.709 video range → sRGB
        let Yf = Double(center.0 - 16) * 1.164, U = Double(center.1 - 128), V = Double(center.2 - 128)
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return InkStyle(r: clamp(Yf + 1.793 * V), g: clamp(Yf - 0.213 * U - 0.533 * V), b: clamp(Yf + 2.112 * U),
                        width: Float(max(thinnest, 1)) / Float(w), visible: visible)
    }
}

/// Finds out whether the brush's width follows pen pressure, from (pressure, measured width) pairs.
/// Compares "width = a × pressure" against "width is constant" and picks whichever fits clearly better.
struct PressureFit {
    private var pairs: [(p: Float, w: Float)] = []
    private var color: (Int, Int, Int)?

    mutating func add(_ st: InkStyle, pressure: Float) -> InkStyle {
        var out = st
        guard st.visible, pressure > 0.02 else { return out }
        let c = (Int(st.r), Int(st.g), Int(st.b))
        if let o = color, abs(o.0 - c.0) + abs(o.1 - c.1) + abs(o.2 - c.2) > 60 { pairs.removeAll() } // other brush/colour
        color = c
        pairs.append((pressure, st.width))
        if pairs.count > 12 { pairs.removeFirst() }
        let ps = pairs.map(\.p)
        guard pairs.count >= 4, (ps.max()! - ps.min()!) >= 0.2 else { return out }
        let spp = pairs.reduce(Float(0)) { $0 + $1.p * $1.p }
        let a = pairs.reduce(Float(0)) { $0 + $1.p * $1.w } / spp
        let mean = pairs.reduce(Float(0)) { $0 + $1.w } / Float(pairs.count)
        let errProp = pairs.reduce(Float(0)) { $0 + pow($1.w - a * $1.p, 2) }
        let errConst = pairs.reduce(Float(0)) { $0 + pow($1.w - mean, 2) }
        if errProp < errConst * 0.5 {
            out.pressureScaled = true
            out.width = a
        }
        return out
    }
}

/// Decides what the pad's local ink should look like, from the captured pictures. Conservative on purpose:
/// it's far better to keep the old look than to show something the real stroke isn't.
struct InkJudge {
    private var lastStyle: InkStyle?
    private var lastStyleNs: UInt64 = 0
    private var pressureFit = PressureFit()
    private var candidate: InkStyle?   // a new look seen once, not yet confirmed
    private var lastRaw: InkStyle?     // last accepted reading as measured (before the pressure fit)

    /// Reads the stroke's look at three points of the same stroke and only believes it when they agree —
    /// and a changed look only when two readings in a row show it. A single odd reading (the app hasn't
    /// painted that spot yet when she draws fast, so it sees the paper) must never turn the pad's ink into
    /// a fat line in the paper colour.
    mutating func judge(_ pb: CVPixelBuffer, _ captureNs: UInt64, _ ink: InkTracker) -> InkStyle? {
        guard captureNs &- lastStyleNs > 80_000_000 else { return nil }
        // Same colour as the paper was there before the pen came by → the app hasn't painted it yet (she's
        // drawing fast, the app lags) — look further back along the stroke; if it's paper there too, give up.
        var found: (pts: [(x: Float, y: Float, pressure: Float, bg: (UInt8, UInt8, UInt8)?)], ms: [(st: InkStyle, p: Float)])?
        for minAge: UInt64 in [80_000_000, 200_000_000] {
            let pts = ink.probePoints(at: captureNs, count: 3, minAge: minAge)
            guard pts.count == 3 else { continue }
            let ms = pts.compactMap { p in InkStyle.measure(pb, x: p.x, y: p.y).map { (st: $0, p: p.pressure) } }
            guard ms.count == 3 else { continue }
            let paper = zip(ms, pts).contains { m, p in
                guard m.st.visible, let bg = p.bg else { return false }
                return abs(Int(bg.0) - Int(m.st.r)) + abs(Int(bg.1) - Int(m.st.g)) + abs(Int(bg.2) - Int(m.st.b)) < 40
            }
            if !paper { found = (pts, ms); break }
        }
        guard let ms = found?.ms else { return nil }
        lastStyleNs = captureNs
        // All three must agree (same colour; same width — or the same width per pressure, for pressure brushes).
        func same(_ a: (st: InkStyle, p: Float), _ b: (st: InkStyle, p: Float)) -> Bool {
            if a.st.agrees(with: b.st) { return true }
            var x = a.st, y = b.st
            x.width /= max(a.p, 0.05); y.width /= max(b.p, 0.05)
            return x.agrees(with: y)
        }
        guard same(ms[0], ms[1]), same(ms[1], ms[2]), same(ms[0], ms[2]) else { return nil }
        let best = ms[0]
        let measured = best.st
        if let c = candidate, c.agrees(with: measured) || (lastRaw.map { $0.agrees(with: measured) } ?? false) {
            candidate = nil
        } else if lastRaw.map({ !$0.agrees(with: measured) }) ?? true {
            candidate = measured   // new look: wait for a second reading before using it
            return nil
        }
        lastRaw = measured
        let st = pressureFit.add(measured, pressure: best.p)
        if let old = lastStyle, !st.differs(from: old) { return nil }
        lastStyle = st
        return st
    }
}
