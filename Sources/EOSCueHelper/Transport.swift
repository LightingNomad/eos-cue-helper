import Foundation

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
            let sender = "\(String(cString: inet_ntoa(from.sin_addr))):\(UInt16(bigEndian: from.sin_port))"
            let data = Data(buf[0..<n])
            // EOS can deliver the same packet twice (e.g. EOS offline sending over loopback from two sockets).
            // Drop an exact repeat that arrives within 150 ms — far faster than any real double press.
            let now = Date()
            recent.removeAll { now.timeIntervalSince($0.time) > 0.15 }
            if let dup = recent.first(where: { $0.data == data }) {
                if !reportedDuplicate {
                    reportedDuplicate = true
                    onDuplicate?("EOS is sending every message twice (from \(dup.sender) and \(sender)). Ignoring the copies.")
                }
                continue
            }
            recent.append((data, now, sender))
            onReceive?(data, sender)
        }
    }

    private var recent: [(data: Data, time: Date, sender: String)] = []
    private var reportedDuplicate = false
    /// Called once, the first time a duplicate packet is dropped.
    var onDuplicate: ((String) -> Void)?

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
