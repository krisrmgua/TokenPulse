import Foundation

/// Optional reconciliation against an HTTPS spend endpoint you configure
/// locally. The local transcript scan is the default. A proxy replaces the
/// coarse Today / Month / by-model totals when both a key cache and an
/// endpoint are present. TokenPulse never mints or refreshes that key.
///
/// Configure it outside the repo:
///   - `TOKENPULSE_PROXY_SPEND_URL`, or one HTTPS URL in
///     `~/Library/Application Support/TokenPulse/proxy-spend-url`
///   - `TOKENPULSE_PROXY_KEYS_FILE`, or a path in
///     `~/Library/Application Support/TokenPulse/proxy-keys-path`
///     The JSON cache is `{ "staging": { "api_key": "...", "expires": "RFC3339" } }`.
///     With neither set, the cache path is `~/.config/tokenpulse/proxy-keys.json`.
///
/// No endpoint or no unexpired key means the proxy stays off and local
/// transcripts remain the numbers on screen. Poll at most every 5 minutes.
/// The response contract is `end_user_id`, `start_date`, `end_date`,
/// `total_spend`, optional `daily_spend`, `total_requests`, and `by_model[]`.
/// The endpoint has no session breakdown, so efficiency scores stay local.

/// One model's spend from the LLM-proxy self-service endpoint.
struct ProxyByModel: Decodable {
    let model: String
    let spend: Double
    let apiRequests: Int
    enum CodingKeys: String, CodingKey {
        case model, spend
        case apiRequests = "api_requests"
    }
}

/// GET /spend/end_user's response shape. Always the caller's own spend —
/// there is no parameter to ask for anyone else's. `daily_spend` is optional
/// so older proxy deployments remain usable.
struct ProxySpendResponse: Decodable {
    let endUserId: String
    let startDate: String
    let endDate: String
    let totalSpend: Double
    var dailySpend: Double? = nil
    let totalRequests: Int
    let byModel: [ProxyByModel]
    enum CodingKeys: String, CodingKey {
        case endUserId = "end_user_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case totalSpend = "total_spend"
        case dailySpend = "daily_spend"
        case totalRequests = "total_requests"
        case byModel = "by_model"
    }
}

/// Reads a local proxy key cache. Read-only — TokenPulse never logs in.
struct ProxyKeyCache {
    private static var path: URL { ProxySpendConfig.keysFile() }

    /// The cached "staging" key, if present and not yet expired.
    static func validKey(now: Date = Date()) -> String? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let staging = obj["staging"] as? [String: Any],
              let apiKey = staging["api_key"] as? String,
              let expiresStr = staging["expires"] as? String,
              let expires = parseDate(expiresStr),
              expires > now
        else { return nil }
        return apiKey
    }

    /// Key caches often serialize `expires` as RFC3339 with
    /// microsecond precision (e.g. "2026-08-16T17:49:51.359659Z"); Foundation's
    /// ISO8601DateFormatter only accepts millisecond precision. Drop the
    /// fractional-seconds component entirely — irrelevant at cache-expiry
    /// granularity — rather than fighting format strings.
    private static func parseDate(_ s: String) -> Date? {
        guard let dotIdx = s.firstIndex(of: ".") else {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        let afterDot = s.index(after: dotIdx)
        guard let tzStart = s[afterDot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        else { return nil }
        let truncated = String(s[..<dotIdx]) + String(s[tzStart...])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: truncated)
    }
}

