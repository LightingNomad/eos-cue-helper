import Foundation
import SwiftUI

struct CueRef: Equatable, Hashable {
    var list: String
    var number: String
    var display: String { "\(list)/\(number)" }
}

enum TargetSource: String, CaseIterable, Identifiable {
    case commandLine = "Command line"
    case pending = "Pending cue"
    case active = "Active cue"
    var id: String { rawValue }
}

enum LabelOp: String {
    case prefix, suffix, both, remove
    /// Remove a given piece of text from the start and/or end of the label (passed as the prefix text).
    case strip
}

struct LogLine: Identifiable {
    enum Kind { case info, rx, tx, error }
    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String
}

/// Preference keys + defaults. Views bind to these with @AppStorage.
enum Pref {
    static let eosIP = "eosIP"
    static let udpSendPort = "udpSendPort"
    static let udpListenPort = "udpListenPort"
    static let targetSource = "targetSource"
    static let defaultList = "defaultList"
    static let prefix = "prefix"
    static let suffix = "suffix"
    static let autoSpace = "autoSpace"
    static let cuelistEnabled = "cuelistEnabled"
    static let pageOnCueFire = "pageOnCueFire"
    static let pageOnCueFireList = "pageOnCueFireList"
    static let keepOnTop = "keepOnTop"
    static let logIncoming = "logIncoming"
    static let autoUpdate = "autoUpdate"

