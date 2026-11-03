import Foundation

/// The computed personal spend snapshot the UI renders.
struct Rollup {
    var todayUSD: Double = 0
    var monthUSD: Double = 0
    var byModelUSD: [String: Double] = [:]
    var opusUSD: Double = 0
    var sessions: Int = 0

    /// True once monthUSD/byModelUSD/opusUSD below have been overwritten by
    /// GET /spend/end_user (the LLM-proxy's own billing record) instead of
    /// this local transcript scan. See ProxySpend.swift: proxy data is the
    /// source of truth for these three fields when available — the local
    /// scan is coverage-limited to this machine's own transcript files (see
    /// README's "Local vs proxy spend" section) and is a fallback, not a
    /// second opinion.
    var proxyReconciled: Bool = false

    // Cache efficiency (tokens).
    var cacheReadTokens: Int = 0
    var uncachedInputTokens: Int = 0   // input + cache_write (tokens not served from cache)

    // Derived.
    var projectedMonthEndUSD: Double = 0

    var opusShare: Double { monthUSD > 0 ? opusUSD / monthUSD : 0 }

    /// cache_read / (cache_read + uncached input). Higher is cheaper/better.
    var cacheHitPct: Double {
        let total = cacheReadTokens + uncachedInputTokens
        return total > 0 ? Double(cacheReadTokens) / Double(total) : 0
    }

    var costPerSessionUSD: Double { sessions > 0 ? monthUSD / Double(sessions) : 0 }
}

/// Aggregates parsed records into a current-month Rollup.
struct SpendStore {
    let pricing: Pricing

    func rollup(from records: [UsageRecord], now: Date = Date()) -> Rollup {
        let cal = Calendar.current
        let dayOfMonth = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30

        var r = Rollup()
        var monthSessions = Set<String>()

        for rec in records {
            let cost = pricing.cost(input: rec.input, cacheWrite: rec.cacheWrite,
                                    cacheRead: rec.cacheRead, output: rec.output,
                                    model: rec.model)

            if cal.isDate(rec.date, equalTo: now, toGranularity: .month) {
                r.monthUSD += cost
                r.byModelUSD[rec.model, default: 0] += cost
                if rec.model.contains("opus") { r.opusUSD += cost }
                r.cacheReadTokens += rec.cacheRead
                r.uncachedInputTokens += rec.input + rec.cacheWrite
                if !rec.sessionId.isEmpty { monthSessions.insert(rec.sessionId) }

                if cal.isDate(rec.date, inSameDayAs: now) { r.todayUSD += cost }
            }
        }

        r.sessions = monthSessions.count
        // Linear projection: month-to-date scaled to the full month.
        r.projectedMonthEndUSD = dayOfMonth > 0
            ? r.monthUSD * Double(daysInMonth) / Double(dayOfMonth)
            : r.monthUSD
        return r
    }
}
