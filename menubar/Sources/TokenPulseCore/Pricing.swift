import Foundation

/// $/MTok rates for one model. cache_write = 1.25x input (5-min TTL),
/// cache_read = 0.10x input.
struct Rate {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double
}

/// Loads the rate table. Built-in defaults are public Anthropic list prices;
/// an optional pricing.json (../pricing.json, env TOKENPULSE_PRICING, or the
/// Jamf-managed support dir) overrides them once the LLM-proxy billing rate is
/// confirmed.
///
/// Rates resolve in three tiers so a brand-new model doesn't silently get
/// mispriced until someone remembers to update this file:
///   1. `overrides` — rate for a confirmed deviation from its family (e.g. a
///      temporary sale price, or a legacy model with no tier codename),
///      longest-substring match — matches "openai.gpt-5.4" against "gpt-5.4".
///   2. `families` — rate for the model's tier codename ("opus"/"sonnet"/
///      "haiku"/"fable" for Anthropic, "sol"/"terra"/"luna" for OpenAI's
///      gpt-5.6 line on Bedrock), matched by substring, so a new dated/point
///      release in a known tier still prices sanely by default.
///   3. `fallback` — last resort for a wholly unrecognized family.
struct Pricing {
    private let overrides: [String: Rate]
    private let families: [String: Rate]
    private let fallback: Rate

    /// Built-in defaults, sourced from aws.amazon.com/bedrock/pricing except
    /// Haiku/Fable (client-rendered on that page — unconfirmed). See
    /// pricing.json's _source/_note fields for provenance per rate.
    static let builtinFamilies: [String: Rate] = [
        "opus":   Rate(input: 5,  output: 25, cacheWrite: 6.25, cacheRead: 0.5),
        "sonnet": Rate(input: 3,  output: 15, cacheWrite: 3.75, cacheRead: 0.3),
        "haiku":  Rate(input: 1,  output: 5,  cacheWrite: 1.25, cacheRead: 0.1),
        "fable":  Rate(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1.0),
        // OpenAI gpt-5.6 tiers, short-context (272K) rate — see _context_window_note.
        "sol":    Rate(input: 5.50, output: 33.00, cacheWrite: 6.875, cacheRead: 0.55),
        "terra":  Rate(input: 2.20, output: 13.20, cacheWrite: 2.75,  cacheRead: 0.22),
        "luna":   Rate(input: 0.22, output: 1.32,  cacheWrite: 0.275, cacheRead: 0.022),
    ]
    static let builtinOverrides: [String: Rate] = [
        // On sale through at least 2026-08-31 — confirm and update/remove after.
        "claude-sonnet-5": Rate(input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2),
        // Legacy non-tiered GPT releases — no cache-write price listed, so
        // cache_write defaults to the input rate (no premium, no discount).
        "gpt-5.4": Rate(input: 2.75, output: 16.50, cacheWrite: 2.75, cacheRead: 0.275),
        "gpt-5.5": Rate(input: 5.50, output: 33.00, cacheWrite: 5.50, cacheRead: 0.55),
    ]
    static let builtinFallback = Rate(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)

    init() {
        // Try to load an override JSON; fall back to built-ins on any failure.
        if let loaded = Pricing.loadFromDisk() {
            self.overrides = loaded.overrides
            self.families = loaded.families
            self.fallback = loaded.fallback
        } else {
            self.overrides = Pricing.builtinOverrides
            self.families = Pricing.builtinFamilies
            self.fallback = Pricing.builtinFallback
        }
    }

    /// Shared across every call — building this per-lookup showed up as a
    /// hot-path allocation, since rate(for:) runs once per token record in
    /// the local transcript scan.
    private static let familyDelimiters = CharacterSet(charactersIn: "./-_")

    /// Every `.`/`-`/`_`/`/`-delimited component of `model`, lowercased and
    /// split once so each family codename can be checked by exact-component
    /// membership — e.g. "sol" matches ".../gpt-5.6-sol" but not
    /// "console-preview", which merely contains "sol" as a raw substring.
    /// Only used for the single-word family codenames: override keys are
    /// themselves multi-component strings (e.g. "gpt-5.4"), so those still
    /// match by plain substring below — component-anchoring would break a
    /// key like that against "openai.gpt-5.4". Computed once per `rate(for:)`
    /// call rather than once per family (was previously re-split up to 7x).
    private func modelComponents(_ model: String) -> Set<String> {
        Set(model.lowercased().components(separatedBy: Self.familyDelimiters))
    }

    func rate(for model: String) -> Rate {
        var best: (len: Int, rate: Rate)? = nil
        for (key, r) in overrides where model.contains(key) {
            if best == nil || key.count > best!.len { best = (key.count, r) }
        }
        if let best { return best.rate }
        let components = modelComponents(model)
        for (name, r) in families where components.contains(name.lowercased()) { return r }
        return fallback
    }

    /// Cost in USD for one assistant message's usage.
    func cost(input: Int, cacheWrite: Int, cacheRead: Int, output: Int, model: String) -> Double {
        let r = rate(for: model)
        return (Double(input) * r.input
              + Double(cacheWrite) * r.cacheWrite
              + Double(cacheRead) * r.cacheRead
              + Double(output) * r.output) / 1_000_000.0
    }

    private static func candidatePaths() -> [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["TOKENPULSE_PRICING"] {
            paths.append(env)
        }
        // Shipped inside the .app bundle (Contents/Resources/pricing.json).
        if let res = Bundle.main.resourceURL?.appendingPathComponent("pricing.json").path {
            paths.append(res)
        }
        paths.append("/Library/Application Support/TokenPulse/pricing.json")
        paths.append("/Library/Application Support/\(BrandMigration.legacyName)/pricing.json")
        // Dev convenience: repo root relative to this package.
        paths.append(FileManager.default.currentDirectoryPath + "/pricing.json")
        paths.append(FileManager.default.currentDirectoryPath + "/../pricing.json")
        return paths
    }

    private static func loadFromDisk() -> (overrides: [String: Rate], families: [String: Rate], fallback: Rate)? {
        for path in candidatePaths() {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            func parse(_ d: [String: Any]?) -> Rate? {
                guard let d, let i = d["input"] as? Double, let o = d["output"] as? Double,
                      let cw = d["cache_write"] as? Double, let cr = d["cache_read"] as? Double
                else { return nil }
                return Rate(input: i, output: o, cacheWrite: cw, cacheRead: cr)
            }
            func parseTable(_ key: String) -> [String: Rate] {
                var table: [String: Rate] = [:]
                if let m = obj[key] as? [String: [String: Any]] {
                    for (k, v) in m { if let r = parse(v) { table[k] = r } }
                }
                return table
            }
            let overrides = parseTable("models")
            // An override file predating this schema (or one that only adds a
            // model override without copying the full families table) must
            // not silently disable family-based pricing for every other
            // model — fill the gap from the built-in table instead.
            let familiesOnDisk = parseTable("families")
            let families = familiesOnDisk.isEmpty ? Pricing.builtinFamilies : familiesOnDisk
            let fb = parse(obj["default"] as? [String: Any]) ?? builtinFallback
            if !overrides.isEmpty || !familiesOnDisk.isEmpty { return (overrides, families, fb) }
        }
        return nil
    }
}
