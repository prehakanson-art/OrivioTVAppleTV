import Foundation
import Network
import SwiftUI

/// "Add from Phone" / "Enter from Phone": the TV runs a tiny LAN HTTP server
/// and shows a QR; the phone page posts text (add-on URLs, keys, playlists) back.
@MainActor
final class PhoneInputServer: ObservableObject {
    @Published private(set) var url: String?
    @Published private(set) var status = "Starting…"
    @Published private(set) var received = 0

    private var listener: NWListener?
    private let title: String
    private let prompt: String
    private let multiline: Bool
    private let onText: ((String) -> Void)?
    /// A file the phone can download (Local Backup / add-on setup export).
    private let export: (filename: String, text: String)?

    init(title: String, prompt: String, multiline: Bool, export: (filename: String, text: String)? = nil, onText: ((String) -> Void)?) {
        self.title = title
        self.prompt = prompt
        self.multiline = multiline
        self.export = export
        self.onText = onText
    }

    func start() {
        guard listener == nil else { return }
        for port in [8098, 8099, 8100, 0] {
            guard let l = try? NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(port))!) else { continue }
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.handle(c) } }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let ip = Self.lanAddress(), let p = l.port?.rawValue else {
                            self.status = "Connect this Apple TV to your home network first."
                            return
                        }
                        self.url = "http://\(ip):\(p)/"
                        self.status = "Waiting for your phone…"
                    case .failed(let e):
                        self.status = "Couldn't start: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
            return
        }
        status = "Couldn't start the local server."
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP

    private func handle(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { c.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if done || error != nil || buf.count > 16_000_000 { c.cancel() } else { self.receive(c, buffer: buf) }
                    return
                }
                let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[headerEnd.upperBound...]
                if body.count < length, !done, error == nil { self.receive(c, buffer: buf); return }
                self.respond(c, head: head, body: Data(body))
            }
        }
    }

    private func respond(_ c: NWConnection, head: String, body: Data) {
        let requestLine = head.split(separator: "\r\n").first ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        if let export, requestLine.hasPrefix("GET"), path == "/" + export.filename {
            let data = Data(export.text.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(export.filename.hasSuffix(".json") ? "application/json" : "text/plain"); charset=utf-8\r\nContent-Disposition: attachment; filename=\"\(export.filename)\"\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(response.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
            status = "Sent to your phone ✓"
            return
        }
        let html: String
        if requestLine.hasPrefix("POST"), let onText {
            let form = String(data: body, encoding: .utf8) ?? ""
            let text = form.split(separator: "&").compactMap { pair -> String? in
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, kv[0] == "text" else { return nil }
                return String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                received += 1
                status = "Received from your phone ✓"
                onText(text)
            }
            html = page(sent: !text.isEmpty)
        } else {
            html = page(sent: false)
        }
        let data = Data(html.utf8)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(response.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
    }

    private func page(sent: Bool) -> String {
        let esc: (String) -> String = { $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let field = multiline
            ? "<textarea name=\"text\" rows=\"6\" autofocus placeholder=\"One per line\"></textarea>"
            : "<input name=\"text\" autofocus autocapitalize=\"off\" autocomplete=\"off\">"
        let form = onText == nil ? "" : "<form method=\"post\">\(field)<button type=\"submit\">Send to Apple TV</button></form>"
        let download = export.map { e in
            "<a class=\"dl\" href=\"/\(esc(e.filename))\" download>Download \(esc(e.filename))</a><textarea readonly rows=\"10\">\(esc(e.text))</textarea>"
        } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Orivio</title><style>
        body{font-family:-apple-system,system-ui,sans-serif;background:#1b1f2a;color:#fff;margin:0;padding:24px}
        h1{font-size:24px}p{color:#aab}textarea,input{width:100%;box-sizing:border-box;font-size:17px;padding:12px;border-radius:12px;border:0;background:#2c3242;color:#fff}
        button{margin-top:16px;width:100%;padding:14px;font-size:18px;font-weight:600;border:0;border-radius:24px;background:#fff;color:#111}
        .ok{background:#30d15822;color:#30d158;padding:12px;border-radius:12px;margin-bottom:16px}
        .dl{display:block;text-align:center;margin:16px 0;padding:14px;font-size:18px;font-weight:600;border-radius:24px;background:#fff;color:#111;text-decoration:none}
        </style></head><body><h1>\(esc(title))</h1>
        \(sent ? "<div class=\"ok\">Sent to your Apple TV ✓</div>" : "")
        <p>\(esc(prompt))</p>\(download)\(form)</body></html>
        """
    }

    /// The Wi-Fi/Ethernet IPv4 address.
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
            if name.hasPrefix("en") { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }
}

/// The QR sheet for phone input.
struct PhoneInputSheet: View {
    let title: String
    let prompt: String
    var multiline = false
    let onDone: () -> Void
    @StateObject private var server: PhoneInputServer

    init(title: String, prompt: String, multiline: Bool = false, onText: @escaping (String) -> Void, onDone: @escaping () -> Void) {
        self.title = title
        self.prompt = prompt
        self.multiline = multiline
        self.onDone = onDone
        _server = StateObject(wrappedValue: PhoneInputServer(title: title, prompt: prompt, multiline: multiline, onText: onText))
    }

    /// Export only: the phone page offers the file for download.
    init(title: String, prompt: String, exportFilename: String, exportText: String, onDone: @escaping () -> Void) {
        self.title = title
        self.prompt = prompt
        self.onDone = onDone
        _server = StateObject(wrappedValue: PhoneInputServer(title: title, prompt: prompt, multiline: false,
                                                             export: (exportFilename, exportText), onText: nil))
    }

    var body: some View {
        SignInSheet(title: title, url: server.url, code: nil, status: server.status, cancelTitle: "Done", onCancel: onDone)
            .onAppear { server.start() }
            .onDisappear { server.stop() }
    }
}
