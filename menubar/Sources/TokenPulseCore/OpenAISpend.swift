import Foundation
import Security

/// One OpenAI billing line item from the Organization Costs API.
struct OpenAICostLine: Equatable {
    let lineItem: String
    let spendUSD: Double
}

/// Best-effort OpenAI Platform API spend for the current local day/month.
/// ChatGPT subscriptions are billed separately and are never included here.
struct OpenAISpendSnapshot {
    let todaySpendUSD: Double
    let monthSpendUSD: Double
    /// User-anchored estimate: entered prepaid balance minus organization
    /// costs reported after that point. Nil until the user sets a baseline.
    let estimatedBalanceUSD: Double?
    let byLineItem: [OpenAICostLine]
    let fetchedAt: Date
}

struct OpenAIBalanceBaseline: Equatable {
    let enteredBalanceUSD: Double
    let baselineDayStart: Date
    let spendAlreadyReportedThatDayUSD: Double

    func estimate(reportedSpendSinceDayStart: Double) -> Double {
        enteredBalanceUSD
            - max(0, reportedSpendSinceDayStart - spendAlreadyReportedThatDayUSD)
    }
}

/// Non-secret estimate anchor. The actual Admin key remains in Keychain.
enum OpenAIBalancePrefs {
    private static let balanceKey = "openAIEstimatedBalanceBaselineUSD"
    private static let dayStartKey = "openAIEstimatedBalanceDayStart"
    private static let daySpendKey = "openAIEstimatedBalanceDaySpendUSD"

    static func baseline(defaults: UserDefaults = .standard) -> OpenAIBalanceBaseline? {
        guard defaults.object(forKey: balanceKey) != nil,
              let dayStart = defaults.object(forKey: dayStartKey) as? Date
        else { return nil }
        return OpenAIBalanceBaseline(
            enteredBalanceUSD: defaults.double(forKey: balanceKey),
            baselineDayStart: dayStart,
            spendAlreadyReportedThatDayUSD: defaults.double(forKey: daySpendKey))
    }

    static func save(currentBalanceUSD: Double, todaySpendUSD: Double,
                     now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(currentBalanceUSD, forKey: balanceKey)
        defaults.set(Calendar.current.startOfDay(for: now), forKey: dayStartKey)
        defaults.set(todaySpendUSD, forKey: daySpendKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: balanceKey)
        defaults.removeObject(forKey: dayStartKey)
        defaults.removeObject(forKey: daySpendKey)
    }
}

enum OpenAISpendError: Error, Equatable {
    case missingKey
    case invalidKey
    case keychain(OSStatus)
    case network
    case http(Int)
    case invalidResponse

    var userMessage: String {
        switch self {
        case .missingKey: return "No OpenAI Admin API key is configured."
        case .invalidKey: return "OpenAI rejected the Admin API key."
        case .keychain(let status): return "Keychain error (\(status))."
        case .network: return "Could not reach the OpenAI Costs API."
        case .http(let status): return "OpenAI Costs API returned HTTP \(status)."
        case .invalidResponse: return "OpenAI returned an unreadable costs response."
        }
    }
}

/// OpenAI Admin API key storage. Jamf-signed builds use Keychain; locally
/// ad-hoc-signed builds use a mode-600 file under Application Support because
/// macOS binds Keychain ACL to CDHash for ad-hoc code (changes every rebuild)
/// and launch-time ACL updates trigger password prompts without "Always Allow".
enum OpenAIKeychain {
    static let service = "com.kris.tokenpulse.openai"
    static let account = "admin-api-key"

    private static let cacheLock = NSLock()
    private static var cachedKey: String?

    /// True when the key is stored (or cached) without reading secret bytes.
    static var isConfigured: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cachedKey != nil { return true }
        if usesFileStorage {
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
        return keychainItemExists
    }

    /// Ad-hoc build still has a Keychain copy but not yet the Application Support file.
    static var needsKeyMigration: Bool {
        usesFileStorage
            && !FileManager.default.fileExists(atPath: fileURL.path)
            && keychainItemExists
    }

