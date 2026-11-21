import Foundation
import Network

/// Finds pads on the local network via Bonjour.
final class PadBrowser {
    private var browser: NWBrowser?
    private(set) var found: [String: NWEndpoint] = [:]
    var onChange: (([String: NWEndpoint]) -> Void)?

    func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_padlink._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var map: [String: NWEndpoint] = [:]
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint { map[name] = r.endpoint }
            }
            DispatchQueue.main.async {
                self?.found = map
                self?.onChange?(map)
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        found = [:]
    }
}

/// A link to the pad — Wi‑Fi (TCP) or USB cable. Same framed protocol on both.
/// All callbacks run on `queue`.
protocol PadTransport: AnyObject {
    var queue: DispatchQueue { get }
    var isUSB: Bool { get }
    var onReady: (() -> Void)? { get set }
    var onMessage: ((Msg, Data) -> Void)? { get set }
    var onClosed: ((String?) -> Void)? { get set }
    func start()
    func send(_ type: Msg, _ payload: Data, completion: (() -> Void)?)
    func close()
}

extension PadTransport {
    func send(_ type: Msg, _ payload: Data = Data()) { send(type, payload, completion: nil) }
}

/// `[u8 type][u32 length][payload]` stream → messages.
struct FrameParser {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [(Msg, Data)] {
        buffer.append(data)
        var out: [(Msg, Data)] = []
        while buffer.count >= 5 {
            let b = buffer.startIndex
            let len = Int(buffer[b+1]) << 24 | Int(buffer[b+2]) << 16 | Int(buffer[b+3]) << 8 | Int(buffer[b+4])
            guard buffer.count >= 5 + len else { break }
            let typeByte = buffer[b]
            let payload = buffer.subdata(in: (b+5)..<(b+5+len))
            buffer.removeSubrange(b..<(b+5+len))
            if let t = Msg(rawValue: typeByte) { out.append((t, payload)) }
        }
        return out
    }
}

/// One TCP connection to a pad over Wi‑Fi.
final class PadConnection: PadTransport {
    let queue = DispatchQueue(label: "padlink.net", qos: .userInteractive)
    let isUSB = false
    private let conn: NWConnection
    private var parser = FrameParser()

    var onReady: (() -> Void)?
    var onMessage: ((Msg, Data) -> Void)?
    var onClosed: ((String?) -> Void)?
    private var closed = false

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.connectionTimeout = 6
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = true
        conn = NWConnection(to: endpoint, using: params)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case .failed(let err):
                self.finish("Verbindung verloren (\(err.localizedDescription))")
            case .waiting(let err):
                self.finish("Pad nicht erreichbar (\(err.localizedDescription))")
            case .cancelled:
                self.finish(nil)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func send(_ type: Msg, _ payload: Data, completion: (() -> Void)?) {
        conn.send(content: frame(type, payload), completion: .contentProcessed { _ in completion?() })
    }

    func close() {
        guard !closed else { return }
        send(.bye)
        conn.cancel()
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClosed?(reason)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for (t, p) in self.parser.feed(data) { self.onMessage?(t, p) }
            }
            if isComplete || error != nil {
                self.finish(isComplete ? "Pad hat die Verbindung beendet" : "Verbindung verloren")
                return
            }
            self.receive()
        }
    }
}