    static func register() {
        UserDefaults.standard.register(defaults: [
            eosIP: "127.0.0.1",
            udpSendPort: 8000,
            udpListenPort: 8001,
            targetSource: TargetSource.commandLine.rawValue,
            defaultList: "1",
            prefix: "",
            suffix: "",
            autoSpace: true,
            cuelistEnabled: true,
            pageOnCueFire: false,
            pageOnCueFireList: "2",
            keepOnTop: false,
            logIncoming: false,
            autoUpdate: true,
        ])
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private let d = UserDefaults.standard
    private let udp = UDPSocket()
    private var labelTimeout: DispatchWorkItem?
    private var pendingOp: (op: LabelOp, prefix: String?, suffix: String?)?
    private var activity: NSObjectProtocol?

    // Connection
    @Published var running = false
    @Published var connError: String?
    @Published var lastHeardFromEOS: Date?
    @Published var eosVersion: String?

    // EOS state
    @Published var commandLine = ""
    @Published var activeCue: CueRef?
    @Published var pendingCue: CueRef?
    @Published var target: CueRef?
    @Published var targetLabel: String?    // nil = not known yet
    @Published var labelState: String = "" // "Loading…", "No reply from EOS", …
    @Published var locked = false
    @Published var lastChange: (cue: CueRef, old: String, new: String)?

    // Cuelist
    @Published var cuelistStatus = ""
    @Published var cuelistError = false

    @Published var log: [LogLine] = []

    init() {
        Pref.register()
        // Keep OSC timing tight even when the window is in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Live OSC control of EOS")
        udp.onReceive = { [weak self] data, ip in
            let msgs = OSCMessage.decode(data)
            Task { @MainActor in msgs.forEach { self?.handle($0) } }
        }
        udp.onError = { [weak self] e in Task { @MainActor in self?.addLog(.error, e) } }
    }

    // MARK: - Settings access

    var eosIP: String { (d.string(forKey: Pref.eosIP) ?? "").trimmingCharacters(in: .whitespaces) }
    var targetSource: TargetSource { TargetSource(rawValue: d.string(forKey: Pref.targetSource) ?? "") ?? .commandLine }
    var prefix: String { d.string(forKey: Pref.prefix) ?? "" }
    var suffix: String { d.string(forKey: Pref.suffix) ?? "" }

    // MARK: - Connection

    enum Health { case off, waiting, ok, error }

    var health: Health {
        if !running { return .off }
        if lastHeardFromEOS != nil { return .ok }
        return connError == nil ? .waiting : .error
    }

    var statusText: String {
        switch health {
        case .off: return "Not connected"
        case .ok: return "Connected to EOS" + (eosVersion.map { " \($0)" } ?? "")
        case .waiting:
            return "Listening — nothing heard from EOS yet (check EOS OSC TX settings)"
        case .error: return connError ?? "Error"
        }
    }

    func connect() {
        disconnect(quiet: true)
        running = true
        connError = nil
        eosVersion = nil
        lastHeardFromEOS = nil

        // EOS output, Send_String macros, and anything else (Stream Deck, QLab…) all arrive here.
        let listen = d.integer(forKey: Pref.udpListenPort)
        do {
            try udp.open(port: UInt16(clamping: listen))
            addLog(.info, "Listening for OSC on UDP port \(listen)")
        } catch {
            connError = error.localizedDescription
            addLog(.error, error.localizedDescription)
        }

        addLog(.info, "Sending UDP to \(eosIP):\(d.integer(forKey: Pref.udpSendPort))")
        hello()
    }

    func disconnect(quiet: Bool = false) {
        udp.close()
        if running && !quiet { addLog(.info, "Disconnected") }
        running = false
    }

    /// Sent once per connect (never on a timer): asks EOS for its version, which also confirms it's answering.
    private func hello() {
        send("/eos/get/version", log: false)
        if let t = target { requestLabel(t) }
    }

    func send(_ address: String, _ args: [OSCArg] = [], log: Bool = true) {
        let msg = OSCMessage(address, args)
        guard running else {
            if log { addLog(.error, "Not connected — couldn't send \(msg.debugText)") }
            return
        }
        if log { addLog(.tx, msg.debugText) }
        udp.send(msg.encoded(), host: eosIP, port: UInt16(clamping: d.integer(forKey: Pref.udpSendPort)))
    }

    // MARK: - Incoming

    private func handle(_ m: OSCMessage) {
        let p = m.parts
        let lower = m.address.lowercased()

        if p.first == "eos" {
            if lastHeardFromEOS == nil { connError = nil }
            lastHeardFromEOS = Date()
        }

        let noisy = lower.hasPrefix("/eos/out/get/cue/")
        if d.bool(forKey: Pref.logIncoming) && !noisy { addLog(.rx, m.debugText) }

        if lower.hasPrefix("/cuelist") { handleCuelist(m); return }
        if lower.hasPrefix("/label") { handleLabelerTrigger(m); return }
        guard p.count >= 3, p[0] == "eos", p[1] == "out" else { return }

        switch p[2] {
        case "get":
            if p.count >= 4 && p[3] == "version" { eosVersion = m.args.first?.text }
            // /eos/out/get/cue/<list>/<cue>/<part>/list/<index>/<count>  args: index, uid, label, ...
            if p.count >= 8 && p[3] == "cue" && p[7] == "list" && p[6] == "0" {
                let ref = CueRef(list: p[4], number: p[5])
                if ref == target {
                    let label = m.args.count >= 3 ? m.args[2].text : ""
                    gotLabel(label)
                }
            }

        case "active", "pending":
            guard p.count >= 4, p[3] == "cue" else { return }
            if p.count >= 5 && p[4] == "text" { return }
            let ref: CueRef? = p.count >= 6 ? CueRef(list: p[4], number: p[5]) : nil
            if p[2] == "active" {
                guard ref != activeCue else { return }
                activeCue = ref
                if targetSource == .active, let ref { setTarget(ref) }
            } else {
                guard ref != pendingCue else { return }
                pendingCue = ref
                if targetSource == .pending, let ref { setTarget(ref) }
            }

        case "cmd":
            commandChanged(m.args.first?.text ?? "")

        case "user":
            // /eos/out/user/<n>/cmd
            if p.count >= 5 && p[4] == "cmd" { commandChanged(m.args.first?.text ?? "") }

        case "event":
            // /eos/out/event/cue/<list>/<cue>/fire
            if p.count >= 7, p[3] == "cue", p.last == "fire",
               d.bool(forKey: Pref.pageOnCueFire),
               p[4] == (d.string(forKey: Pref.pageOnCueFireList) ?? "").trimmingCharacters(in: .whitespaces) {
                cuelist(.next, reason: "cue \(p[4])/\(p[5]) fired")
            }

        case "notify":
            // /eos/out/notify/cue/<list>/... — something in that list changed; refresh our label.
            if p.count >= 5, p[3] == "cue", let t = target, p[4] == t.list {
                requestLabel(t)
            }

        default:
            break
        }
    }

    private static let cueRegex = try! NSRegularExpression(
        pattern: #"(?i)\bcue\s+(?:(\d+)\s*/\s*)?(\d+(?:\.\d+)?)(?![\d./])"#)

    private func commandChanged(_ text: String) {
        commandLine = text
        guard targetSource == .commandLine else { return }
        // Ignore anything typed after "Label" (it's label text, not a cue reference).
        var scan = text
        if let r = scan.range(of: "Label", options: .caseInsensitive) { scan = String(scan[..<r.lowerBound]) }
        let ns = scan as NSString
        guard let m = Self.cueRegex.matches(in: scan, range: NSRange(location: 0, length: ns.length)).last else { return }
        let list: String
        if m.range(at: 1).location != NSNotFound {
            list = ns.substring(with: m.range(at: 1))
        } else {
            list = pendingCue?.list ?? activeCue?.list ?? (d.string(forKey: Pref.defaultList) ?? "1")
        }
        setTarget(CueRef(list: list, number: ns.substring(with: m.range(at: 2))))
    }

    // MARK: - Target cue & label

    func setTarget(_ ref: CueRef, manual: Bool = false) {
        if locked && !manual { return }
        guard ref != target else { return }
        target = ref
        targetLabel = nil
        pendingOp = nil
        requestLabel(ref)
    }

    /// Manual entry: "5", "2/5", "2/5.5".
    func setTargetFromText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let bits = t.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        let ref: CueRef
        if bits.count == 2 {
            ref = CueRef(list: bits[0], number: bits[1])
        } else {
            ref = CueRef(list: target?.list ?? d.string(forKey: Pref.defaultList) ?? "1", number: bits[0])
        }
        guard Double(ref.number) != nil, Int(ref.list) != nil else {
            addLog(.error, "\"\(t)\" isn't a cue number")
            return
        }
        target = nil
        setTarget(ref, manual: true)
    }

    func refreshLabel() {
        if let t = target { requestLabel(t) }
    }

    private func requestLabel(_ ref: CueRef) {
        guard running else { labelState = "Not connected"; return }
        labelState = "Loading label…"
        send("/eos/get/cue/\(ref.list)/\(ref.number)", log: false)
        labelTimeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.target == ref, self.targetLabel == nil else { return }
                self.labelState = "No reply from EOS (does cue \(ref.display) exist?)"
                if self.pendingOp != nil {
                    self.pendingOp = nil
                    self.addLog(.error, "Couldn't read label of cue \(ref.display) — nothing changed")
                }
            }
        }
        labelTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func gotLabel(_ label: String) {
        targetLabel = label
        labelState = ""
        labelTimeout?.cancel()
        if let op = pendingOp {
            pendingOp = nil
            apply(op.op, prefix: op.prefix, suffix: op.suffix)
        }
    }

