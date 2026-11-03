import Foundation

/// Workspace credit usage shown by ChatGPT Settings → Usage Limits.
/// Credits are not a bill. `estimatedUSD` uses OpenAI's public rate-card
/// equivalence only when the workspace does not expose a contracted estimate.
struct ChatGPTWorkUsageSnapshot: Equatable {
    static let publicUSDPerCredit = 0.04
    static let proPlanMonthlyUSD = 200.0

    let todayCredits: Double
    let monthCredits: Double
    let byProduct: [String: Double]
    let fetchedAt: Date
    let dataFreshnessAt: Date?
    let serverEstimatedUSD: Double?

    var estimatedUSD: Double {
        serverEstimatedUSD ?? monthCredits * Self.publicUSDPerCredit
    }

    var todayEstimatedUSD: Double {
        todayCredits * Self.publicUSDPerCredit
    }

    /// True when today's total cannot be read as final.
    ///
    /// ChatGPT aggregates credits only through `dataFreshnessAt`, which lags
    /// the clock by hours, so a zero means "idle so far" and "used it, not
    /// ingested yet" indistinguishably. A non-zero total is still a usable
    /// lower bound, so only a zero is withheld.
    var todayIsPending: Bool {
        guard todayCredits == 0 else { return false }
        guard let dataFreshnessAt else { return true }
        return dataFreshnessAt < fetchedAt
    }

    var proPlanEquivalents: Double {
        estimatedUSD / Self.proPlanMonthlyUSD
    }

    var estimateUsesPublicRateCard: Bool {
        serverEstimatedUSD == nil
    }
}

enum ChatGPTWorkUsageError: Error, Equatable {
    case authNotFound
    case invalidAuth
    case network
    case http(Int)
    case invalidResponse

    var userMessage: String {
        switch self {
        case .authNotFound:
            return "Codex is not signed in. Sign in to ChatGPT in Codex first."
        case .invalidAuth:
            return "The Codex ChatGPT login expired. Reopen Codex and sign in again."
        case .network:
            return "Could not reach ChatGPT workspace usage."
        case .http(let status):
            return "ChatGPT workspace usage returned HTTP \(status)."
        case .invalidResponse:
            return "ChatGPT returned an unreadable workspace usage response."
        }
    }
}

enum ChatGPTWorkUsageParse {
    struct Response: Decodable {
        let data: [Day]
        let dataFreshnessTS: String?

        enum CodingKeys: String, CodingKey {
            case data
            case dataFreshnessTS = "data_freshness_ts"
        }
    }

    struct Day: Decodable {
        let date: String
        let values: [String: Double]
    }

    struct EstimateResponse: Decodable {
        let estimatedUSDMicros: Double?

        enum CodingKeys: String, CodingKey {
            case estimatedUSDMicros = "estimated_usage_usd_micros"
        }
    }

    static func snapshot(from data: Data, now: Date = Date(),
                         calendar: Calendar = .current,
                         serverEstimatedUSD: Double? = nil) -> ChatGPTWorkUsageSnapshot? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        let today = dayString(now, calendar: calendar)
        var todayCredits = 0.0
        var monthCredits = 0.0
        var byProduct: [String: Double] = [:]
        for day in response.data {
            let total = day.values.values.reduce(0, +)
            monthCredits += total
            if day.date == today { todayCredits += total }
            for (product, credits) in day.values {
                byProduct[product, default: 0] += credits
            }
        }
        return ChatGPTWorkUsageSnapshot(
            todayCredits: todayCredits,
            monthCredits: monthCredits,
            byProduct: byProduct,
            fetchedAt: now,
            dataFreshnessAt: response.dataFreshnessTS.flatMap(isoDate),
            serverEstimatedUSD: serverEstimatedUSD)
    }

    static func estimatedUSD(from data: Data) -> Double? {
        guard let response = try? JSONDecoder().decode(EstimateResponse.self, from: data),
              let micros = response.estimatedUSDMicros
        else { return nil }
        return micros / 1_000_000
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        var calendar = calendar
        calendar.timeZone = calendar.timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func isoDate(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }
}

private enum CodexChatGPTAuth {
    struct Credentials {
        let accessToken: String
        let accountID: String
    }

    private struct File: Decodable {
        let authMode: String?
        let tokens: Tokens

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case tokens
        }
    }

    private struct Tokens: Decodable {
        let accessToken: String
        let accountID: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }

    static func credentials(fileManager: FileManager = .default) -> Credentials? {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONDecoder().decode(File.self, from: data),
              auth.authMode == nil || auth.authMode == "chatgpt",
              !auth.tokens.accessToken.isEmpty,
              !auth.tokens.accountID.isEmpty
        else { return nil }
        return Credentials(accessToken: auth.tokens.accessToken,
                           accountID: auth.tokens.accountID)
    }
}

