import Foundation

enum HTTPError: LocalizedError {
    case badURL(String)
    case status(Int)
    case notJSON
    case timeout
    case cancelled
    case other(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Bad URL (\(s))"
        case .status(let code): return "HTTP \(code)"
        case .notJSON: return "Not a valid response"
        case .timeout: return "Timed out"
        case .cancelled: return "Cancelled"
        case .other(let s): return s
        }
    }

    static func wrap(_ error: Error) -> HTTPError {
        if let e = error as? HTTPError { return e }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            case .badURL, .unsupportedURL: return .badURL(e.failingURL?.absoluteString ?? "")
            default: return .other(e.localizedDescription)
            }
        }
        if error is CancellationError { return .cancelled }
        return .other(error.localizedDescription)
    }
}

/// One shared session. Its `URLCache` is on disk, so anything that must be
/// fresh says so on the `URLRequest` (`fresh: true`) — `ttl: 0` is not
/// "uncached" when the shared session has a disk cache.
enum HTTP {
    static let userAgent = "OrivioTV/1.0 (tvOS)"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20,
                                   directory: Persistence.cachesURL.appendingPathComponent("URLCache"))
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 6
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// A session that never touches any cache (streams, auth, sync).
    static let ephemeral: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                        body: Data? = nil, fresh: Bool = false, timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        if fresh { r.cachePolicy = .reloadIgnoringLocalCacheData }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if body != nil, headers["Content-Type"] == nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    @discardableResult
    static func data(_ request: URLRequest, session: URLSession = HTTP.session) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.other("No HTTP response") }
            guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode) }
            return (data, http)
        } catch {
            throw HTTPError.wrap(error)
        }
    }

    static func data(_ url: URL, fresh: Bool = false, timeout: TimeInterval = 20, headers: [String: String] = [:]) async throws -> Data {
        try await data(request(url, headers: headers, fresh: fresh, timeout: timeout)).0
    }

    static func json<T: Decodable>(_ type: T.Type, _ request: URLRequest, session: URLSession = HTTP.session) async throws -> T {
        let (data, _) = try await data(request, session: session)
        do { return try JSONDecoder.orivio.decode(T.self, from: data) } catch { throw HTTPError.notJSON }
    }

    static func json<T: Decodable>(_ type: T.Type, url: URL, fresh: Bool = false, timeout: TimeInterval = 20,
                                   headers: [String: String] = [:]) async throws -> T {
        try await json(T.self, request(url, headers: headers, fresh: fresh, timeout: timeout))
    }

    static func jsonObject(_ request: URLRequest, session: URLSession = HTTP.ephemeral) async throws -> Any {
        let (data, _) = try await data(request, session: session)
        if data.isEmpty { return [String: Any]() }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw HTTPError.notJSON }
        return obj
    }

    /// Encodes a path component unreserved-only (RFC 3986): `Law & Order`
    /// would otherwise break catalog extras.
    static func encodeComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func query(_ items: [String: String]) -> String {
        items.sorted { $0.key < $1.key }.map { "\(encodeComponent($0.key))=\(encodeComponent($0.value))" }.joined(separator: "&")
    }
}

/// Bounded fan-out: run `work` for every element with at most `limit` in flight.
func boundedConcurrentMap<T, R>(_ items: [T], limit: Int, _ work: @escaping (T) async -> R) async -> [R] {
    guard !items.isEmpty else { return [] }
    var results = [R?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, R).self) { group in
        var next = 0
        func addNext() {
            guard next < items.count else { return }
            let i = next
            let item = items[i]
            next += 1
            group.addTask { (i, await work(item)) }
        }
        for _ in 0..<min(limit, items.count) { addNext() }
        while let (i, r) = await group.next() {
            results[i] = r
            addNext()
        }
    }
    return results.compactMap { $0 }
}

/// Run `operation` with a wall-clock deadline. Returns (or throws `.timeout`)
/// AT the deadline even when the operation ignores cancellation — a task group
/// here waited for its children on the way out, so a stuck call (YouTubeKit's
/// page parser) ran 6 s "timeouts" for 13 s.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            race.start(c, work: Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            }, timer: Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                race.finish(.failure(HTTPError.timeout))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Resumes its continuation once, with whichever of work / deadline / cancel
/// comes first, and cancels the others.
private final class DeadlineRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func start(_ c: CheckedContinuation<T, Error>, work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        self.work = work
        self.timer = timer
        if let pending {
            // Cancelled (or finished) before the continuation existed.
            lock.unlock()
            work.cancel(); timer.cancel()
            c.resume(with: pending)
            return
        }
        if done { lock.unlock(); return }
        continuation = c
        lock.unlock()
    }

    func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let c = continuation
        continuation = nil
        if c == nil { pending = r }
        let w = work, t = timer
        lock.unlock()
        w?.cancel(); t?.cancel()
        c?.resume(with: r)
    }
}
