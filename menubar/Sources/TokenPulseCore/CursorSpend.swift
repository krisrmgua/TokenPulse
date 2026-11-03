import Foundation
import SQLite3

/// Personal Cursor IDE spend from Cursor's DashboardService RPCs
/// (api2.cursor.sh). Auth is the access token Cursor already stores in
/// state.vscdb — TokenPulse never logs in or refreshes it. No token →
/// silently inert, same contract as ProxySpend.
///
/// Always scoped to the signed-in userId from GetMe. Unfiltered
/// GetAggregatedUsageEvents returns team-wide totals for owners/admins;
/// that must never feed a personal menu-bar monitor.

/// One model's aggregation from GetAggregatedUsageEvents.
struct CursorUsageAgg {
    let model: String
    let spendUSD: Double
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
}

/// Included Pro/Team allowance from GetCurrentPeriodUsage.planUsage.
/// Dollar totals from GetAggregatedUsageEvents are list/API costs and must
/// not drive personal-mode % remaining — use this instead.
struct CursorPlanUsage {
    let limitUSD: Double
    let includedSpendUSD: Double
    let totalPercentUsed: Double
    let percentLeft: Int
    /// Billing-cycle window from the same GetCurrentPeriodUsage response.
    let billingCycleStart: Date?
    let billingCycleEnd: Date?

    init(limitUSD: Double, includedSpendUSD: Double, totalPercentUsed: Double,
         percentLeft: Int, billingCycleStart: Date? = nil, billingCycleEnd: Date? = nil) {
        self.limitUSD = limitUSD
        self.includedSpendUSD = includedSpendUSD
        self.totalPercentUsed = totalPercentUsed
        self.percentLeft = percentLeft
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
    }

    static func percentLeft(from totalPercentUsed: Double) -> Int {
        Int(max(0, min(100, (100 - totalPercentUsed).rounded())))
    }

    var resetDescription: String? {
        guard let billingCycleEnd else { return nil }
        return ChatGPTUsageParse.displayDate(billingCycleEnd)
    }
}

/// Best-effort personal Cursor spend snapshot for the UI / CLI.
struct CursorSpendSnapshot {
    /// Calendar month to date, local timezone.
    let totalSpendUSD: Double
    /// Calendar day to date, local timezone.
    let todaySpendUSD: Double
    /// Per-model breakdown over the same window as `totalSpendUSD`.
    let byModel: [CursorUsageAgg]
    let fetchedAt: Date
    let userId: Int
    /// Pro/Team included allowance meter; nil when the endpoint omits planUsage.
    let planUsage: CursorPlanUsage?

    /// Menu-bar fragment for personal mode: `98%`, or `0% Oct 15` when exhausted
    /// and Cursor reported `billingCycleEnd`.
    func personalBarPercent(allowanceUSD: Double) -> String {
        let remaining = cursorPersonalRemainingPercent(cursor: self, allowanceUSD: allowanceUSD)
        if remaining == 0, let end = planUsage?.billingCycleEnd {
            return "0% \(ChatGPTUsageParse.shortBarResetDate(from: end))"
        }
        return "\(remaining)%"
    }
}

/// Whether Cursor already has a login TokenPulse can use. Checking this does
/// not read the Keychain, so it never raises the Mac password sheet.
enum CursorLoginAvailability: Equatable {
    case missing
    case ready
    case needsKeychain
}

/// Reads `cursorAuth/accessToken` from Cursor's local state DB.
struct CursorAuthCache {
    static var stateDBURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                isDirectory: false)
    }

    /// Classifies a stored Cursor credential without decrypting it.
    static func loginAvailability(stored: String?) -> CursorLoginAvailability {
        guard let stored, !stored.isEmpty else { return .missing }
        return stored.hasPrefix(CursorTokenCrypto.prefix) ? .needsKeychain : .ready
    }

    /// Login state on this Mac. Does not prompt for the Keychain password.
    static func loginAvailability() -> CursorLoginAvailability {
        loginAvailability(stored: storedCredential())
    }

    /// Bearer token Cursor left on disk, or nil if the DB/key is missing.
    static func accessToken() -> String? {
        guard let stored = storedCredential(), !stored.isEmpty,
              let token = CursorTokenCrypto.decode(stored), !token.isEmpty else { return nil }
        return token
    }

    /// Raw ItemTable value, still encrypted when Cursor used safe storage.
    private static func storedCredential() -> String? {
        let path = stateDBURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        // Read-only + no create — never mutate Cursor's DB.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let stored = String(cString: cStr)
        return stored.isEmpty ? nil : stored
    }
}

