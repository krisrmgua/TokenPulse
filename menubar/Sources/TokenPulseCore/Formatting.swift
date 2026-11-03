import Foundation

enum Fmt {
    /// Compact dollars: $0.84, $12, $1.2k, $750k.
    static func money(_ v: Double) -> String {
        let a = abs(v)
        switch a {
        case 0..<10:      return String(format: "$%.2f", v)
        case 10..<1_000:  return String(format: "$%.0f", v)
        case 1_000..<1_000_000:
            return String(format: "$%.1fk", v / 1_000)
        default:
            return String(format: "$%.1fM", v / 1_000_000)
        }
    }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    /// Exact whole dollars with a thousands separator: $1,500. For thresholds,
    /// where `money`'s "$1.5k" rounding would hide what was actually set.
    static func exactMoney(_ v: Double) -> String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.maximumFractionDigits = v == v.rounded() ? 0 : 2
        return "$" + (n.string(from: v as NSNumber) ?? String(format: "%.0f", v))
    }

    /// Workspace credits with separators and useful sub-credit precision.
    static func credits(_ v: Double) -> String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.minimumFractionDigits = 0
        n.maximumFractionDigits = 3
        return n.string(from: v as NSNumber) ?? String(format: "%.3f", v)
    }

    /// Compact token counts: 940, 44k, 668k, 1.2M.
    static func tokens(_ v: Double) -> String {
        switch abs(v) {
        case 0..<1_000:        return String(format: "%.0f", v)
        case 1_000..<1_000_000: return String(format: "%.0fk", v / 1_000)
        default:                return String(format: "%.1fM", v / 1_000_000)
        }
    }

    /// Short display name for a model ID from either source: local transcripts
    /// ("claude-sonnet-5") or the LLM-proxy's fully-qualified Bedrock ID
    /// ("bedrock/global.anthropic.claude-sonnet-5") — both become "sonnet-5".
    /// Strips a recognized "global.<vendor>." prefix rather than splitting on
    /// every "." — a blind last-dot split mangles model names that contain a
    /// literal "." of their own, like "gpt-5.4" or "gpt-5.6-luna".
    static func shortModel(_ model: String) -> String {
        let afterSlash = model.split(separator: "/").last.map(String.init) ?? model
        let deprefixed = afterSlash.range(of: #"^global\.(anthropic|openai)\."#, options: .regularExpression)
            .map { String(afterSlash[$0.upperBound...]) } ?? afterSlash
        return deprefixed.replacingOccurrences(of: "claude-", with: "")
    }
}
