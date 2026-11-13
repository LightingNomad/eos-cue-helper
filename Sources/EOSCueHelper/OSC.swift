import Foundation

/// A single OSC argument.
enum OSCArg: Equatable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)
    case bool(Bool)
    case int64(Int64)
    case double(Double)
    case null

    var text: String {
        switch self {
        case .int(let v): return String(v)
        case .int64(let v): return String(v)
        case .float(let v): return OSCArg.format(Double(v))
        case .double(let v): return OSCArg.format(v)
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .blob(let d): return "<\(d.count) bytes>"
        case .null: return "nil"
        }
    }

    var number: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .int64(let v): return Double(v)
        case .float(let v): return Double(v)
        case .double(let v): return v
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    static func format(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e12 { return String(Int64(d)) }
        return String(d)
    }
}

struct OSCMessage {
    var address: String
    var args: [OSCArg]

    init(_ address: String, _ args: [OSCArg] = []) {
        self.address = address
        self.args = args
    }

    /// Address split into path components, without empty pieces.
    var parts: [String] { address.split(separator: "/").map(String.init) }

    var debugText: String {
        args.isEmpty ? address : address + "  " + args.map { a -> String in
            if case .string(let s) = a { return "\"\(s)\"" }
            return a.text
        }.joined(separator: ", ")
    }

    // MARK: Encoding

    func encoded() -> Data {
        var tags = ","
        var body = Data()
        for a in args {
            switch a {
            case .int(let v): tags += "i"; body.appendBE(UInt32(bitPattern: v))
            case .float(let v): tags += "f"; body.appendBE(v.bitPattern)
            case .string(let s): tags += "s"; body.appendOSCString(s)
            case .blob(let b):
                tags += "b"
                body.appendBE(UInt32(b.count))
                body.append(b)
                while body.count % 4 != 0 { body.append(0) }
            case .bool(let b): tags += b ? "T" : "F"
            case .int64(let v): tags += "h"; body.appendBE(UInt64(bitPattern: v))
            case .double(let v): tags += "d"; body.appendBE(v.bitPattern)
            case .null: tags += "N"
            }
        }
        var d = Data()
        d.appendOSCString(address)
        d.appendOSCString(tags)
        d.append(body)
        return d
    }

    // MARK: Decoding

    /// Decodes an OSC packet (message or bundle) into its messages.
    static func decode(_ data: Data) -> [OSCMessage] {
        let bytes = [UInt8](data)
        var out: [OSCMessage] = []
        decodePacket(bytes, 0, bytes.count, into: &out, depth: 0)
        return out
    }

    private static func decodePacket(_ b: [UInt8], _ start: Int, _ end: Int, into out: inout [OSCMessage], depth: Int) {
        guard end > start, depth < 8 else { return }
        if b[start] == UInt8(ascii: "#") {
            // #bundle\0 + 8 byte timetag + elements
            var r = Reader(b: b, pos: start, end: end)
            guard r.string() == "#bundle", r.skip(8) else { return }
            while r.pos + 4 <= end {
                guard let size = r.int32(), size > 0 else { return }
                let s = r.pos, e = s + Int(size)
                guard e <= end else { return }
                decodePacket(b, s, e, into: &out, depth: depth + 1)
                r.pos = e
            }
        } else if b[start] == UInt8(ascii: "/") {
            var r = Reader(b: b, pos: start, end: end)
            guard let addr = r.string() else { return }
            var args: [OSCArg] = []
            if r.pos < end, let tags = r.string(), tags.hasPrefix(",") {
                for t in tags.dropFirst() {
                    switch t {
                    case "i": if let v = r.int32() { args.append(.int(v)) } else { break }
                    case "f": if let v = r.uint32() { args.append(.float(Float(bitPattern: v))) }
                    case "s", "S": if let s = r.string() { args.append(.string(s)) }
                    case "b":
                        if let n = r.int32(), n >= 0, r.pos + Int(n) <= end {
                            args.append(.blob(Data(b[r.pos..<(r.pos + Int(n))])))
                            r.pos += (Int(n) + 3) & ~3
                        }
                    case "h": if let v = r.uint64() { args.append(.int64(Int64(bitPattern: v))) }
                    case "d": if let v = r.uint64() { args.append(.double(Double(bitPattern: v))) }
                    case "t": _ = r.skip(8)
                    case "c", "r", "m": _ = r.skip(4)
                    case "T": args.append(.bool(true))
                    case "F": args.append(.bool(false))
                    case "N", "I": args.append(.null)
                    default: break
                    }
                }
            }
            out.append(OSCMessage(addr, args))
        }
    }

    private struct Reader {
        let b: [UInt8]
        var pos: Int
        let end: Int

        mutating func string() -> String? {
            var i = pos
            while i < end && b[i] != 0 { i += 1 }
            guard i < end else { return nil }
            let s = String(decoding: b[pos..<i], as: UTF8.self)
            pos = (i + 4) & ~3
            return s
        }
        mutating func uint32() -> UInt32? {
            guard pos + 4 <= end else { return nil }
            var v: UInt32 = 0
            for k in 0..<4 { v = (v << 8) | UInt32(b[pos + k]) }
            pos += 4
            return v
        }
        mutating func int32() -> Int32? { uint32().map { Int32(bitPattern: $0) } }
        mutating func uint64() -> UInt64? {
            guard let hi = uint32(), let lo = uint32() else { return nil }
            return (UInt64(hi) << 32) | UInt64(lo)
        }
        mutating func skip(_ n: Int) -> Bool {
            guard pos + n <= end else { return false }
            pos += n
            return true
        }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendOSCString(_ s: String) {
        var bytes = Array(s.utf8)
        bytes.append(0)
        while bytes.count % 4 != 0 { bytes.append(0) }
        append(contentsOf: bytes)
    }
}