/// Pure parsers for Cursor Dashboard JSON — kept free of network/SQLite so
/// `--selftest` can cover field coercion and $ conversion without fixtures.
enum CursorSpendParse {
    static func aggregations(from obj: [String: Any]) -> [CursorUsageAgg]? {
        guard let rows = obj["aggregations"] as? [[String: Any]] else { return nil }
        var byModel: [CursorUsageAgg] = []
        byModel.reserveCapacity(rows.count)
        for row in rows {
            let model = row["modelIntent"] as? String ?? "unknown"
            let cents = doubleField(row, "totalCents")
            byModel.append(CursorUsageAgg(
                model: model,
                spendUSD: cents / 100.0,
                inputTokens: intField(row, "inputTokens"),
                outputTokens: intField(row, "outputTokens"),
                cacheWriteTokens: intField(row, "cacheWriteTokens"),
                cacheReadTokens: intField(row, "cacheReadTokens")))
        }
        byModel.sort { $0.spendUSD > $1.spendUSD }
        return byModel
    }

    /// Window total from `GetAggregatedUsageEvents.totalCostCents` → USD.
    ///
    /// This is the charged amount — list cost plus `cursorTokenFee`, net of any
    /// `enterpriseUsageDiscountPercent` — and runs a few percent above the
    /// `tokenUsage.totalCents` carried on individual usage events. Both figures
    /// must come from here so Today and Month stay on one basis.
    static func totalSpendUSD(from obj: [String: Any]) -> Double {
        doubleField(obj, "totalCostCents") / 100.0
    }

    static func intField(_ row: [String: Any], _ key: String) -> Int {
        if let i = row[key] as? Int { return i }
        if let n = row[key] as? NSNumber { return n.intValue }
        if let s = row[key] as? String { return Int(s) ?? 0 }
        return 0
    }

    static func doubleField(_ row: [String: Any], _ key: String) -> Double {
        if let d = row[key] as? Double { return d }
        if let n = row[key] as? NSNumber { return n.doubleValue }
        if let s = row[key] as? String { return Double(s) ?? 0 }
        return 0
    }

    /// Parses `GetCurrentPeriodUsage.planUsage` — limit and includedSpend are
    /// cents; totalPercentUsed is what Cursor shows as "% of included usage".
    /// Billing-cycle bounds live on the root object (`billingCycleStart` /
    /// `billingCycleEnd`, epoch millis as number or string).
    static func planUsage(from obj: [String: Any]) -> CursorPlanUsage? {
        guard let plan = obj["planUsage"] as? [String: Any] else { return nil }
        let limitCents = doubleField(plan, "limit")
        guard limitCents > 0 else { return nil }
        let includedCents = doubleField(plan, "includedSpend")
        let totalPct = doubleField(plan, "totalPercentUsed")
        return CursorPlanUsage(
            limitUSD: limitCents / 100.0,
            includedSpendUSD: includedCents / 100.0,
            totalPercentUsed: totalPct,
            percentLeft: CursorPlanUsage.percentLeft(from: totalPct),
            billingCycleStart: epochMillisDate(obj, "billingCycleStart"),
            billingCycleEnd: epochMillisDate(obj, "billingCycleEnd"))
    }

    /// Cursor sends cycle bounds as epoch-millis numbers or digit strings.
    static func epochMillisDate(_ obj: [String: Any], _ key: String) -> Date? {
        let millis: Double?
        if let d = obj[key] as? Double { millis = d }
        else if let n = obj[key] as? NSNumber { millis = n.doubleValue }
        else if let s = obj[key] as? String { millis = Double(s) }
        else { millis = nil }
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000.0)
    }
}

/// Fetches personal Cursor spend and caches it client-side. Failures keep
/// last-known data (or nil) — no UI error surface in the menu bar.
final class CursorSpendClient {
    private static let baseURL = "https://api2.cursor.sh"
    private static let staleAfter: TimeInterval = 30 * 60

    /// Shared with proxy via `Config.remotePollInterval` (default 5 min).
    private var minRefreshInterval: TimeInterval

    /// Serial queue for cache state — same rationale as ProxyReconciler
    /// (CLI semaphore path must not hop to main).
    private let stateQueue = DispatchQueue(label: "com.kris.tokenpulse.cursor-spend")

    private var lastAttempt: Date?
    private var lastSuccess: CursorSpendSnapshot?
    private var cachedUserId: Int?

    init(minRefreshInterval: TimeInterval = 5 * 60) {
        self.minRefreshInterval = minRefreshInterval
    }

    func setMinRefreshInterval(_ interval: TimeInterval) {
        stateQueue.async { self.minRefreshInterval = interval }
    }

