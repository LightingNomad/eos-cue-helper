import AppKit
import SwiftUI

@main
struct EOSCueHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared
    @StateObject private var updater = Updater.shared

    var body: some Scene {
        Window("EOS Cue Helper", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
            }
            CommandMenu("Cue") {
                Button("Add Prefix") { model.apply(.prefix) }.keyboardShortcut("1")
                Button("Add Suffix") { model.apply(.suffix) }.keyboardShortcut("2")
                Button("Add Both") { model.apply(.both) }.keyboardShortcut("3")
                Button("Remove Prefix/Suffix") { model.apply(.remove) }.keyboardShortcut("4")
                Button("Undo Last Label Change") { model.undo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Label") { model.refreshLabel() }.keyboardShortcut("r")
                Divider()
                Button("Cuelist: Previous Page") { model.cuelist(.previous) }.keyboardShortcut("[")
                Button("Cuelist: Next Page") { model.cuelist(.next) }.keyboardShortcut("]")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppModel.shared.connect()
            Updater.shared.launchCheck()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    @AppStorage(Pref.keepOnTop) private var keepOnTop = false
    @AppStorage(Pref.logIncoming) private var logIncoming = false
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 12) {
            if let rel = updater.available {
                UpdateBanner(release: rel)
            }
            ConnectionSection()
            TargetSection()
            LabelSection()
            CuelistSection()
            DisclosureGroup(isExpanded: $showLog) {
                LogView()
            } label: {
                HStack {
                    Text("Log").font(.headline)
                    Spacer()
                    if showLog {
                        Toggle("Show all incoming", isOn: $logIncoming).toggleStyle(.checkbox).font(.caption)
                        Button("Clear") { model.log.removeAll() }.font(.caption)
                    }
                }
            }
            HStack {
                Toggle("Keep window on top", isOn: $keepOnTop).toggleStyle(.checkbox)
                Spacer()
                Text("v\(updater.currentVersion)").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 440)
        .background(WindowLevel(floating: keepOnTop))
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var updater: Updater
    let release: Updater.Release

    var body: some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("Version \(release.version) is available")
            Spacer()
            Button(updater.busy ? "Installing…" : "Install & Relaunch") { updater.install() }
                .disabled(updater.busy)
        }
        .padding(8)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Connection

struct ConnectionSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.mode) private var mode = ConnMode.udp
    @AppStorage(Pref.eosIP) private var eosIP = "127.0.0.1"
    @AppStorage(Pref.udpSendPort) private var udpSendPort = 8000
    @AppStorage(Pref.udpListenPort) private var udpListenPort = 8001
    @AppStorage(Pref.tcpPort) private var tcpPort = 3037
    @AppStorage(Pref.tcpFraming) private var tcpFraming = TCPClient.Framing.slip.rawValue
    @State private var expanded = false

    var dotColor: Color {
        switch model.health {
        case .ok: return .green
        case .waiting: return .orange
        case .error: return .red
        case .off: return .gray
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(dotColor).frame(width: 10, height: 10)
                    Text(model.statusText).lineLimit(2).font(.callout)
                    Spacer()
                    Button { withAnimation { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Connection settings")
                    Button(model.running ? "Reconnect" : "Connect") { model.connect() }
                }
                if expanded || model.health == .error {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("Protocol")
                            Picker("", selection: $mode) {
                                ForEach(ConnMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                        }
                        GridRow {
                            Text("EOS IP")
                            TextField("192.168.1.100", text: $eosIP).frame(width: 150)
                        }
                        if mode == .udp {
                            GridRow {
                                Text("Send to port")
                                HStack {
                                    TextField("", value: $udpSendPort, format: .number.grouping(.never)).frame(width: 70)
                                    Text("EOS \"OSC UDP RX Port\"").foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        } else {
                            GridRow {
                                Text("TCP port")
                                HStack {
                                    TextField("", value: $tcpPort, format: .number.grouping(.never)).frame(width: 70)
                                    Picker("", selection: $tcpFraming) {
                                        Text("OSC 1.1 (SLIP) – 3037").tag(TCPClient.Framing.slip.rawValue)
                                        Text("OSC 1.0 – 3032").tag(TCPClient.Framing.length.rawValue)
                                    }
                                    .labelsHidden().frame(width: 180)
                                }
                            }
                        }
                        GridRow {
                            Text("Listen on UDP")
                            HStack {
                                TextField("", value: $udpListenPort, format: .number.grouping(.never)).frame(width: 70)
                                Text(mode == .udp ? "EOS \"OSC UDP TX Port\" + Cuelist triggers" : "for Cuelist / other triggers")
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    Text(mode == .udp
                         ? "In EOS Setup ▸ System ▸ Show Control ▸ OSC: turn on OSC RX and OSC TX, set OSC UDP TX IP Address to this Mac."
                         : "In EOS Setup ▸ System ▸ Show Control ▸ OSC: turn on OSC RX and OSC TX. TCP needs no IP setup in EOS.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Apply & Connect") { model.connect(); expanded = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(4)
        }
        .onAppear { expanded = false }
    }
}

// MARK: Target

struct TargetSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.targetSource) private var source = TargetSource.commandLine
    @State private var manual = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("TARGET").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Follow", selection: $source) {
                        ForEach(TargetSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 270)
                    .help("Which EOS cue the app targets")
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.target.map { "Cue \($0.display)" } ?? "No cue yet")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(model.target == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                    Spacer()
                    Toggle(isOn: $model.locked) {
                        Image(systemName: model.locked ? "lock.fill" : "lock.open")
                    }
                    .toggleStyle(.button)
                    .help("Lock: stop following EOS and stay on this cue")
                }
                HStack {
                    if let label = model.targetLabel {
                        Text(label.isEmpty ? "(no label)" : label)
                            .font(.title3)
                            .foregroundStyle(label.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    } else {
                        Text(model.target == nil ? "Select a cue in EOS" : model.labelState)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.refreshLabel() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Re-read the label from EOS (⌘R)")
                        .disabled(model.target == nil)
                }
                HStack(spacing: 6) {
                    TextField("Go to cue (5 or 2/5)", text: $manual)
                        .onSubmit { model.setTargetFromText(manual); manual = "" }
                        .frame(width: 150)
                    Spacer()
                    Group {
                        if let a = model.activeCue { Text("Active \(a.display)") }
                        if let p = model.pendingCue { Text("Pending \(p.display)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !model.commandLine.isEmpty {
                    Text(model.commandLine)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .padding(4)
        }
    }
}

// MARK: Labels

struct LabelSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.prefix) private var prefix = ""
    @AppStorage(Pref.suffix) private var suffix = ""
    @AppStorage(Pref.autoSpace) private var autoSpace = true

    private var canApply: Bool { model.target != nil && model.running }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("LABEL").font(.caption.bold()).foregroundStyle(.secondary)
                HStack {
                    TextField("Prefix", text: $prefix).textFieldStyle(.roundedBorder)
                        .onSubmit { model.apply(.prefix) }
                    Button("Add Prefix") { model.apply(.prefix) }
                        .disabled(!canApply || prefix.isEmpty).frame(width: 100)
                        .help("⌘1")
                }
                HStack {
                    TextField("Suffix", text: $suffix).textFieldStyle(.roundedBorder)
                        .onSubmit { model.apply(.suffix) }
                    Button("Add Suffix") { model.apply(.suffix) }
                        .disabled(!canApply || suffix.isEmpty).frame(width: 100)
                        .help("⌘2")
                }
                if let current = model.targetLabel, !(prefix.isEmpty && suffix.isEmpty) {
                    HStack(spacing: 4) {
                        Text("Both →").foregroundStyle(.secondary)
                        Text("\"\(model.preview(.both, current: current, prefix: prefix, suffix: suffix))\"")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption)
                }
                HStack {
                    Button("Add Both") { model.apply(.both) }
                        .disabled(!canApply || (prefix.isEmpty && suffix.isEmpty)).help("⌘3")
                    Button("Remove") { model.apply(.remove) }
                        .disabled(!canApply || (prefix.isEmpty && suffix.isEmpty))
                        .help("Strip this prefix/suffix from the label (⌘4)")
                    Button("Undo") { model.undo() }
                        .disabled(model.lastChange == nil)
                        .help(model.lastChange.map { "Put cue \($0.cue.display) back to \"\($0.old)\" (⇧⌘Z)" } ?? "")
                    Spacer()
                    Toggle("Auto space", isOn: $autoSpace).toggleStyle(.checkbox).font(.caption)
                        .help("Put a space between the prefix/suffix and the label")
                }
            }
            .padding(4)
        }
    }
}

// MARK: Cuelist

struct CuelistSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.cuelistEnabled) private var enabled = true
    @AppStorage(Pref.pageOnCueFire) private var pageOnFire = false
    @AppStorage(Pref.pageOnCueFireList) private var fireList = "2"
    @State private var page = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CUELIST").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Respond to /cuelist OSC", isOn: $enabled).toggleStyle(.checkbox).font(.caption)
                }
                HStack {
                    Button { model.cuelist(.previous) } label: { Label("Prev", systemImage: "chevron.left") }
                    TextField("Page", text: $page)
                        .frame(width: 60)
                        .onSubmit(goToPage)
                    Button("Go", action: goToPage).disabled(page.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { model.cuelist(.next) } label: { Label("Next", systemImage: "chevron.right") }
                    Spacer()
                }
                if !model.cuelistStatus.isEmpty {
                    Text(model.cuelistStatus)
                        .font(.caption)
                        .foregroundStyle(model.cuelistError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    Toggle("Next page when EOS cue list", isOn: $pageOnFire).toggleStyle(.checkbox)
                    TextField("", text: $fireList).frame(width: 34).disabled(!pageOnFire)
                    Text("fires a cue")
                }
                .font(.caption)
            }
            .padding(4)
        }
    }

    private func goToPage() {
        let name = page.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.cuelist(.page(name))
    }
}

