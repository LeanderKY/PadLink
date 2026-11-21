import Foundation
import Network
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

enum DisplayMode: String, CaseIterable, Identifiable {
    case mirror, extend
    var id: String { rawValue }
    var title: String { self == .mirror ? "Bildschirm kopieren" : "Zweiter Bildschirm" }
}

enum Quality: Int, CaseIterable, Identifiable {
    case fast = 0, balanced = 1, sharp = 2
    var id: Int { rawValue }
    var title: String { ["Schnell", "Ausgewogen", "Scharf"][rawValue] }
    /// Longest edge in pixels, bitrate
    var maxLongEdge: Int { [1920, 2560, 2880][rawValue] }
    var bitrate: Int { [18, 30, 45][rawValue] * 1_000_000 }
}

struct HelloReply: Decodable {
    let status: String
    let token: String?
    let padName: String?
    let width: Int?
    let height: Int?
}

/// One live connection: network + capture + encoder + pen input.
final class StreamSession {
    enum Event {
        case waitingForApproval
        case streaming(padName: String)
        case token(String)
        case stats(rttMs: Double, fps: Int)
        case ended(String?)
    }

    var onEvent: ((Event) -> Void)?   // always called on main

    private let conn: PadTransport
    private let mode: DisplayMode
    private let quality: Quality
    private var hello: [String: Any]

    private let source = ScreenSource()
    private var encoder: VideoEncoder?
    private let injector = InputInjector()
    private let virtualDisplay = PadVirtualDisplay()
    private var activity: NSObjectProtocol?

    // Flow control — touched from capture, encoder and network threads, so guarded by flowLock.
    // Rule: never queue pictures. If the pad hasn't shown the last frames yet, don't even encode;
    // as soon as there is room again, encode the *newest* picture. No backlog, no forced keyframes.
    private let flowLock = NSLock()
    private var frameId: UInt64 = 0
    private var inFlight: [UInt64: UInt64] = [:]   // sent, not yet shown on the pad: frameId → send time (ns)
    private var encoding = 0                       // handed to the encoder, not yet out
    private var pendingFrame = false               // a newer picture is waiting for room
    private var sentThisSecond = 0

    // Local ink on the pad (see Ink.swift). inkFifo: inkSeq of each frame in the encoder, guarded by flowLock.
    private let ink = InkTracker()
    private var inkFifo: [UInt32] = []
    private var lastStyle: InkStyle?          // capture queue
    private var lastStyleNs: UInt64 = 0       // capture queue
    private var inkTimer: DispatchSourceTimer?

    // Pen over UDP (Wi‑Fi only): no TCP head-of-line stalls when a packet is lost. Samples also come over
    // TCP; duplicates are dropped by sequence number, so whichever copy is first wins.
    private var udp: NWListener?
    private var udpConns: [NWConnection] = []
    private let udpKey = UInt32.random(in: 1...UInt32.max)
    private var udpGaveUp = false
    private var tcpReady = false
    private var helloSent = false

    // conn.queue only
    private var lastPenSeq: UInt32 = 0
    private var lastInkSent: UInt32 = 0
    private var penIsDown = false
    private var lowBitrate = false
    private var restoreBitrate: DispatchWorkItem?
    private var fps = 0
    private var rtt: Double = 0
    private var timer: DispatchSourceTimer?
    private var ended = false

    /// Frames allowed between "encoded" and "shown on the pad". Each one is up to ~16 ms of extra lag,
    /// so the cable (no radio jitter) gets by with fewer than Wi‑Fi.
    private let maxInFlight: Int

    init(transport: PadTransport, mode: DisplayMode, quality: Quality, macId: String, macName: String, token: String?) {
        conn = transport
        maxInFlight = transport.isUSB ? 2 : 3
        self.mode = mode
        self.quality = quality
        hello = ["v": 2, "macId": macId, "macName": macName, "token": token ?? NSNull()]
    }

