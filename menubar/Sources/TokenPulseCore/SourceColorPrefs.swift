import Foundation

/// Whether the healthy zone paints green or stays the original label color.
enum GoodZoneStyle: String {
    case green
    case white
}

enum CursorAccountMode: String {
    case work
    case personal
}

enum ClaudeAccountMode: String {
    case work
    case personal
}

enum ChatGPTAccountMode: String {
    case work
    case personal
}

/// Per-source color configuration persisted under Options › Colors.
enum ColorSource: String, CaseIterable {
    case chatGPT
    case chatGPTWork
    case claude
    case claudePersonal
    case cursorWork
    case cursorPersonal
    case openAI
    case grokBot

    var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT personal"
        case .chatGPTWork: return "ChatGPT work"
        case .claude: return "Claude work"
        case .claudePersonal: return "Claude personal"
        case .cursorWork: return "Cursor work"
        case .cursorPersonal: return "Cursor personal"
        case .openAI: return "OpenAI API"
        case .grokBot: return "Grok Bot"
        }
    }
}

struct SpendUpColorConfig {
    /// nil means live fleet policy (Claude only).
    var redOverrideUSD: Double?
    var orangePercent: Double
    var yellowPercent: Double
    var goodStyle: GoodZoneStyle

    func effectiveCap(policyUSD: Double) -> Double {
        redOverrideUSD ?? policyUSD
    }

    func level(for usd: Double, policyUSD: Double) -> SpendTint {
        SpendTint.levelSpendUp(usd, cap: effectiveCap(policyUSD: policyUSD),
                               orangePercent: orangePercent, yellowPercent: yellowPercent)
    }

    /// Spend-up steps must satisfy `yellow < orange` (% of month cap).
    static func accepted(orange: Double, yellow: Double) -> (orange: Double, yellow: Double) {
        let w = min(max(orange.rounded(), 2), 99)
        return (w, min(max(yellow.rounded(), 1), w - 1))
    }

    static func applyingOrange(_ orange: Double, to cfg: (orange: Double, yellow: Double))
        -> (orange: Double, yellow: Double) {
        let w = min(max(orange.rounded(), 2), 99)
        var c = cfg.yellow
        if w <= c { c = max(1, w - 1) }
        return Self.accepted(orange: w, yellow: c)
    }

    static func applyingYellow(_ yellow: Double, to cfg: (orange: Double, yellow: Double))
        -> (orange: Double, yellow: Double) {
        let c = min(max(yellow.rounded(), 1), 98)
        var w = cfg.orange
        if c >= w { w = min(99, c + 1) }
        return Self.accepted(orange: w, yellow: c)
    }
}

struct RemainingColorConfig {
    var red: Double
    var orange: Double
    var yellow: Double
    var goodStyle: GoodZoneStyle

    var isEnabled: Bool { red > 0 || orange > 0 || yellow > 0 }

    func level(for remaining: Double) -> SpendTint {
        SpendTint.levelRemainingDown(remaining, red: red, orange: orange, yellow: yellow)
    }

    /// Remaining-% thresholds must satisfy `red < orange < yellow` (lower
    /// remaining is worse). Unlike spend-up percents, orange is not above yellow.
    static func accepted(red: Double, orange: Double, yellow: Double)
        -> (red: Double, orange: Double, yellow: Double) {
        let r = min(max(red.rounded(), 0), 97)
        var o = min(max(orange.rounded(), 1), 98)
        var y = min(max(yellow.rounded(), 2), 99)
        if o <= r { o = min(r + 1, 98) }
        if y <= o { y = min(o + 1, 99) }
        return (r, o, y)
    }

    /// Apply a new orange step; widen yellow upward if needed.
    static func applyingOrange(_ orange: Double, to cfg: (red: Double, orange: Double, yellow: Double))
        -> (red: Double, orange: Double, yellow: Double) {
        let o = min(max(orange.rounded(), 1), 98)
        var r = cfg.red
        var y = cfg.yellow
        if o <= r { r = max(0, o - 1) }
        if y <= o { y = min(99, o + 1) }
        return accepted(red: r, orange: o, yellow: y)
    }