    /// Best current snapshot, or nil (omit Cursor sections). Completion runs
    /// on `stateQueue`; UI callers must hop to main themselves.
    /// Auth/SQLite work stays off the caller's thread (AppDelegate timers
    /// fire on main — never open Cursor's multi‑GB state.vscdb there).
    func currentSpend(now: Date = Date(),
                      force: Bool = false,
                      completion: @escaping (CursorSpendSnapshot?) -> Void) {
        stateQueue.async {
            guard let token = CursorAuthCache.accessToken() else {
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
            self.fetch(token: token, now: now) { snap in
                self.stateQueue.async {
                    if let snap { self.lastSuccess = snap }
                    completion(snap ?? self.freshEnough(now: now))
                }
            }
        }
    }

    private func freshEnough(now: Date) -> CursorSpendSnapshot? {
        // Refuse a cached "today" from a prior calendar day — otherwise a
        // midnight $0 (or yesterday's total) sticks until staleAfter elapses.
        guard let snap = lastSuccess,
              now.timeIntervalSince(snap.fetchedAt) < Self.staleAfter,
              History.dayString(snap.fetchedAt) == History.dayString(now)
        else { return nil }
        return snap
    }

    private func fetch(token: String, now: Date,
                       completion: @escaping (CursorSpendSnapshot?) -> Void) {
        resolveUserId(token: token) { userId in
            guard let userId else { completion(nil); return }

            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: now)
            let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? dayStart

            let group = DispatchGroup()
            var month: (rows: [CursorUsageAgg], totalUSD: Double)?
            var todayUSD: Double?
            let lock = NSLock()

            group.enter()
            self.fetchAggregates(token: token, userId: userId,
                                 start: monthStart, end: now) { result in
                lock.lock(); month = result; lock.unlock()
                group.leave()
            }

            group.enter()
            self.fetchAggregates(token: token, userId: userId,
                                 start: dayStart, end: now) { result in
                lock.lock(); todayUSD = result?.totalUSD; lock.unlock()
                group.leave()
            }

            var planUsage: CursorPlanUsage?
            group.enter()
            self.fetchCurrentPeriodUsage(token: token) { usage in
                lock.lock(); planUsage = usage; lock.unlock()
                group.leave()
            }

            group.notify(queue: self.stateQueue) {
                lock.lock()
                let monthResult = month
                let today = todayUSD
                let plan = planUsage
                lock.unlock()
                if let monthResult {
                    completion(CursorSpendSnapshot(
                        totalSpendUSD: monthResult.totalUSD,
                        todaySpendUSD: today ?? 0,
                        byModel: monthResult.rows,
                        fetchedAt: now,
                        userId: userId,
                        planUsage: plan))
                    return
                }
                // A failed spend aggregate must not hide the plan meter that
                // personal mode actually displays; reuse same-day spend if any.
                guard let plan else { completion(nil); return }
                let prior = self.freshEnough(now: now)
                completion(CursorSpendSnapshot(
                    totalSpendUSD: prior?.totalSpendUSD ?? 0,
                    todaySpendUSD: prior?.todaySpendUSD ?? 0,
                    byModel: prior?.byModel ?? [],
                    fetchedAt: now,
                    userId: userId,
                    planUsage: plan))
            }
        }
    }

    private func fetchCurrentPeriodUsage(token: String,
                                         completion: @escaping (CursorPlanUsage?) -> Void) {
        postJSON(path: "/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                 token: token, body: [:], connect: true) { data in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(nil); return }
            completion(CursorSpendParse.planUsage(from: obj))
        }
    }

    private func resolveUserId(token: String, completion: @escaping (Int?) -> Void) {
        if let cachedUserId {
            completion(cachedUserId)
            return
        }
        postJSON(path: "/aiserver.v1.DashboardService/GetMe", token: token, body: [:]) { data in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(nil); return }
            let id: Int? = {
                if let i = obj["userId"] as? Int { return i }
                if let n = obj["userId"] as? NSNumber { return n.intValue }
                if let s = obj["userId"] as? String { return Int(s) }
                return nil
            }()
            if let id { self.stateQueue.async { self.cachedUserId = id } }
            completion(id)
        }
    }

    /// Aggregated spend over an explicit window.
    ///
    /// The date range is not optional. Asked without one, the endpoint answers
    /// for a rolling window of roughly the last day, which reads as a
    /// month-to-date total that is wrong on every day but the first.
    private func fetchAggregates(token: String, userId: Int,
                                 start: Date, end: Date,
                                 completion: @escaping ((rows: [CursorUsageAgg], totalUSD: Double)?) -> Void) {
        // userId is required — omitting it returns team-wide totals for owners.
        let body: [String: Any] = [
            "userId": userId,
            "startDate": Self.epochMillis(start),
            "endDate": Self.epochMillis(end),
        ]
        postJSON(path: "/aiserver.v1.DashboardService/GetAggregatedUsageEvents",
                 token: token, body: body) { data in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = CursorSpendParse.aggregations(from: obj)
            else { completion(nil); return }
            completion((rows, CursorSpendParse.totalSpendUSD(from: obj)))
        }
    }

    private static func epochMillis(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    private func postJSON(path: String, token: String, body: [String: Any],
                          connect: Bool = false,
                          completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: Self.baseURL + path),
              let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else { completion(nil); return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if connect {
            req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        }
        req.setValue("TokenPulse/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data
            else { completion(nil); return }
            completion(data)
        }.resume()
    }
}