    func start() {
        if !conn.isUSB { startUdp() }
        conn.onReady = { [weak self] in
            guard let self else { return }
            self.tcpReady = true
            self.sendHelloIfReady()
            // Don't let a stuck UDP setup hold up the connection.
            self.conn.queue.asyncAfter(deadline: .now() + 0.5) { self.udpGaveUp = true; self.sendHelloIfReady() }
        }
        conn.onMessage = { [weak self] t, p in self?.handle(t, p) }
        conn.onClosed = { [weak self] reason in self?.end(reason) }
        conn.start()
    }

    func stop() { end(nil) }

    private func sendHelloIfReady() {
        guard tcpReady, !helloSent else { return }
        if !conn.isUSB, udp?.port == nil, !udpGaveUp { return }
        helloSent = true
        if let port = udp?.port?.rawValue {
            hello["udpPort"] = Int(port)
            hello["udpKey"] = Int(udpKey)
        }
        let json = (try? JSONSerialization.data(withJSONObject: hello)) ?? Data()
        conn.send(.hello, json)
    }

    private func startUdp() {
        guard let l = try? NWListener(using: .udp, on: .any) else { udpGaveUp = true; return }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.sendHelloIfReady()
            case .failed, .cancelled: self.udpGaveUp = true; self.sendHelloIfReady()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self, !self.ended else { c.cancel(); return }
            self.udpConns.append(c)
            c.start(queue: self.conn.queue)
            self.receiveUdp(c)
        }
        l.start(queue: conn.queue)
        udp = l
    }

    /// Datagram: u32 key, u8 count, count × pen sample (oldest first). Each datagram repeats the last few
    /// samples, so a lost packet costs nothing.
    private func receiveUdp(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.ended else { return }
            if let data, data.count >= 5 {
                var r = ByteReader(data)
                if r.u32() == self.udpKey {
                    let n = Int(r.u8())
                    for _ in 0..<n { if let e = PenEvent(&r) { self.handlePen(e) } else { break } }
                }
            }
            if error == nil { self.receiveUdp(c) }
        }
    }

    /// conn.queue. Every pen sample, from TCP or UDP, goes through here exactly once.
    private func handlePen(_ e: PenEvent) {
        if e.seq != 0 {
            guard e.seq > lastPenSeq else { return }   // already handled (other path) or too old
            lastPenSeq = e.seq
        }
        ink.record(e, at: DispatchTime.now().uptimeNanoseconds)
        injector.handle(e)

        // Wi‑Fi: while the pen draws, send smaller pictures (less airtime → steadier, quicker delivery);
        // when it lifts, go back to full quality and refresh the picture once.
        guard !conn.isUSB else { return }
        if e.isDown && !penIsDown {
            penIsDown = true
            restoreBitrate?.cancel()
            if !lowBitrate { encoder?.setBitrate(quality.bitrate * 6 / 10); lowBitrate = true }
        } else if !e.isDown && penIsDown {
            penIsDown = false
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.ended, !self.penIsDown, self.lowBitrate else { return }
                self.lowBitrate = false
                self.encoder?.setBitrate(self.quality.bitrate)
                self.requestKeyframe()
            }
            restoreBitrate = work
            conn.queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent?(e) } }

    private func end(_ reason: String?) {
        conn.queue.async { [self] in
            guard !ended else { return }
            ended = true
            timer?.cancel()
            inkTimer?.cancel()
            restoreBitrate?.cancel()
            udp?.cancel()
            udpConns.forEach { $0.cancel() }
            conn.close()
            source.stop()
            encoder?.invalidate()
            injector.releaseAll()
            DispatchQueue.main.async { [self] in
                virtualDisplay.destroy()
                if let a = activity { ProcessInfo.processInfo.endActivity(a) }
                onEvent?(.ended(reason))
            }
        }
    }

    // MARK: Incoming

    private func handle(_ type: Msg, _ payload: Data) {
        switch type {
        case .helloReply:
            guard let r = try? JSONDecoder().decode(HelloReply.self, from: payload) else { return end("Unbekannte Antwort vom Pad") }
            switch r.status {
            case "ok":
                if let t = r.token { emit(.token(t)) }
                let w = r.width ?? 2880, h = r.height ?? 1800
                let name = r.padName ?? "Pad"
                DispatchQueue.main.async { self.beginStreaming(padWidth: w, padHeight: h, padName: name) }
            case "pending":
                emit(.waitingForApproval)
            default:
                end("Auf dem Pad abgelehnt")
            }
        case .pen:
            if let e = PenEvent(payload) { handlePen(e) }
        case .frameAck:
            guard payload.count >= 8 else { return }
            var r = ByteReader(payload)
            let id = r.u64()
            release { $0.key > id }
        case .pong:
            guard payload.count >= 8 else { return }
            var r = ByteReader(payload)
            let sample = Double(DispatchTime.now().uptimeNanoseconds &- r.u64()) / 1_000_000
            rtt = rtt == 0 ? sample : rtt * 0.7 + sample * 0.3
        case .command:
            if let c = payload.first.flatMap(PadCommand.init(rawValue:)) { injector.command(c) }
        case .scroll:
            guard payload.count >= 9 else { return }
            var r = ByteReader(payload)
            let dx = r.f32(), dy = r.f32(), zoom = r.u8() == 1
            injector.scroll(dx: dx, dy: dy, zoom: zoom)
        case .keyframeRequest:
            requestKeyframe()
        case .padBye:
            end("Auf dem Pad getrennt")
        default: break
        }
    }

    // MARK: Streaming

    @MainActor
    private func beginStreaming(padWidth: Int, padHeight: Int, padName: String) {
        Task { @MainActor in
            do {
                let displayID: CGDirectDisplayID
                if mode == .extend {
                    let pw = min(padWidth, 2880) & ~1, ph = min(padHeight, 1800) & ~1
                    guard virtualDisplay.create(pixelWidth: pw, pixelHeight: ph), let id = virtualDisplay.displayID else {
                        throw NSError(domain: "PadLink", code: 2, userInfo: [NSLocalizedDescriptionKey: "Zweiter Bildschirm konnte nicht erstellt werden"])
                    }
                    displayID = id
                    try await waitForDisplay(id)
                } else {
                    displayID = CGMainDisplayID()
                }
                injector.setDisplay(displayID)

                // Encode size: display aspect, fitted into the pad and the quality preset.
                let mode = CGDisplayCopyDisplayMode(displayID)
                let dw = Double(mode?.pixelWidth ?? Int(CGDisplayPixelsWide(displayID)))
                let dh = Double(mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(displayID)))
                let longEdge = Double(min(quality.maxLongEdge, max(padWidth, padHeight)))
                let scale = min(1.0, longEdge / max(dw, dh))
                let w = Int(dw * scale) & ~7, h = Int(dh * scale) & ~7

                guard let enc = VideoEncoder(width: w, height: h, bitrate: quality.bitrate, fps: 60) else {
                    throw NSError(domain: "PadLink", code: 3, userInfo: [NSLocalizedDescriptionKey: "Video-Encoder nicht verfügbar"])
                }
                encoder = enc
                enc.onFrame = { [weak self] data, key in self?.sendFrame(data, key: key) }
                enc.onDone = { [weak self] in self?.encoderDone() }
                source.onFrame = { [weak self] pb, pts, ns in self?.offer(pb, pts, ns) }
                source.onStopped = { [weak self] msg in self?.end("Bildschirmaufnahme gestoppt: \(msg)") }

                var cfg = ByteWriter()
                cfg.u32(UInt32(w)); cfg.u32(UInt32(h))
                conn.send(.videoConfig, cfg.data)

                try await source.start(displayID: displayID, width: w, height: h, fps: 60)
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
                    reason: "Bildschirm auf dem Pad")
                startTimer()
                onEvent?(.streaming(padName: padName))
                // A still screen produces no frames — push the first picture right away.
                try? await Task.sleep(nanoseconds: 150_000_000)
                requestKeyframe()
            } catch {
                end(error.localizedDescription)
            }
        }
    }

    private func waitForDisplay(_ id: CGDirectDisplayID) async throws {
        for _ in 0..<30 {
            if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               c.displays.contains(where: { $0.displayID == id }) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func requestKeyframe() {
        encoder?.requestKeyframe()
        source.repeatLastFrame()
    }

    /// Capture queue: encode only if the pad keeps up, otherwise remember that a newer picture exists.
    private func offer(_ pb: CVPixelBuffer, _ pts: CMTime, _ captureNs: UInt64) {
        measureInk(pb, captureNs)
        let inkSeq = ink.confirmedSeq(at: captureNs)
        flowLock.lock()
        let room = inFlight.count + encoding < maxInFlight
        if room { encoding += 1; pendingFrame = false; inkFifo.append(inkSeq) } else { pendingFrame = true }
        flowLock.unlock()
        if room { encoder?.encode(pb, pts: pts) }
    }

    private func encoderDone() {
        flowLock.lock()
        encoding -= 1
        if !inkFifo.isEmpty { inkFifo.removeFirst() }
        flowLock.unlock()
    }

    /// Capture queue: tell the pad what the stroke looks like, so its instant ink matches the real brush.
    private func measureInk(_ pb: CVPixelBuffer, _ captureNs: UInt64) {
        guard captureNs &- lastStyleNs > 80_000_000, let p = ink.probePoint(at: captureNs),
              let st = InkStyle.measure(pb, x: p.x, y: p.y) else { return }
        lastStyleNs = captureNs
        if let old = lastStyle, !st.differs(from: old) { return }
        lastStyle = st
        conn.queue.async { [self] in if !ended { conn.send(.inkStyle, st.payload()) } }
    }

    /// Drop finished frames from the in-flight list; if a picture was held back, send the newest one now.
    private func release(_ keep: ((key: UInt64, value: UInt64)) -> Bool) {
        flowLock.lock()
        inFlight = inFlight.filter(keep)
        let resend = pendingFrame && inFlight.count + encoding < maxInFlight
        flowLock.unlock()
        if resend { source.repeatLastFrame() }
    }

    /// Encoder thread. The frame is counted as in flight *before* `encoding` drops, so there is no gap.
    private func sendFrame(_ data: Data, key: Bool) {
        flowLock.lock()
        frameId += 1
        let id = frameId
        inFlight[id] = DispatchTime.now().uptimeNanoseconds
        let inkSeq = inkFifo.first ?? 0
        flowLock.unlock()
        var w = ByteWriter()
        w.u8((key ? 1 : 0) | 2)   // bit1: inkSeq follows
        w.u64(id)
        w.u32(inkSeq)
        w.bytes(data)
        conn.queue.async { [self] in
            guard !ended else { return }
            conn.send(.videoFrame, w.data)
            sentThisSecond += 1
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: conn.queue)
        var ticks = 0
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self, !self.ended else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            // Frames that were never ACKed (e.g. dropped by the decoder) must not block forever.
            self.release { now &- $0.value < 1_000_000_000 }
            ticks += 1
            if ticks % 4 == 0 {
                var w = ByteWriter(); w.u64(now)
                self.conn.send(.ping, w.data)
                self.fps = self.sentThisSecond
                self.sentThisSecond = 0
                self.emit(.stats(rttMs: self.rtt, fps: self.fps))
            }
        }
        t.resume()
        timer = t

        // Screen standing still (nothing drawn by the last pen samples, or all of it already shown):
        // tell the pad it can drop its local ink up to there. Only when every sent picture is on the pad.
        let it = DispatchSource.makeTimerSource(queue: conn.queue)
        it.schedule(deadline: .now() + 0.02, repeating: 0.02)
        it.setEventHandler { [weak self] in
            guard let self, !self.ended, self.ink.lastSeq > self.lastInkSent else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now &- self.source.lastChangeNs > 70_000_000 else { return }
            self.flowLock.lock()
            let idle = self.inFlight.isEmpty && self.encoding == 0 && !self.pendingFrame
            self.flowLock.unlock()
            guard idle else { return }
            let seq = self.ink.confirmedSeq(at: now)
            guard seq > self.lastInkSent else { return }
            self.lastInkSent = seq
            var w = ByteWriter(); w.u32(seq)
            self.conn.send(.ink, w.data)
        }
        it.resume()
        inkTimer = it
    }
}