    /// One-time: copy an existing Keychain entry into Application Support when
    /// switching to file storage, using kSecUseAuthenticationUISkip so we never
    /// pop a password sheet on launch.
    static func migrateFromKeychainIfNeeded() {
        guard usesFileStorage,
              !FileManager.default.fileExists(atPath: fileURL.path),
              keychainItemExists
        else { return }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              isValidAdminKeyFormat(key),
              writeFileKey(key)
        else { return }
        _ = SecItemDelete(baseQuery as CFDictionary)
        cacheLock.lock()
        cachedKey = key
        cacheLock.unlock()
    }

    static func apiKey() -> String? {
        cacheLock.lock()
        if let cached = cachedKey {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let key = usesFileStorage ? readFileKey() : readKeychainKey()
        guard let key else { return nil }
        cacheLock.lock()
        cachedKey = key
        cacheLock.unlock()
        return key
    }

    static func save(_ raw: String) -> Result<Void, OpenAISpendError> {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidAdminKeyFormat(key) else {
            return .failure(.invalidKey)
        }
        invalidateCache()
        if usesFileStorage {
            guard writeFileKey(key) else { return .failure(.keychain(errSecIO)) }
            _ = SecItemDelete(baseQuery as CFDictionary)
            cacheLock.lock()
            cachedKey = key
            cacheLock.unlock()
            return .success(())
        }
        let data = Data(key.utf8)
        _ = SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            cacheLock.lock()
            cachedKey = key
            cacheLock.unlock()
            return .success(())
        }
        return .failure(.keychain(status))
    }

    @discardableResult
    static func delete() -> Result<Void, OpenAISpendError> {
        invalidateCache()
        if usesFileStorage {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let status = SecItemDelete(baseQuery as CFDictionary)
        return (status == errSecSuccess || status == errSecItemNotFound)
            ? .success(()) : .failure(.keychain(status))
    }

    static func isValidAdminKeyFormat(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.hasPrefix("sk-admin-") && key.count > "sk-admin-".count
    }

    private static var usesFileStorage: Bool { Bundle.main.isAdHocSigned }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenPulse", isDirectory: true)
            .appendingPathComponent("openai-admin-api-key")
    }

    private static func invalidateCache() {
        cacheLock.lock()
        cachedKey = nil
        cacheLock.unlock()
    }

    private static func readFileKey() -> String? {
        restrictKeyFile()
        guard let data = try? Data(contentsOf: fileURL),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    private static func writeFileKey(_ key: String) -> Bool {
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: dir.path)
            try Data(key.utf8).write(to: fileURL, options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return false
        }
        restrictKeyFile()
        return true
    }

    /// The key file is owner-only, its folder is owner-only, and Time Machine skips it.
    private static func restrictKeyFile() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: dir.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func readKeychainKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Presence check that avoids triggering the Keychain password sheet.
    private static var keychainItemExists: Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private extension Bundle {
    var isAdHocSigned: Bool {
        guard let url = executableURL else { return true }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let flags = dict[kSecCodeInfoFlags as String] as? UInt32
        else { return true }
        return (flags & 0x0002) != 0 // kSecCodeSignatureAdhoc
    }
}

/// Pure decoder/summer used by the live client and offline tests.
enum OpenAISpendParse {
    struct Page: Decodable {
        let data: [Bucket]
        let hasMore: Bool
        let nextPage: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case nextPage = "next_page"
        }
    }

    struct Bucket: Decodable {
        let startTime: Int
        let endTime: Int
        let results: [Cost]

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case results
        }
    }

    struct Cost: Decodable {
        let amount: Amount
        let lineItem: String?

        enum CodingKeys: String, CodingKey {
            case amount
            case lineItem = "line_item"
        }
    }

    struct Amount: Decodable {
        let value: Double
        let currency: String?
    }

    static func decode(_ data: Data) -> Page? {
        try? JSONDecoder().decode(Page.self, from: data)
    }

    static func total(_ buckets: [Bucket]) -> Double {
        buckets.flatMap(\.results).reduce(0) { sum, result in
            result.amount.currency?.lowercased() == "usd" || result.amount.currency == nil
                ? sum + result.amount.value : sum
        }
    }

    static func lines(_ buckets: [Bucket]) -> [OpenAICostLine] {
        var totals: [String: Double] = [:]
        for result in buckets.flatMap(\.results) {
            guard result.amount.currency?.lowercased() == "usd"
                    || result.amount.currency == nil else { continue }
            totals[result.lineItem ?? "Other", default: 0] += result.amount.value
        }
        return totals.map(OpenAICostLine.init)
            .sorted { $0.spendUSD > $1.spendUSD }
    }
}

