import Foundation

/// One day's efficiency snapshot. Local-only, powers streaks/trend/personal-best.
struct Snapshot: Codable {
    let date: String        // yyyy-MM-dd (local)
    let score: Int
    let costMTD: Double
    let cacheHitPct: Double
    let opusShare: Double
    let modelFitPct: Double
}

/// Append-one-per-day local history at
/// ~/Library/Application Support/TokenPulse/history.json.
struct History {
    let url: URL
    private(set) var snapshots: [Snapshot]

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("TokenPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: base.path)
        return base.appendingPathComponent("history.json")
    }

    static func dayString(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    init(url: URL = History.defaultURL()) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode([Snapshot].self, from: data) {
            snapshots = s.sorted { $0.date < $1.date }
        } else {
            snapshots = []
        }
    }

    /// Upsert today's snapshot (replace same-date) and persist.
    mutating func record(_ eff: EfficiencyResult, rollup: Rollup, today: String = History.dayString()) {
        let snap = Snapshot(date: today, score: eff.score, costMTD: rollup.monthUSD,
                            cacheHitPct: eff.cacheHitPct, opusShare: rollup.opusShare,
                            modelFitPct: eff.modelFit.rightModelPct)
        snapshots.removeAll { $0.date == today }
        snapshots.append(snap)
        snapshots.sort { $0.date < $1.date }
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        }
    }

    var personalBest: Int { snapshots.map(\.score).max() ?? 0 }

    /// Consecutive days (ending today) with score ≥ threshold; a calendar gap breaks it.
    func streak(threshold: Int, today: Date = Date()) -> Int {
        let cal = Calendar.current
        let byDate = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.date, $0) })
        var count = 0
        var day = today
        while true {
            let key = History.dayString(day)
            guard let s = byDate[key], s.score >= threshold else { break }
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    /// Today's score minus the snapshot ~7 days ago (closest on/before). 0 if none.
    func trend7d(today: Date = Date()) -> Int {
        guard let latest = snapshots.last else { return 0 }
        let cal = Calendar.current
        guard let weekAgo = cal.date(byAdding: .day, value: -7, to: today) else { return 0 }
        let target = History.dayString(weekAgo)
        let prior = snapshots.last { $0.date <= target }
        return latest.score - (prior?.score ?? latest.score)
    }
}
