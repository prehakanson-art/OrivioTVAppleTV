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
    /// One serial queue owns the JSContext (JSCore isn't thread-safe); fetch
    /// completions hop back onto it before touching JS values.
    private let queue = DispatchQueue(label: "tv.nuvio.plugin.runtime")
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    func run(
        scraperJS: String,
        tmdbID: String,
        mediaType: String,
        season: Int?,
        episode: Int?,
        timeout: TimeInterval = 25
    ) async -> [ScraperResult] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.execute(
                    scraperJS: scraperJS, tmdbID: tmdbID, mediaType: mediaType,
                    season: season, episode: episode, timeout: timeout, continuation: continuation
                )
            }
        }
    }

    // MARK: - Execution (runs on `queue`)

    private func execute(
        scraperJS: String, tmdbID: String, mediaType: String,
        season: Int?, episode: Int?, timeout: TimeInterval,
        continuation: CheckedContinuation<[ScraperResult], Never>
    ) {
        guard let context = JSContext() else { continuation.resume(returning: []); return }

        var finished = false
        let finish: ([ScraperResult]) -> Void = { [weak self] results in
            self?.queue.async {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: results)
            }
        }

        context.exceptionHandler = { _, value in
            NSLog("[Plugin] JS exception: %@", value?.toString() ?? "?")
        }

        installConsole(context)
        installFetch(context)
        installTimers(context)
        installBase64(context)

        // Call args + result capture.
        let argsJSON = Self.argsJSON(tmdbID: tmdbID, mediaType: mediaType, season: season, episode: episode)
        context.setObject(argsJSON, forKeyedSubscript: "__nuvio_args" as NSString)
        let getArgs: @convention(block) () -> String = { argsJSON }
        context.setObject(getArgs, forKeyedSubscript: "__get_call_args" as NSString)
        let capture: @convention(block) (String) -> Void = { json in
            finish(Self.parseResults(json))
        }
        context.setObject(capture, forKeyedSubscript: "__capture_result" as NSString)

        // Module shims + optional crypto-js/cheerio.
        context.evaluateScript(Self.bootstrap)
        Self.bootstrapExtras(context)

        // The scraper defines module.exports.getStreams (or a global).
        context.evaluateScript(scraperJS)
        // Invoke it and capture the JSON result.
        context.evaluateScript(Self.callGlue)

        // Safety timeout: if the scraper never resolves, return nothing.
        queue.asyncAfter(deadline: .now() + timeout) { finish([]) }
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

    /// `__nativeFetch(url, method, headersJson, body, resolve, reject)` runs a
    /// URLSession request and calls back into JS on the runtime queue.
    private func installFetch(_ context: JSContext) {
        let fetch: @convention(block) (String, String, String, String, JSValue, JSValue) -> Void = {
            [weak self] urlString, method, headersJson, body, resolve, reject in
            guard let self, let url = URL(string: urlString) else {
                reject.call(withArguments: ["Bad URL"]); return
            }
            var request = URLRequest(url: url)
            request.httpMethod = method.isEmpty ? "GET" : method
            if let data = headersJson.data(using: .utf8),
               let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            }
            if !body.isEmpty, method.uppercased() != "GET" { request.httpBody = body.data(using: .utf8) }

            self.session.dataTask(with: request) { data, response, error in
                self.queue.async {
                    if let error {
                        reject.call(withArguments: [error.localizedDescription]); return
                    }
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    var headerMap: [String: String] = [:]
                    http?.allHeaderFields.forEach { k, v in
                        headerMap[String(describing: k).lowercased()] = String(describing: v)
                    }
                    let payload: [String: Any] = [
                        "ok": (200..<300).contains(status),
                        "status": status,
                        "statusText": "",
                        "url": http?.url?.absoluteString ?? urlString,
                        "body": data.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                        "headers": headerMap
                    ]
                    resolve.call(withArguments: [payload])
                }
            }.resume()
        }
        context.setObject(fetch, forKeyedSubscript: "__nativeFetch" as NSString)
    }

    private func installTimers(_ context: JSContext) {
        let setTimeout: @convention(block) (JSValue, Double) -> Void = { [weak self] fn, ms in
            self?.queue.asyncAfter(deadline: .now() + max(0, ms) / 1000) {
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