/// Throttled OpenAI Costs client. Failures retain a recent last-known snapshot,
/// matching the silent-degradation contract used by Cursor and the spend proxy.
final class OpenAISpendClient {
    private static let endpoint = "https://api.openai.com/v1/organization/costs"
    private static let staleAfter: TimeInterval = 30 * 60

    private var minRefreshInterval: TimeInterval
    private let stateQueue = DispatchQueue(label: "com.kris.tokenpulse.openai-spend")
    private var lastAttempt: Date?
    private var lastSuccess: OpenAISpendSnapshot?

    init(minRefreshInterval: TimeInterval = 5 * 60) {
        self.minRefreshInterval = minRefreshInterval
    }

    func setMinRefreshInterval(_ interval: TimeInterval) {
        stateQueue.async { self.minRefreshInterval = interval }
    }

    func currentSpend(now: Date = Date(), force: Bool = false,
                      completion: @escaping (OpenAISpendSnapshot?) -> Void) {
        stateQueue.async {
            guard let key = OpenAIKeychain.apiKey() else {
                completion(nil)
                return
            }
            let dayChanged = self.lastSuccess.map {
                History.dayString($0.fetchedAt) != History.dayString(now)
            } ?? false
            let due = force || dayChanged
                || (self.lastAttempt.map { now.timeIntervalSince($0) >= self.minRefreshInterval } ?? true)
            guard due else {
                completion(self.freshEnough(now: now))
                return
            }
            self.lastAttempt = now
            self.fetch(key: key, now: now) { result in
                self.stateQueue.async {
                    if case .success(let snapshot) = result { self.lastSuccess = snapshot }
                    completion((try? result.get()) ?? self.freshEnough(now: now))
                }
            }
        }
    }

    /// Explicit, uncached probe for the Options action and CLI smoke check.
    func testConnection(now: Date = Date(),
                        completion: @escaping (Result<OpenAISpendSnapshot, OpenAISpendError>) -> Void) {
        stateQueue.async {
            guard let key = OpenAIKeychain.apiKey() else {
                completion(.failure(.missingKey))
                return
            }
            self.fetch(key: key, now: now, completion: completion)
        }
    }

    func clearCache() {
        stateQueue.async {
            self.lastAttempt = nil
            self.lastSuccess = nil
        }
    }

    private func freshEnough(now: Date) -> OpenAISpendSnapshot? {
        guard let snapshot = lastSuccess,
              now.timeIntervalSince(snapshot.fetchedAt) < Self.staleAfter,
              History.dayString(snapshot.fetchedAt) == History.dayString(now)
        else { return nil }
        return snapshot
    }

    private func fetch(key: String, now: Date,
                       completion: @escaping (Result<OpenAISpendSnapshot, OpenAISpendError>) -> Void) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else {
            completion(.failure(.invalidResponse))
            return
        }
        let monthLimit = min(180, (calendar.range(of: .day, in: .month, for: now)?.count ?? 31) + 2)

