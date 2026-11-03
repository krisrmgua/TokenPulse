import Foundation

enum PresentationMode: String {
    case combined
    case perSource
}

/// Work-mode sources that paint `D` day and `M` month figures in the menu bar.
enum BarSpendSource: String, CaseIterable {
    case chatGPTWork
    case cursorWork
    case claudeWork

    var dailyKey: String { rawValue + "ShowDailyInBar" }
    var monthlyKey: String { rawValue + "ShowMonthlyInBar" }
}

/// Deployment config. In production this is overridden by a Jamf-managed
/// plist so thresholds can change without a rebuild (see load()).
struct Config {
    /// Opus alert fires when opus_cost / total_cost exceeds this (share of $).
    var opusAlertShare: Double = 0.20

    /// How often to rescan transcripts.
    var pollInterval: TimeInterval = 10

    /// Shared poll + client throttle for remote spend sources (optional spend proxy,
    /// Cursor Dashboard, and OpenAI Costs). Kept in lockstep so all endpoints get the same
    /// courtesy interval — overridable via Jamf without a rebuild.
    var remotePollInterval: TimeInterval = 5 * 60

    /// Floor/ceiling for Jamf `remotePollInterval` (seconds). Reject values
    /// outside this range so a bad profile can't schedule sub-second timers
    /// (CPU/network DoS) or disable remote refresh indefinitely.
    static let remotePollIntervalMin: TimeInterval = 60
    static let remotePollIntervalMax: TimeInterval = 3600

    /// Efficiency score, gamification, and the Scoreboard window are off by
    /// default — spend monitoring stands alone until this is explicitly enabled.
    var showEfficiencyDetails: Bool = false

    /// Month spend that paints a figure red; 75% of it is orange and 50% is
    /// yellow (see SpendTint). Set to 0 to turn color coding off entirely.
    var spendRedUSD: Double = 1500

    /// Claude spend red cap when the user picks "Use policy default" in Options.
    var effectiveSpendRedUSD: Double {
        Prefs.claudeColors(policyUSD: spendRedUSD).effectiveCap(policyUSD: spendRedUSD)
    }

    /// Accept only sane remote poll intervals; nil means keep the default.
    static func acceptedRemotePollInterval(_ r: TimeInterval) -> TimeInterval? {
        (r >= remotePollIntervalMin && r <= remotePollIntervalMax) ? r : nil
    }

    /// Load overrides from the Jamf-managed plist if present; otherwise defaults.
    /// Path is the standard managed-preferences location so a config profile can
    /// push threshold changes fleet-wide.
    static func load() -> Config {
        var cfg = Config()
        let path = "/Library/Managed Preferences/com.kris.tokenpulse.plist"
        guard let dict = NSDictionary(contentsOfFile: path) else { return cfg }
        if let o = dict["opusAlertShare"] as? Double { cfg.opusAlertShare = o }
        if let e = dict["showEfficiencyDetails"] as? Bool { cfg.showEfficiencyDetails = e }
        if let s = dict["spendRedUSD"] as? Double, s >= 0 { cfg.spendRedUSD = s }
        if let r = dict["remotePollInterval"] as? Double,
           let accepted = acceptedRemotePollInterval(r) {
            cfg.remotePollInterval = accepted
        }
        return cfg
    }
}

/// Per-user UI toggles from the dropdown's Options section, persisted in
/// UserDefaults. Separate from Config, which is fleet policy pushed by Jamf and
/// must not be overwritten by a click.
/// Defaults come from the getters rather than `register(defaults:)` so a read
/// can't depend on registration having run first.
/// Point sizes for what the menu bar draws.
struct BarSizes: Equatable {
    let money: CGFloat
    let label: CGFloat
    let icon: CGFloat    // app icons, such as ChatGPT and Grok Bot
    let symbol: CGFloat  // SF Symbols
    /// Crop transparent padding from app icons, so the visible mark fills `icon` points.
    let trimIcons: Bool

    static let standard = BarSizes(money: 11, label: 10, icon: 13, symbol: 11, trimIcons: false)
    /// Matches Tickr's look: 12-point text and marks that really are 14 points. Labels match the
    /// numbers, and trimming matters because app icons only fill about 80% of their image.
    static let increased = BarSizes(money: 12, label: 12, icon: 14, symbol: 12, trimIcons: true)
}

