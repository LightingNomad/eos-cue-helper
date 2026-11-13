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

    private static let appleScript = """
    on run argv
      set js to item 1 of argv
      if application "Google Chrome" is not running then return "ERR:Google Chrome is not running"
      tell application "Google Chrome"
        repeat with w in windows
          repeat with t in tabs of w
            if (URL of t) contains "thecuelist.com" then
              set r to execute t javascript js
              if r is missing value then return ""
              return r as text
            end if
          end repeat
        end repeat
      end tell
      return "ERR:No Cuelist tab is open in Chrome"
    end run
    """

    /// Performs the action, then reports the resulting page ("13 / 123") or an error. Completion runs on main.
    static func perform(_ action: Action, completion: @escaping (Result<String, TransportError>) -> Void) {
        queue.async {
            var result = runJS(script(for: action))
            if case .success = result {
                Thread.sleep(forTimeInterval: 0.25)
                result = runJS(readPageScript)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runJS(_ js: String) -> Result<String, TransportError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript, js]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(.message("osascript failed: \(error.localizedDescription)")) }
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