    // MARK: - Prefix / suffix

    private func join(_ a: String, _ b: String) -> String {
        guard d.bool(forKey: Pref.autoSpace), !a.isEmpty, !b.isEmpty,
              a.last != " ", b.first != " " else { return a + b }
        return a + " " + b
    }

    /// The label that `op` would produce from `current`.
    func preview(_ op: LabelOp, current: String, prefix pfx: String? = nil, suffix sfx: String? = nil) -> String {
        let p = (pfx ?? prefix).trimmingCharacters(in: d.bool(forKey: Pref.autoSpace) ? .whitespaces : [])
        let s = (sfx ?? suffix).trimmingCharacters(in: d.bool(forKey: Pref.autoSpace) ? .whitespaces : [])
        var label = current
        switch op {
        case .prefix:
            if !p.isEmpty && !label.hasPrefix(p) { label = join(p, label) }
        case .suffix:
            if !s.isEmpty && !label.hasSuffix(s) { label = join(label, s) }
        case .both:
            if !p.isEmpty && !label.hasPrefix(p) { label = join(p, label) }
            if !s.isEmpty && !label.hasSuffix(s) { label = join(label, s) }
        case .remove:
            if !p.isEmpty && label.hasPrefix(p) {
                label = String(label.dropFirst(p.count))
                if d.bool(forKey: Pref.autoSpace) { label = String(label.drop(while: { $0 == " " })) }
            }
            if !s.isEmpty && label.hasSuffix(s) {
                label = String(label.dropLast(s.count))
                if d.bool(forKey: Pref.autoSpace) { while label.last == " " { label.removeLast() } }
            }
        case .strip:
            // Same text checked at both ends; spaces left over at the cut are trimmed.
            if !p.isEmpty && label.hasPrefix(p) {
                label = String(label.dropFirst(p.count).drop(while: { $0 == " " }))
            }
            if !p.isEmpty && label.hasSuffix(p) {
                label = String(label.dropLast(p.count))
                while label.last == " " { label.removeLast() }
            }
        }
        return label
    }

    func apply(_ op: LabelOp, prefix pfx: String? = nil, suffix sfx: String? = nil) {
        guard let t = target else { addLog(.error, "No target cue yet"); return }
        guard let current = targetLabel else {
            // Label not known yet (e.g. triggered from an EOS macro right after selecting a cue): fetch, then apply.
            pendingOp = (op, pfx, sfx)
            requestLabel(t)
            return
        }
        let new = preview(op, current: current, prefix: pfx, suffix: sfx)
        guard new != current else {
            let what: String
            switch op {
            case .remove: what = "Cue \(t.display) doesn't start/end with the prefix/suffix"
            case .strip: what = "Cue \(t.display) doesn't start or end with \"\(pfx ?? "")\""
            default: what = "Cue \(t.display) already has that \(op.rawValue)"
            }
            addLog(.info, what + " — no change")
            return
        }
        writeLabel(new, to: t, old: current)
    }

    func undo() {
        guard let c = lastChange else { return }
        writeLabel(c.old, to: c.cue, old: c.new, isUndo: true)
    }

