import Foundation
import Network

/// Plain BSD UDP socket: binds a listen port and sends from the same socket.
final class UDPSocket {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "eoscuehelper.udp")

    /// Called on a background queue with each datagram and the sender's IP.
    var onReceive: ((Data, String) -> Void)?
    var onError: ((String) -> Void)?

    func open(port: UInt16) throws {
        try queue.sync {
            closeLocked()
            let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard s >= 0 else { throw TransportError.message("socket(): \(String(cString: strerror(errno)))") }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc != 0 {
                let e = errno
                Darwin.close(s)
                if e == EADDRINUSE {
                    throw TransportError.message("UDP port \(port) is already in use by another app (Vor? the old Labeler?). Quit it or pick another port.")
                }
                throw TransportError.message("Can't listen on UDP \(port): \(String(cString: strerror(e)))")
            }
            _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
            fd = s
            let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
            src.setEventHandler { [weak self] in self?.drain() }
            src.setCancelHandler { Darwin.close(s) }
            src.resume()
            source = src
        }
    }

    func close() { queue.sync { closeLocked() } }

    private func closeLocked() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func drain() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    buf.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, 0, sp, &len) }
                }
            }
            if n <= 0 { break }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            onReceive?(Data(buf[0..<n]), ip)
        }
    }

    func send(_ data: Data, host: String, port: UInt16) {
        queue.async { [self] in
            guard fd >= 0 else { onError?("UDP socket not open"); return }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res, let sa = r.pointee.ai_addr else {
                    onError?("Can't resolve EOS address \"\(host)\"")
                    return
                }
                addr.sin_addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                freeaddrinfo(res)
            }
            let sent = data.withUnsafeBytes { raw in
                withUnsafePointer(to: &addr) { ap in
                    ap.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 { onError?("UDP send to \(host):\(port) failed: \(String(cString: strerror(errno)))") }
        }
    }
}

enum TransportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// TCP client to EOS with automatic reconnect. Supports SLIP (OSC 1.1) or length-prefix (OSC 1.0) framing.
final class TCPClient {
    enum Framing: String { case slip, length }
    enum State { case connecting, connected, disconnected(String) }

    private let queue = DispatchQueue(label: "eoscuehelper.tcp")
    private var conn: NWConnection?
    private var wanted = false
    private var host = ""
    private var port: UInt16 = 3037
    private var framing: Framing = .slip
    private var slip = SLIP.Decoder()
    private var lengthDecoder = LengthPrefix.Decoder()
    private var ready = false

    /// Called on a background queue.
    var onPacket: ((Data) -> Void)?
    var onState: ((State) -> Void)?

    func start(host: String, port: UInt16, framing: Framing) {
        queue.async { [self] in
            self.host = host
            self.port = port
            self.framing = framing
            wanted = true
            conn?.cancel()
            conn = nil
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            wanted = false
            ready = false
            conn?.cancel()
            conn = nil
        }
    }

    private func connect() {
        guard wanted, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        slip = SLIP.Decoder()
        lengthDecoder = LengthPrefix.Decoder()
        ready = false
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        onState?(.connecting)
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready:
                self.ready = true
                self.onState?(.connected)
                self.receive(on: c)
            case .waiting(let e):
                self.drop(c, reason: e.localizedDescription)
            case .failed(let e):
                self.drop(c, reason: e.localizedDescription)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func drop(_ c: NWConnection, reason: String) {
        ready = false
        c.cancel()
        conn = nil
        onState?(.disconnected(reason))
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wanted, self.conn == nil else { return }
            self.connect()
        }
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, c === self.conn else { return }
            if let data, !data.isEmpty {
                let packets = self.framing == .slip ? self.slip.feed(data) : self.lengthDecoder.feed(data)
                packets.forEach { self.onPacket?($0) }
            }
            if isComplete || error != nil {
                self.drop(c, reason: error?.localizedDescription ?? "EOS closed the connection")
            } else {
                self.receive(on: c)
            }
        }
    }

    /// Returns false if not connected.
    func send(_ packet: Data) {
        queue.async { [self] in
            guard ready, let c = conn else { return }
            let framed = framing == .slip ? SLIP.encode(packet) : LengthPrefix.encode(packet)
            c.send(content: framed, completion: .contentProcessed { _ in })
        }
    }
}
