import AppKit
import Foundation

/// Drives the Cuelist web app (app.thecuelist.com) open in Google Chrome by running
/// JavaScript in its tab through AppleScript. Chrome does not need to be in front.
/// Requires Chrome ▸ View ▸ Developer ▸ "Allow JavaScript from Apple Events".
enum CuelistDriver {
    enum Action: Equatable {
        case next, previous, page(String)

        var name: String {
            switch self {
            case .next: return "Next page"
            case .previous: return "Previous page"
            case .page(let n): return "Page \(n)"
            }
        }
    }

    private static let queue = DispatchQueue(label: "eoscuehelper.cuelist")

    // Finds the page-number box in Cuelist's toolbar (the numeric text box next to "/ 123").
    private static let findPageBox = """
    var box = document.querySelector('input.current-page-input') ||
      Array.prototype.slice.call(document.querySelectorAll('input[type=text]'))
        .filter(function (x) { return /^\\s*\\d+\\s*$/.test(x.value); })[0];
    function total() {
      if (!box) return '';
      var n = box.parentElement, m = null;
      for (var i = 0; i < 3 && n && !m; i++, n = n.parentElement) m = (n.textContent || '').match(/\\/\\s*(\\d+)/);
      return m ? m[1] : '';
    }
    """

    private static func script(for action: Action) -> String {
        switch action {
        case .next, .previous:
            let key = action == .next ? "ArrowRight" : "ArrowLeft"
            let code = action == .next ? 39 : 37
            return """
            (function () {
              if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
              var o = {key: '\(key)', code: '\(key)', keyCode: \(code), which: \(code), bubbles: true, cancelable: true};
              document.dispatchEvent(new KeyboardEvent('keydown', o));
              document.dispatchEvent(new KeyboardEvent('keyup', o));
              return 'ok';
            })()
            """
        case .page(let name):
            // Cuelist's page box (Vue) only acts on a `change` event and matches page *names* exactly.
            let quoted = String(data: try! JSONEncoder().encode(name), encoding: .utf8)!
            return """
            (function () {
              \(findPageBox)
              if (!box) return 'ERR:Could not find the page number box in Cuelist';
              var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
              setter.call(box, \(quoted));
              box.dispatchEvent(new Event('input', {bubbles: true}));
              box.dispatchEvent(new Event('change', {bubbles: true}));
              return 'ok';
            })()
            """
        }
    }

    private static let readPageScript = """
    (function () {
      \(findPageBox)
      if (!box) return '';
      var t = total();
      return box.value + (t ? ' / ' + t : '');
    })()
    """

    /// Runs `js` (if not empty) in every Cuelist tab except the skipped ones, waits a moment, then
    /// reports every Cuelist tab, one line each: id, window #, bounds (l t r b), page, title.
    private static let appleScript = """
    on run argv
      set js to item 1 of argv
      set readJS to item 2 of argv
      set skipList to item 3 of argv
      set sepT to character id 9
      set sepN to character id 10
      if application "Google Chrome" is not running then return "ERR:Google Chrome is not running"
      set found to {}
      tell application "Google Chrome"
        set wi to 0
        repeat with w in windows
          set wi to wi + 1
          repeat with t in tabs of w
            if (URL of t) contains "thecuelist.com" then
              set tid to (id of t) as text
              if js is not "" and skipList does not contain ("," & tid & ",") then execute t javascript js
              set end of found to {t, tid, wi, bounds of w}
            end if
          end repeat
        end repeat
        if (count of found) is 0 then return "ERR:No Cuelist tab is open in Chrome"
        if js is not "" then delay 0.25
        set out to ""
        repeat with x in found
          set t to item 1 of x
          set b to item 4 of x
          set r to execute t javascript readJS
          if r is missing value then set r to ""
          set out to out & (item 2 of x) & sepT & (item 3 of x) & sepT & (item 1 of b) & sepT & (item 2 of b) & sepT & (item 3 of b) & sepT & (item 4 of b) & sepT & r & sepT & (title of t) & sepN
        end repeat
      end tell
      return out
    end run
    """

    /// Runs `action` in every Cuelist tab not in `excluded` (nil = just list the tabs). Completion runs on main.
    static func perform(_ action: Action?, excluding excluded: Set<Int>,
                        completion: @escaping (Result<[CuelistTab], TransportError>) -> Void) {
        let js = action.map(script(for:)) ?? ""
        let skip = "," + excluded.map(String.init).joined(separator: ",") + ","
        queue.async {
            let result = run([js, readPageScript, skip]).map(parseTabs)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func parseTabs(_ text: String) -> [CuelistTab] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, let id = Int(f[0]), let win = Int(f[1]),
                  let l = Double(f[2]), let t = Double(f[3]), let r = Double(f[4]), let b = Double(f[5]) else { return nil }
            return CuelistTab(id: id, window: win, screen: screenName(left: l, top: t, right: r, bottom: b),
                              page: f[6], title: f.count > 7 ? f[7] : "")
        }
    }

    /// Which display a Chrome window sits on. Chrome reports top-left-origin global coordinates.
    private static func screenName(left: Double, top: Double, right: Double, bottom: Double) -> String {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return "" }
        let center = NSPoint(x: (left + right) / 2, y: primary.frame.maxY - (top + bottom) / 2)
        let s = screens.first(where: { $0.frame.contains(center) }) ?? primary
        return s.localizedName
    }

    private static func run(_ args: [String]) -> Result<String, TransportError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(.message("osascript failed: \(error.localizedDescription)")) }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let o = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let e = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 {
            if e.contains("JavaScript through AppleScript is turned off") || e.contains("Allow JavaScript from Apple Events") {
                return .failure(.message("In Chrome, turn on View ▸ Developer ▸ Allow JavaScript from Apple Events"))
            }
            if e.contains("-1743") || e.lowercased().contains("not allowed") {
                return .failure(.message("macOS blocked control of Chrome. Allow it in System Settings ▸ Privacy & Security ▸ Automation"))
            }
            return .failure(.message(e.isEmpty ? "AppleScript error" : e))
        }
        if o.hasPrefix("ERR:") { return .failure(.message(String(o.dropFirst(4)))) }
        return .success(o)
    }
}

struct CuelistTab: Identifiable, Equatable {
    let id: Int        // Chrome's tab id (stable while Chrome is open)
    let window: Int    // Chrome window number, front-most first
    let screen: String // display the window is on
    let page: String   // "39 / 123"
    let title: String
}
