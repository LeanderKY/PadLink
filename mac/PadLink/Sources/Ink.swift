import Foundation
import CoreVideo

/// Bookkeeping for the pad's "local ink" (the pad draws the stroke itself, instantly, and removes it as soon
/// as the real picture from the Mac shows it).
///
/// The Mac's job: for every captured picture, say up to which pen sample the screen already contains the
/// stroke ("inkSeq"), and measure what the stroke looks like (colour, width) so the pad's ink matches.
/// Nothing is predicted — the pad only ever draws samples the pen really produced.
final class InkTracker {
    private struct Sample { let seq: UInt32; let t: UInt64; let x: Float; let y: Float; let down: Bool }

    private let lock = NSLock()
    private var log: [Sample] = []          // last ~1 s of pen samples
    private(set) var lastSeq: UInt32 = 0

    /// An app needs time to draw after it gets a pen event (event → next frame → compositor).
    /// Only samples at least this old count as "on screen" in a captured picture.
    static let appRenderMargin: UInt64 = 60_000_000

    func record(_ e: PenEvent, at t: UInt64) {
        guard e.seq != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        log.append(Sample(seq: e.seq, t: t, x: e.x, y: e.y, down: e.isDown))
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
    func probePoint(at captureNs: UInt64) -> (x: Float, y: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard let s = log.last(where: { $0.down && captureNs &- $0.t >= 60_000_000 && captureNs &- $0.t <= 250_000_000 }) else { return nil }
        return (s.x, s.y)
    }
}

/// What the stroke under the pen looks like on the Mac screen.
struct InkStyle: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    /// Stroke width as a fraction of the picture width.
    var width: Float
    /// false = nothing is being drawn under the pen (selection, hand tool …) → the pad shows no ink.
    var visible: Bool

    func payload() -> Data {
        var w = ByteWriter()
        w.u8(r); w.u8(g); w.u8(b); w.f32(width); w.u8(visible ? 1 : 0)
        return w.data
    }

    func differs(from o: InkStyle) -> Bool {
        visible != o.visible || abs(Int(r) - Int(o.r)) + abs(Int(g) - Int(o.g)) + abs(Int(b) - Int(o.b)) > 24
            || abs(width - o.width) > max(0.0006, o.width * 0.2)
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
        let maxRun = max(w, h) / 12
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
            let len = (dx != 0 && dy != 0) ? Int(Double(run) / 2.0.squareRoot()) : run
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
