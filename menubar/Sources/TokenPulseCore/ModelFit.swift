import Foundation

/// A session leaking $ to lightweight Opus turns — the actionable model-fit finding.
struct ModelFitOffender {
    let label: String        // project + prompt snippet
    let reason: String       // e.g. "42 of 483 turns lightweight on Opus"
    let opusUSD: Double      // lightweight Opus $ in this session
    let sonnetUSD: Double    // same turns at Sonnet rates
    var savingsUSD: Double { max(0, opusUSD - sonnetUSD) }
}

/// Local model-fit advisor — ZERO LLM calls by default ($0, fully private).
///
/// Why turn-level, not session-level: real sessions are long agentic runs that
/// all look "hard" in aggregate, so session-level classification reports a
/// useless 100%. The real waste is *inside* those sessions — individual turns
/// with no tool use and tiny output that Opus handled. We score on the share of
/// spend going to those lightweight Opus turns. The fix is habit-level (default
/// to Sonnet, escalate to Opus), since Claude Code picks model per session.
struct ModelFitResult {
    let rightModelPct: Double      // 1 - (lightweight Opus $ / month $)
    let recoverableUSD: Double     // lightweight Opus $ moved to Sonnet
    let lightTurnShare: Double     // lightweight Opus turns / all Opus turns
    let offenders: [ModelFitOffender]
    let advisorCostUSD: Double     // our own spend classifying (0 in local mode)

    static func compute(_ aggs: [SessionAgg], rollup: Rollup, config: Config) -> ModelFitResult {
        let lightCost = aggs.reduce(0.0) { $0 + $1.lightOpusCost }
        let recoverable = aggs.reduce(0.0) { $0 + $1.lightSavings }
        let opusTurns = aggs.reduce(0) { $0 + ($1.usedOpus ? $1.turns : 0) }
        let lightTurns = aggs.reduce(0) { $0 + $1.lightTurns }

        let offenders = aggs
            .filter { $0.lightSavings > 0.05 }
            .sorted { $0.lightSavings > $1.lightSavings }
            .prefix(8)
            .map { a in
                ModelFitOffender(
                    label: ContextResult.label(for: a),
                    reason: "\(a.lightTurns) of \(a.turns) turns lightweight on Opus",
                    opusUSD: a.lightOpusCost, sonnetUSD: a.lightOpusAtSonnet)
            }

        let rightPct = rollup.monthUSD > 0 ? max(0, 1 - lightCost / rollup.monthUSD) : 1
        let share = opusTurns > 0 ? Double(lightTurns) / Double(opusTurns) : 0

        return ModelFitResult(rightModelPct: rightPct,
                              recoverableUSD: recoverable,
                              lightTurnShare: share,
                              offenders: Array(offenders),
                              advisorCostUSD: 0)
    }
}