    private func writeLabel(_ label: String, to cue: CueRef, old: String, isUndo: Bool = false) {
        // Writes the label directly; doesn't touch anyone's command line.
        send("/eos/set/cue/\(cue.list)/\(cue.number)/label", [.string(label)])
        addLog(.info, "Cue \(cue.display): \"\(old)\" → \"\(label)\"")
        lastChange = isUndo ? nil : (cue, old, label)
        if cue == target { targetLabel = label }
        // Read it back once to confirm what EOS actually stored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.target == cue else { return }
            self.send("/eos/get/cue/\(cue.list)/\(cue.number)", log: false)
        }
    }

    /// Splits "/label/prefix/remove=\"My Label\"" into path ["prefix", "remove"] and value "My Label".
    /// The value can also come as the first argument (how EOS Send_String delivers "…=value").
    /// Path keeps its case (page names); compare with lowercased(). Surrounding quotes are stripped.
    private func splitCommand(_ m: OSCMessage) -> (path: [String], value: String?) {
        let rest = m.parts.dropFirst().joined(separator: "/")
        var left = rest
        var value: String?
        if let eq = rest.firstIndex(of: "=") {
            left = String(rest[..<eq])
            value = String(rest[rest.index(after: eq)...])
        }
        if value?.isEmpty ?? true, let a = m.args.first { value = a.text }
        value = value.map { v in
            var s = v.trimmingCharacters(in: .whitespaces)
            let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’"]
            if s.count >= 2, let f = s.first, let l = s.last, quotes.contains(f), quotes.contains(l) {
                s = String(s.dropFirst().dropLast())
            }
            return s
        }
        if value?.isEmpty == true { value = nil }
        return (left.split(separator: "/").map(String.init), value)
    }

    /// /label/prefix="My Prefix"          add that prefix (also becomes the app's prefix)
    /// /label/suffix="My Suffix"          add that suffix (also becomes the app's suffix)
    /// /label/prefix/remove="My Label"    remove that text from the start or end of the label
    /// /label/suffix/remove="My Label"    same
    /// /label/remove                      remove the app's current prefix/suffix
    /// /label/both, /label/undo, /label/cue="2/5"      (/labeler/... works too)
    private func handleLabelerTrigger(_ m: OSCMessage) {
        addLog(.rx, m.debugText)
        let (path, text) = splitCommand(m)
        let cmd = path.map { $0.lowercased() }
        if cmd.contains("remove") {
            // /label/remove, /label/prefix/remove="X", /label/suffix/remove="X"
            if let text { apply(.strip, prefix: text) } else { apply(.remove) }
            return
        }
        switch cmd.first ?? "" {
        case "prefix":
            if let text { d.set(text, forKey: Pref.prefix) }
            apply(.prefix, prefix: text)
        case "suffix":
            if let text { d.set(text, forKey: Pref.suffix) }
            apply(.suffix, suffix: text)
        case "both", "apply": apply(.both)
        case "undo": undo()
        case "cue", "target":
            if let cue = text ?? (path.count > 1 ? path.dropFirst().joined(separator: "/") : nil) {
                setTargetFromText(cue)
            }
        default: addLog(.error, "Unknown label command \(m.address)")
        }
    }

    // MARK: - Cuelist

    /// /cuelist/next, /cuelist/last (or /prev, /previous, /back), /cuelist/page=12, /cuelist/page/12, /cuelist/page 12
    private func handleCuelist(_ m: OSCMessage) {
        addLog(.rx, m.debugText)
        guard d.bool(forKey: Pref.cuelistEnabled) else {
            addLog(.info, "Cuelist control is turned off — ignored")
            return
        }
        let (path, arg) = splitCommand(m)
        let value = arg ?? (path.count > 1 ? path.dropFirst().joined(separator: "/") : nil)
        switch path.first?.lowercased() ?? "" {
        case "next", "forward", "fwd": cuelist(.next)
        case "last", "prev", "previous", "back": cuelist(.previous)
        case "page", "goto":
            if let v = value {
                cuelist(.page(v))
            } else {
                addLog(.error, "\(m.address) needs a page number, e.g. /cuelist/page=12")
            }
        default:
            addLog(.error, "Unknown Cuelist command \(m.address)")
        }
    }

    func cuelist(_ action: CuelistDriver.Action, reason: String? = nil) {
        if let reason { addLog(.info, "\(action.name) (\(reason))") }
        CuelistDriver.perform(action) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let page):
                self.cuelistError = false
                self.cuelistStatus = page.isEmpty ? "\(action.name) ✓" : "Page \(page)"
            case .failure(let e):
                self.cuelistError = true
                self.cuelistStatus = e.localizedDescription
                self.addLog(.error, "Cuelist: \(e.localizedDescription)")
            }
        }
    }

    // MARK: - Log

    func addLog(_ kind: LogLine.Kind, _ text: String) {
        log.append(LogLine(kind: kind, text: text))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}
