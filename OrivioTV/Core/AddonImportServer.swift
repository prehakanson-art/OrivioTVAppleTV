import Foundation
import Network

/// A tiny HTTP server on the Apple TV so add-ons can be added from a phone.
///
/// Typing a manifest URL on a TV remote is miserable, and the existing
/// "Add-on Setup" QR only goes the other way (it *exports* what is installed).
/// This serves a one-field page on the local network; the QR on screen is just
/// its address, so scanning it opens the form with no app to install.
///
/// Deliberately small and deliberately local:
///
/// * Bound to the LAN interface only, and only while the screen showing the QR
///   is open — `stop()` on disappear. It is not a background service.
/// * No shell, no filesystem, no proxying. The only thing it accepts is a
///   manifest URL, which goes through the same `AddonManager.install` path as
///   a URL typed on the TV, so the same validation applies.
/// * http, not https: a self-signed certificate on a LAN address would make
///   every phone show a security warning, which trains exactly the wrong
///   instinct. Nothing secret crosses it.
@MainActor
final class AddonImportServer: ObservableObject {
    /// What the QR encodes, e.g. "http://192.168.1.20:8090". nil until the
    /// listener is actually up.
    @Published private(set) var address: String?
    /// Manifest URLs accepted so far this session, newest first — the TV
    /// echoes them back so you can see the phone worked.
    @Published private(set) var accepted: [String] = []
    @Published private(set) var lastError: String?

    /// Installs an accepted URL. Set by the view so this type stays free of
    /// any dependency on AddonManager.
    var onInstall: ((String) async -> Result<String, Error>)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Fixed rather than ephemeral so the QR is stable across restarts of the
    /// screen; high enough to need no privilege.
    private static let port: UInt16 = 8099

    func start() {
        guard listener == nil else { return }
        lastError = nil
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.address = Self.lanAddress().map { "http://\($0):\(Self.port)" }
                        if self?.address == nil {
                            self?.lastError = "This Apple TV isn't on a network."
                        }
                    case .failed(let error):
                        self?.lastError = error.localizedDescription
                        self?.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        address = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Read until the headers are complete AND the declared body has arrived.
    /// A form POST routinely splits across packets, so parsing the first chunk
    /// alone would silently lose submissions.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            Task { @MainActor in
                if error != nil { self.drop(connection); return }
                guard let request = HTTPRequest(buffer), request.isComplete else {
                    // Cap it: without this a connection that never sends a
                    // complete request grows this buffer without bound.
                    if isComplete || buffer.count > 64 * 1024 { self.drop(connection) }
                    else { self.receive(connection, buffer: buffer) }
                    return
                }
                await self.respond(to: request, on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        var body = Self.page(accepted: accepted, message: nil)
        if request.method == "POST" {
            let raw = Self.formValue("url", in: request.body)
            let urls = raw
                .replacingOccurrences(of: ",", with: "\n")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var results: [String] = []
            for url in urls {
                guard let onInstall else { break }
                switch await onInstall(url) {
                case .success(let name):
                    accepted.insert(name, at: 0)
                    results.append("Added \(name)")
                case .failure(let error):
                    results.append("Couldn't add: \(error.localizedDescription)")
                }
            }
            body = Self.page(accepted: accepted,
                             message: results.isEmpty ? "Enter a manifest URL." : results.joined(separator: " · "))
        }
        send(body, on: connection)
    }

    private func send(_ html: String, on connection: NWConnection) {
        let data = Data(html.utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(data.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + data,
                        completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.drop(connection) }
        })
    }

    // MARK: - Parsing

    private struct HTTPRequest {
        let method: String
        let body: String
        let isComplete: Bool

        init?(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8),
                  let headerEnd = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n"),
                  let requestLine = text.split(whereSeparator: \.isNewline).first
            else { return nil }
            method = requestLine.split(separator: " ").first.map(String.init) ?? "GET"
            body = String(text[headerEnd.upperBound...])
            // A POST is only complete once the declared body length is here.
            let declared = text.range(of: #"(?i)content-length:\s*(\d+)"#, options: .regularExpression)
                .flatMap { Int(text[$0].filter(\.isNumber)) } ?? 0
            isComplete = method != "POST" || body.utf8.count >= declared
        }
    }

    private static func formValue(_ name: String, in body: String) -> String {
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == name else { continue }
            return parts[1]
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? String(parts[1])
        }
        return ""
    }

    /// Escaped so an add-on name can't inject markup into the page the phone
    /// renders — the names come from third-party manifests.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(accepted: [String], message: String?) -> String {
        let list = accepted.isEmpty ? "" :
            "<h2>Added</h2><ul>" + accepted.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
        let note = message.map { "<p class=note>\(escape($0))</p>" } ?? ""
        return """
        <!doctype html><html><head><meta charset=utf-8>
        <meta name=viewport content="width=device-width,initial-scale=1">
        <title>Add add-ons to Orivio</title><style>
        :root{color-scheme:dark}
        body{margin:0;padding:24px;background:#0d0f14;color:#f2f2f7;
             font:16px/1.5 -apple-system,system-ui,sans-serif}
        h1{font-size:22px;margin:0 0 4px} p{color:#9a9aa6;margin:0 0 20px}
        textarea{width:100%;box-sizing:border-box;padding:14px;font-size:16px;
              border-radius:12px;border:1px solid #2c2f3a;background:#161923;color:#fff;
              font-family:ui-monospace,Menlo,monospace;resize:vertical}
        button{margin-top:12px;width:100%;padding:14px;font-size:17px;font-weight:600;
               border:0;border-radius:12px;background:#7c3aed;color:#fff}
        .note{margin:16px 0 0;color:#c7c7d1}
        ul{padding-left:20px} li{margin:4px 0}
        </style></head><body>
        <h1>Add add-ons</h1>
        <p>Paste one manifest URL, or a whole Add-on Setup export — one URL
        per line. Scanning the Export Add-on Setup QR from another Orivio
        gives you exactly that list.</p>
        <form method=post action="/">
        <textarea name=url rows=6 autocapitalize=off autocorrect=off
                  spellcheck=false placeholder="https://&hellip;/manifest.json" autofocus></textarea>
        <button type=submit>Add to Orivio</button>
        </form>\(note)\(list)
        </body></html>
        """
    }

    /// This device's IPv4 address on the LAN.
    ///
    /// Walks the interface list rather than assuming a name: the Apple TV is
    /// "en0" over Ethernet and Wi-Fi both, but not on every model, and picking
    /// wrong yields a QR that resolves to nothing.
    private static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var best: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            let ip = String(cString: host)
            if name.hasPrefix("en") { return ip }   // wired or Wi-Fi, preferred
            if best == nil { best = ip }
        }
        return best
    }
}
