import XCTest

/// Drives the app with real Siri Remote presses from a script file (simulator testing).
/// Script: whitespace-separated tokens — up down left right select menu play,
/// `hold` (long select), `wait`, `shot:name` (screenshot to the output dir).
/// Env (via TEST_RUNNER_ prefix): REMOTE_SCRIPT (path), REMOTE_OUT (dir), REMOTE_ARGS (launch args, `|`-separated).
final class RemoteScriptTests: XCTestCase {
    func testRunScript() throws {
        let env = ProcessInfo.processInfo.environment
        // On a device the Mac's files aren't reachable: REMOTE_SCRIPT_TEXT carries the script itself.
        guard let script = env["REMOTE_SCRIPT_TEXT"] ?? env["REMOTE_SCRIPT"].flatMap({ try? String(contentsOfFile: $0) }) else {
            throw XCTSkip("no REMOTE_SCRIPT")
        }
        let out = env["REMOTE_OUT"] ?? NSTemporaryDirectory()
        let app = XCUIApplication()
        app.launchArguments = (env["REMOTE_ARGS"] ?? "").split(separator: "|").map(String.init)
        app.launch()
        let remote = XCUIRemote.shared
        for token in script.split(whereSeparator: { $0.isWhitespace }) {
            let t = String(token)
            switch t {
            case "up": remote.press(.up)
            case "down": remote.press(.down)
            case "left": remote.press(.left)
            case "right": remote.press(.right)
            case "select": remote.press(.select)
            case "menu": remote.press(.menu)
            case "play": remote.press(.playPause)
            case "hold": remote.press(.select, forDuration: 1.2)
            case "wait": Thread.sleep(forTimeInterval: 2); continue
            // Quick presses (0.25 s apart), the way a thumb clicks through rows.
            case "u": remote.press(.up); Thread.sleep(forTimeInterval: 0.25); continue
            case "d": remote.press(.down); Thread.sleep(forTimeInterval: 0.25); continue
            // Very quick presses (0.06 s apart): a fast flick, or a slow device catching up.
            case "U": remote.press(.up); Thread.sleep(forTimeInterval: 0.06); continue
            case "D": remote.press(.down); Thread.sleep(forTimeInterval: 0.06); continue
            case "l": remote.press(.left); Thread.sleep(forTimeInterval: 0.25); continue
            case "r": remote.press(.right); Thread.sleep(forTimeInterval: 0.25); continue
            default:
                if t.hasPrefix("type:") {
                    // `type:the_bear` types "the bear" into the focused field.
                    app.typeText(String(t.dropFirst(5)).replacingOccurrences(of: "_", with: " "))
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }
                if t.hasPrefix("sleep:"), let s = Double(t.dropFirst(6)) { Thread.sleep(forTimeInterval: s); continue }
                // `burst:N` — N screenshots as fast as the runner can take them
                // (~every 100–150 ms), for inspecting a transition frame by frame.
                if t.hasPrefix("burst:"), let n = Int(t.dropFirst(6)) {
                    for i in 0..<n {
                        let shot = XCUIScreen.main.screenshot()
                        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(t.dropFirst(6))-\(i).png"))
                    }
                    continue
                }
                if t.hasPrefix("shot:") {
                    let shot = XCUIScreen.main.screenshot()
                    try? shot.pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(t.dropFirst(5)).png"))
                    // Also kept in the result bundle (the way back from a device).
                    let a = XCTAttachment(screenshot: shot)
                    a.name = String(t.dropFirst(5))
                    a.lifetime = .keepAlways
                    add(a)
                    continue
                }
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
}