// MARK: Log

struct LogView: View {
    @EnvironmentObject var model: AppModel
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.log) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(Self.fmt.string(from: line.time)).foregroundStyle(.tertiary)
                            Text(symbol(line.kind)).foregroundStyle(color(line.kind))
                            Text(line.text).foregroundStyle(line.kind == .error ? .red : .primary)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: model.log.count) { _ in
                if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func symbol(_ k: LogLine.Kind) -> String {
        switch k { case .info: return "•"; case .rx: return "←"; case .tx: return "→"; case .error: return "!" }
    }
    private func color(_ k: LogLine.Kind) -> Color {
        switch k { case .info: return .secondary; case .rx: return .blue; case .tx: return .green; case .error: return .red }
    }
}

// MARK: Settings window

struct SettingsView: View {
    @EnvironmentObject var updater: Updater
    @AppStorage(Pref.defaultList) private var defaultList = "1"
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true

    var body: some View {
        Form {
            Section("EOS") {
                TextField("Default cue list", text: $defaultList)
                    .help("Used when the command line says \"Cue 5\" without a list and no active/pending cue is known")
                Text("Labels are written with /eos/set/cue/<list>/<cue>/label \"text\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("OSC triggers (send to the listen port)") {
                Text("""
                /cuelist/next   /cuelist/last   /cuelist/page=12
                /label/prefix="My Prefix"   /label/suffix="My Suffix"
                /label/prefix   /label/suffix   (use the text in the app)
                /label/both   /label/remove   /label/undo   /label/cue="2/5"
                """)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
            Section("Updates") {
                Toggle("Install updates automatically at launch", isOn: $autoUpdate)
                HStack {
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.busy)
                    Text(updater.status).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

// MARK: Helpers

/// Sets the hosting window's level (float above EOS / Chrome when wanted).
struct WindowLevel: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.level = floating ? .floating : .normal }
    }
}