    /// Apply a new yellow step; pull orange downward if needed.
    static func applyingYellow(_ yellow: Double, to cfg: (red: Double, orange: Double, yellow: Double))
        -> (red: Double, orange: Double, yellow: Double) {
        let y = min(max(yellow.rounded(), 2), 99)
        var r = cfg.red
        var o = cfg.orange
        if y <= o { o = max(r + 1, y - 1) }
        if o <= r { r = max(0, o - 1) }
        return accepted(red: r, orange: o, yellow: y)
    }

    /// Apply a new red step; pull orange/yellow upward if needed.
    static func applyingRed(_ red: Double, to cfg: (red: Double, orange: Double, yellow: Double))
        -> (red: Double, orange: Double, yellow: Double) {
        let r = min(max(red.rounded(), 0), 97)
        var o = cfg.orange
        var y = cfg.yellow
        if r >= o { o = min(98, r + 1) }
        if o >= y { y = min(99, o + 1) }
        return accepted(red: r, orange: o, yellow: y)
    }
}

extension Prefs {
    // MARK: - ChatGPT account

    private static let chatGPTAccountModeKey = "chatGPTAccountMode"

    static var chatGPTAccountMode: ChatGPTAccountMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: chatGPTAccountModeKey),
                  let mode = ChatGPTAccountMode(rawValue: raw) else { return .personal }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: chatGPTAccountModeKey) }
    }

    static var chatGPTIsPersonal: Bool { chatGPTAccountMode == .personal }

    // MARK: - Claude account

    private static let claudeAccountModeKey = "claudeAccountMode"

    static var claudeAccountMode: ClaudeAccountMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: claudeAccountModeKey),
                  let mode = ClaudeAccountMode(rawValue: raw) else { return .work }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: claudeAccountModeKey) }
    }

    static var claudeIsPersonal: Bool { claudeAccountMode == .personal }

    // MARK: - Cursor account

    private static let cursorAccountModeKey = "cursorAccountMode"
    private static let cursorPersonalAllowanceKey = "cursorPersonalAllowanceUSD"

    static var cursorAccountMode: CursorAccountMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: cursorAccountModeKey),
                  let mode = CursorAccountMode(rawValue: raw) else { return .work }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cursorAccountModeKey) }
    }

    static var cursorPersonalAllowanceUSD: Double {
        get {
            let v = numberPref(cursorPersonalAllowanceKey, default: 20)
            return v > 0 ? v : 20
        }
        set { UserDefaults.standard.set(max(0.01, newValue), forKey: cursorPersonalAllowanceKey) }
    }

    static var cursorIsPersonal: Bool { cursorAccountMode == .personal }

    // MARK: - Per-source colors

    static let spendOrangePercentDefault: Double = 75
    static let spendYellowPercentDefault: Double = 50
    static let remainingYellowDefault: Double = 50
    static let remainingOrangeDefault: Double = 25
    static let remainingRedDefault: Double = 10
    static let openAIRedDefault: Double = 5
    static let openAIOrangeDefault: Double = 20
    static let openAIYellowDefault: Double = 50

    static func chatGPTColors() -> RemainingColorConfig {
        remainingConfig(prefix: "chatGPT",
                        redDefault: remainingRedDefault,
                        orangeDefault: remainingOrangeDefault,
                        yellowDefault: remainingYellowDefault)
    }

    static func chatGPTWorkColors() -> SpendUpColorConfig {
        spendUpConfig(prefix: "chatGPTWork",
                      policyUSD: ChatGPTWorkUsageSnapshot.proPlanMonthlyUSD,
                      usePolicyDefault: false)
    }

    static func openAIColors() -> RemainingColorConfig {
        remainingConfig(prefix: "openAI",
                        redDefault: openAIRedDefault,
                        orangeDefault: openAIOrangeDefault,
                        yellowDefault: openAIYellowDefault)
    }

    static func cursorPersonalColors() -> RemainingColorConfig {
        remainingConfig(prefix: "cursorPersonal",
                        redDefault: remainingRedDefault,
                        orangeDefault: remainingOrangeDefault,
                        yellowDefault: remainingYellowDefault)
    }

    static func claudePersonalColors() -> RemainingColorConfig {
        remainingConfig(prefix: "claudePersonal",
                        redDefault: remainingRedDefault,
                        orangeDefault: remainingOrangeDefault,
                        yellowDefault: remainingYellowDefault)
    }

    static func grokBotColors() -> RemainingColorConfig {
        remainingConfig(prefix: "grokBot",
                        redDefault: remainingRedDefault,
                        orangeDefault: remainingOrangeDefault,
                        yellowDefault: remainingYellowDefault)
    }

    static func claudeColors(policyUSD: Double) -> SpendUpColorConfig {
        spendUpConfig(prefix: "claude", policyUSD: policyUSD, usePolicyDefault: true)
    }

    static func cursorWorkColors(policyUSD: Double) -> SpendUpColorConfig {
        spendUpConfig(prefix: "cursorWork", policyUSD: policyUSD, usePolicyDefault: false)
    }

    /// Every UserDefaults key the Options section writes: layout, per-source
    /// visibility, account modes, color thresholds, and the pre-per-source
    /// global keys. API credentials live in the Keychain, not here, so a reset
    /// never signs the user out of anything.
    static var ownedKeys: [String] {
        layoutKeys
            + [chatGPTAccountModeKey, claudeAccountModeKey,
               cursorAccountModeKey, cursorPersonalAllowanceKey]
            + ColorSource.allCases.flatMap(colorKeys(for:))
            + [legacySpendRedOverrideKey, legacyWarningPercentKey, legacyCautionPercentKey]
    }

    /// Return every Options setting to its first-launch value.
    static func resetToDefaults() {
        let d = UserDefaults.standard
        for key in ownedKeys { d.removeObject(forKey: key) }
    }

    static func resetColors(for source: ColorSource) {
        let d = UserDefaults.standard
        for key in colorKeys(for: source) { d.removeObject(forKey: key) }
    }

    private static func colorKeys(for source: ColorSource) -> [String] {
        switch source {
        case .chatGPT: return chatGPTColorKeys
        case .chatGPTWork: return chatGPTWorkColorKeys
        case .claude: return claudeColorKeys
        case .claudePersonal: return claudePersonalColorKeys
        case .cursorWork: return cursorWorkColorKeys
        case .cursorPersonal: return cursorPersonalColorKeys
        case .openAI: return openAIColorKeys
        case .grokBot: return grokBotColorKeys
        }
    }

    static func setGoodStyle(_ style: GoodZoneStyle, for source: ColorSource) {
        UserDefaults.standard.set(style.rawValue, forKey: goodStyleKey(source))
    }

    // MARK: - Remaining-down setters

    static func setRemainingRed(_ value: Double, for source: ColorSource) {
        let cfg = remainingValues(for: source)
        storeRemaining(source: source,
                       RemainingColorConfig.applyingRed(value, to: cfg))
    }

    static func setRemainingOrange(_ value: Double, for source: ColorSource) {
        let cfg = remainingValues(for: source)
        storeRemaining(source: source,
                       RemainingColorConfig.applyingOrange(value, to: cfg))
    }

    static func setRemainingYellow(_ value: Double, for source: ColorSource) {
        let cfg = remainingValues(for: source)
        storeRemaining(source: source,
                       RemainingColorConfig.applyingYellow(value, to: cfg))
    }

    static func disableRemainingTinting(for source: ColorSource) {
        let d = UserDefaults.standard
        d.set(0.0, forKey: redKey(source))
        d.set(0.0, forKey: orangeKey(source))
        d.set(0.0, forKey: yellowKey(source))
    }

    // MARK: - Spend-up setters

    static func setSpendRedOverride(_ value: Double?, for source: ColorSource) {
        let key = spendRedKey(source)
        guard let value else {
            return UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(max(0, value), forKey: key)
    }

    static func setSpendOrangePercent(_ value: Double, for source: ColorSource) {
        let cfg = spendValues(for: source)
        storeSpendPercents(source: source,
                           SpendUpColorConfig.applyingOrange(value, to: cfg))
    }

    static func setSpendYellowPercent(_ value: Double, for source: ColorSource) {
        let cfg = spendValues(for: source)
        storeSpendPercents(source: source,
                           SpendUpColorConfig.applyingYellow(value, to: cfg))
    }

    static func acceptedSpendPercents(warning: Double, caution: Double)
        -> (warning: Double, caution: Double) {
        let a = SpendUpColorConfig.accepted(orange: warning, yellow: caution)
        return (a.orange, a.yellow)
    }

    // MARK: - Legacy global keys (migration source only)

    private static let legacySpendRedOverrideKey = "spendRedOverrideUSD"
    private static let legacyWarningPercentKey = "spendWarningPercent"
    private static let legacyCautionPercentKey = "spendCautionPercent"

    static var spendRedOverrideUSD: Double? {
        get {
            (UserDefaults.standard.object(forKey: legacySpendRedOverrideKey) as? Double)
                .flatMap { $0 >= 0 ? $0 : nil }
        }
        set {
            guard let v = newValue, v >= 0 else {
                return UserDefaults.standard.removeObject(forKey: legacySpendRedOverrideKey)
            }
            UserDefaults.standard.set(v, forKey: legacySpendRedOverrideKey)
        }
    }

    static var warningPercent: Double {
        get { spendPercentsLegacy().warning }
        set {
            let w = min(max(newValue.rounded(), 2), 99)
            storeLegacySpend(warning: w, caution: min(spendPercentsLegacy().caution, w - 1))
        }
    }

    static var cautionPercent: Double {
        get { spendPercentsLegacy().caution }
        set {
            let c = min(max(newValue.rounded(), 1), 98)
            storeLegacySpend(warning: max(spendPercentsLegacy().warning, c + 1), caution: c)
        }
    }

    static let warningPercentDefault = spendOrangePercentDefault
    static let cautionPercentDefault = spendYellowPercentDefault

    static func resetSpendThresholds() {
        let d = UserDefaults.standard
        for key in [legacySpendRedOverrideKey, legacyWarningPercentKey, legacyCautionPercentKey] {
            d.removeObject(forKey: key)
        }
    }

    // MARK: - Private helpers

    private static func remainingConfig(prefix: String,
                                        redDefault: Double,
                                        orangeDefault: Double,
                                        yellowDefault: Double) -> RemainingColorConfig {
        let accepted = RemainingColorConfig.accepted(
            red: numberPref("\(prefix)RedRemaining", default: redDefault),
            orange: numberPref("\(prefix)OrangeRemaining", default: orangeDefault),
            yellow: numberPref("\(prefix)YellowRemaining", default: yellowDefault))
        return RemainingColorConfig(
            red: accepted.red, orange: accepted.orange, yellow: accepted.yellow,
            goodStyle: goodStylePref(prefix))
    }

    private static func spendUpConfig(prefix: String, policyUSD: Double,
                                      usePolicyDefault: Bool) -> SpendUpColorConfig {
        let migrated = migratedSpendIfNeeded(prefix: prefix)
        let redKey = "\(prefix)RedCapUSD"
        let orangeKey = "\(prefix)OrangePercent"
        let yellowKey = "\(prefix)YellowPercent"
        let redOverride: Double?
        if UserDefaults.standard.object(forKey: redKey) != nil {
            redOverride = (UserDefaults.standard.object(forKey: redKey) as? Double).map { max(0, $0) }
        } else if migrated {
            redOverride = spendRedOverrideUSD
        } else {
            redOverride = nil
        }
        let orange = numberPref(orangeKey,
                                default: migrated ? warningPercent : spendOrangePercentDefault)
        let yellow = numberPref(yellowKey,
                                default: migrated ? cautionPercent : spendYellowPercentDefault)
        let percents = SpendUpColorConfig.accepted(orange: orange, yellow: yellow)
        return SpendUpColorConfig(
            redOverrideUSD: redOverride,
            orangePercent: percents.orange,
            yellowPercent: percents.yellow,
            goodStyle: goodStylePref(prefix))
    }

    private static func migratedSpendIfNeeded(prefix: String) -> Bool {
        let flag = "\(prefix)MigratedFromLegacy"
        if UserDefaults.standard.bool(forKey: flag) { return false }
        guard prefix == "claude" || prefix == "cursorWork" else { return false }
        guard UserDefaults.standard.object(forKey: "\(prefix)RedCapUSD") == nil else { return false }
        let hasLegacy = UserDefaults.standard.object(forKey: legacySpendRedOverrideKey) != nil
            || UserDefaults.standard.object(forKey: legacyWarningPercentKey) != nil
            || UserDefaults.standard.object(forKey: legacyCautionPercentKey) != nil
        if hasLegacy {
            UserDefaults.standard.set(true, forKey: flag)
            return true
        }
        return false
    }

    private static func goodStylePref(_ prefix: String) -> GoodZoneStyle {
        guard let raw = UserDefaults.standard.string(forKey: "\(prefix)GoodStyle"),
              let style = GoodZoneStyle(rawValue: raw) else { return .green }
        return style
    }

    private static func goodStyleKey(_ source: ColorSource) -> String {
        switch source {
        case .chatGPT: return "chatGPTGoodStyle"
        case .chatGPTWork: return "chatGPTWorkGoodStyle"
        case .claude: return "claudeGoodStyle"
        case .claudePersonal: return "claudePersonalGoodStyle"
        case .cursorWork: return "cursorWorkGoodStyle"
        case .cursorPersonal: return "cursorPersonalGoodStyle"
        case .openAI: return "openAIGoodStyle"
        case .grokBot: return "grokBotGoodStyle"
        }
    }

    private static func redKey(_ source: ColorSource) -> String {
        switch source {
        case .chatGPT: return "chatGPTRedRemaining"
        case .claudePersonal: return "claudePersonalRedRemaining"
        case .cursorPersonal: return "cursorPersonalRedRemaining"
        case .openAI: return "openAIRedRemaining"
        case .grokBot: return "grokBotRedRemaining"
        default: return ""
        }
    }

    private static func orangeKey(_ source: ColorSource) -> String {
        switch source {
        case .chatGPT: return "chatGPTOrangeRemaining"
        case .claudePersonal: return "claudePersonalOrangeRemaining"
        case .cursorPersonal: return "cursorPersonalOrangeRemaining"
        case .openAI: return "openAIOrangeRemaining"
        case .grokBot: return "grokBotOrangeRemaining"
        default: return ""
        }
    }

    private static func yellowKey(_ source: ColorSource) -> String {
        switch source {
        case .chatGPT: return "chatGPTYellowRemaining"
        case .claudePersonal: return "claudePersonalYellowRemaining"
        case .cursorPersonal: return "cursorPersonalYellowRemaining"
        case .openAI: return "openAIYellowRemaining"
        case .grokBot: return "grokBotYellowRemaining"
        default: return ""
        }
    }

    private static func spendRedKey(_ source: ColorSource) -> String {
        switch source {
        case .chatGPTWork: return "chatGPTWorkRedCapUSD"
        case .claude: return "claudeRedCapUSD"
        case .cursorWork: return "cursorWorkRedCapUSD"
        default: return ""
        }
    }

    private static func remainingValues(for source: ColorSource)
        -> (red: Double, orange: Double, yellow: Double) {
        switch source {
        case .chatGPT:
            let c = chatGPTColors()
            return (c.red, c.orange, c.yellow)
        case .claudePersonal:
            let c = claudePersonalColors()
            return (c.red, c.orange, c.yellow)
        case .cursorPersonal:
            let c = cursorPersonalColors()
            return (c.red, c.orange, c.yellow)
        case .openAI:
            let c = openAIColors()
            return (c.red, c.orange, c.yellow)
        case .grokBot:
            let c = grokBotColors()
            return (c.red, c.orange, c.yellow)
        default:
            return (0, 0, 0)
        }
    }

    private static func storeRemaining(source: ColorSource,
                                       _ accepted: (red: Double, orange: Double, yellow: Double)) {
        let d = UserDefaults.standard
        d.set(accepted.red, forKey: redKey(source))
        d.set(accepted.orange, forKey: orangeKey(source))
        d.set(accepted.yellow, forKey: yellowKey(source))
    }

    private static func spendValues(for source: ColorSource)
        -> (orange: Double, yellow: Double) {
        switch source {
        case .chatGPTWork:
            let c = chatGPTWorkColors()
            return (c.orangePercent, c.yellowPercent)
        case .claude:
            let c = claudeColors(policyUSD: Config().spendRedUSD)
            return (c.orangePercent, c.yellowPercent)
        case .cursorWork:
            let c = cursorWorkColors(policyUSD: Config().spendRedUSD)
            return (c.orangePercent, c.yellowPercent)
        default:
            return (spendOrangePercentDefault, spendYellowPercentDefault)
        }
    }

    private static func storeSpendPercents(source: ColorSource,
                                           _ accepted: (orange: Double, yellow: Double)) {
        let d = UserDefaults.standard
        switch source {
        case .chatGPTWork:
            d.set(accepted.orange, forKey: "chatGPTWorkOrangePercent")
            d.set(accepted.yellow, forKey: "chatGPTWorkYellowPercent")
        case .claude:
            d.set(accepted.orange, forKey: "claudeOrangePercent")
            d.set(accepted.yellow, forKey: "claudeYellowPercent")
        case .cursorWork:
            d.set(accepted.orange, forKey: "cursorWorkOrangePercent")
            d.set(accepted.yellow, forKey: "cursorWorkYellowPercent")
        default:
            break
        }
    }

    private static func spendPercentsLegacy()
        -> (warning: Double, caution: Double) {
        acceptedSpendPercents(
            warning: numberPref(legacyWarningPercentKey, default: spendOrangePercentDefault),
            caution: numberPref(legacyCautionPercentKey, default: spendYellowPercentDefault))
    }

    private static func storeLegacySpend(warning: Double, caution: Double) {
        let d = UserDefaults.standard
        d.set(warning, forKey: legacyWarningPercentKey)
        d.set(caution, forKey: legacyCautionPercentKey)
    }

    private static var chatGPTColorKeys: [String] {
        ["chatGPTRedRemaining", "chatGPTOrangeRemaining", "chatGPTYellowRemaining", "chatGPTGoodStyle"]
    }
    private static var chatGPTWorkColorKeys: [String] {
        ["chatGPTWorkRedCapUSD", "chatGPTWorkOrangePercent",
         "chatGPTWorkYellowPercent", "chatGPTWorkGoodStyle"]
    }
    private static var claudeColorKeys: [String] {
        ["claudeRedCapUSD", "claudeOrangePercent", "claudeYellowPercent", "claudeGoodStyle", "claudeMigratedFromLegacy"]
    }
    private static var claudePersonalColorKeys: [String] {
        ["claudePersonalRedRemaining", "claudePersonalOrangeRemaining",
         "claudePersonalYellowRemaining", "claudePersonalGoodStyle"]
    }
    private static var cursorWorkColorKeys: [String] {
        ["cursorWorkRedCapUSD", "cursorWorkOrangePercent", "cursorWorkYellowPercent",
         "cursorWorkGoodStyle", "cursorWorkMigratedFromLegacy"]
    }
    private static var cursorPersonalColorKeys: [String] {
        ["cursorPersonalRedRemaining", "cursorPersonalOrangeRemaining",
         "cursorPersonalYellowRemaining", "cursorPersonalGoodStyle"]
    }
    private static var openAIColorKeys: [String] {
        ["openAIRedRemaining", "openAIOrangeRemaining", "openAIYellowRemaining", "openAIGoodStyle"]
    }
    private static var grokBotColorKeys: [String] {
        ["grokBotRedRemaining", "grokBotOrangeRemaining",
         "grokBotYellowRemaining", "grokBotGoodStyle"]
    }

    fileprivate static func numberPref(_ key: String, default fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
}
