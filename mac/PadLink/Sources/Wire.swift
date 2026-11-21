import Foundation

/// Message types — see PROTOCOL.md.
enum Msg: UInt8 {
    // Mac → Pad
    case hello = 0x01, videoConfig = 0x02, videoFrame = 0x03, ping = 0x04, bye = 0x05
    case ink = 0x06, inkStyle = 0x07
    // Pad → Mac
    case helloReply = 0x81, pen = 0x82, pong = 0x83, frameAck = 0x84
    case command = 0x85, scroll = 0x86, keyframeRequest = 0x87, padBye = 0x88
}

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    let data: Data
    var pos: Int
    init(_ data: Data) { self.data = data; self.pos = data.startIndex }
    var remaining: Int { data.endIndex - pos }

    mutating func u8() -> UInt8 { defer { pos += 1 }; return data[pos] }
    mutating func u32() -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 { v = (v << 8) | UInt32(data[pos]); pos += 1 }
        return v
    }
    mutating func u64() -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<8 { v = (v << 8) | UInt64(data[pos]); pos += 1 }
        return v
    }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
}

func frame(_ type: Msg, _ payload: Data = Data()) -> Data {
    var w = ByteWriter()
    w.u8(type.rawValue)
    w.u32(UInt32(payload.count))
    w.bytes(payload)
    return w.data
}

struct PenEvent {
    enum Action: UInt8 { case hoverMove = 0, down = 1, move = 2, up = 3, hoverExit = 4, hoverEnter = 5 }
    var action: Action
    var eraser: Bool
    var sideButton: Bool
    var x: Float, y: Float
    var pressure: Float
    var tiltX: Float, tiltY: Float
    /// Running number per pen sample (0 = old pad app without numbering). Used to drop duplicates
    /// (pen samples arrive over UDP *and* TCP) and to tell the pad which samples the screen already shows.
    var seq: UInt32 = 0

    static let size = 27

    init?(_ payload: Data) {
        var r = ByteReader(payload)
        self.init(&r)
    }

    init?(_ r: inout ByteReader) {
        guard r.remaining >= 23 else { return nil }
        guard let a = Action(rawValue: r.u8()) else { return nil }
        action = a
        eraser = r.u8() == 1
        sideButton = (r.u8() & 1) != 0
        x = r.f32(); y = r.f32(); pressure = r.f32(); tiltX = r.f32(); tiltY = r.f32()
        if r.remaining >= 4 { seq = r.u32() }
    }

    var isDown: Bool { action == .down || action == .move }
}

enum PadCommand: UInt8 {
    case undo = 1, redo, brush, eraser, zoomIn, zoomOut, fit, handDown, handUp, smaller, bigger
}