enum Prefs {
    static var notificationsEnabled: Bool {
        get { boolPref("notificationsEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }
    static var allowanceAlertsEnabled: Bool {
        get { boolPref("allowanceAlertsEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "allowanceAlertsEnabled") }
    }
    static var opusAlertsEnabled: Bool {
        get { boolPref("opusAlertsEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "opusAlertsEnabled") }
    }
    static var notificationSounds: Bool {
        get { boolPref("notificationSounds", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "notificationSounds") }
    }
    static var alertThresholds: [Int] {
        get { (UserDefaults.standard.array(forKey: "alertThresholds") as? [Int]).flatMap { AllowanceAlertLedger.parseThresholds($0.map(String.init).joined(separator: ",")) } ?? [15,10,5] }
        set { UserDefaults.standard.set(newValue, forKey: "alertThresholds") }
    }
    static var disabledAlertThresholds: [Int] {
        get { UserDefaults.standard.array(forKey: "disabledAlertThresholds") as? [Int] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "disabledAlertThresholds") }
    }
    static var activeAlertThresholds: [Int] { alertThresholds.filter { !disabledAlertThresholds.contains($0) } }
    static var statusBarDesign: StatusBarDesign {
        get { UserDefaults.standard.string(forKey: "statusBarDesign").flatMap(StatusBarDesign.init(rawValue:)) ?? .divider }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "statusBarDesign") }
    }
    static var themedProviderLogos: Bool {
        get { boolPref("themedProviderLogos", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "themedProviderLogos") }
    }
    /// Off returns the panel to the overview each time it opens.
    static var rememberPanelPlace: Bool {
        get { boolPref("rememberPanelPlace", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "rememberPanelPlace") }
    }
    private static let presentationModeKey = "presentationMode"
    private static let usageRefreshMinutesKey = "usageRefreshMinutes"
    static let usageRefreshChoices = [1, 2, 3, 5, 10, 15, 30]
    private static let spendColorsEnabledKey = "spendColorsEnabled"
    private static let darkBarBackgroundKey = "darkMenuBarBackground"
    private static let pastelBarColorsKey = "pastelMenuBarColors"
    /// Stored under the option's original name, so existing choices are kept.
    private static let increaseBarSizeKey = "matchTickrMenuBarSize"
    private static let showClaudeInBarKey = "showClaudeInMenuBar"
    private static let showCursorInBarKey = "showCursorInMenuBar"
    private static let showChatGPTInBarKey = "showChatGPTInMenuBar"
    private static let showOpenAIInBarKey = "showOpenAIInMenuBar"
    private static let showGrokBotInBarKey = "showGrokBotInMenuBar"
    private static let enabledClaudeKey = "enabledClaude"
    private static let enabledCursorKey = "enabledCursor"
    private static let enabledChatGPTKey = "enabledChatGPT"
    private static let enabledOpenAIKey = "enabledOpenAI"
    private static let enabledGrokBotKey = "enabledGrokBot"

    /// The menu bar is always per source. A saved combined-total choice is
    /// rewritten so an old setting cannot hide personal allowances.
    static var presentationMode: PresentationMode {
        get { .perSource }
        set { UserDefaults.standard.set(PresentationMode.perSource.rawValue, forKey: presentationModeKey) }
    }

    /// How often remote usage is checked. One minute unless a listed choice is saved.
    static var usageRefreshMinutes: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: usageRefreshMinutesKey)
            return usageRefreshChoices.contains(stored) ? stored : 1
        }
        set {
            let minutes = usageRefreshChoices.contains(newValue) ? newValue : 1
            UserDefaults.standard.set(minutes, forKey: usageRefreshMinutesKey)
        }
    }

    static var usageRefreshInterval: TimeInterval { TimeInterval(usageRefreshMinutes * 60) }

    static func retireCombinedPresentation() {
        guard UserDefaults.standard.string(forKey: presentationModeKey) == PresentationMode.combined.rawValue else { return }
        UserDefaults.standard.set(PresentationMode.perSource.rawValue, forKey: presentationModeKey)
    }

    /// Master switch for spend tinting in both the menu bar and the dropdown.
    /// Off by default: the original app painted every figure in the label color,
    /// and thresholds are a per-user judgement call rather than a fleet default.
    static var spendColorsEnabled: Bool {
        get { boolPref(spendColorsEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: spendColorsEnabledKey) }
    }

    /// New installs use the capsule backdrop; saved user choices are preserved.
    static var darkBarBackground: Bool {
        get { boolPref(darkBarBackgroundKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: darkBarBackgroundKey) }
    }

    /// Pastel spend tints in the menu bar instead of the full-strength system
    /// colors. Off by default.
    static var pastelBarColors: Bool {
        get { boolPref(pastelBarColorsKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: pastelBarColorsKey) }
    }

    /// Larger menu-bar text and icons (always on).
    static let increaseBarSize = true

    static var barSizes: BarSizes { .increased }

    /// Per-source visibility across both the menu-bar title and dropdown.
    static var showClaudeInBar: Bool {
        get { boolPref(showClaudeInBarKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: showClaudeInBarKey) }
    }

    static var showCursorInBar: Bool {
        get { boolPref(showCursorInBarKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: showCursorInBarKey) }
    }

    /// ChatGPT's weekly subscription allowance is not spend. Off by default;
    /// enable under Options › ChatGPT › Show.
    static var showChatGPTInBar: Bool {
        get { boolPref(showChatGPTInBarKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: showChatGPTInBarKey) }
    }

    /// Off by default; enable under Options › OpenAI API › Show.
    static var showOpenAIInBar: Bool {
        get { boolPref(showOpenAIInBarKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: showOpenAIInBarKey) }
    }

    /// Grok Bot weekly Sand usage (% remaining). Off by default; needs Cursor
    /// signed in. Enable under Options › Grok Bot › Show.
    static var showGrokBotInBar: Bool {
        get { boolPref(showGrokBotInBarKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: showGrokBotInBarKey) }
    }

    /// Enable turns a source on or off completely: no fetching, no dropdown rows, no bar.
    /// Claude and Cursor are on by default; the others stay off until enabled.
    static var enabledClaude: Bool {
        get { boolPref(enabledClaudeKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: enabledClaudeKey) }
    }

    static var enabledCursor: Bool {
        get { boolPref(enabledCursorKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: enabledCursorKey) }
    }

    static var enabledChatGPT: Bool {
        // Defaults to the old Show setting, so existing menus keep what they had.
        get { boolPref(enabledChatGPTKey, default: boolPref(showChatGPTInBarKey, default: false)) }
        set { UserDefaults.standard.set(newValue, forKey: enabledChatGPTKey) }
    }

    static var enabledOpenAI: Bool {
        // Defaults to the old Show setting, so existing menus keep what they had.
        get { boolPref(enabledOpenAIKey, default: boolPref(showOpenAIInBarKey, default: false)) }
        set { UserDefaults.standard.set(newValue, forKey: enabledOpenAIKey) }
    }

    static var enabledGrokBot: Bool {
        // Defaults to the old Show setting, so existing menus keep what they had.
        get { boolPref(enabledGrokBotKey, default: boolPref(showGrokBotInBarKey, default: false)) }
        set { UserDefaults.standard.set(newValue, forKey: enabledGrokBotKey) }
    }

    /// Menu-bar figures need the source enabled AND shown in the menu.
    static var includeClaudeInBar: Bool { enabledClaude && showClaudeInBar }
    static var includeCursorInBar: Bool { enabledCursor && showCursorInBar }
    static var includeOpenAIInBar: Bool { enabledOpenAI && showOpenAIInBar }
    static var includeGrokBotInBar: Bool { enabledGrokBot && showGrokBotInBar }

    /// Per-source D/M menu-bar figures. Both on by default; at least one stays on.
    static func showDailyInBar(for source: BarSpendSource) -> Bool {
        boolPref(source.dailyKey, default: true)
    }

    static func showMonthlyInBar(for source: BarSpendSource) -> Bool {
        boolPref(source.monthlyKey, default: true)
    }

    static func setShowDailyInBar(_ on: Bool, for source: BarSpendSource) {
        UserDefaults.standard.set(on, forKey: source.dailyKey)
        if !on && !showMonthlyInBar(for: source) {
            UserDefaults.standard.set(true, forKey: source.monthlyKey)
        }
    }

    static func setShowMonthlyInBar(_ on: Bool, for source: BarSpendSource) {
        UserDefaults.standard.set(on, forKey: source.monthlyKey)
        if !on && !showDailyInBar(for: source) {
            UserDefaults.standard.set(true, forKey: source.dailyKey)
        }
    }

    /// Layout and visibility keys, for `resetToDefaults()`.
    static var layoutKeys: [String] {
        ["notificationsEnabled", "allowanceAlertsEnabled", "opusAlertsEnabled", "notificationSounds", "alertThresholds", "disabledAlertThresholds", "statusBarDesign", "themedProviderLogos", "rememberPanelPlace", presentationModeKey, usageRefreshMinutesKey, spendColorsEnabledKey, darkBarBackgroundKey, pastelBarColorsKey,
         increaseBarSizeKey, // legacy key cleared on reset; size is always increased now
         showClaudeInBarKey, showCursorInBarKey, showChatGPTInBarKey, showOpenAIInBarKey,
         showGrokBotInBarKey, enabledClaudeKey, enabledCursorKey, enabledChatGPTKey,
         enabledOpenAIKey, enabledGrokBotKey]
            + BarSpendSource.allCases.flatMap { [$0.dailyKey, $0.monthlyKey] }
    }

    private static func boolPref(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}