/// Throttled read-only client for the same workspace usage endpoints used by
/// ChatGPT Settings. Authentication is reused from the signed-in Codex CLI and
/// is never logged, persisted by TokenPulse, or sent anywhere except chatgpt.com.
final class ChatGPTWorkUsageClient {
    private static let endpoint =
        "https://chatgpt.com/backend-api/wham/usage/daily-workspace-user-credit-usage"
    private static let estimateEndpoint =
        "https://chatgpt.com/backend-api/wham/usage/credits/estimate"
    private static let staleAfter: TimeInterval = 30 * 60

    private var minRefreshInterval: TimeInterval
    private let stateQueue = DispatchQueue(label: "com.kris.tokenpulse.chatgpt-work-usage")
    private var lastAttempt: Date?
    private var lastSuccess: ChatGPTWorkUsageSnapshot?

    init(minRefreshInterval: TimeInterval = 5 * 60) {
        self.minRefreshInterval = minRefreshInterval
    }

    func setMinRefreshInterval(_ interval: TimeInterval) {
        stateQueue.async { self.minRefreshInterval = interval }
    }

    func currentUsage(now: Date = Date(), force: Bool = false,
                      completion: @escaping (ChatGPTWorkUsageSnapshot?) -> Void) {
        stateQueue.async {
            let due = force
                || (self.lastAttempt.map { now.timeIntervalSince($0) >= self.minRefreshInterval } ?? true)
            guard due else {
                completion(self.freshEnough(now: now))
                return
            }
            self.lastAttempt = now
            self.fetch(now: now) { result in
                self.stateQueue.async {
                    if case .success(let snapshot) = result { self.lastSuccess = snapshot }
                    completion((try? result.get()) ?? self.freshEnough(now: now))
                }
            }
        }
    }

    func testConnection(now: Date = Date(),
                        completion: @escaping (Result<ChatGPTWorkUsageSnapshot,
                                                     ChatGPTWorkUsageError>) -> Void) {
        stateQueue.async { self.fetch(now: now, completion: completion) }
    }

    func clearCache() {
        stateQueue.async {
            self.lastAttempt = nil
            self.lastSuccess = nil
        }
    }

    private func freshEnough(now: Date) -> ChatGPTWorkUsageSnapshot? {
        guard let snapshot = lastSuccess,
              now.timeIntervalSince(snapshot.fetchedAt) < Self.staleAfter
        else { return nil }
        return snapshot
    }

    private func fetch(now: Date,
                       completion: @escaping (Result<ChatGPTWorkUsageSnapshot,
                                                    ChatGPTWorkUsageError>) -> Void) {
        guard let credentials = CodexChatGPTAuth.credentials() else {
            completion(.failure(.authNotFound))
            return
        }
        guard let url = Self.requestURL(now: now) else {
            completion(.failure(.invalidResponse))
            return
        }
        var request = URLRequest(url: url)
        apply(credentials, to: &request)
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else {
                completion(.failure(.network))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(.invalidAuth))
                return
            }
            guard http.statusCode == 200, let data,
                  let initial = ChatGPTWorkUsageParse.snapshot(from: data, now: now)
            else {
                completion(.failure(http.statusCode == 200
                    ? .invalidResponse : .http(http.statusCode)))
                return
            }
            self.fetchEstimate(credits: initial.monthCredits,
                               credentials: credentials) { serverEstimate in
                guard let snapshot = ChatGPTWorkUsageParse.snapshot(
                    from: data, now: now, serverEstimatedUSD: serverEstimate
                ) else {
                    completion(.failure(.invalidResponse))
                    return
                }
                completion(.success(snapshot))
            }
        }.resume()
    }

    private func fetchEstimate(credits: Double, credentials: CodexChatGPTAuth.Credentials,
                               completion: @escaping (Double?) -> Void) {
        guard let url = URL(string: Self.estimateEndpoint),
              let body = try? JSONSerialization.data(
                withJSONObject: ["credits": (credits * 1_000_000).rounded() / 1_000_000])
        else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        apply(credentials, to: &request)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200, let data
            else {
                completion(nil)
                return
            }
            completion(ChatGPTWorkUsageParse.estimatedUSD(from: data))
        }.resume()
    }

    private func apply(_ credentials: CodexChatGPTAuth.Credentials,
                       to request: inout URLRequest) {
        request.setValue("Bearer \(credentials.accessToken)",
                         forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID,
                         forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")
    }

    static func requestURL(now: Date = Date(), calendar: Calendar = .current) -> URL? {
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "start_date", value: formatter.string(from: interval.start)),
            URLQueryItem(name: "end_date", value: formatter.string(from: now)),
            URLQueryItem(name: "group_by", value: "day"),
        ]
        return components?.url
    }
}
