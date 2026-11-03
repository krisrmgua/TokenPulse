import Foundation

/// One calendar day's combined work spend (Claude + Cursor + ChatGPT work).
struct DailySpend: Codable, Equatable {
    let date: String   // yyyy-MM-dd local
    let dayUSD: Double
    let monthUSD: Double
}

/// Chart row for the current month: cumulative MTD actuals plus a climb to proj. eom.
struct SpendChartPoint: Identifiable, Equatable {
    var id: Int { day }
    let day: Int
    let date: String
    /// Month-to-date spend through this day (nil when not yet recorded).
    let actualUSD: Double?
    /// Cumulative projection from today through month-end (nil before today).
    let projectedUSD: Double?
    var isToday: Bool
}

/// Append-one-per-day local spend log at
/// ~/Library/Application Support/TokenPulse/spend-ledger.json.
struct SpendLedger {
    let url: URL
    private(set) var days: [DailySpend]

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("TokenPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: base.path)
        return base.appendingPathComponent("spend-ledger.json")
    }

    init(url: URL = SpendLedger.defaultURL()) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DailySpend].self, from: data) {
            days = decoded.sorted { $0.date < $1.date }
        } else {
            days = []
        }
    }

    /// Upsert today's combined work spend and persist.
    mutating func record(dayUSD: Double, monthUSD: Double, today: String = History.dayString()) {
        let entry = DailySpend(date: today, dayUSD: max(0, dayUSD), monthUSD: max(0, monthUSD))
        days.removeAll { $0.date == today }
        days.append(entry)
        days.sort { $0.date < $1.date }
        // Keep roughly a year so the file stays small.
        if days.count > 400 {
            days = Array(days.suffix(366))
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        }
    }

    func entry(on date: String) -> DailySpend? {
        days.first { $0.date == date }
    }

    /// Cumulative month-to-date line, then a dotted climb from today to projected EOM.
    func monthChart(now: Date = Date(),
                    todayUSD: Double,
                    monthUSD: Double,
                    projectedMonthEndUSD: Double? = nil) -> [SpendChartPoint] {
        let cal = Calendar.current
        let dayOfMonth = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let prefix = String(format: "%04d-%02d-", year, month)
        let byDate = Dictionary(uniqueKeysWithValues: days.filter { $0.date.hasPrefix(prefix) }.map { ($0.date, $0) })
        let todayKey = History.dayString(now)
        let eom = projectedMonthEndUSD ?? projectedMonthEnd(monthUSD: monthUSD, now: now)
        let remainingDays = max(0, daysInMonth - dayOfMonth)

        return (1...daysInMonth).map { day in
            let key = String(format: "%04d-%02d-%02d", year, month, day)
            let isToday = key == todayKey
            let actual: Double?
            if day < dayOfMonth {
                // Prefer stored MTD; fall back to summing recorded day totals in order.
                if let mtd = byDate[key]?.monthUSD {
                    actual = mtd
                } else {
                    actual = cumulativeDayUSD(through: day, prefix: prefix, year: year, month: month, byDate: byDate)
                }
            } else if day == dayOfMonth {
                actual = monthUSD
            } else {
                actual = nil
            }
            let projected: Double?
            if day < dayOfMonth {
                projected = nil
            } else if day == dayOfMonth {
                projected = monthUSD
            } else if remainingDays > 0 {
                let step = day - dayOfMonth
                projected = monthUSD + (eom - monthUSD) * Double(step) / Double(remainingDays)
            } else {
                projected = eom
            }
            return SpendChartPoint(day: day, date: key, actualUSD: actual,
                                  projectedUSD: projected, isToday: isToday)
        }
    }

    /// Running sum of `dayUSD` for days 1...through when MTD was not stored.
    private func cumulativeDayUSD(through: Int, prefix: String, year: Int, month: Int,
                                  byDate: [String: DailySpend]) -> Double? {
        var total = 0.0
        var sawAny = false
        for day in 1...through {
            let key = String(format: "%04d-%02d-%02d", year, month, day)
            guard let entry = byDate[key] else { continue }
            sawAny = true
            total += entry.dayUSD
        }
        return sawAny ? total : nil
    }
}
