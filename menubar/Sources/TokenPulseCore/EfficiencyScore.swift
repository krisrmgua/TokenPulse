import Foundation

/// The composite efficiency result the UI renders. Score rewards what devs
/// actually control: model fit (50) + context discipline (35) + cost hygiene
/// (15). Cache hit % is INFORMATIONAL ONLY (mostly automatic) — it does not
/// move the score.
struct EfficiencyResult {
    let score: Int            // 0..100
    let grade: String         // A..F
    let modelFitPoints: Double // out of 50
    let contextPoints: Double  // out of 35
    let costPoints: Double     // out of 15

    let modelFit: ModelFitResult
    let context: ContextResult
    let cacheHitPct: Double    // info only
    let costPerSessionUSD: Double

    /// Top actionable tip across advisors.
    var topTip: String {
        if modelFit.recoverableUSD > 0.25 {
            return "\(Fmt.pct(modelFit.lightTurnShare)) of Opus turns were lightweight — default to Sonnet, escalate for hard work (~\(Fmt.money(modelFit.recoverableUSD)) recoverable)."
        }
        return context.tips.first ?? "Efficiency looks healthy."
    }

    static func grade(for score: Int) -> String {
        switch score {
        case 90...:   return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        case 60..<70: return "D"
        default:      return "F"
        }
    }

    static func compute(rollup: Rollup, scan: ScanResult,
                        pricing: Pricing, config: Config) -> EfficiencyResult {
        let aggs = sessionAggregates(scan, pricing: pricing)
        let modelFit = ModelFitResult.compute(aggs, rollup: rollup, config: config)
        let context = ContextResult.compute(aggs, rollup: rollup, pricing: pricing)

        // Model fit (50): right-model share directly.
        let modelFitPts = 50 * clamp01(modelFit.rightModelPct)

        // Context (35): lean context-per-turn within a healthy band, minus churn.
        // Full credit ≤ 60k tok/turn, zero ≥ 250k; churn > 10% bleeds up to 10 pts.
        let m = context.contextPerTurnMedian
        let band = clamp01((250_000 - m) / (250_000 - 60_000))
        let churnPenalty = min(1.0, max(0, context.churn - 0.10) / 0.20)  // 0..1
        let contextPts = max(0, 35 * band - 10 * churnPenalty)

        // Cost hygiene (15): $/session vs target. Full ≤ $8, zero ≥ $50.
        let cps = rollup.costPerSessionUSD
        let costFrac = clamp01((50 - cps) / (50 - 8))
        let costPts = 15 * costFrac

        let total = Int((modelFitPts + contextPts + costPts).rounded())
        let clamped = min(100, max(0, total))

        return EfficiencyResult(
            score: clamped, grade: grade(for: clamped),
            modelFitPoints: modelFitPts, contextPoints: contextPts, costPoints: costPts,
            modelFit: modelFit, context: context,
            cacheHitPct: rollup.cacheHitPct, costPerSessionUSD: cps)
    }
}

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
