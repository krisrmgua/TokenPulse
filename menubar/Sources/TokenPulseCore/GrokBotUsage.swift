import Foundation

/// Grok Bot (Cursor Sand) weekly allowance from DashboardService/GetSandUsageStatus.
/// Auth reuses the Cursor IDE access token already on disk — same account as
/// Grok Bot when both are signed into the same Cursor login.
struct GrokBotUsageSnapshot: Equatable {
    /// Percent of weekly limit remaining (API returns % used; we invert).
    let percentLeft: Int
    /// Raw API `usagePercent` (% used), for CLI/debug.
    let percentUsed: Double
    let resetAt: Date?
    let planLabel: String?
    let cursorPlanName: String?
    let fetchedAt: Date

    var resetDescription: String {
        guard let resetAt else { return "unknown" }
        return ChatGPTUsageParse.displayDate(resetAt)
    }

    /// Menu-bar fragment: `61%`, or `0% Sep 20` when exhausted and a reset is known.
    var personalBarPercent: String {
        if percentLeft == 0, let resetAt {
            return "0% \(ChatGPTUsageParse.shortBarResetDate(from: resetAt))"
        }
        return "\(percentLeft)%"
    }
}

enum GrokBotUsageError: Error, Equatable {
    case missingToken
    case network
    case http(Int)
    case invalidResponse
    case pooledEnterprise

    var userMessage: String {
        switch self {
        case .missingToken:
            return "No Cursor access token — sign in to Cursor (or Grok Bot) first."
        case .network:
            return "Could not reach Cursor Dashboard for Grok Bot usage."
        case .http(let status):
            return "Grok Bot usage API returned HTTP \(status)."
        case .invalidResponse:
            return "Grok Bot usage response was unreadable."
        case .pooledEnterprise:
            return "Grok Bot weekly usage is hidden for pooled enterprise allowances."
        }
    }
}

enum GrokBotUsageParse {
    /// `usagePercent` is % used (sidebar “Weekly usage 39%”). TokenPulse shows
    /// % left to match Claude / ChatGPT / Cursor personal.
    static func percentLeft(from usagePercent: Double) -> Int {
        Int(max(0, min(100, (100 - usagePercent).rounded())))
    }

    /// Enterprise pooled plans intentionally omit a personal weekly meter.
    static func isPooledEnterprise(_ obj: [String: Any]) -> Bool {
        boolField(obj, "usesPooledEnterpriseAllowance")
            || boolField(obj, "uses_pooled_enterprise_allowance")
    }

    static func snapshot(from obj: [String: Any],
                         now: Date = Date()) -> GrokBotUsageSnapshot? {
        if isPooledEnterprise(obj) { return nil }
        guard let used = optionalDouble(obj, "usagePercent")
                ?? optionalDouble(obj, "usage_percent")
        else { return nil }

        let resetAt = dateField(obj, "nextResetTimestampUtc")
            ?? dateField(obj, "next_reset_timestamp_utc")
        let plan = stringField(obj, "grokPlanLabel")
            ?? stringField(obj, "grok_plan_label")
        let cursorPlan = stringField(obj, "cursorPlanName")
            ?? stringField(obj, "cursor_plan_name")

        return GrokBotUsageSnapshot(
            percentLeft: percentLeft(from: used),
            percentUsed: used,
            resetAt: resetAt,
            planLabel: plan,
            cursorPlanName: cursorPlan,
            fetchedAt: now)
    }

    private static func optionalDouble(_ obj: [String: Any], _ key: String) -> Double? {
        if let d = obj[key] as? Double { return d }
        if let n = obj[key] as? NSNumber { return n.doubleValue }
        if let s = obj[key] as? String { return Double(s) }
        return nil
    }

    private static func boolField(_ obj: [String: Any], _ key: String) -> Bool {
        if let b = obj[key] as? Bool { return b }
        if let n = obj[key] as? NSNumber { return n.boolValue }
        return false
    }

    private static func stringField(_ obj: [String: Any], _ key: String) -> String? {
        guard let s = obj[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func dateField(_ obj: [String: Any], _ key: String) -> Date? {
        guard let s = stringField(obj, key) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}

/// Throttled Grok Bot weekly-usage client. Failures keep last-known data.
final class GrokBotUsageClient {
    private static let baseURL = "https://api2.cursor.sh"
    private static let staleAfter: TimeInterval = 30 * 60

    private var minRefreshInterval: TimeInterval
    private let stateQueue = DispatchQueue(label: "com.kris.tokenpulse.grok-bot-usage")
    private var lastAttempt: Date?
    private var lastSuccess: GrokBotUsageSnapshot?

    init(minRefreshInterval: TimeInterval = 5 * 60) {
        self.minRefreshInterval = minRefreshInterval
    }

    func setMinRefreshInterval(_ interval: TimeInterval) {
        stateQueue.async { self.minRefreshInterval = interval }
    }

    func currentUsage(now: Date = Date(), force: Bool = false,
                      completion: @escaping (GrokBotUsageSnapshot?) -> Void) {
        stateQueue.async {
            guard let token = CursorAuthCache.accessToken() else {
                completion(nil)
                return
            }
            let due = force
                || (self.lastAttempt.map { now.timeIntervalSince($0) >= self.minRefreshInterval } ?? true)
            guard due else {
                completion(self.freshEnough(now: now))
                return
            }
            self.lastAttempt = now
            self.fetch(token: token, now: now) { snap in
                self.stateQueue.async {
                    if let snap { self.lastSuccess = snap }
                    completion(snap ?? self.freshEnough(now: now))
                }
            }
        }
    }

    func testConnection(now: Date = Date(),
                        completion: @escaping (Result<GrokBotUsageSnapshot, GrokBotUsageError>) -> Void) {
        stateQueue.async {
            guard let token = CursorAuthCache.accessToken() else {
                completion(.failure(.missingToken))
                return
            }
            self.fetchResult(token: token, now: now, completion: completion)
        }
    }

    private func freshEnough(now: Date) -> GrokBotUsageSnapshot? {
        guard let snap = lastSuccess,
              now.timeIntervalSince(snap.fetchedAt) < Self.staleAfter
        else { return nil }
        return snap
    }

    private func fetch(token: String, now: Date,
                       completion: @escaping (GrokBotUsageSnapshot?) -> Void) {
        fetchResult(token: token, now: now) { result in
            completion(try? result.get())
        }
    }

    private func fetchResult(token: String, now: Date,
                             completion: @escaping (Result<GrokBotUsageSnapshot, GrokBotUsageError>) -> Void) {
        guard let url = URL(string: Self.baseURL
                + "/aiserver.v1.DashboardService/GetSandUsageStatus"),
              let body = try? JSONSerialization.data(withJSONObject: [:])
        else {
            completion(.failure(.invalidResponse))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, response, error in
            if error != nil {
                completion(.failure(.network))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network))
                return
            }
            guard http.statusCode == 200, let data else {
                completion(.failure(.http(http.statusCode)))
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completion(.failure(.invalidResponse))
                return
            }
            if GrokBotUsageParse.isPooledEnterprise(obj) {
                completion(.failure(.pooledEnterprise))
                return
            }
            guard let snap = GrokBotUsageParse.snapshot(from: obj, now: now) else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(snap))
        }.resume()
    }
}
