import AppKit
import Foundation

/// Self-updater: checks the latest GitHub release, downloads the zipped .app, swaps it in place, relaunches.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release { let version: String; let zipURL: URL; let notes: String }

    @Published var available: Release?
    @Published var status = ""
    @Published var busy = false

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    private let repo = Bundle.main.object(forInfoDictionaryKey: "GitHubRepo") as? String ?? ""

    /// At launch: install automatically if enabled (safe — nothing is running yet). Otherwise just offer it.
    func launchCheck() {
        Task {
            await check(userInitiated: false)
            if available != nil && UserDefaults.standard.bool(forKey: Pref.autoUpdate) {
                install()
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard !repo.isEmpty, Bundle.main.bundleURL.pathExtension == "app" else {
            if userInitiated { status = "Updates only work from the installed .app" }
            return
        }
        busy = true
        defer { busy = false }
        if userInitiated { status = "Checking…" }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let urlString = zip["browser_download_url"] as? String,
                  let url = URL(string: urlString)
            else {
                if userInitiated { status = "No releases found" }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(version, than: currentVersion) {
                available = Release(version: version, zipURL: url, notes: json["body"] as? String ?? "")
                status = "Version \(version) is available"
            } else {
                available = nil
                if userInitiated { status = "You're up to date (\(currentVersion))" }
            }
        } catch {
            if userInitiated { status = "Update check failed: \(error.localizedDescription)" }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func install() {
        guard let rel = available, !busy else { return }
        busy = true
        status = "Downloading \(rel.version)…"
        Task {
            do {
                let (file, _) = try await URLSession.shared.download(from: rel.zipURL)
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("EOSCueHelperUpdate-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zipPath = work.appendingPathComponent("update.zip")
                try fm.moveItem(at: file, to: zipPath)

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zipPath.path, work.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0,
                      let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" })
                else { throw TransportError.message("Downloaded update is not a valid app") }

                let dest = Bundle.main.bundleURL.path
                let pid = ProcessInfo.processInfo.processIdentifier
                // Wait for us to quit, swap the bundle (keeping the old one if anything fails), relaunch.
                let script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                DEST="$1"; NEW="$2"
                rm -rf "$DEST.old"
                if mv "$DEST" "$DEST.old" && mv "$NEW" "$DEST"; then rm -rf "$DEST.old"; else rm -rf "$DEST"; mv "$DEST.old" "$DEST"; fi
                xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
                open "$DEST"
                rm -rf "$3"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-c", script, "updater", dest, newApp.path, work.path]
                try p.run()
                status = "Installing \(rel.version)…"
                NSApp.terminate(nil)
            } catch {
                busy = false
                status = "Update failed: \(error.localizedDescription)"
            }
        }
    }
}
