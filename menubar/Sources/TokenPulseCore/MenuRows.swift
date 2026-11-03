import Foundation

/// A tinted substring inside a row (money, percent, etc.).
struct MoneyTint {
    let text: String
    let tint: SpendTint
    let goodStyle: GoodZoneStyle
    /// Start the search after this anchor. Needed because a row can show the
    /// same formatted amount twice ("Today $1.2k · Month $1.2k") and only the
    /// month figure is tinted.
    let after: String?

    init(_ text: String, _ tint: SpendTint,
         goodStyle: GoodZoneStyle = .green, after: String? = nil) {
        self.text = text
        self.tint = tint
        self.goodStyle = goodStyle
        self.after = after
    }

    func range(in s: String) -> NSRange? {
        let ns = s as NSString
        var start = 0
        if let after {
            let anchor = ns.range(of: after)
            guard anchor.location != NSNotFound else { return nil }
            start = anchor.location + anchor.length
        }
        let r = ns.range(of: text, range: NSRange(location: start, length: ns.length - start))
        return r.location == NSNotFound ? nil : r
    }
}

/// One line in the dropdown. Shared by the live menu (AppDelegate) and the
/// offscreen preview renderer, so both stay identical.
enum MenuRow {
    case header(String)
    case body(String, tints: [MoneyTint])
    case separator
    /// Collapsed by default — rendered as an NSMenu submenu in the live menu.
    /// `children` may themselves include nested `.submenu` rows.
    case submenu(title: String, titleTints: [MoneyTint], children: [MenuRow])
}

/// Untinted spellings, so the many plain rows stay a one-argument call.
extension MenuRow {
    static func body(_ s: String) -> MenuRow { .body(s, tints: []) }

    static func submenu(title: String, children: [MenuRow]) -> MenuRow {
        .submenu(title: title, titleTints: [], children: children)
    }
}

/// Linear month-end projection (same formula SpendStore uses for Claude).
func projectedMonthEnd(monthUSD: Double, now: Date = Date()) -> Double {
    let cal = Calendar.current
    let day = cal.component(.day, from: now)
    let days = cal.range(of: .day, in: .month, for: now)?.count ?? 30
    return day > 0 ? monthUSD * Double(days) / Double(day) : monthUSD
}

/// The user's source toggles apply to the entire menu presentation, not only
/// the compact status-bar title. Defaults match upstream: Cursor + Claude.
struct MenuSourceVisibility {
    var chatGPT = false
    var cursor = true
    var openAI = false
    var claude = true
    var grokBot = false
}

/// Dropdown facade. The menu is per source. Combined remains available for
/// the work-spend total, which does not add personal allowances.
func tokenpulseMenuRows(_ r: Rollup, _ eff: EfficiencyResult, _ config: Config,
                        cursor: CursorSpendSnapshot? = nil,
                        openAI: OpenAISpendSnapshot? = nil,
                        chatGPT: ChatGPTUsageSnapshot? = nil,
                        chatGPTWork: ChatGPTWorkUsageSnapshot? = nil,
                        claudeUsage: ClaudeUsageSnapshot? = nil,
                        grokBot: GrokBotUsageSnapshot? = nil,
                        chatGPTAccountMode: ChatGPTAccountMode = Prefs.chatGPTAccountMode,
                        cursorAccountMode: CursorAccountMode = Prefs.cursorAccountMode,
                        claudeAccountMode: ClaudeAccountMode = Prefs.claudeAccountMode,
                        visibility: MenuSourceVisibility = MenuSourceVisibility(),
                        presentation: PresentationMode = Prefs.presentationMode) -> [MenuRow] {
    let perSource = perSourceMenuRows(
        r, eff, config, cursor: cursor, openAI: openAI, chatGPT: chatGPT,
        chatGPTWork: chatGPTWork, claudeUsage: claudeUsage, grokBot: grokBot,
        chatGPTAccountMode: chatGPTAccountMode, cursorAccountMode: cursorAccountMode,
        claudeAccountMode: claudeAccountMode, visibility: visibility)
    guard presentation == .combined else { return perSource }

    let claudeIsWork = claudeAccountMode == .work && visibility.claude
    let cursorIsWork = cursorAccountMode == .work && visibility.cursor && cursor != nil
    let combinedToday = (claudeIsWork ? r.todayUSD : 0)
        + (cursorIsWork ? cursor?.todaySpendUSD ?? 0 : 0)
    let combinedMonth = (claudeIsWork ? r.monthUSD : 0)
        + (cursorIsWork ? cursor?.totalSpendUSD ?? 0 : 0)

    var rows: [MenuRow] = []
    if claudeIsWork || cursorIsWork {
        rows.append(.header("Your spend"))
        rows.append(.body(
            "  Today: \(Fmt.money(combinedToday))   ·   Month: \(Fmt.money(combinedMonth))"))
        rows.append(.body(
            "  Projected month-end: \(Fmt.money(projectedMonthEnd(monthUSD: combinedMonth)))"))
        rows.append(.separator)
    }

    // Keep the original provider order for the default view. Non-dollar
    // providers remain separate because percentages/balances cannot be summed.
    for prefix in ["Claude", "Cursor", "Grok Bot", "ChatGPT", "OpenAI API"] {
        if let row = perSource.first(where: {
            if case .submenu(let title, _, _) = $0 { return title.hasPrefix(prefix) }
            return false
        }) {
            rows.append(row)
        }
    }
    // Per-source rows after the provider submenus are the optional Efficiency
    // block; preserve it in combined mode as upstream did.
    rows.append(contentsOf: perSource.filter {
        if case .submenu = $0 { return false }
        return true
    })
    return rows
}

