import Foundation

/// Per-session aggregate over current-month records. Shared by the context-spend
/// insights and the model-fit advisor.
struct SessionAgg {
    let id: String
    var cwd: String = ""
    var firstPrompt: String = ""
    var turns: Int = 0          // assistant responses in the session this month
    var input: Int = 0
    var cacheWrite: Int = 0
    var cacheRead: Int = 0
    var output: Int = 0
    var toolUses: Int = 0
    var models: Set<String> = []
    var totalCost: Double = 0
    var opusCost: Double = 0
    /// What this session's Opus usage would have cost on Sonnet (token-for-token).
    var opusAsSonnetCost: Double = 0

    // Lightweight Opus turns: tiny output, no tool use — work Opus is overkill for.
    var lightTurns: Int = 0
    var lightOpusCost: Double = 0
    var lightOpusAtSonnet: Double = 0
    var lightSavings: Double { max(0, lightOpusCost - lightOpusAtSonnet) }

    /// Tokens spent feeding context (everything that isn't output).
    var contextTokens: Int { input + cacheWrite + cacheRead }
    var contextPerTurn: Double { turns > 0 ? Double(contextTokens) / Double(turns) : 0 }
    var usedOpus: Bool { models.contains { $0.contains("opus") } }
    var projectLabel: String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? "—" : base
    }
}

/// Builds per-session aggregates for the current month.
func sessionAggregates(_ scan: ScanResult, pricing: Pricing, now: Date = Date()) -> [SessionAgg] {
    let cal = Calendar.current
    var byId: [String: SessionAgg] = [:]

    for rec in scan.records where cal.isDate(rec.date, equalTo: now, toGranularity: .month) {
        guard !rec.sessionId.isEmpty else { continue }
        var a = byId[rec.sessionId] ?? SessionAgg(id: rec.sessionId)
        a.turns += 1
        a.input += rec.input
        a.cacheWrite += rec.cacheWrite
        a.cacheRead += rec.cacheRead
        a.output += rec.output
        a.toolUses += rec.toolUseCount
        a.models.insert(rec.model)

        let cost = pricing.cost(input: rec.input, cacheWrite: rec.cacheWrite,
                                cacheRead: rec.cacheRead, output: rec.output, model: rec.model)
        a.totalCost += cost
        if rec.model.contains("opus") {
            a.opusCost += cost
            let asSonnet = pricing.cost(input: rec.input, cacheWrite: rec.cacheWrite,
                                        cacheRead: rec.cacheRead, output: rec.output,
                                        model: "claude-sonnet-5")
            a.opusAsSonnetCost += asSonnet
            // Lightweight turn: no tools and tiny output → Opus is overkill.
            if rec.toolUseCount == 0 && rec.output < 250 {
                a.lightTurns += 1
                a.lightOpusCost += cost
                a.lightOpusAtSonnet += asSonnet
            }
        }
        byId[rec.sessionId] = a
    }

    // Attach metadata (cwd, first prompt).
    for (id, meta) in scan.sessions {
        if byId[id] != nil {
            byId[id]!.cwd = meta.cwd
            byId[id]!.firstPrompt = meta.firstPrompt
        }
    }
    return Array(byId.values)
}

/// A session whose context-per-turn is well above the norm.
struct BloatedSession {
    let label: String        // project + prompt snippet
    let contextPerTurn: Double
    let costUSD: Double
}

/// Context-spend insights — the input-token lever (~90% of $ is context).
struct ContextResult {
    let contextPerTurnMedian: Double
    let churn: Double                 // cache_write / total context tokens
    let contextCostShare: Double      // context $ / total $ (non-output share)
    let bloated: [BloatedSession]     // worst offenders, sorted desc
    let bigReadFlag: Bool             // a single turn dumped a huge context
    let tips: [String]

    static func compute(_ aggs: [SessionAgg], rollup: Rollup, pricing: Pricing) -> ContextResult {
        let perTurns = aggs.map { $0.contextPerTurn }.filter { $0 > 0 }.sorted()
        let median = perTurns.isEmpty ? 0 : perTurns[perTurns.count / 2]

        let totalContextTok = aggs.reduce(0) { $0 + $1.contextTokens }
        let totalCacheWrite = aggs.reduce(0) { $0 + $1.cacheWrite }
        let churn = totalContextTok > 0 ? Double(totalCacheWrite) / Double(totalContextTok) : 0

        // Context cost share = (month $ minus output $) / month $.
        let outputCost = aggs.reduce(0.0) { acc, a in
            acc + pricing.cost(input: 0, cacheWrite: 0, cacheRead: 0, output: a.output,
                               model: a.models.first ?? "claude-opus-4-8")
        }
        let share = rollup.monthUSD > 0 ? max(0, (rollup.monthUSD - outputCost) / rollup.monthUSD) : 0

        // Bloated = context-per-turn > 2x median and non-trivial cost.
        let bloated = aggs
            .filter { median > 0 && $0.contextPerTurn > 2 * median && $0.totalCost > 0.5 }
            .sorted { $0.contextPerTurn > $1.contextPerTurn }
            .prefix(5)
            .map { BloatedSession(label: label(for: $0),
                                  contextPerTurn: $0.contextPerTurn, costUSD: $0.totalCost) }

        // Big read = any session that averaged > 400k context tokens/turn.
        let bigRead = aggs.contains { $0.contextPerTurn > 400_000 }

        var tips: [String] = []
        if churn > 0.15 {
            tips.append("High context churn — avoid mid-session model switches and re-reading changed files.")
        }
        if median > 120_000 {
            tips.append("Heavy context per turn — `/clear` between unrelated tasks and lean on compaction.")
        }
        if bigRead {
            tips.append("A session dumped a huge file into context — read narrower ranges or use a subagent.")
        }
        if tips.isEmpty { tips.append("Context discipline looks healthy — keep sessions scoped.") }

        return ContextResult(contextPerTurnMedian: median, churn: churn,
                             contextCostShare: share, bloated: Array(bloated),
                             bigReadFlag: bigRead, tips: tips)
    }

    static func label(for a: SessionAgg) -> String {
        let prompt = a.firstPrompt.isEmpty ? "(no prompt)" : "'\(a.firstPrompt.prefix(48))'"
        return "\(a.projectLabel) — \(prompt)"
    }
}
