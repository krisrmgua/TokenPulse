import AppKit
import Foundation

/// Offline checks shared by XCTest (`swift test`) and the `--selftest` CLI
/// fallback (Command Line Tools without the XCTest framework).
enum TokenPulseSelfChecks {
    /// Runs all checks; returns the number of failures (0 = pass).
    @discardableResult
    static func runAll(printResults: Bool = false) -> Int {
        var fails = 0
        func check(_ name: String, _ cond: Bool) {
            if printResults { print("\(cond ? "PASS" : "FAIL"): \(name)") }
            if !cond { fails += 1 }
        }

        // Model-fit
        var light = SessionAgg(id: "s1")
        light.cwd = "/Users/x/money-frontend"
        light.firstPrompt = "rename variable across files"
        light.turns = 10
        light.models = ["claude-opus-4-8"]
        light.opusCost = 4.0
        light.totalCost = 4.0
        light.lightTurns = 5
        light.lightOpusCost = 1.20
        light.lightOpusAtSonnet = 0.72

        var hard = SessionAgg(id: "s2")
        hard.firstPrompt = "refactor the auth architecture"
        hard.turns = 20
        hard.output = 50_000
        hard.models = ["claude-opus-4-8"]
        hard.opusCost = 37.20
        hard.totalCost = 37.20

        var roll = Rollup()
        roll.monthUSD = 41.20
        let mf = ModelFitResult.compute([light, hard], rollup: roll, config: Config())
        check("model-fit flags 1 offender (lightweight opus)", mf.offenders.count == 1)
        check("offender names the project", mf.offenders.first?.label.contains("money-frontend") ?? false)
        check("offender reason names turns", mf.offenders.first?.reason.contains("5 of 10") ?? false)
        check("offender savings = $0.48", abs((mf.offenders.first?.savingsUSD ?? 0) - 0.48) < 0.001)
        check("recoverable ≈ $0.48", abs(mf.recoverableUSD - 0.48) < 0.001)
        check("lightTurnShare = 5/30", abs(mf.lightTurnShare - 5.0 / 30.0) < 0.001)
        check("rightModel% ≈ 1 - 1.20/41.20", abs(mf.rightModelPct - (1 - 1.20 / 41.20)) < 0.001)

        // Context
        var bloat = SessionAgg(id: "s3")
        bloat.turns = 1
        bloat.cacheRead = 480_000
        bloat.cacheWrite = 20_000
        bloat.totalCost = 2
        var ctxRoll = Rollup()
        ctxRoll.monthUSD = 2
        let ctx = ContextResult.compute([bloat], rollup: ctxRoll, pricing: Pricing())
        check("big-read flag fires at 500k ctx/turn", ctx.bigReadFlag)
        check("churn = 20k/500k = 0.04", abs(ctx.churn - 0.04) < 0.001)

        // History
        let cal = Calendar.current
        let today = cal.date(from: DateComponents(year: 2026, month: 6, day: 17))!
        var snaps: [Snapshot] = []
        for i in 0..<8 {
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            snaps.append(Snapshot(date: History.dayString(d), score: 85, costMTD: 100,
                                  cacheHitPct: 0.9, opusShare: 0.3, modelFitPct: 0.95))
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tok-selfchecks-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? JSONEncoder().encode(snaps).write(to: tmp)
        let h = History(url: tmp)
        check("history streak = 8 days", h.streak(threshold: 80, today: today) == 8)
        check("personal best = 85", h.personalBest == 85)
        check("7-day trend flat (0)", h.trend7d(today: today) == 0)

        let spendLedgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tok-selfchecks-spend-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: spendLedgerURL) }
        var spendLedger = SpendLedger(url: spendLedgerURL)
        spendLedger.record(dayUSD: 12.5, monthUSD: 40, today: "2026-11-03")
        spendLedger.record(dayUSD: 14.0, monthUSD: 54, today: "2026-11-03") // upsert
        check("spend ledger upserts today", spendLedger.entry(on: "2026-11-03")?.dayUSD == 14.0)
        let spendNow = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        let spendChart = spendLedger.monthChart(
            now: spendNow, todayUSD: 14, monthUSD: 54, projectedMonthEndUSD: 540)
        check("spend chart covers November", spendChart.count == 30)
        check("spend chart today is MTD", spendChart.first(where: \.isToday)?.actualUSD == 54)
        check("spend chart eom projection", abs((spendChart.last?.projectedUSD ?? 0) - 540) < 0.001)
        check("spend chart future has no actual", spendChart.last?.actualUSD == nil)

        // Cursor parse
        check("doubleField accepts Int", abs(CursorSpendParse.doubleField(["totalCents": 250], "totalCents") - 250) < 0.001)
        check("doubleField accepts String", abs(CursorSpendParse.doubleField(["totalCents": "99.5"], "totalCents") - 99.5) < 0.001)
        check("intField accepts String", CursorSpendParse.intField(["inputTokens": "42"], "inputTokens") == 42)

        let aggObj: [String: Any] = [
            "aggregations": [
                ["modelIntent": "claude-4-opus", "totalCents": 1234,
                 "inputTokens": 10, "outputTokens": 20,
                 "cacheWriteTokens": 1, "cacheReadTokens": 2],
                ["modelIntent": "gpt-5", "totalCents": "566",
                 "inputTokens": 3, "outputTokens": 4,
                 "cacheWriteTokens": 0, "cacheReadTokens": 0],
            ] as [[String: Any]],
        ]
        let aggs = CursorSpendParse.aggregations(from: aggObj) ?? []
        check("aggregations parses 2 models", aggs.count == 2)
        check("aggregations sorts by spend desc", aggs.first?.model == "claude-4-opus")
        check("aggregations month $ = 18.00", abs(aggs.reduce(0.0) { $0 + $1.spendUSD } - 18.0) < 0.001)
        check("missing aggregations key → nil", CursorSpendParse.aggregations(from: [:]) == nil)

        // Window totals come from totalCostCents (the charged figure), which
        // runs above the per-model rows once Cursor's token fee is applied.
        check("window total reads totalCostCents",
              abs(CursorSpendParse.totalSpendUSD(from: ["totalCostCents": 7338.0]) - 73.38) < 0.001)
        check("window total accepts String cents",
              abs(CursorSpendParse.totalSpendUSD(from: ["totalCostCents": "10071.426999"]) - 100.714) < 0.001)
        check("window total absent → 0",
              abs(CursorSpendParse.totalSpendUSD(from: [:])) < 0.001)

