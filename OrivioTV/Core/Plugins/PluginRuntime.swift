import Foundation
import JavaScriptCore

/// Runs a Orivio JS scraper's `getStreams(tmdbId, mediaType, season, episode)`
/// in JavaScriptCore, providing the host environment the scrapers expect:
/// `console.*`, an async `fetch` bridged to URLSession, `atob`/`btoa` and
/// `setTimeout`. crypto-js / cheerio are loaded when a bundled resource is
/// present (see `bootstrapExtras`); scrapers that need them and find them
/// absent fail gracefully and return nothing.
// Manually thread-safe, not actor-isolated: every mutable value the JS
// execution touches (the JSContext, `finished`, JS callbacks) is local to
// `execute` and confined to `queue` — nothing escapes across threads except
// through that queue hop. `@unchecked` because the compiler can't see that
// confinement, only the code review can.
final class PluginRuntime: @unchecked Sendable {
    private let fetchDelegate: BoundedFetchDelegate
    /// Session wired to `fetchDelegate` so response bodies are inspected as they
    /// arrive instead of after URLSession has already buffered the whole thing.
    /// Built in `init` rather than lazily: concurrent runs each install their own
    /// `fetch` binding, and a `lazy var` touched from several of those queues at
    /// once is a data race. Never invalidated (URLSession retains its delegate
    /// until you do), which is fine — one PluginRuntime lives for the life of
    /// the app.
    private let session: URLSession

    init() {
        let delegate = BoundedFetchDelegate(maxBytes: Self.maxFetchBytes)
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        fetchDelegate = delegate
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }

    /// Scrapers whose run hit the safety timeout this session.
    ///
    /// A wedged scraper — one in a synchronous infinite loop — permanently owns
    /// the libdispatch thread backing its per-run queue AND the JSContext held
    /// by its pending callbacks; tvOS does not expose JavaScriptCore's execution
    /// time limit, so there is no way to interrupt it. What we CAN do is stop
    /// re-running it: without this, every stream search started another copy and
    /// leaked another thread + JSContext until the app was jetsam'd.
    private let timedOutLock = NSLock()
    private var timedOutScraperIDs = Set<String>()

    /// Scoped accessors. Taking the lock inline in an `async` function is an
    /// error under the Swift 6 language mode — the compiler cannot see that the
    /// critical section never spans a suspension point, and a lock held across
    /// one would deadlock the cooperative pool.
    private func hasTimedOut(_ scraperID: String) -> Bool {
        timedOutLock.lock(); defer { timedOutLock.unlock() }
        return timedOutScraperIDs.contains(scraperID)
    }