/// Provider-by-provider dropdown used by the opt-in per-source presentation.
private func perSourceMenuRows(
    _ r: Rollup, _ eff: EfficiencyResult, _ config: Config,
    cursor: CursorSpendSnapshot?,
    openAI: OpenAISpendSnapshot?,
    chatGPT: ChatGPTUsageSnapshot?,
    chatGPTWork: ChatGPTWorkUsageSnapshot?,
    claudeUsage: ClaudeUsageSnapshot?,
    grokBot: GrokBotUsageSnapshot?,
    chatGPTAccountMode: ChatGPTAccountMode,
    cursorAccountMode: CursorAccountMode,
    claudeAccountMode: ClaudeAccountMode,
    visibility: MenuSourceVisibility
) -> [MenuRow] {
    let visibleCursor = visibility.cursor ? cursor : nil
    let visibleOpenAI = visibility.openAI ? openAI : nil
    let cursorIsPersonal = cursorAccountMode == .personal
    let claudeIsPersonal = claudeAccountMode == .personal
    let claudeColors = Prefs.claudeColors(policyUSD: config.spendRedUSD)
    let claudeMonthTint = claudeColors.level(for: r.monthUSD, policyUSD: config.spendRedUSD)
    let chatGPTColors = Prefs.chatGPTColors()
    let chatGPTWorkColors = Prefs.chatGPTWorkColors()
    let openAIColors = Prefs.openAIColors()
    let cursorWorkColors = Prefs.cursorWorkColors(policyUSD: config.spendRedUSD)
    let cursorPersonalColors = Prefs.cursorPersonalColors()
    let claudePersonalColors = Prefs.claudePersonalColors()
    let grokBotColors = Prefs.grokBotColors()
    let allowance = Prefs.cursorPersonalAllowanceUSD

    var rows: [MenuRow] = []
    let claudeModels: [MenuRow] = r.byModelUSD.isEmpty
        ? [.body("(no usage)")]
        : r.byModelUSD.sorted(by: { $0.value > $1.value }).map {
            .body("\(Fmt.shortModel($0.key)): \(Fmt.money($0.value))")
        }

    if visibility.chatGPT, chatGPTAccountMode == .personal, let chatGPT {
        // Both Codex windows: the 5-hour limit first, then the weekly one.
        var title = "ChatGPT · "
        var titleTints: [MoneyTint] = []
        var children: [MenuRow] = []
        if let s = chatGPT.session {
            let text = "\(s.percentLeft)%"
            let tint = chatGPTColors.level(for: Double(s.percentLeft))
            title += "5H \(text) · "
            titleTints.append(MoneyTint(text, tint, goodStyle: chatGPTColors.goodStyle, after: "ChatGPT · 5H "))
            children.append(.body("5-hour limit: \(text) left, resets \(ChatGPTUsageParse.displayDate(s.resetAt))",
                                  tints: [MoneyTint(text, tint, goodStyle: chatGPTColors.goodStyle, after: "5-hour limit: ")]))
        }
        let weekly = "\(chatGPT.percentLeft)%"
        let weeklyTint = chatGPTColors.level(for: Double(chatGPT.percentLeft))
        title += "W \(weekly) left"
        titleTints.append(MoneyTint(weekly, weeklyTint, goodStyle: chatGPTColors.goodStyle, after: "W "))
        children.append(.body("Weekly limit: \(weekly) left, resets \(chatGPT.resetDescription)",
                              tints: [MoneyTint(weekly, weeklyTint, goodStyle: chatGPTColors.goodStyle, after: "Weekly limit: ")]))
        rows.append(.submenu(title: title, titleTints: titleTints, children: children))
    }

    if visibility.chatGPT, chatGPTAccountMode == .work, let work = chatGPTWork {
        let monthText = Fmt.money(work.estimatedUSD)
        let monthTint = chatGPTWorkColors.level(
            for: work.estimatedUSD,
            policyUSD: ChatGPTWorkUsageSnapshot.proPlanMonthlyUSD)
        let products: [MenuRow] = work.byProduct
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { MenuRow.body("\($0.key.capitalized): \(Fmt.credits($0.value)) credits") }
        var children: [MenuRow] = [
            .body(work.todayIsPending
                ? "Today: pending — ChatGPT has not aggregated today yet"
                : "Today: \(Fmt.credits(work.todayCredits)) credits · "
                    + "est. \(Fmt.money(work.todayEstimatedUSD))"),
            .body("Month: \(Fmt.credits(work.monthCredits)) credits · "
                + "est. \(monthText)",
                  tints: [MoneyTint(monthText, monthTint,
                                    goodStyle: chatGPTWorkColors.goodStyle,
                                    after: "Month: ")]),
            .body(String(format: "$200 Pro equivalent: %.2f months",
                         work.proPlanEquivalents)),
            .body(work.estimateUsesPublicRateCard
                ? "Estimate: public rate-card equivalent ($0.04/credit), not a bill"
                : "Estimate: workspace-provided planning value, not a bill"),
        ]
        if let freshness = work.dataFreshnessAt {
            children.append(.body("Data fresh through: \(ChatGPTUsageParse.displayDate(freshness))"))
        }
        if !products.isEmpty {
            children.append(.separator)
            children.append(.submenu(title: "By product", children: products))
        }
        rows.append(.submenu(
            title: "ChatGPT work · \(monthText) est.",
            titleTints: [MoneyTint(monthText, monthTint,
                                   goodStyle: chatGPTWorkColors.goodStyle,
                                   after: "ChatGPT work · ")],
            children: children))
    }

    if let cursor = visibleCursor {
        if cursorIsPersonal {
            let remaining = cursorPersonalRemainingPercent(
                cursor: cursor, allowanceUSD: allowance)
            let pctText = cursor.personalBarPercent(allowanceUSD: allowance)
            let pctTint = cursorPersonalColors.level(for: Double(remaining))
            let modelRows: [MenuRow] = cursor.byModel.isEmpty
                ? [.body("(no usage events)")]
                : cursor.byModel.map {
                    let tok = Double($0.inputTokens + $0.outputTokens
                        + $0.cacheReadTokens + $0.cacheWriteTokens)
                    return .body("\(Fmt.shortModel($0.model)): \(Fmt.tokens(tok)) tokens")
                }
            var children: [MenuRow] = [
                .body("Included usage: \(remaining)% left",
                      tints: [MoneyTint("\(remaining)%", pctTint,
                                        goodStyle: cursorPersonalColors.goodStyle,
                                        after: "Included usage: ")]),
            ]
            if let plan = cursor.planUsage {
                children.append(.body(
                    "Allowance: \(Fmt.exactMoney(plan.limitUSD)) · "
                        + "used \(Fmt.exactMoney(plan.includedSpendUSD)) · "
                        + "\(Int(plan.totalPercentUsed.rounded()))% consumed"))
                if let reset = plan.resetDescription {
                    children.append(.body("Resets: \(reset)"))
                }
            } else {
                children.append(.body("Allowance: \(Fmt.exactMoney(allowance))"))
            }
            children.append(.body("Token totals below are not your Pro bill"))
            children.append(.separator)
            children.append(.submenu(title: "By model", children: modelRows))
            rows.append(.submenu(
                title: "Cursor · \(pctText) left",
                titleTints: [MoneyTint(pctText, pctTint, goodStyle: cursorPersonalColors.goodStyle,
                                       after: "Cursor · ")],
                children: children))
        } else {
            let cursorMonthTint = cursorWorkColors.level(
                for: cursor.totalSpendUSD, policyUSD: config.spendRedUSD)
            let modelRows: [MenuRow] = cursor.byModel.isEmpty
                ? [.body("(no usage events)")]
                : cursor.byModel.map { .body("\(Fmt.shortModel($0.model)): \(Fmt.money($0.spendUSD))") }
            rows.append(.submenu(
                title: "Cursor · Today \(Fmt.money(cursor.todaySpendUSD)) · Month \(Fmt.money(cursor.totalSpendUSD))",
                titleTints: [MoneyTint(Fmt.money(cursor.totalSpendUSD), cursorMonthTint,
                                       goodStyle: cursorWorkColors.goodStyle, after: "Month ")],
                children: [
                    .body("Today: \(Fmt.money(cursor.todaySpendUSD))",
                          tints: [MoneyTint(Fmt.money(cursor.todaySpendUSD),
                                            cursorWorkColors.level(for: cursor.todaySpendUSD,
                                                                   policyUSD: config.spendRedUSD),
                                            goodStyle: cursorWorkColors.goodStyle, after: "Today: ")]),
                    .body("Month: \(Fmt.money(cursor.totalSpendUSD))",
                          tints: [MoneyTint(Fmt.money(cursor.totalSpendUSD), cursorMonthTint,
                                            goodStyle: cursorWorkColors.goodStyle, after: "Month: ")]),
                    .body("Projected month-end: \(Fmt.money(projectedMonthEnd(monthUSD: cursor.totalSpendUSD)))"),
                    .separator,
                    .submenu(title: "By model", children: modelRows),
                ]))
        }
    }

    if visibility.grokBot, let grokBot {
        let pctText = grokBot.personalBarPercent
        let pctTint = grokBotColors.level(for: Double(grokBot.percentLeft))
        var children: [MenuRow] = [
            .body("Weekly limit: \(grokBot.percentLeft)% left",
                  tints: [MoneyTint("\(grokBot.percentLeft)%", pctTint,
                                    goodStyle: grokBotColors.goodStyle,
                                    after: "Weekly limit: ")]),
            .body("Resets: \(grokBot.resetDescription)"),
        ]
        if let plan = grokBot.planLabel {
            children.append(.body("Plan: \(plan)"))
        }
        children.append(.body("Uses Cursor login; API reports % used, shown as % left"))
        rows.append(.submenu(
            title: "Grok Bot · \(pctText) left",
            titleTints: [MoneyTint(pctText, pctTint, goodStyle: grokBotColors.goodStyle,
                                   after: "Grok Bot · ")],
            children: children))
    }

    if let openAI = visibleOpenAI {
        let lineRows: [MenuRow] = openAI.byLineItem.isEmpty
            ? [.body("(no cost line items)")]
            : openAI.byLineItem.map { .body("\($0.lineItem): \(Fmt.money($0.spendUSD))") }
        let balanceTitle = openAI.estimatedBalanceUSD.map {
            " · Est. balance \(Fmt.money($0))"
        } ?? ""
        var openAIChildren: [MenuRow] = []
        if let balance = openAI.estimatedBalanceUSD {
            let balanceTint = openAIColors.level(for: balance)
            let balanceText = Fmt.money(balance)
            openAIChildren.append(.body("Estimated prepaid balance: \(balanceText)",
                                        tints: [MoneyTint(balanceText, balanceTint,
                                                          goodStyle: openAIColors.goodStyle,
                                                          after: "Estimated prepaid balance: ")]))
            openAIChildren.append(.body("Estimate; reset after adding credits"))
            openAIChildren.append(.separator)
        }
        openAIChildren.append(contentsOf: [
            .body("Today: \(Fmt.money(openAI.todaySpendUSD))"),
            .body("Month: \(Fmt.money(openAI.monthSpendUSD))"),
            .body("Projected month-end: \(Fmt.money(projectedMonthEnd(monthUSD: openAI.monthSpendUSD)))"),
            .body("Daily cost pipeline; figures may lag"),
            .separator,
            .submenu(title: "By line item", children: lineRows),
        ])
        var titleTints: [MoneyTint] = []
        if let balance = openAI.estimatedBalanceUSD {
            let balanceText = Fmt.money(balance)
            titleTints.append(MoneyTint(balanceText,
                                        openAIColors.level(for: balance),
                                        goodStyle: openAIColors.goodStyle,
                                        after: "Est. balance "))
        }
        rows.append(.submenu(
            title: "OpenAI API\(balanceTitle) · Today \(Fmt.money(openAI.todaySpendUSD)) · Month \(Fmt.money(openAI.monthSpendUSD))",
            titleTints: titleTints,
            children: openAIChildren))
    }

    if visibility.claude {
        if claudeIsPersonal, let usage = claudeUsage,
           usage.session != nil || usage.weekly != nil {
            var children: [MenuRow] = []
            if let session = usage.session {
                let text = "\(session.percentLeft)%"
                children.append(.body(
                    "Five-hour limit: \(text) left",
                    tints: [MoneyTint(text,
                                      claudePersonalColors.level(for: Double(session.percentLeft)),
                                      goodStyle: claudePersonalColors.goodStyle,
                                      after: "Five-hour limit: ")]))
                children.append(.body("Resets: \(session.resetDescription)"))
            }
            if usage.session != nil && usage.weekly != nil { children.append(.separator) }
            if let weekly = usage.weekly {
                let text = "\(weekly.percentLeft)%"
                children.append(.body(
                    "Weekly limit: \(text) left",
                    tints: [MoneyTint(text,
                                      claudePersonalColors.level(for: Double(weekly.percentLeft)),
                                      goodStyle: claudePersonalColors.goodStyle,
                                      after: "Weekly limit: ")]))
                children.append(.body("Resets: \(weekly.resetDescription)"))
            }
            let titleLabel = usage.personalBarLabel ?? "—"
            var titleTints: [MoneyTint] = []
            if let session = usage.session {
                titleTints.append(MoneyTint(
                    session.personalBarPercent,
                    claudePersonalColors.level(for: Double(session.percentLeft)),
                    goodStyle: claudePersonalColors.goodStyle,
                    after: "Claude · 5H "))
            }
            if let weekly = usage.weekly {
                let prefix = usage.session == nil ? "Claude · W " : " W "
                titleTints.append(MoneyTint(
                    weekly.personalBarPercent,
                    claudePersonalColors.level(for: Double(weekly.percentLeft)),
                    goodStyle: claudePersonalColors.goodStyle,
                    after: prefix))
            }
            rows.append(.submenu(
                title: "Claude · \(titleLabel)",
                titleTints: titleTints,
                children: children))
        } else if !claudeIsPersonal {
            rows.append(.submenu(
                title: "Claude · Today \(Fmt.money(r.todayUSD)) · Month \(Fmt.money(r.monthUSD))",
                titleTints: [MoneyTint(Fmt.money(r.monthUSD), claudeMonthTint,
                                       goodStyle: claudeColors.goodStyle, after: "Month ")],
                children: [
                    .body("Today: \(Fmt.money(r.todayUSD))",
                          tints: [MoneyTint(Fmt.money(r.todayUSD),
                                            claudeColors.level(for: r.todayUSD,
                                                               policyUSD: config.spendRedUSD),
                                            goodStyle: claudeColors.goodStyle, after: "Today: ")]),
                    .body("Month: \(Fmt.money(r.monthUSD))",
                          tints: [MoneyTint(Fmt.money(r.monthUSD), claudeMonthTint,
                                            goodStyle: claudeColors.goodStyle, after: "Month: ")]),
                    .body("Projected month-end: \(Fmt.money(r.projectedMonthEndUSD))"),
                    .separator,
                    .submenu(title: "By model", children: claudeModels),
                ]))
        }
    }

    if config.showEfficiencyDetails && visibility.claude && !claudeIsPersonal {
        if !rows.isEmpty { rows.append(.separator) }
        let history = History()
        let streak = history.streak(threshold: 80)
        let trend = history.trend7d()
        let arrow = trend > 0 ? "↑" : (trend < 0 ? "↓" : "→")
        rows.append(.header("Efficiency  ·  \(eff.score) (\(eff.grade)) \(arrow)"))
        rows.append(.body("  Model fit: \(Fmt.pct(eff.modelFit.rightModelPct))  ·  \(Fmt.pct(eff.modelFit.lightTurnShare)) Opus turns lightweight  ·  recoverable \(Fmt.money(eff.modelFit.recoverableUSD))"))
        rows.append(.body("  Context/turn: \(Fmt.tokens(eff.context.contextPerTurnMedian))  ·  churn \(Fmt.pct(eff.context.churn))"))
        let trendStr = trend > 0 ? "+\(trend)" : "\(trend)"
        rows.append(.body("  Streak: \(streak)d  ·  Best: \(history.personalBest)  ·  7-day \(trendStr)"))
        let earned = Achievements.badges(eff: eff, rollup: r, history: history).filter { $0.earned }
        if !earned.isEmpty {
            rows.append(.body("  Badges: " + earned.map { "\($0.emoji) \($0.name)" }.joined(separator: "   ")))
        }
        rows.append(.body("  Tip: \(eff.topTip)"))
    }
    return rows
}