/// Local proxy settings. Nothing here has a built-in host.
enum ProxySpendConfig {
    static func endpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        validatedEndpoint(environment["TOKENPULSE_PROXY_SPEND_URL"] ?? fileLine("proxy-spend-url"))
    }

    static func validatedEndpoint(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: line), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              !line.contains("\n"), !line.contains("\r") else { return nil }
        return url
    }

    static func keysFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let env = environment["TOKENPULSE_PROXY_KEYS_FILE"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        if let line = fileLine("proxy-keys-path"), !line.isEmpty {
            return URL(fileURLWithPath: (line as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tokenpulse/proxy-keys.json")
    }

    private static func fileLine(_ name: String) -> String? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenPulse/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line, !line.isEmpty else { return nil }
        return line
    }
}

/// Fetches month-to-date spend from the configured endpoint and caches it.
/// A missing endpoint or a network error keeps the last local numbers.
final class ProxyReconciler {
    private static let staleAfter: TimeInterval = 30 * 60          // don't serve a very old cached success forever

    /// Shared with Cursor via `Config.remotePollInterval` (default 5 min).
    private var minRefreshInterval: TimeInterval

    /// Confines all reads/writes of the three properties below to one queue.
    /// `currentSpend` gets called from very different contexts — the running
    /// app's main-thread Timers, or `--proxy-check`'s CLI verification path,
    /// which blocks its thread on a raw DispatchSemaphore with no run loop
    /// draining — and URLSession always delivers its own completion on a
    /// background queue regardless of caller context. A private serial queue
    /// is correct under all of them; hopping to "main" specifically is not —
    /// that deadlocked the semaphore-based CLI path, which never spins a run
    /// loop to drain a queued `DispatchQueue.main.async` block.
    private let stateQueue = DispatchQueue(label: "com.kris.tokenpulse.proxy-reconciler")

    private var lastAttempt: Date?
    private var lastSuccess: (response: ProxySpendResponse, at: Date)?

    init(minRefreshInterval: TimeInterval = 5 * 60) {
        self.minRefreshInterval = minRefreshInterval
    }

    func setMinRefreshInterval(_ interval: TimeInterval) {
        stateQueue.async { self.minRefreshInterval = interval }
    }

    /// Best current spend snapshot: freshly fetched if due and a valid key
    /// exists, the last successful fetch if still fresh enough, or nil
    /// (meaning: fall back to the local transcript scan). `completion` fires
    /// on `stateQueue`, not necessarily the caller's thread — callers that
    /// need a specific thread (AppDelegate wants main, for UI) must hop
    /// themselves, exactly as AppDelegate.refreshProxySpend() already does.
    func currentSpend(now: Date = Date(), completion: @escaping (ProxySpendResponse?) -> Void) {
        guard let apiKey = ProxyKeyCache.validKey(now: now) else {
            completion(nil)
            return
        }
        stateQueue.async {
            let due = self.lastAttempt.map { now.timeIntervalSince($0) >= self.minRefreshInterval } ?? true
            guard due else {
                completion(self.freshEnough(now: now))
                return
            }
            self.lastAttempt = now
            self.fetch(apiKey: apiKey, now: now) { result in
                self.stateQueue.async {
                    if let result { self.lastSuccess = (result, now) }
                    completion(result ?? self.freshEnough(now: now))
                }
            }
        }
    }

    /// Must only be called while already running on `stateQueue`.
    private func freshEnough(now: Date) -> ProxySpendResponse? {
        guard let (resp, at) = lastSuccess, now.timeIntervalSince(at) < Self.staleAfter else { return nil }
        return resp
    }

    private func fetch(apiKey: String, now: Date, completion: @escaping (ProxySpendResponse?) -> Void) {
        // The daily value belongs to end_date. Send the local date explicitly
        // so the proxy's UTC default cannot return tomorrow's partial spend.
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) else {
            completion(nil)
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = cal.timeZone
        guard let endpoint = ProxySpendConfig.endpoint(),
              var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { completion(nil); return }
        url.queryItems = [
            URLQueryItem(name: "start_date", value: df.string(from: monthStart)),
            URLQueryItem(name: "end_date", value: df.string(from: now)),
        ]
        guard let finalURL = url.url else { completion(nil); return }

        var req = URLRequest(url: finalURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10   // matches the endpoint's own SPEND_QUERY_TIMEOUT_SECONDS

        URLSession.shared.dataTask(with: req) { data, response, error in
            let decoded: ProxySpendResponse? = {
                guard error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data
                else { return nil }
                return try? JSONDecoder().decode(ProxySpendResponse.self, from: data)
            }()
            // Delivered on URLSession's own background queue — fine as-is;
            // the caller (currentSpend, above) re-enters stateQueue itself
            // before touching lastSuccess, so no hop is needed here.
            completion(decoded)
        }.resume()
    }
}

extension Rollup {
    /// A copy with monthUSD/byModelUSD/opusUSD — and everything purely
    /// derived from them (pace, fair-share-used%, projected month-end, opus
    /// share, menu-bar heat) — replaced by the proxy's numbers. Fields with
    /// no proxy equivalent (sessions, cache-hit tokens, $/session) stay local:
    /// the endpoint has no session-level breakdown, so those features
    /// structurally can't move off local data (see
    /// EfficiencyScore.swift, which is why this reconciled copy is only ever
    /// used for display, never fed back into EfficiencyResult.compute).
    func reconciled(with proxy: ProxySpendResponse, now: Date = Date()) -> Rollup {
        var r = self
        r.monthUSD = proxy.totalSpend
        if let dailySpend = proxy.dailySpend { r.todayUSD = dailySpend }
        r.byModelUSD = Dictionary(uniqueKeysWithValues: proxy.byModel.map { ($0.model, $0.spend) })
        r.opusUSD = proxy.byModel.filter { $0.model.contains("opus") }.reduce(0) { $0 + $1.spend }
        r.proxyReconciled = true
        let cal = Calendar.current
        let dayOfMonth = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        r.projectedMonthEndUSD = dayOfMonth > 0
            ? r.monthUSD * Double(daysInMonth) / Double(dayOfMonth)
            : r.monthUSD
        return r
    }
}
