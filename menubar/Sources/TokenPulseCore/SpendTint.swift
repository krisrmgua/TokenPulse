import AppKit

/// How hot a figure is relative to per-source thresholds. `.good` is the
/// healthy zone; `.normal` means tinting is off for this value.
enum SpendTint {
    case normal
    case good
    case caution
    case warning
    case over

    /// Spend rises toward the cap: green below yellow, then yellow, orange, red.
    static func levelSpendUp(_ usd: Double, cap: Double,
                             orangePercent: Double, yellowPercent: Double) -> SpendTint {
        guard cap > 0 else { return .normal }
        let orangeAt = cap * orangePercent / 100
        let yellowAt = cap * yellowPercent / 100
        if usd >= cap { return .over }
        if usd >= orangeAt { return .warning }
        if usd >= yellowAt { return .caution }
        return .good
    }

    /// Remaining falls toward zero: green above yellow, then yellow, orange, red.
    static func levelRemainingDown(_ remaining: Double,
                                   red: Double, orange: Double, yellow: Double) -> SpendTint {
        guard red > 0 || orange > 0 || yellow > 0 else { return .normal }
        if remaining <= red { return .over }
        if remaining <= orange { return .warning }
        if remaining <= yellow { return .caution }
        return .good
    }

    /// Day-scale equivalent of the month cap: a whole month spent at this daily
    /// rate lands exactly on `cap`, so day figures can use the same three steps
    /// without a second threshold to configure.
    static func dailyCap(_ cap: Double, now: Date = Date()) -> Double {
        let days = Calendar.current.range(of: .day, in: .month, for: now)?.count ?? 30
        return cap / Double(days)
    }

    /// Dropdown color. Red / orange / yellow are max-chroma hex so they read
    /// the same in both appearances. Green still follows the appearance.
    func menuColor(goodStyle: GoodZoneStyle = .green) -> NSColor? {
        switch self {
        case .normal:  return nil
        case .good:    return goodStyle == .green
            ? Self.themed(light: Self.forestGreen, dark: .systemGreen) : nil
        case .caution: return BrightSpendColor.yellow
        case .warning: return BrightSpendColor.orange
        case .over:    return BrightSpendColor.red
        }
    }

    /// Menu-bar color. Either palette is fixed rather than appearance-following:
    /// the bar's appearance flips with whatever window happens to sit behind it,
    /// so following it makes the figures change shade as the user switches
    /// windows. Pastel defaults on; toggle it under Options.
    func barColor(goodStyle: GoodZoneStyle = .green) -> NSColor? {
        let pastel = Prefs.pastelBarColors
        switch self {
        case .normal:  return nil
        case .good:
            guard goodStyle == .green else { return nil }
            return pastel ? SpendPalette.green : MenuBarPalette.green
        case .caution: return pastel ? SpendPalette.yellow : MenuBarPalette.yellow
        case .warning: return pastel ? SpendPalette.orange : MenuBarPalette.orange
        case .over:    return pastel ? SpendPalette.red : MenuBarPalette.red
        }
    }

    /// The system yellow/orange washes out on a light menu background, so
    /// light mode gets darker variants.
    private static func themed(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static let forestGreen = NSColor(srgbRed: 0.10, green: 0.55, blue: 0.18, alpha: 1)
}

/// Max-chroma sRGB for the three hot levels: #FF0000, #FF8000, #FFFF00.
enum BrightSpendColor {
    static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let orange = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
    static let yellow = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
}

/// Optional pastel tints for the menu bar, for bars where the saturated system
/// colors read as heavy over the window content behind them. Fixed sRGB, so
/// these never shift with the appearance.
enum SpendPalette {
    static let yellow = NSColor(srgbRed: 1.00, green: 0.98, blue: 0.72, alpha: 1)
    static let orange = NSColor(srgbRed: 1.00, green: 0.89, blue: 0.72, alpha: 1)
    static let red = NSColor(srgbRed: 1.00, green: 0.76, blue: 0.75, alpha: 1)
    static let green = NSColor(srgbRed: 0.78, green: 0.96, blue: 0.78, alpha: 1)
}

/// Fixed menu-bar text colors: every dynamic NSColor resolved once against the
/// dark appearance. Text attachments bake their color anyway, and pinning the
/// text runs to match keeps the whole item looking identical no matter which
/// window is frontmost.
enum MenuBarPalette {
    static let label = pinned(.labelColor)
    static let secondaryLabel = pinned(.secondaryLabelColor)
    static let yellow = BrightSpendColor.yellow
    static let orange = BrightSpendColor.orange
    static let red = BrightSpendColor.red
    static let green = pinned(.systemGreen)

    private static func pinned(_ color: NSColor) -> NSColor {
        var out = color
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }
}

/// Row text with each tinted substring recolored. Shared by the live menu, the
/// submenu titles, and the offscreen preview so all three agree.
enum MenuText {
    /// `colorsEnabled` is passed explicitly by tests; production reads the pref.
    static func attributed(_ s: String, font: NSFont, tints: [MoneyTint],
                           colorsEnabled: Bool = Prefs.spendColorsEnabled) -> NSAttributedString {
        let attr = NSMutableAttributedString(
            string: s, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        guard colorsEnabled else { return attr }
        for t in tints {
            guard let color = t.tint.menuColor(goodStyle: t.goodStyle),
                  let range = t.range(in: s) else { continue }
            attr.addAttribute(.foregroundColor, value: color, range: range)
        }
        return attr
    }
}

/// Percent remaining for personal Cursor Pro. Prefer GetCurrentPeriodUsage
/// (matches Cursor's own "% of included usage"); fall back to allowance − spend.
func cursorPersonalRemainingPercent(cursor: CursorSpendSnapshot,
                                    allowanceUSD: Double) -> Int {
    if let plan = cursor.planUsage {
        return plan.percentLeft
    }
    return cursorPersonalRemainingPercent(
        monthSpendUSD: cursor.totalSpendUSD, allowanceUSD: allowanceUSD)
}

/// Legacy fallback when GetCurrentPeriodUsage is unavailable.
func cursorPersonalRemainingPercent(monthSpendUSD: Double, allowanceUSD: Double) -> Int {
    guard allowanceUSD > 0 else { return 0 }
    let remaining = max(0, allowanceUSD - monthSpendUSD)
    return Int(max(0, min(100, (remaining / allowanceUSD * 100).rounded())))
}