    func run(
        scraperID: String,
        scraperName: String,
        scraperJS: String,
        tmdbID: String,
        mediaType: String,
        season: Int?,
        episode: Int?,
        timeout: TimeInterval = 25
    ) async -> [ScraperResult] {
        if hasTimedOut(scraperID) {
            NSLog("[Plugin] skipping '%@' — it timed out earlier this session and its run can't be interrupted; it stays skipped until the app restarts.", scraperName)
            return []
        }
        // A serial queue owns each JSContext (JSCore isn't thread-safe) and fetch
        // completions hop back onto it before touching JS values — but the queue is
        // created PER RUN, not shared. One shared queue meant every scraper ran
        // strictly one at a time (PluginStore's bounded concurrency did nothing),
        // and a scraper doing long synchronous work blocked every other scraper
        // behind it. tvOS does not expose JavaScriptCore's execution time limit, so
        // a runaway script cannot be interrupted; isolating it to its own queue is
        // what keeps it from taking the rest of the plugins down with it.
        let queue = DispatchQueue(label: "tv.nuvio.plugin.runtime.\(UUID().uuidString)")
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.execute(
                    queue: queue,
                    scraperID: scraperID, scraperName: scraperName,
                    scraperJS: scraperJS, tmdbID: tmdbID, mediaType: mediaType,
                    season: season, episode: episode, timeout: timeout, continuation: continuation
                )
            }
        }
    }

    private func markTimedOut(_ scraperID: String) {
        timedOutLock.lock()
        timedOutScraperIDs.insert(scraperID)
        timedOutLock.unlock()
    }

    // MARK: - Execution (runs on `queue`)

    private func execute(
        queue: DispatchQueue,
        scraperID: String, scraperName: String,
        scraperJS: String, tmdbID: String, mediaType: String,
        season: Int?, episode: Int?, timeout: TimeInterval,
        continuation: CheckedContinuation<[ScraperResult], Never>
    ) {
        guard let context = JSContext() else { continuation.resume(returning: []); return }

        // Guarded by a lock rather than by the runtime queue, so the safety
        // timeout below can resume the continuation even when that queue is
        // wedged by a synchronous script. Hopping onto the queue to resume was
        // the reason a runaway scraper left its `run()` awaiting forever.
        // Returns true only for the caller that actually resumed, so the timeout
        // can tell "I fired first" (the scraper is wedged) from "I lost the
        // race" (the scraper finished normally, just close to the deadline).
        let finishLock = NSLock()
        var finished = false
        let finish: ([ScraperResult]) -> Bool = { results in
            finishLock.lock()
            let already = finished
            finished = true
            finishLock.unlock()
            guard !already else { return false }
            continuation.resume(returning: results)
            return true
        }

        context.exceptionHandler = { _, value in
            NSLog("[Plugin] JS exception: %@", value?.toString() ?? "?")
        }

        installConsole(context)
        installFetch(context, queue: queue)
        installTimers(context, queue: queue)
        installBase64(context)

        // Call args + result capture.
        let argsJSON = Self.argsJSON(tmdbID: tmdbID, mediaType: mediaType, season: season, episode: episode)
        context.setObject(argsJSON, forKeyedSubscript: "__nuvio_args" as NSString)
        let getArgs: @convention(block) () -> String = { argsJSON }
        context.setObject(getArgs, forKeyedSubscript: "__get_call_args" as NSString)
        let capture: @convention(block) (String) -> Void = { json in
            _ = finish(Self.parseResults(json))
        }
        context.setObject(capture, forKeyedSubscript: "__capture_result" as NSString)

        // Module shims + optional crypto-js/cheerio.
        context.evaluateScript(Self.bootstrap)
        Self.bootstrapExtras(context)

        // The scraper defines module.exports.getStreams (or a global).
        context.evaluateScript(scraperJS)
        // Invoke it and capture the JSON result.
        context.evaluateScript(Self.callGlue)

        // Safety timeout. Scheduled OFF the runtime queue: posted onto it, a
        // scraper doing long synchronous work held the queue and its own timeout
        // could never run — so its `run()` continuation never resumed and every
        // plugin queued behind it was stuck until relaunch.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 1) { [weak self] in
            guard finish([]) else { return }
            // We resumed instead of the script, so this run never came back:
            // `queue`'s thread and this JSContext are gone for good. Remember the
            // scraper so the rest of the session skips it — otherwise every
            // subsequent search leaks another thread and another JSContext.
            self?.markTimedOut(scraperID)
            NSLog("[Plugin] '%@' timed out after %.0fs — its thread and JSContext can't be reclaimed (tvOS exposes no JS execution time limit), so it will be skipped for the rest of this session.",
                  scraperName, timeout + 1)
        }
    }

    // MARK: Host bindings

    private func installConsole(_ context: JSContext) {
        let console = JSValue(newObjectIn: context)
        let log: @convention(block) () -> Void = {
            let args = JSContext.currentArguments()?.map { ($0 as? JSValue)?.toString() ?? "" } ?? []
            NSLog("[Plugin] %@", args.joined(separator: " "))
        }
        for level in ["log", "error", "warn", "info", "debug"] {
            console?.setObject(log, forKeyedSubscript: level as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    /// Largest response body handed back to JS. A scraper is a text/JSON client;
    /// without a ceiling a hostile (or just wrong) URL could pull a multi-GB
    /// body into RAM and jetsam the box mid-browse.
    private static let maxFetchBytes = 8 * 1024 * 1024

    /// `__nativeFetch(url, method, headersJson, body, resolve, reject)` runs a
    /// URLSession request and calls back into JS on the runtime queue.
    private func installFetch(_ context: JSContext, queue: DispatchQueue) {
        let fetch: @convention(block) (String, String, String, String, JSValue, JSValue) -> Void = {
            [weak self] urlString, method, headersJson, body, resolve, reject in
            guard let self, let url = URL(string: urlString) else {
                reject.call(withArguments: ["Bad URL"]); return
            }
            // http/https ONLY. This accepted any scheme, so a scraper — third
            // party JS the user installed from a repo URL — could `fetch` a
            // file:// path and read anything inside the app sandbox (the
            // account token blob included) straight into its own results.
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                reject.call(withArguments: ["Unsupported URL scheme"]); return
            }
            var request = URLRequest(url: url)
            request.httpMethod = method.isEmpty ? "GET" : method
            if let data = headersJson.data(using: .utf8),
               let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            }
            if !body.isEmpty, method.uppercased() != "GET" { request.httpBody = body.data(using: .utf8) }

            // Delegate-driven rather than a completion-handler task: the size cap
            // has to be enforced BEFORE the body is in memory (see
            // BoundedFetchDelegate). Register before `resume()` so no callback
            // can arrive with nothing to deliver it to.
            let task = self.session.dataTask(with: request)
            self.fetchDelegate.register(task) { data, response, error in
                queue.async {
                    if let error {
                        reject.call(withArguments: [error.localizedDescription]); return
                    }
                    // Insist on a real HTTP response: the body used to be handed
                    // back whatever the response actually was, so a non-HTTP
                    // load still delivered its contents to the script.
                    guard let http = response as? HTTPURLResponse else {
                        reject.call(withArguments: ["Non-HTTP response"]); return
                    }
                    // Backstop only — the delegate already rejects on an
                    // oversized Content-Length before the body downloads and
                    // cancels mid-flight once the accumulated bytes cross the
                    // cap. Kept in case a future caller bypasses the delegate.
                    if let data, data.count > Self.maxFetchBytes {
                        reject.call(withArguments: ["Response too large"]); return
                    }
                    let status = http.statusCode
                    var headerMap: [String: String] = [:]
                    http.allHeaderFields.forEach { k, v in
                        headerMap[String(describing: k).lowercased()] = String(describing: v)
                    }
                    let payload: [String: Any] = [
                        "ok": (200..<300).contains(status),
                        "status": status,
                        "statusText": "",
                        "url": http.url?.absoluteString ?? urlString,
                        "body": data.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                        "headers": headerMap
                    ]
                    resolve.call(withArguments: [payload])
                }
            }
            task.resume()
        }
        context.setObject(fetch, forKeyedSubscript: "__nativeFetch" as NSString)
    }

    private func installTimers(_ context: JSContext, queue: DispatchQueue) {
        let setTimeout: @convention(block) (JSValue, Double) -> Void = { fn, ms in
            queue.asyncAfter(deadline: .now() + max(0, ms) / 1000) {
                fn.call(withArguments: [])
            }
        }
        context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
    }

    private func installBase64(_ context: JSContext) {
        let btoa: @convention(block) (String) -> String = { s in
            Data(s.utf8).base64EncodedString()
        }
        let atob: @convention(block) (String) -> String = { s in
            Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        context.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
    }

    // MARK: JS glue

    private static func argsJSON(tmdbID: String, mediaType: String, season: Int?, episode: Int?) -> String {
        var obj: [String: Any] = ["tmdbId": tmdbID, "mediaType": mediaType]
        obj["season"] = season as Any? ?? NSNull()
        obj["episode"] = episode as Any? ?? NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// module/exports + a `fetch` polyfill wrapping `__nativeFetch` in a Promise
    /// whose resolved value looks like a real `Response`.
    private static let bootstrap = """
    var module = { exports: {} };
    var exports = module.exports;
    globalThis.fetch = function(url, opts) {
        opts = opts || {};
        var method = opts.method || 'GET';
        var headers = JSON.stringify(opts.headers || {});
        var body = opts.body ? (typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body)) : '';
        return new Promise(function(resolve, reject) {
            __nativeFetch(String(url), method, headers, body, function(res) {
                res.headers = res.headers || {};
                resolve({
                    ok: res.ok, status: res.status, statusText: res.statusText || '', url: res.url,
                    headers: { get: function(k){ return res.headers[String(k).toLowerCase()]; } },
                    text: function(){ return Promise.resolve(res.body); },
                    json: function(){ return Promise.resolve(JSON.parse(res.body)); }
                });
            }, function(err){ reject(new Error(err)); });
        });
    };
    """

    private static let callGlue = """
    (async function() {
        try {
            var getStreams = (module.exports && module.exports.getStreams) || globalThis.getStreams;
            if (!getStreams) { __capture_result('[]'); return; }
            var args = JSON.parse(__get_call_args());
            var result = await getStreams(args.tmdbId, args.mediaType, args.season, args.episode);
            __capture_result(JSON.stringify(result || []));
        } catch (e) {
            console.error('getStreams error:', (e && e.message) || e);
            __capture_result('[]');
        }
    })();
    """

    /// Load crypto-js / cheerio from bundled resources when present, so scrapers
    /// that need them work without a network dependency.
    private static func bootstrapExtras(_ context: JSContext) {
        for resource in ["crypto-js.min", "cheerio.min"] {
            if let url = Bundle.main.url(forResource: resource, withExtension: "js"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                context.evaluateScript(source)
            }
        }
    }

    // MARK: Result parsing

    private static func parseResults(_ json: String) -> [ScraperResult] {
        guard let data = json.data(using: .utf8) else { return [] }
        // Lenient element decode: one malformed stream shouldn't drop the rest.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return raw.compactMap { element in
            guard let elemData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? JSONDecoder().decode(ScraperResult.self, from: elemData)
        }
    }
}

/// Streams a plugin `fetch` response and refuses one that is too big BEFORE it
/// is in memory.
///
/// `PluginRuntime.maxFetchBytes` used to be checked only in the `dataTask`
/// completion handler — by which point URLSession had already buffered the
/// entire body, so a multi-gigabyte response exhausted memory and jetsam'd the
/// app long before the check could ever fire. The cap has to live where the
/// bytes arrive, which means a delegate:
///   * a declared `Content-Length` over the cap cancels the task with no body
///     downloaded at all (the pre-check);
///   * a chunked response that declares no length is cancelled the moment the
///     accumulated bytes cross the cap.
/// `@unchecked Sendable` because the per-task state is hand-guarded by `lock`;
/// URLSession calls these delegate methods on its own operation queue.
private final class BoundedFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum FetchError: LocalizedError {
        case responseTooLarge
        var errorDescription: String? { "Response too large" }
    }

    private let maxBytes: Int
    private let lock = NSLock()
    private var handlers: [Int: (Data?, URLResponse?, Error?) -> Void] = [:]
    private var buffers: [Int: Data] = [:]
    private var oversized: Set<Int> = []

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
        super.init()
    }

    /// Must be called BEFORE `task.resume()`.
    func register(_ task: URLSessionTask, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        lock.lock()
        handlers[task.taskIdentifier] = completion
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // The pre-check: `expectedContentLength` is the server's declared
        // Content-Length (-1 when it declares none), and this fires before a
        // single body byte is accepted.
        if response.expectedContentLength > Int64(maxBytes) {
            lock.lock()
            oversized.insert(dataTask.taskIdentifier)
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        lock.lock()
        var buffer = buffers[id] ?? Data()
        buffer.append(data)
        let tooBig = buffer.count > maxBytes
        if tooBig {
            // Drop what we already hold rather than carrying it to completion.
            buffers[id] = nil
            oversized.insert(id)
        } else {
            buffers[id] = buffer
        }
        lock.unlock()
        if tooBig { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock()
        let handler = handlers.removeValue(forKey: id)
        let data = buffers.removeValue(forKey: id)
        let tooBig = oversized.remove(id) != nil
        lock.unlock()
        guard let handler else { return }
        // A cap breach cancels the task, so `error` here is a plain
        // "cancelled" — report the real reason instead.
        if tooBig {
            handler(nil, task.response, FetchError.responseTooLarge)
        } else {
            handler(data, task.response, error)
        }
    }
}