        // Per-source month projection (there is intentionally no combined D/M mode).
        let projNow = cal.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let daysInAug = cal.range(of: .day, in: .month, for: projNow)?.count ?? 31
        let expectedProj = 25.0 * Double(daysInAug) / 10.0
        check("per-source projected = month * days/day",
              abs(projectedMonthEnd(monthUSD: 25.0, now: projNow) - expectedProj) < 0.001)
        let openAIJSON = """
        {"data":[{"start_time":1,"end_time":2,"results":[
          {"amount":{"value":1.25,"currency":"usd"},"line_item":"Responses API"},
          {"amount":{"value":0.75,"currency":"usd"},"line_item":"Responses API"},
          {"amount":{"value":4,"currency":"eur"},"line_item":"Ignored"}
        ]}],"has_more":true,"next_page":"next"}
        """
        let openAIPage = OpenAISpendParse.decode(Data(openAIJSON.utf8))
        check("OpenAI costs page decodes", openAIPage?.hasMore == true
              && openAIPage?.nextPage == "next")
        check("OpenAI costs sum USD only",
              abs(OpenAISpendParse.total(openAIPage?.data ?? []) - 2.0) < 0.001)
        check("OpenAI line items aggregate",
              OpenAISpendParse.lines(openAIPage?.data ?? [])
                == [OpenAICostLine(lineItem: "Responses API", spendUSD: 2.0)])
        check("OpenAI Admin key format rejects normal keys",
              OpenAIKeychain.isValidAdminKeyFormat("sk-admin-example")
                && !OpenAIKeychain.isValidAdminKeyFormat("sk-project-example"))
        check("Cursor login is missing until a token is stored",
              CursorAuthCache.loginAvailability(stored: nil) == .missing
                && CursorAuthCache.loginAvailability(stored: "") == .missing)
        check("Cursor login is ready when the token is already plain",
              CursorAuthCache.loginAvailability(stored: "session") == .ready)
        check("Cursor login needs Keychain when Cursor encrypted it",
              CursorAuthCache.loginAvailability(stored: CursorTokenCrypto.prefix + "abc") == .needsKeychain)
        let balanceBaseline = OpenAIBalanceBaseline(
            enteredBalanceUSD: 20, baselineDayStart: Date(timeIntervalSince1970: 0),
            spendAlreadyReportedThatDayUSD: 3)
        check("estimated OpenAI balance subtracts only new reported spend",
              abs(balanceBaseline.estimate(reportedSpendSinceDayStart: 5) - 18) < 0.001)
        check("estimated OpenAI balance does not double-count earlier day spend",
              abs(balanceBaseline.estimate(reportedSpendSinceDayStart: 2) - 20) < 0.001)
        check("estimated OpenAI balance may go negative",
              abs(balanceBaseline.estimate(reportedSpendSinceDayStart: 25) + 2) < 0.001)