        fetchWindow(key: key, start: dayStart, end: now, limit: 2) { dayResult in
            switch dayResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let dayBuckets):
                self.fetchWindow(key: key, start: monthStart, end: now,
                                 limit: monthLimit) { monthResult in
                    switch monthResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let monthBuckets):
                        let finish: (Double?) -> Void = { estimatedBalance in
                            completion(.success(OpenAISpendSnapshot(
                                todaySpendUSD: OpenAISpendParse.total(dayBuckets),
                                monthSpendUSD: OpenAISpendParse.total(monthBuckets),
                                estimatedBalanceUSD: estimatedBalance,
                                byLineItem: OpenAISpendParse.lines(monthBuckets),
                                fetchedAt: now)))
                        }
                        guard let baseline = OpenAIBalancePrefs.baseline() else {
                            finish(nil)
                            return
                        }
                        let elapsedDays = calendar.dateComponents(
                            [.day], from: baseline.baselineDayStart, to: now).day ?? 0
                        let balanceLimit = min(180, max(2, elapsedDays + 2))
                        self.fetchWindow(key: key, start: baseline.baselineDayStart,
                                         end: now, limit: balanceLimit) { balanceResult in
                            switch balanceResult {
                            case .success(let buckets):
                                finish(baseline.estimate(
                                    reportedSpendSinceDayStart: OpenAISpendParse.total(buckets)))
                            case .failure:
                                // Balance is best-effort and must not hide otherwise valid costs.
                                finish(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private func fetchWindow(key: String, start: Date, end: Date, limit: Int,
                             page: [Int]? = nil,
                             accumulated: [OpenAISpendParse.Bucket] = [],
                             pageCount: Int = 0,
                             completion: @escaping (Result<[OpenAISpendParse.Bucket], OpenAISpendError>) -> Void) {
        guard pageCount < 20 else {
            completion(.failure(.invalidResponse))
            return
        }
        guard let url = Self.costsURL(start: start, end: end, limit: limit, pageIndexes: page),
              url.scheme == "https", url.host == "api.openai.com" else {
            completion(.failure(.invalidResponse))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil else {
                completion(.failure(.network))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(.invalidKey))
                return
            }
            guard http.statusCode == 200, let data,
                  let decoded = OpenAISpendParse.decode(data) else {
                completion(.failure(http.statusCode == 200 ? .invalidResponse : .http(http.statusCode)))
                return
            }

            let all = accumulated + decoded.data
            if decoded.hasMore {
                guard let next = decoded.nextPage, let indexes = Self.pageIndexes(next) else {
                    completion(.failure(.invalidResponse))
                    return
                }
                self.fetchWindow(key: key, start: start, end: end, limit: limit,
                                 page: indexes, accumulated: all, pageCount: pageCount + 1,
                                 completion: completion)
            } else {
                completion(.success(all))
            }
        }.resume()
    }

    /// Pure URL construction so pagination and exact range parameters are
    /// covered without sending a live request in unit tests.
    static func requestURL(start: Date, end: Date, limit: Int,
                           page: String? = nil) -> URL? {
        let indexes: [Int]?
        if let page {
            guard let parsed = pageIndexes(page) else { return nil }
            indexes = parsed
        } else {
            indexes = nil
        }
        return costsURL(start: start, end: end, limit: limit, pageIndexes: indexes)
    }

    /// Builds the Costs URL. A page cursor arrives as indexes into `pageAlphabet`,
    /// so a server-supplied string cannot change the host.
    private static func costsURL(start: Date, end: Date, limit: Int,
                                 pageIndexes: [Int]?) -> URL? {
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(ceil(end.timeIntervalSince1970)))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "group_by", value: "line_item"),
        ]
        if let pageIndexes {
            guard let token = pageToken(pageIndexes) else { return nil }
            items.append(URLQueryItem(name: "page", value: token))
        }
        components?.queryItems = items
        guard let url = components?.url,
              url.scheme == "https", url.host == "api.openai.com",
              let pinned = URL(string: endpoint),
              url.host == pinned.host else { return nil }
        return URL(string: "https://api.openai.com/v1/organization/costs?\(url.query ?? "")")
    }

    private static let pageAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

    /// Maps a server page cursor onto indexes in `pageAlphabet`. Anything else is rejected.
    private static func pageIndexes(_ raw: String) -> [Int]? {
        guard raw.count <= 512, !raw.contains("..") else { return nil }
        var indexes: [Int] = []
        indexes.reserveCapacity(raw.count)
        for character in raw {
            guard let index = pageAlphabet.firstIndex(of: character) else { return nil }
            indexes.append(index)
        }
        return indexes
    }

    /// Rebuilds a cursor from the constant alphabet. The characters do not come from the server string.
    private static func pageToken(_ indexes: [Int]) -> String? {
        guard indexes.count <= 512, indexes.allSatisfy({ $0 >= 0 && $0 < pageAlphabet.count }) else { return nil }
        return String(indexes.map { pageAlphabet[$0] })
    }
}
