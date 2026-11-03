import Foundation

struct Badge {
    let name: String
    let earned: Bool
    let detail: String
    let emoji: String
}

/// Derives badges from the current rollup/efficiency + local history.
enum Achievements {
    static func badges(eff: EfficiencyResult, rollup: Rollup, history: History) -> [Badge] {
        let streak7 = history.streak(threshold: 80) >= 7
        let streak30 = history.streak(threshold: 80) >= 30
        let isBest = rollup.monthUSD > 0 && eff.score >= history.personalBest && eff.score > 0
        let realUsage = rollup.monthUSD > 0

        return [
            Badge(name: "Cache Master", earned: eff.cacheHitPct >= 0.90,
                  detail: "≥90% cache hits (you: \(Fmt.pct(eff.cacheHitPct)))", emoji: "🎯"),
            Badge(name: "Sonnet Saver", earned: realUsage && rollup.opusShare <= 0.40,
                  detail: "Opus ≤40% of spend (you: \(Fmt.pct(rollup.opusShare)))", emoji: "💸"),
            Badge(name: "Right Model", earned: eff.modelFit.rightModelPct >= 0.90,
                  detail: "≥90% model-fit (you: \(Fmt.pct(eff.modelFit.rightModelPct)))", emoji: "✅"),
            Badge(name: "Lean Context", earned: realUsage && eff.context.contextPerTurnMedian <= 60_000,
                  detail: "≤60k context/turn (you: \(Fmt.tokens(eff.context.contextPerTurnMedian)))", emoji: "🪶"),
            Badge(name: "7-Day Streak", earned: streak7,
                  detail: "7 days at score ≥80 (current: \(history.streak(threshold: 80)))", emoji: "🔥"),
            Badge(name: "30-Day Streak", earned: streak30,
                  detail: "30 days at score ≥80", emoji: "🏆"),
            Badge(name: "Personal Best", earned: isBest,
                  detail: "Best score yet: \(history.personalBest)", emoji: "⭐️"),
        ]
    }
}