        // ChatGPT weekly allowance parsers (Codex app-server JSON plus the
        // human-readable `/status` format used for manual verification).
        var denver = Calendar(identifier: .gregorian)
        denver.timeZone = TimeZone(identifier: "America/Denver")!
        let chatGPTNow = denver.date(from: DateComponents(
            year: 2026, month: 8, day: 26, hour: 9))!
        let chatGPTRaw = """
        \u{001B}[2m│ Weekly limit: \u{001B}[22m[█████████████░░░░░░░] 64% left
        \u{001B}[2m│               (resets 11:00 on 1 Sep)
        """
        let chatGPT = ChatGPTUsageParse.snapshot(
            from: chatGPTRaw, now: chatGPTNow, calendar: denver,
            codexPath: "/tmp/codex")
        check("ChatGPT status parses percent", chatGPT?.percentLeft == 64)
        check("ChatGPT status parses reset year",
              chatGPT.map { denver.component(.year, from: $0.resetAt) } == 2026)
        check("ChatGPT status rejects day 00",
              ChatGPTUsageParse.snapshot(
                from: "Weekly limit: 64% left (resets 11:00 on 00 Sep)",
                now: chatGPTNow, calendar: denver) == nil)
        check("ChatGPT status rejects day 99",
              ChatGPTUsageParse.snapshot(
                from: "Weekly limit: 64% left (resets 11:00 on 99 Sep)",
                now: chatGPTNow, calendar: denver) == nil)
        let appServerJSON = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1788282000}}}}"#
        let chatGPTJSON = ChatGPTUsageParse.snapshot(
            fromAppServerData: Data(appServerJSON.utf8), now: chatGPTNow,
            codexPath: "/tmp/codex")
        check("ChatGPT app server parses remaining percent",
              chatGPTJSON?.percentLeft == 64)
        check("ChatGPT app server parses reset timestamp",
              chatGPTJSON?.resetAt.timeIntervalSince1970 == 1_788_282_000)
        // Real shape: primary is the 5-hour window (67% used), secondary the weekly one (11% used).
        let realShape = ChatGPTUsageParse.snapshot(
            fromAppServerData: Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":67,"windowDurationMins":300,"resetsAt":1793501921},"secondary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1794088721}}}}"#.utf8),
            now: chatGPTNow, codexPath: "/tmp/codex")
        check("ChatGPT parses 5-hour and weekly windows",
              realShape?.session?.percentLeft == 33 && realShape?.percentLeft == 89
              && realShape?.barPercentLeft == 33)
        let zeroChatGPTReset = denver.date(from: DateComponents(
            year: 2026, month: 9, day: 20, hour: 11))!
        let zeroChatGPT = ChatGPTUsageSnapshot(
            percentLeft: 0, resetAt: zeroChatGPTReset,
            fetchedAt: chatGPTNow, codexPath: "codex")
        check("ChatGPT 0% bar includes short reset date",
              zeroChatGPT.personalBarPercent
                == "0% \(ChatGPTUsageParse.shortBarResetDate(from: zeroChatGPTReset, calendar: denver))")
        check("ChatGPT non-zero bar stays percent only",
              chatGPT?.personalBarPercent == "64%")
        let chatGPTWorkJSON = """
        {"data":[
          {"date":"2026-08-25","values":{"codex":100.25,"chatgpt":10,"work":2.5}},
          {"date":"2026-08-26","values":{"codex":5,"chatgpt":1,"work":0.5}}
        ],"data_freshness_ts":"2026-08-26T14:00:00Z"}
        """.data(using: .utf8)!
        let chatGPTWork = ChatGPTWorkUsageParse.snapshot(
            from: chatGPTWorkJSON, now: chatGPTNow, calendar: denver)
        check("ChatGPT work parses today's credits",
              abs((chatGPTWork?.todayCredits ?? 0) - 6.5) < 0.001)
        check("ChatGPT work sums month credits",
              abs((chatGPTWork?.monthCredits ?? 0) - 119.25) < 0.001)
        check("ChatGPT work estimates API-equivalent dollars",
              abs((chatGPTWork?.estimatedUSD ?? 0) - 4.77) < 0.001)
        check("ChatGPT work computes $200 Pro equivalents",
              abs((chatGPTWork?.proPlanEquivalents ?? 0) - 0.02385) < 0.000_001)
        check("ChatGPT work non-zero today is not pending",
              chatGPTWork?.todayIsPending == false)

        // A zero today is only trustworthy once the provider has aggregated
        // past the current moment — otherwise it is indistinguishable from
        // usage that has not been ingested.
        let staleZeroJSON = """
        {"data":[
          {"date":"2026-08-26","values":{"codex":0,"chatgpt":0,"work":0}}
        ],"data_freshness_ts":"2026-08-26T14:00:00Z"}
        """.data(using: .utf8)!
        let staleZero = ChatGPTWorkUsageParse.snapshot(
            from: staleZeroJSON, now: chatGPTNow, calendar: denver)
        check("ChatGPT work zero today with lagging data is pending",
              staleZero?.todayIsPending == true)

        let freshZeroJSON = """
        {"data":[
          {"date":"2026-08-26","values":{"codex":0,"chatgpt":0,"work":0}}
        ],"data_freshness_ts":"2099-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let freshZero = ChatGPTWorkUsageParse.snapshot(
            from: freshZeroJSON, now: chatGPTNow, calendar: denver)
        check("ChatGPT work zero today with caught-up data is not pending",
              freshZero?.todayIsPending == false)

        let noFreshnessJSON = """
        {"data":[{"date":"2026-08-26","values":{"codex":0}}]}
        """.data(using: .utf8)!
        check("ChatGPT work zero today without a freshness stamp is pending",
              ChatGPTWorkUsageParse.snapshot(
                from: noFreshnessJSON, now: chatGPTNow, calendar: denver)?.todayIsPending == true)

        let pendingEff = EfficiencyResult.compute(
            rollup: Rollup(), scan: ScanResult(records: [], sessions: [:]),
            pricing: Pricing(), config: Config())
        let pendingRows = tokenpulseMenuRows(
            Rollup(), pendingEff, Config(), chatGPTWork: staleZero,
            chatGPTAccountMode: .work,
            visibility: MenuSourceVisibility(
                chatGPT: true, cursor: false, openAI: false, claude: false))
        check("ChatGPT work pending menu row explains the gap",
              pendingRows.contains { row in
                  guard case .submenu(_, _, let children) = row else { return false }
                  return children.contains { child in
                      if case .body(let text, _) = child {
                          return text.contains("Today: pending")
                      }
                      return false
                  }
              })
        var menuRoll = Rollup()
        menuRoll.todayUSD = 3
        menuRoll.monthUSD = 40
        let menuEff = EfficiencyResult.compute(
            rollup: menuRoll, scan: ScanResult(records: [], sessions: [:]),
            pricing: Pricing(), config: Config())
        let hiddenRows = tokenpulseMenuRows(
            menuRoll, menuEff, Config(), chatGPT: chatGPTJSON,
            visibility: MenuSourceVisibility(
                chatGPT: false, cursor: false, openAI: false, claude: false))
        check("hidden sources produce no usage rows", hiddenRows.isEmpty)
        let chatOnlyRows = tokenpulseMenuRows(
            menuRoll, menuEff, Config(), chatGPT: chatGPTJSON,
            chatGPTAccountMode: .personal,
            visibility: MenuSourceVisibility(
                chatGPT: true, cursor: false, openAI: false, claude: false))
        check("ChatGPT-only menu omits spend totals and Claude",
              chatOnlyRows.count == 1 && chatOnlyRows.allSatisfy { row in
                  if case .submenu(let title, _, _) = row { return title.hasPrefix("ChatGPT") }
                  return false
              })
        let chatWorkRows = tokenpulseMenuRows(
            menuRoll, menuEff, Config(), chatGPTWork: chatGPTWork,
            chatGPTAccountMode: .work,
            visibility: MenuSourceVisibility(
                chatGPT: true, cursor: false, openAI: false, claude: false))
        check("ChatGPT work menu shows estimated dollars",
              chatWorkRows.contains { row in
                  if case .submenu(let title, _, let children) = row {
                      return title == "ChatGPT work · $4.77 est."
                          && children.contains { child in
                              if case .body(let text, _) = child {
                                  return text.contains("119.25 credits")
                                      && text.contains("$4.77")
                              }
                              return false
                          }
                  }
                  return false
              })
        let personalCursor = CursorSpendSnapshot(
            totalSpendUSD: 10, todaySpendUSD: 1.5, byModel: [],
            fetchedAt: chatGPTNow, userId: 1,
            planUsage: CursorPlanUsage(limitUSD: 20, includedSpendUSD: 5,
                                       totalPercentUsed: 25, percentLeft: 75))
        let openAISpend = OpenAISpendSnapshot(
            todaySpendUSD: 2, monthSpendUSD: 25, estimatedBalanceUSD: 9,
            byLineItem: [], fetchedAt: chatGPTNow)
        let personalModeRows = tokenpulseMenuRows(
            menuRoll, menuEff, Config(), cursor: personalCursor,
            openAI: openAISpend, cursorAccountMode: .personal,
            claudeAccountMode: .personal,
            visibility: MenuSourceVisibility(
                chatGPT: false, cursor: true, openAI: true, claude: true))
        check("menu omits cross-provider Your spend summary",
              !personalModeRows.contains { row in
                  if case .header(let title) = row { return title == "Your spend" }
                  return false
              })
        check("personal Cursor title is percent left, not of $N",
              personalModeRows.contains { row in
                  if case .submenu(let title, _, _) = row {
                      return title == "Cursor · 75% left"
                  }
                  return false
              })
        check("personal Cursor submenu omits API list-cost Today/Month",
              personalModeRows.contains { row in
                  if case .submenu(let title, _, let children) = row, title.hasPrefix("Cursor ·") {
                      return !children.contains { child in
                          if case .body(let text, _) = child {
                              return text.hasPrefix("Today: $") || text.hasPrefix("Month: $")
                          }
                          return false
                      }
                  }
                  return false
              })
        let combinedRows = tokenpulseMenuRows(
            menuRoll, menuEff, Config(), cursor: personalCursor,
            cursorAccountMode: .work, claudeAccountMode: .work,
            visibility: MenuSourceVisibility(
                chatGPT: false, cursor: true, openAI: false, claude: true),
            presentation: .combined)
        check("combined presentation keeps upstream Your spend header",
              combinedRows.contains { row in
                  if case .header(let title) = row { return title == "Your spend" }
                  return false
              })
        check("combined presentation sums Claude and Cursor",
              combinedRows.contains { row in
                  if case .body(let text, _) = row {
                      return text.contains("Today: $4.50") && text.contains("Month: $50")
                  }
                  return false
              })
        check("ChatGPT configured executable wins",
              ChatGPTUsageClient.codexExecutable(
                environment: ["TOKENPULSE_CODEX_PATH": "/bin/sh"]) == "/bin/sh")
        let vis = MenuSourceVisibility()
        check("default visibility is Cursor and Claude only",
              !vis.chatGPT && vis.cursor && !vis.openAI && vis.claude && !vis.grokBot)
        let claudeRaw = """
        \u{001B}[2mCurrent session\u{001B}[0m
        ████▌ 9% used
        Resets 3:30pm (America/Los_Angeles)
        Current week (all models)
        ███████████████████▌ 39% used
        Resets May 17, 10am (America/Los_Angeles)
        """
        let claudeUsage = ClaudeUsageParse.snapshot(
            from: claudeRaw, now: chatGPTNow, claudePath: "/tmp/claude")
        check("Claude usage parses five-hour remaining",
              claudeUsage?.session?.percentLeft == 91)
        check("Claude usage parses weekly remaining",
              claudeUsage?.weekly?.percentLeft == 61)
        check("Claude menu meter prefers weekly remaining",
              claudeUsage?.menuPercentLeft == 61)
        check("Claude personal bar shows 5H and W",
              claudeUsage?.personalBarLabel == "5H 91% W 61%")
        check("Claude personal bar session-only",
              ClaudeUsageParse.snapshot(
                from: "Current session\n25% used\nResets 8pm (America/Denver)",
                now: chatGPTNow)?.personalBarLabel == "5H 75%")
        check("Claude short bar reset keeps month+day",
              ClaudeUsageParse.shortBarResetDate(
                from: "Sep 20 at 10:59am (America/Denver)") == "Sep 20"
                && ClaudeUsageParse.shortBarResetDate(
                    from: "May 17, 10am (America/Los_Angeles)") == "May 17"
                && ClaudeUsageParse.shortBarResetDate(
                    from: "3:30pm (America/Denver)") == nil)
        let zeroWeekly = ClaudeUsageWindow(
            percentLeft: 0,
            resetDescription: "Sep 20 at 11am (America/Denver)")
        check("Claude 0% weekly bar includes short reset date",
              zeroWeekly.personalBarPercent == "0% Sep 20")
        let zeroSessionTimeOnly = ClaudeUsageWindow(
            percentLeft: 0,
            resetDescription: "1:50pm (America/Denver)")
        check("Claude 0% session without calendar date stays 0%",
              zeroSessionTimeOnly.personalBarPercent == "0%")
        let cursorAddressed = "Current\u{001B}[12Gsession\r\u{001B}[3C"
            + "█████████\u{001B}[55G18%\u{001B}[59Gused\r\u{001B}[3C"
            + "Resets\u{001B}[11G3am\u{001B}[15G(America/Denver)\r\u{001B}[3C"
            + "Current\u{001B}[12Gweek\u{001B}[17G(all\u{001B}[22Gmodels)\r\u{001B}[3C"
            + "█▌\u{001B}[55G3%\u{001B}[58Gused\r\u{001B}[3C"
            + "Resets\u{001B}[11GSep\u{001B}[15G5\u{001B}[17Gat\u{001B}[20G11am\u{001B}[25G(America/Denver)"
        let addressed = ClaudeUsageParse.snapshot(from: cursorAddressed, now: chatGPTNow)
        check("Claude usage parses cursor-addressed TUI frames",
              addressed?.session?.percentLeft == 82 && addressed?.weekly?.percentLeft == 97)
        check("Claude rejects half-painted reset 'Sep'",
              !ClaudeUsageParse.isCompleteResetDescription("Sep")
                && ClaudeUsageParse.isCompleteResetDescription("Sep 16 at 11am (America/Denver)")
                && ClaudeUsageParse.isCompleteResetDescription("3:30pm (America/Los_Angeles)")
                && !ClaudeUsageParse.isCompleteResetDescription("Oct 3 a")
                && ClaudeUsageParse.isCompleteResetDescription("Oct 3 at 11am"))
        let partialWeek = """
        Current session
        9% used
        Resets 3:30pm (America/Denver)
        Current week (all models)
        59% used
        Resets Sep
        """
        let partialSnap = ClaudeUsageParse.snapshot(from: partialWeek, now: chatGPTNow)
        check("Claude omits weekly when reset is still 'Sep'",
              partialSnap?.session?.percentLeft == 91 && partialSnap?.weekly == nil)
        let csiWeekOnlySession = "Current\u{001B}[12Gsession\r"
            + "9%\u{001B}[59Gused\r"
            + "Resets\u{001B}[11G3:30pm\u{001B}[18G(America/Denver)\r"
            + "Current\u{001B}[12Gweek\u{001B}[17G(all\u{001B}[22Gmodels)\r"
            + "59%\u{001B}[59Gused\r"
            + "Resets\u{001B}[11GSep"
        let csiPartial = ClaudeUsageParse.snapshot(from: csiWeekOnlySession, now: chatGPTNow)
        check("Claude CSI 'Current week' keeps waiting (no weekly yet)",
              csiPartial?.session != nil && csiPartial?.weekly == nil)
        check("Claude configured executable wins",
              ClaudeUsageClient.claudeExecutable(
                environment: ["TOKENPULSE_CLAUDE_PATH": "/bin/sh"]) == "/bin/sh")
        check("Claude Desktop bundled paths prefer numeric newest",
              ClaudeUsageClient.desktopBundledClaudeCodePaths().first?.contains("claude-code") != false
                || ClaudeUsageClient.desktopBundledClaudeCodePaths().isEmpty)
        check("Grok Bot usagePercent 39 → 61% left",
              GrokBotUsageParse.percentLeft(from: 39) == 61)
        let grokObj: [String: Any] = [
            "usagePercent": 34.595012,
            "nextResetTimestampUtc": "2026-09-16T20:30:58.668Z",
            "grokPlanLabel": "Grok Bot Plan",
        ]
        check("Grok Bot Sand status parses",
              GrokBotUsageParse.snapshot(from: grokObj)?.percentLeft == 65)
        let zeroGrok = GrokBotUsageSnapshot(
            percentLeft: 0, percentUsed: 100,
            resetAt: denver.date(from: DateComponents(
                year: 2026, month: 9, day: 20, hour: 14)),
            planLabel: "Grok Bot Plan", cursorPlanName: "Pro",
            fetchedAt: chatGPTNow)
        check("Grok Bot 0% bar includes short reset date",
              zeroGrok.personalBarPercent
                == "0% \(ChatGPTUsageParse.shortBarResetDate(from: zeroGrok.resetAt!, calendar: denver))")
        check("Grok Bot 0% without reset stays 0%",
              GrokBotUsageSnapshot(
                percentLeft: 0, percentUsed: 100, resetAt: nil,
                planLabel: nil, cursorPlanName: nil,
                fetchedAt: chatGPTNow).personalBarPercent == "0%")
        check("Grok Bot pooled enterprise is omitted",
              GrokBotUsageParse.snapshot(from: [
                  "usagePercent": 10,
                  "usesPooledEnterpriseAllowance": true,
              ]) == nil)
        // Spend tint steps: cap = red, 75% = orange, 50% = yellow.
        check("spendRedUSD default is 1500", Config().spendRedUSD == 1500)
        check("tint red at the cap",
              SpendTint.levelSpendUp(1500, cap: 1500, orangePercent: 75, yellowPercent: 50) == .over)
        check("tint red above the cap",
              SpendTint.levelSpendUp(2600, cap: 1500, orangePercent: 75, yellowPercent: 50) == .over)
        let orangeAt = 1500 * 0.75
        let yellowAt = 1500 * 0.50
        check("tint orange at the orange step",
              SpendTint.levelSpendUp(orangeAt, cap: 1500, orangePercent: 75, yellowPercent: 50) == .warning)
        check("tint yellow at the yellow step",
              SpendTint.levelSpendUp(yellowAt, cap: 1500, orangePercent: 75, yellowPercent: 50) == .caution)
        check("tint good below the yellow step",
              SpendTint.levelSpendUp(yellowAt - 1, cap: 1500, orangePercent: 75, yellowPercent: 50) == .good)
        check("tint normal when cap is 0",
              SpendTint.levelSpendUp(5000, cap: 0, orangePercent: 75, yellowPercent: 50) == .normal)
        check("remaining-down red at floor",
              SpendTint.levelRemainingDown(5, red: 10, orange: 25, yellow: 50) == .over)
        check("remaining-down good above yellow",
              SpendTint.levelRemainingDown(60, red: 10, orange: 25, yellow: 50) == .good)
        check("remaining orange 33 sticks when yellow is 50",
              RemainingColorConfig.applyingOrange(33, to: (10, 51, 50)).orange == 33)
        let ordered = RemainingColorConfig.accepted(red: 10, orange: 33, yellow: 50)
        check("remaining order is red < orange < yellow",
              ordered.red < ordered.orange && ordered.orange < ordered.yellow)
        check("spend-up yellow 60 sticks when orange is 51",
              SpendUpColorConfig.applyingYellow(60, to: (51, 50)).yellow == 60)
        check("spend-up order is yellow < orange",
              SpendUpColorConfig.applyingOrange(75, to: (51, 50)).orange == 75
                && SpendUpColorConfig.applyingOrange(75, to: (51, 50)).yellow < 75)
        check("openAI remaining yellow pulls orange down",
              RemainingColorConfig.applyingYellow(15, to: (5, 20, 50)).orange == 14)
        check("cursor personal 72% remaining (fallback)",
              cursorPersonalRemainingPercent(monthSpendUSD: 5.6, allowanceUSD: 20) == 72)
        check("cursor personal 0% when over allowance (fallback)",
              cursorPersonalRemainingPercent(monthSpendUSD: 25, allowanceUSD: 20) == 0)
        check("cursor planUsage percent left",
              CursorPlanUsage.percentLeft(from: 61.557575757575755) == 38)
        let planJSON: [String: Any] = [
            "billingCycleStart": "1789535837000",
            "billingCycleEnd": 1_792_127_837_000,
            "planUsage": [
                "limit": 2000,
                "includedSpend": 2000,
                "totalPercentUsed": 61.557575757575755,
            ] as [String: Any],
        ]
        check("cursor planUsage parses",
              CursorSpendParse.planUsage(from: planJSON)?.percentLeft == 38)
        let parsedPlan = CursorSpendParse.planUsage(from: planJSON)
        check("cursor planUsage parses billingCycleEnd",
              parsedPlan?.billingCycleEnd?.timeIntervalSince1970 == 1_792_127_837.0)
        let zeroCursor = CursorSpendSnapshot(
            totalSpendUSD: 0, todaySpendUSD: 0, byModel: [],
            fetchedAt: chatGPTNow, userId: 1,
            planUsage: CursorPlanUsage(
                limitUSD: 20, includedSpendUSD: 20,
                totalPercentUsed: 100, percentLeft: 0,
                billingCycleEnd: parsedPlan?.billingCycleEnd))
        check("cursor 0% bar includes billing cycle reset date",
              zeroCursor.personalBarPercent(allowanceUSD: 20)
                == "0% \(ChatGPTUsageParse.shortBarResetDate(from: parsedPlan!.billingCycleEnd!))")
        check("cursor reset description uses billingCycleEnd",
              parsedPlan?.resetDescription != nil)
        check("step defaults are 75/50",
              Prefs.warningPercentDefault == 75 && Prefs.cautionPercentDefault == 50)
        check("yellow step is held below orange",
              Prefs.acceptedSpendPercents(warning: 60, caution: 80) == (60, 59))
        check("steps are clamped into range",
              Prefs.acceptedSpendPercents(warning: 500, caution: 0) == (99, 1))
        check("ordered steps pass through unchanged",
              Prefs.acceptedSpendPercents(warning: 75, caution: 50) == (75, 50))
        check("claude effective cap follows policy with no override",
              Prefs.claudeColors(policyUSD: Config().spendRedUSD).effectiveCap(
                policyUSD: Config().spendRedUSD) == Config().spendRedUSD)
        check("good green paints bar",
              SpendTint.good.barColor(goodStyle: .green) != nil)
        check("good white leaves bar uncolored",
              SpendTint.good.barColor(goodStyle: .white) == nil)
        check("exact money keeps the real threshold", Fmt.exactMoney(1500) == "$1,500")
        let augCap = SpendTint.dailyCap(1500, now: cal.date(from: DateComponents(year: 2026, month: 8, day: 10))!)
        check("daily cap = month cap / days in month", abs(augCap - 1500.0 / 31.0) < 0.001)

        // Menu-bar palette must not shift when the appearance behind the bar
        // flips; the dropdown palette must, since the menu background does too.
        func resolved(_ c: NSColor, _ name: NSAppearance.Name) -> NSColor {
            var out = c
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                out = c.usingColorSpace(.sRGB) ?? c
            }
            return out
        }
        func appearanceInvariant(_ c: NSColor?) -> Bool {
            guard let c else { return false }
            let light = resolved(c, .aqua), dark = resolved(c, .darkAqua)
            return abs(light.redComponent - dark.redComponent) < 0.001
                && abs(light.greenComponent - dark.greenComponent) < 0.001
                && abs(light.blueComponent - dark.blueComponent) < 0.001
                && abs(light.alphaComponent - dark.alphaComponent) < 0.001
        }
        check("bar red is appearance-invariant", appearanceInvariant(MenuBarPalette.red))
        check("bar orange is appearance-invariant", appearanceInvariant(MenuBarPalette.orange))
        check("bar yellow is appearance-invariant", appearanceInvariant(MenuBarPalette.yellow))
        check("bar green is appearance-invariant", appearanceInvariant(MenuBarPalette.green))
        check("pastel red is appearance-invariant", appearanceInvariant(SpendPalette.red))
        check("pastel orange is appearance-invariant", appearanceInvariant(SpendPalette.orange))
        check("pastel yellow is appearance-invariant", appearanceInvariant(SpendPalette.yellow))
        check("pastel green is appearance-invariant", appearanceInvariant(SpendPalette.green))
        check("every hot level has a bar color",
              [SpendTint.caution, .warning, .over].allSatisfy { $0.barColor() != nil })
        check("bar label is appearance-invariant", appearanceInvariant(MenuBarPalette.label))
        check("bar secondary label is appearance-invariant",
              appearanceInvariant(MenuBarPalette.secondaryLabel))
        check("bright red is #FF0000",
              BrightSpendColor.red.redComponent == 1
                && BrightSpendColor.red.greenComponent == 0
                && BrightSpendColor.red.blueComponent == 0)
        check("bright orange is #FF8000",
              BrightSpendColor.orange.redComponent == 1
                && abs(BrightSpendColor.orange.greenComponent - 0.5) < 0.001
                && BrightSpendColor.orange.blueComponent == 0)
        check("bright yellow is #FFFF00",
              BrightSpendColor.yellow.redComponent == 1
                && BrightSpendColor.yellow.greenComponent == 1
                && BrightSpendColor.yellow.blueComponent == 0)
        check("dropdown red is max-chroma #FF0000",
              appearanceInvariant(SpendTint.over.menuColor()))
        check("dropdown orange is max-chroma #FF8000",
              appearanceInvariant(SpendTint.warning.menuColor()))
        check("dropdown yellow is max-chroma #FFFF00",
              appearanceInvariant(SpendTint.caution.menuColor()))
        check("dropdown green follows the appearance",
              !appearanceInvariant(SpendTint.good.menuColor(goodStyle: .green)))
        check("normal level has no color in either palette",
              SpendTint.normal.barColor() == nil && SpendTint.normal.menuColor() == nil)

        // Tinting is opt-in: with colors off, a hot figure still draws in the
        // label color, matching the original app.
        let hotRow = "  Month: $1.9k"
        let hotTint = [MoneyTint("$1.9k", .over, after: "Month: ")]
        let barFont = NSFont.systemFont(ofSize: 13)
        func tintedColors(_ s: NSAttributedString) -> Set<NSColor> {
            var found: Set<NSColor> = []
            s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) {
                value, _, _ in
                if let color = value as? NSColor { found.insert(color) }
            }
            return found
        }
        check("colors off leaves the row in one plain color",
              tintedColors(MenuText.attributed(hotRow, font: barFont, tints: hotTint,
                                               colorsEnabled: false)) == [NSColor.labelColor])
        check("colors on tints the hot figure red",
              tintedColors(MenuText.attributed(hotRow, font: barFont, tints: hotTint,
                                               colorsEnabled: true)).contains(BrightSpendColor.red))
        check("reset covers layout, accounts, and color keys",
              Prefs.ownedKeys.contains("presentationMode")
                && Prefs.ownedKeys.contains("spendColorsEnabled")
                && Prefs.ownedKeys.contains("chatGPTAccountMode")
                && Prefs.ownedKeys.contains("chatGPTWorkRedCapUSD")
                && Prefs.ownedKeys.contains("chatGPTWorkShowDailyInBar")
                && Prefs.ownedKeys.contains("cursorWorkShowMonthlyInBar")
                && Prefs.ownedKeys.contains("claudeWorkShowDailyInBar")
                && Prefs.ownedKeys.contains("cursorAccountMode")
                && Prefs.ownedKeys.contains("claudeYellowPercent")
                && Prefs.ownedKeys.contains("openAIRedRemaining")
                && Prefs.ownedKeys.contains("showGrokBotInMenuBar")
                && Prefs.ownedKeys.contains("grokBotRedRemaining")
                && Prefs.ownedKeys.contains("rememberPanelPlace"))
        check("reset leaves no duplicate keys",
              Set(Prefs.ownedKeys).count == Prefs.ownedKeys.count)
        let savedDaily = Prefs.showDailyInBar(for: .cursorWork)
        let savedMonthly = Prefs.showMonthlyInBar(for: .cursorWork)
        Prefs.setShowDailyInBar(true, for: .cursorWork)
        Prefs.setShowMonthlyInBar(true, for: .cursorWork)
        Prefs.setShowDailyInBar(false, for: .cursorWork)
        check("hiding daily leaves monthly on",
              !Prefs.showDailyInBar(for: .cursorWork)
                && Prefs.showMonthlyInBar(for: .cursorWork))
        Prefs.setShowMonthlyInBar(false, for: .cursorWork)
        check("hiding the last D/M figure turns daily back on",
              Prefs.showDailyInBar(for: .cursorWork)
                && !Prefs.showMonthlyInBar(for: .cursorWork))
        Prefs.setShowDailyInBar(savedDaily, for: .cursorWork)
        Prefs.setShowMonthlyInBar(savedMonthly, for: .cursorWork)

        // Money tint targeting: only the anchored occurrence is tinted.
        let dupRow = "  Today: $1.2k   ·   Month: $1.2k"
        let monthOnly = MoneyTint("$1.2k", .over, after: "Month: ")
        check("anchored tint skips the earlier duplicate",
              monthOnly.range(in: dupRow) == (dupRow as NSString).range(of: "$1.2k", options: .backwards))
        check("tint with a missing anchor resolves to nil",
              MoneyTint("$1.2k", .over, after: "Quarter: ").range(in: dupRow) == nil)

        check("remotePollInterval default is 5 min", Config().remotePollInterval == 5 * 60)
        check("remotePollInterval accepts 60s", Config.acceptedRemotePollInterval(60) == 60)
        check("remotePollInterval accepts 1h", Config.acceptedRemotePollInterval(3600) == 3600)
        check("remotePollInterval rejects sub-minute", Config.acceptedRemotePollInterval(0.001) == nil)
        check("remotePollInterval rejects >1h", Config.acceptedRemotePollInterval(3601) == nil)

        // Proxy decode + reconcile
        let proxyJSON = """
        {"end_user_id":"user@example.com","start_date":"2026-08-01","end_date":"2026-08-17",
         "daily_spend":2.25,"total_spend":12.34,"total_requests":9,
         "by_model":[{"model":"claude-opus-4-8","spend":10.0,"api_requests":5},
                     {"model":"claude-sonnet-5","spend":2.34,"api_requests":4}]}
        """.data(using: .utf8)!
        if let resp = try? JSONDecoder().decode(ProxySpendResponse.self, from: proxyJSON) {
            check("proxy decode total_spend", abs(resp.totalSpend - 12.34) < 0.001)
            check("proxy decode by_model count", resp.byModel.count == 2)
            check("proxy decode api_requests", resp.byModel.first?.apiRequests == 5)

            var local = Rollup()
            local.todayUSD = 1.5
            local.monthUSD = 99
            local.byModelUSD = ["local-only": 99]
            let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 17))!
            let full = local.reconciled(with: resp, now: now)
            check("proxy reconcile overwrites month", abs(full.monthUSD - 12.34) < 0.001)
            check("proxy reconcile uses daily spend", abs(full.todayUSD - 2.25) < 0.001)
            check("proxy reconcile marks reconciled", full.proxyReconciled)
            let costsNow = Date(timeIntervalSince1970: 100)
            check("proxy endpoint requires https", ProxySpendConfig.validatedEndpoint("https://proxy.example/spend")?.host == "proxy.example")
            check("proxy endpoint rejects a non-https URL", ProxySpendConfig.validatedEndpoint("http://proxy.example/spend") == nil)
            check("OpenAI costs stay on api.openai.com", OpenAISpendClient.requestURL(start: costsNow, end: costsNow, limit: 2, page: "next/cursor")?.host == "api.openai.com")
            check("OpenAI costs reject a page that leaves the API", OpenAISpendClient.requestURL(start: costsNow, end: costsNow, limit: 2, page: "https://evil.example/costs") == nil)
        } else {
            check("proxy decode JSON", false)
        }

        switch TokenPulseCLI.outputPath(forFlag: "--menu-preview", in: ["TokenPulse"]) {
        case .success(nil): check("preview absent flag is nil", true)
        default: check("preview absent flag is nil", false)
        }
        switch TokenPulseCLI.outputPath(forFlag: "--menu-preview", in: ["TokenPulse", "--menu-preview"]) {
        case .failure: check("preview missing path is failure", true)
        default: check("preview missing path is failure", false)
        }
        switch TokenPulseCLI.outputPath(forFlag: "--menu-preview", in: ["TokenPulse", "--menu-preview", "--help"]) {
        case .failure: check("preview flag-like path is failure", true)
        default: check("preview flag-like path is failure", false)
        }
        switch TokenPulseCLI.outputPath(forFlag: "--menu-preview", in: ["TokenPulse", "--menu-preview", "/tmp/out.png"]) {
        case .success(let p) where p == "/tmp/out.png": check("preview path is captured", true)
        default: check("preview path is captured", false)
        }

        _ = NSApplication.shared
        let rootMenu = NSMenu()
        let options = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        let optionsMenu = NSMenu(); options.submenu = optionsMenu; rootMenu.addItem(options)
        let display = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu(); display.submenu = displayMenu; optionsMenu.addItem(display)
        let firstTree = MissionRow.read(rootMenu)
        let originalOptionsID = firstTree[0].id
        let originalDisplayID = firstTree[0].children[0].id
        rootMenu.insertItem(NSMenuItem(title: "Provider added after refresh", action: nil, keyEquivalent: ""), at: 0)
        let refreshedTree = MissionRow.read(rootMenu)
        check("Mission options route survives provider visibility change", refreshedTree[1].id == originalOptionsID)
        check("Mission nested route survives provider visibility change", refreshedTree[1].children[0].id == originalDisplayID)
        let info = NSMenuItem(); let view = NSView(); view.addSubview(NSTextField(labelWithString: "Today: pending — not aggregated")); info.view = view
        optionsMenu.addItem(info)
        check("Mission extracts informational view text without inventing zero", MissionRow.read(optionsMenu).last?.title == "Today: pending — not aggregated")
        let nested = NSMenuItem(title: "Colors", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(); nested.submenu = colorMenu
        let red = NSMenuItem(title: "Red", action: nil, keyEquivalent: ""); red.submenu = NSMenu()
        red.submenu?.addItem(NSMenuItem(title: "10%", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        colorMenu.addItem(red); rootMenu.addItem(nested)
        check("Mission keeps nested threshold menus navigable", MissionRow.read(rootMenu).last?.isChoiceMenu == false)

        let presentation = MissionModel(); presentation.rows = MissionRow.read(rootMenu); presentation.route = "options"
        presentation.path = [originalDisplayID]
        check("Mission resolves the selected nested screen after refresh", presentation.currentTitle == "Display")

        check("menu-bar styles number in order", StatusBarDesign.allCases.map(\.number) == [1, 2, 3, 4, 5, 6, 7])
        check("work spend only offers Divider and Compact stack",
              StatusBarDesign.options(spendOnly: true).map(\.number) == [1, 4])
        check("work spend keeps Compact stack",
              StatusBarDesign.resolved(.stack, spendOnly: true) == .stack)
        check("work spend drops Twin gauges to Divider",
              StatusBarDesign.resolved(.rings, spendOnly: true) == .divider)
        check("cash has no quota gauge", StatusBarMetric(label: "B", value: "$9.27").fraction == nil)
        check("exhausted allowance remains an empty bar", StatusBarMetric(label: "5H", value: "0%", percent: 0).fraction == 0)
        let weeklyEmpty = StatusBarBlock(provider: "ChatGPT", icon: nil, metrics: [StatusBarMetric(label: "5H", value: "100%", percent: 100), StatusBarMetric(label: "W", value: "0%", percent: 0)])
        let sessionEmpty = StatusBarBlock(provider: "ChatGPT", icon: nil, metrics: [StatusBarMetric(label: "5H", value: "0%", percent: 0), StatusBarMetric(label: "W", value: "40%", percent: 40)])
        let remaining = StatusBarBlock(provider: "Cursor", icon: nil, metrics: [StatusBarMetric(label: "Pro", value: "89%", percent: 89)])
        let spend = StatusBarBlock(provider: "Claude", icon: nil, metrics: [StatusBarMetric(label: "M", value: "$10")])
        check("weekly zero marks that provider exhausted", weeklyEmpty.allowanceEmpty)
        check("five-hour zero marks that provider exhausted", sessionEmpty.allowanceEmpty)
        check("a remaining allowance keeps the normal capsule", !remaining.allowanceEmpty)
        check("spend without a percent is not an empty allowance", !spend.allowanceEmpty)
        func backdropRed(_ block: StatusBarBlock) -> CGFloat {
            var painted = block
            painted.design = .baseline
            let image = StatusBarArtwork.image(blocks: [painted], dark: true)
            let width = Int(image.size.width), height = Int(image.size.height)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return -1 }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
            NSGraphicsContext.restoreGraphicsState()
            return rep.colorAt(x: 2, y: height / 2)?.usingColorSpace(.deviceRGB)?.redComponent ?? -1
        }
        check("an empty allowance paints a blackish red capsule", backdropRed(weeklyEmpty) > backdropRed(remaining) + 0.08 && backdropRed(weeklyEmpty) < 0.35)
        check("quota renderer clamps invalid percentages", StatusBarMetric(label: "W", value: "120%", percent: 120).fraction == 1 && StatusBarMetric(label: "W", value: "-5%", percent: -5).fraction == 0)
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previousArguments
        arguments["statusBarDesign"] = "unknown-future-style"
        arguments["statusBarDesign.cursor"] = "unknown-future-style"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("unknown menu-bar style safely defaults to design one", Prefs.statusBarDesign == .divider)
        check("unknown per-provider style falls back to legacy then Divider",
              Prefs.rawStatusBarDesign(for: .cursor) == .divider)
        arguments["presentationMode"] = "unknown"
        arguments["darkMenuBarBackground"] = "unknown"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("fresh-style presentation defaults to per-source", Prefs.presentationMode == .perSource)
        arguments["presentationMode"] = "combined"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("saved combined display stays on per-source", Prefs.presentationMode == .perSource)
        arguments["usageRefreshMinutes"] = 0
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("usage refresh defaults to 1 minute", Prefs.usageRefreshMinutes == 1 && Prefs.usageRefreshInterval == 60)
        arguments["usageRefreshMinutes"] = 15
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("usage refresh keeps a listed interval", Prefs.usageRefreshMinutes == 15 && Prefs.usageRefreshInterval == 15 * 60)
        arguments["usageRefreshMinutes"] = 4
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("usage refresh rejects an unlisted interval", Prefs.usageRefreshMinutes == 1)
        arguments["rememberPanelPlace"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("panel returns to the overview unless asked to remember", !Prefs.rememberPanelPlace)
        arguments["rememberPanelPlace"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("panel can reopen where it left off", Prefs.rememberPanelPlace)
        check("fresh-style background defaults to capsule", Prefs.darkBarBackground)
        for style in StatusBarDesign.allCases {
            arguments["statusBarDesign"] = style.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            check("stored menu-bar style resolves \(style.number)", Prefs.statusBarDesign == style)
        }
        arguments["statusBarDesign.cursor"] = StatusBarDesign.stack.rawValue
        arguments["statusBarDesign.claude"] = StatusBarDesign.rings.rawValue
        arguments["cursorAccountMode"] = "work"
        arguments["claudeAccountMode"] = "personal"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("per-provider Compact stack survives work mode",
              Prefs.statusBarDesign(for: .cursor) == .stack)
        check("per-provider Twin gauges stays on personal Claude",
              Prefs.statusBarDesign(for: .claude) == .rings)
        arguments["claudeAccountMode"] = "work"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        check("per-provider Twin gauges clamps to Divider on work Claude",
              Prefs.statusBarDesign(for: .claude) == .divider)
        check("OpenAI is always spend-only", MenuBarProvider.openAI.isSpendOnly)
        check("owned keys include per-provider menu-bar styles",
              Prefs.ownedKeys.contains("statusBarDesign.cursor")
                && Prefs.ownedKeys.contains("statusBarDesign.openAI"))
        UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)

        check("alert thresholds normalize percent labels and duplicates", AllowanceAlertLedger.parseThresholds("5%, 15, 10, 10") == [15,10,5])
        for invalid in ["", "0, 5", "100", "five", "10.5"] { check("alert thresholds reject \(invalid)", AllowanceAlertLedger.parseThresholds(invalid) == nil) }
        func observation(_ percent: Int, provider: String = "chatgpt", window: String = "session", cycle: String = "a") -> AllowanceObservation {
            AllowanceObservation(providerID: provider, provider: "ChatGPT", windowID: window, window: "5-hour window", percent: percent, cycle: cycle, reset: "Nov 6, 2026 at 9:00 AM MST")
        }
        var ledger = AllowanceAlertLedger()
        check("healthy allowance does not alert", ledger.observe(observation(30), thresholds: [15,10,5]) == nil)
        check("15 percent alert fires", ledger.observe(observation(15), thresholds: [15,10,5]) == 15)
        check("repeat poll does not repeat alert", ledger.observe(observation(14), thresholds: [15,10,5]) == nil)
        check("10 percent alert fires separately", ledger.observe(observation(10), thresholds: [15,10,5]) == 10)
        check("5 percent alert fires separately", ledger.observe(observation(5), thresholds: [15,10,5]) == 5)
        check("weekly window alerts independently", ledger.observe(observation(10, window: "weekly"), thresholds: [15,10,5]) == 10)
        check("another provider alerts independently", ledger.observe(observation(10, provider: "claude"), thresholds: [15,10,5]) == 10)
        check("new reset cycle re-arms alerts", ledger.observe(observation(10, cycle: "b"), thresholds: [15,10,5]) == 10)
        _ = ledger.observe(observation(70, cycle: "b"), thresholds: [15,10,5])
        check("recovered allowance re-arms alerts", ledger.observe(observation(14, cycle: "b"), thresholds: [15,10,5]) == 15)
        var jump = AllowanceAlertLedger()
        check("large drop emits only most urgent crossed level", jump.observe(observation(4), thresholds: [15,10,5]) == 5)
        check("large drop marks less urgent levels handled", jump.observe(observation(9), thresholds: [15,10,5]) == nil)
        check("new less urgent threshold does not repeat a worse alert", jump.observe(observation(4), thresholds: [20,15,10,5]) == nil)
        check("new more urgent threshold can still alert", jump.observe(observation(2), thresholds: [20,15,10,5,3]) == 3)
        if let encoded = try? JSONEncoder().encode(jump), var restored = try? JSONDecoder().decode(AllowanceAlertLedger.self, from: encoded) {
            check("alert deduplication survives restart", restored.observe(observation(3), thresholds: [15,10,5]) == nil)
        } else { check("alert deduplication survives restart", false) }
        check("disabled thresholds do not alert", jump.observe(observation(1, cycle: "c"), thresholds: []) == nil)
        check("unknown percent is never fabricated as zero", jump.observe(observation(-1, cycle: "c"), thresholds: [15,10,5]) == nil)
        let content = AllowanceNotification.content(observation(9), threshold: 10, sound: false)
        check("notification names the app", content.title == "TokenPulse")
        check("notification names provider and actual remaining percent", content.subtitle == "ChatGPT · 9% left")
        check("notification names allowance window", content.body.contains("5-hour window allowance"))
        check("notification includes reset and provider route", content.body.contains("Nov 6") && content.userInfo["providerID"] as? String == "chatgpt")
        check("notification respects silent setting", content.sound == nil)
        let resetNow = ISO8601DateFormatter().date(from: "2026-11-01T20:00:00Z")!
        check("Claude reset uses source timezone", AllowanceReset.claudeDate("3:30pm (America/Los_Angeles)", fetchedAt: resetNow) == ISO8601DateFormatter().date(from: "2026-11-01T23:30:00Z"))
        check("Claude weekly reset has date and time", AllowanceReset.claudeDate("Nov 6, 9am (America/Denver)", fetchedAt: resetNow) == ISO8601DateFormatter().date(from: "2026-11-06T16:00:00Z"))
        check("unreported Claude reset stays unknown", AllowanceReset.claudeDate("not reported", fetchedAt: resetNow) == nil)
        let displayNow = denver.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 21, minute: 1))!
        let displayToday = denver.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 22, minute: 40))!
        let displayTomorrow = denver.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 1, minute: 57))!
        let displayLater = denver.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 14, minute: 58))!
        let displayNextYear = denver.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 8, minute: 30))!
        check("reset today leads with Today", ChatGPTUsageParse.displayDate(displayToday, now: displayNow, calendar: denver) == "Today at 10:40 PM MST")
        check("reset tomorrow leads with Tomorrow", ChatGPTUsageParse.displayDate(displayTomorrow, now: displayNow, calendar: denver) == "Tomorrow at 1:57 AM MST")
        check("later reset keeps the calendar date", ChatGPTUsageParse.displayDate(displayLater, now: displayNow, calendar: denver) == "Nov 7, 2026 at 2:58 PM MST")
        check("next-year reset keeps the calendar date", ChatGPTUsageParse.displayDate(displayNextYear, now: displayNow, calendar: denver) == "Jan 2, 2027 at 8:30 AM MST")

        if printResults {
            print("self-test \(fails == 0 ? "OK" : "FAILED (\(fails))")")
        }
        return fails
    }
}
