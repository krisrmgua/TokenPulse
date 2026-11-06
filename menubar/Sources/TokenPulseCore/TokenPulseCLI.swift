import AppKit
import Foundation
import UserNotifications

/// Process entry for the TokenPulse executable and CLI flags.
/// Kept in the library so `@testable` tests cover the same module as the app.
public enum TokenPulseCLI {
    public enum OutputPathError: Error, Equatable {
        case missingPath
        case looksLikeFlag(String)

        public var message: String {
            switch self {
            case .missingPath:
                return "requires an output PNG path"
            case .looksLikeFlag(let other):
                return "requires an output PNG path, not \(other)"
            }
        }
    }

    /// PNG path for `--menu-preview` / `--scoreboard-preview`.
    /// `.success(nil)` = flag absent (caller continues). Missing or flag-like
    /// next argv is `.failure` — never fall through to the GUI, which hangs.
    public static func outputPath(forFlag flag: String, in arguments: [String]) -> Result<String?, OutputPathError> {
        guard let i = arguments.firstIndex(of: flag) else { return .success(nil) }
        guard i + 1 < arguments.count else { return .failure(.missingPath) }
        let path = arguments[i + 1]
        if path.hasPrefix("-") { return .failure(.looksLikeFlag(path)) }
        return .success(path)
    }

    private static func printHelp() {
        print("""
        TokenPulse — subscription allowances + Claude / Cursor / OpenAI spend

          (no flags)                 run the menu-bar app
          -h, --help                 this text
          --print                    JSON rollup (local transcripts only)
          --selftest                 offline checks (no XCTest needed)
          --proxy-check              live configured proxy spend
          --cursor-check             live Cursor Dashboard spend
          --grok-bot-check           Grok Bot weekly usage via Cursor Sand API
          --chatgpt-check            ChatGPT weekly limit via Codex app server
          --chatgpt-work-check       ChatGPT workspace credits + USD estimate
          --claude-check             Claude Pro/Max limits via Claude /usage
          --openai-check             live OpenAI organization costs (local secret store)
          --reset-options            clear Options settings (keeps saved API keys)
          --menu-preview PATH        PNG of the dropdown (PATH is required)
          --scoreboard-preview PATH  PNG of the scoreboard (PATH is required)
          --mission-review           open the live Mission Control popover
          --mission-preview          isolated sample UI; no remote calls or saved edits
          --mission-work             sample work account modes (with --mission-preview)
          --mission-screen ROUTE     sample screen/submenu (with --mission-preview)
          --mission-capture PATH     sample UI PNG; requires --mission-preview
          --bar-design-preview PATH  offline proof sheet of all seven menu-bar styles
          --bar-render PATH          tray PNG via StatusBarArtwork (JSON on stdin)
          --provider-icon-preview PATH  themed and monochrome provider marks
          --notification-preview     send a clearly labeled macOS notification test
          --notification-status      macOS permission and test-delivery status
          --debug-sessions           dump this month's model-fit classification

        --menu-preview / --scoreboard-preview without PATH used to launch the
        GUI and hang. They now exit 2 instead.

        Build the repository app bundle:
          cd menubar && ./make-app.sh && open TokenPulse.app
        """)
    }

    public static func run() {

    if CommandLine.arguments.contains("--notification-status") || CommandLine.arguments.contains("--notification-preview") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if CommandLine.arguments.contains("--notification-status") {
                center.getDeliveredNotifications { delivered in
                    let result: [String: Any] = ["authorized": settings.authorizationStatus == .authorized,
                        "alertsEnabled": settings.alertSetting == .enabled, "deliveredCount": delivered.count,
                        "previewDelivered": delivered.contains { $0.request.identifier == "tokenpulse.preview" }]
                    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self)); exit(0)
                }
            } else {
                guard settings.authorizationStatus == .authorized, settings.alertSetting == .enabled else {
                    fputs("Enable TokenPulse notifications in macOS Notifications settings first.\n", stderr); exit(2)
                }
                let sample = AllowanceObservation(providerID: "chatgpt", provider: "ChatGPT", windowID: "session", window: "Preview · 5-hour", percent: 15, cycle: "preview", reset: nil)
                let content = AllowanceNotification.content(sample, threshold: 15, sound: false)
                content.subtitle = "Notification preview"
                content.body = "Allowance alerts include the provider, window and reset time."
                let identifier = "tokenpulse.preview"
                center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                    if let error { fputs("Notification failed: \(error.localizedDescription)\n", stderr); exit(1) }
                    print("TokenPulse test notification queued.")
                    AllowanceNotification.scheduleAutoDismiss(identifier: identifier)
                    // Stay alive until auto-dismiss clears the banner.
                    DispatchQueue.main.asyncAfter(deadline: .now() + AllowanceNotification.autoDismissSeconds + 1.5) { exit(0) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AllowanceNotification.autoDismissSeconds + 8) { fputs("Notification check timed out.\n", stderr); exit(1) }
        app.run()
        return
    }

    if CommandLine.arguments.contains("--provider-icon-preview") {
        switch outputPath(forFlag: "--provider-icon-preview", in: CommandLine.arguments) {
        case .success(let path?):
            do { try StatusBarPreview.writeIcons(to: path); exit(0) }
            catch { fputs("error: \(error)\n", stderr); exit(1) }
        default: fputs("error: --provider-icon-preview requires an output PNG path\n", stderr); exit(2)
        }
    }

    if CommandLine.arguments.contains("--bar-design-preview") {
        switch outputPath(forFlag: "--bar-design-preview", in: CommandLine.arguments) {
        case .success(let path?):
            do { try StatusBarPreview.write(to: path); exit(0) }
            catch { fputs("error: \(error)\n", stderr); exit(1) }
        default: fputs("error: --bar-design-preview requires an output PNG path\n", stderr); exit(2)
        }
    }

    if CommandLine.arguments.contains("--bar-render") {
        switch outputPath(forFlag: "--bar-render", in: CommandLine.arguments) {
        case .success(let path?):
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                try StatusBarRender.write(json: data, to: path)
                exit(0)
            } catch {
                fputs("error: \(error)\n", stderr); exit(1)
            }
        default: fputs("error: --bar-render requires an output PNG path\n", stderr); exit(2)
        }
    }

    if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
        printHelp()
        exit(0)
    }

    if CommandLine.arguments.contains("--mission-capture") {
        guard CommandLine.arguments.contains("--mission-preview") else {
            fputs("error: --mission-capture requires --mission-preview\n", stderr); exit(2)
        }
        if case .failure(let error) = outputPath(forFlag: "--mission-capture", in: CommandLine.arguments) {
            fputs("error: --mission-capture \(error.message)\n", stderr); exit(2)
        }
    }

    // Headless mode: parse once, print the rollup as JSON, exit. Used for
    // verification against ccusage and (later) pushing to the aggregator.
    if CommandLine.arguments.contains("--print") {
        let cfg = Config.load()
        let store = SpendStore(pricing: Pricing())
        let scan = TranscriptParser().scan()
        let r = store.rollup(from: scan.records)
        let eff = EfficiencyResult.compute(rollup: r, scan: scan, pricing: Pricing(), config: cfg)
        let out: [String: Any] = [
            "todayUSD": r.todayUSD,
            "monthUSD": r.monthUSD,
            "opusUSD": r.opusUSD,
            "opusShare": r.opusShare,
            "sessions": r.sessions,
            "cacheHitPct": r.cacheHitPct,
            "costPerSessionUSD": r.costPerSessionUSD,
            "projectedMonthEndUSD": r.projectedMonthEndUSD,
            "byModelUSD": r.byModelUSD,
            "efficiency": [
                "score": eff.score,
                "grade": eff.grade,
                "modelFitPoints": eff.modelFitPoints,
                "contextPoints": eff.contextPoints,
                "costPoints": eff.costPoints,
                "rightModelPct": eff.modelFit.rightModelPct,
                "lightTurnShare": eff.modelFit.lightTurnShare,
                "recoverableUSD": eff.modelFit.recoverableUSD,
                "advisorCostUSD": eff.modelFit.advisorCostUSD,
                "contextPerTurnMedian": eff.context.contextPerTurnMedian,
                "churn": eff.context.churn,
                "contextCostShare": eff.context.contextCostShare,
                "bigReadFlag": eff.context.bigReadFlag,
                "topTip": eff.topTip,
                "offenders": eff.modelFit.offenders.map {
                    ["label": $0.label, "reason": $0.reason,
                     "opusUSD": $0.opusUSD, "sonnetUSD": $0.sonnetUSD, "savingsUSD": $0.savingsUSD]
                },
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    }

    // Exercises the configured proxy spend endpoint once. Verification only —
    // the running app calls this asynchronously off a 5-minute timer instead.
    if CommandLine.arguments.contains("--proxy-check") {
        guard ProxySpendConfig.endpoint() != nil else {
            print("No proxy spend URL. Set TOKENPULSE_PROXY_SPEND_URL or ~/Library/Application Support/TokenPulse/proxy-spend-url.")
            exit(1)
        }
        guard ProxyKeyCache.validKey() != nil else {
            print("No valid cached proxy key at \(ProxySpendConfig.keysFile().path).")
            exit(1)
        }
        // Masks the identifying part of an email so this verification tool's
        // output — which can end up in shell history, a screen share, or a
        // pasted support ticket — confirms the round-trip worked without
        // echoing a real identity attached to real spend figures.
        func maskEmail(_ s: String) -> String {
            guard let at = s.firstIndex(of: "@"), at > s.startIndex else { return "***" }
            return "\(s[s.startIndex])***\(s[at...])"
        }
        let sem = DispatchSemaphore(value: 0)
        ProxyReconciler().currentSpend { resp in
            if let resp {
                print("OK: end_user_id=\(maskEmail(resp.endUserId)) window=\(resp.startDate)..\(resp.endDate)")
                print("total_spend=\(resp.totalSpend) total_requests=\(resp.totalRequests)")
                for m in resp.byModel { print("  \(m.model): $\(m.spend) (\(m.apiRequests) reqs)") }
            } else {
                print("FAILED — no response (network error, non-200, or decode failure)")
            }
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + 15)
        if waitResult == .timedOut {
            print("TIMED OUT after 15s waiting for GET /spend/end_user")
            exit(1)
        }
        exit(0)
    }

    // Exercises personal Cursor Dashboard spend once (GetMe + userId-scoped
    // GetAggregatedUsageEvents). Auth from Cursor's local state.vscdb — never
    // used by the running app's 5-minute timer path as a sync call.
    if CommandLine.arguments.contains("--cursor-check") {
        guard CursorAuthCache.accessToken() != nil else {
            print("No Cursor access token at \(CursorAuthCache.stateDBURL.path) — sign in to Cursor first.")
            exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        CursorSpendClient().currentSpend(force: true) { snap in
            if let snap {
                print("OK: userId=\(snap.userId) models=\(snap.byModel.count)")
                print("today_spend=\(String(format: "%.2f", snap.todaySpendUSD)) total_spend=\(String(format: "%.2f", snap.totalSpendUSD))")
                if let plan = snap.planUsage {
                    print(String(format: "plan_limit=%.2f included_spend=%.2f total_percent_used=%.1f percent_left=%d",
                                 plan.limitUSD, plan.includedSpendUSD, plan.totalPercentUsed, plan.percentLeft))
                    if let reset = plan.resetDescription {
                        print("billing_cycle_resets=\(reset)")
                    }
                    if let start = plan.billingCycleStart {
                        print("billing_cycle_start=\(ChatGPTUsageParse.displayDate(start))")
                    }
                }
                for m in snap.byModel {
                    print(String(format: "  %@: $%.2f  in=%d out=%d cache_w=%d cache_r=%d",
                                 m.model, m.spendUSD, m.inputTokens, m.outputTokens,
                                 m.cacheWriteTokens, m.cacheReadTokens))
                }
            } else {
                print("FAILED — no response (network error, non-200, or decode failure)")
            }
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + 20)
        if waitResult == .timedOut {
            print("TIMED OUT after 20s waiting for Cursor DashboardService")
            exit(1)
        }
        exit(0)
    }

    // Grok Bot weekly Sand meter (GetSandUsageStatus). Same Cursor bearer token
    // as --cursor-check; API usagePercent is % used — we print percent_left.
    if CommandLine.arguments.contains("--grok-bot-check") {
        guard CursorAuthCache.accessToken() != nil else {
            print("No Cursor access token at \(CursorAuthCache.stateDBURL.path) — sign in to Cursor first.")
            exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        var succeeded = false
        GrokBotUsageClient().testConnection { result in
            switch result {
            case .success(let snap):
                succeeded = true
                print("OK: Grok Bot weekly usage via GetSandUsageStatus")
                print(String(format: "percent_used=%.1f percent_left=%d",
                             snap.percentUsed, snap.percentLeft))
                print("resets=\(snap.resetDescription)")
                if let plan = snap.planLabel { print("plan=\(plan)") }
                if let cursor = snap.cursorPlanName { print("cursor_plan=\(cursor)") }
            case .failure(let error):
                print("FAILED — \(error.userMessage)")
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 20) == .timedOut {
            print("TIMED OUT after 20s waiting for GetSandUsageStatus")
            exit(1)
        }
        exit(succeeded ? 0 : 1)
    }

    // The ChatGPT subscription meter is exposed by the Codex app server as a
    // structured account/rateLimits/read response. It uses the existing Codex
    // login and never reads or prints the underlying credential.
    if CommandLine.arguments.contains("--chatgpt-check") {
        let sem = DispatchSemaphore(value: 0)
        var succeeded = false
        ChatGPTUsageClient().testConnection { result in
            switch result {
            case .success(let snapshot):
                succeeded = true
                print("OK: ChatGPT weekly limit via Codex app server")
                print("percent_left=\(snapshot.percentLeft)")
                print("resets=\(snapshot.resetDescription)")
                print("codex=\(snapshot.codexPath)")
            case .failure(let error):
                print("FAILED — \(error.userMessage)")
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 40) == .timedOut {
            print("TIMED OUT after 40s waiting for Codex account usage")
            exit(1)
        }
        exit(succeeded ? 0 : 1)
    }

    if CommandLine.arguments.contains("--chatgpt-work-check") {
        let sem = DispatchSemaphore(value: 0)
        var succeeded = false
        ChatGPTWorkUsageClient().testConnection { result in
            switch result {
            case .success(let snapshot):
                succeeded = true
                print("OK: ChatGPT work usage")
                print("today_credits=\(Fmt.credits(snapshot.todayCredits))")
                print("today_pending=\(snapshot.todayIsPending)")
                if let freshness = snapshot.dataFreshnessAt {
                    print("data_fresh_through=\(ISO8601DateFormatter().string(from: freshness))")
                }
                print("month_credits=\(Fmt.credits(snapshot.monthCredits))")
                print("estimated_usd=\(String(format: "%.2f", snapshot.estimatedUSD))")
                print("pro_200_equivalents=\(String(format: "%.2f", snapshot.proPlanEquivalents))")
                print("estimate_source=\(snapshot.estimateUsesPublicRateCard ? "public_rate_card" : "workspace")")
            case .failure(let error):
                print("FAILED — \(error.userMessage)")
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 40) == .timedOut {
            print("TIMED OUT after 40s waiting for ChatGPT work usage")
            exit(1)
        }
        exit(succeeded ? 0 : 1)
    }

    // Claude subscription quota stays inside the official CLI. The client
    // drives `/usage` through a pseudo-terminal and parses only its displayed
    // percentages/reset labels; it never reads or prints OAuth credentials.
    if CommandLine.arguments.contains("--claude-check") {
        let sem = DispatchSemaphore(value: 0)
        var succeeded = false
        ClaudeUsageClient().testConnection { result in
            switch result {
            case .success(let snapshot):
                succeeded = true
                print("OK: Claude subscription limits via Claude CLI /usage")
                if let session = snapshot.session {
                    print("session_percent_left=\(session.percentLeft)")
                    print("session_resets=\(session.resetDescription)")
                }
                if let weekly = snapshot.weekly {
                    print("weekly_percent_left=\(weekly.percentLeft)")
                    print("weekly_resets=\(weekly.resetDescription)")
                }
                print("claude=\(snapshot.claudePath)")
            case .failure(let error):
                print("FAILED — \(error.userMessage)")
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 45) == .timedOut {
            print("TIMED OUT after 45s waiting for Claude /usage")
            exit(1)
        }
        exit(succeeded ? 0 : 1)
    }

    // Explicit OpenAI Organization Costs smoke test. The Admin key is read from
    // local storage and is never printed or accepted as an argument.
    if CommandLine.arguments.contains("--openai-check") {
        guard OpenAIKeychain.apiKey() != nil else {
            print("No OpenAI Admin API key configured — set it from TokenPulse → Options → OpenAI API.")
            exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        var succeeded = false
        OpenAISpendClient().testConnection { result in
            switch result {
            case .success(let snapshot):
                succeeded = true
                print("OK: OpenAI Platform organization costs")
                print("today_spend=\(String(format: "%.2f", snapshot.todaySpendUSD)) "
                    + "month_spend=\(String(format: "%.2f", snapshot.monthSpendUSD))")
                if let balance = snapshot.estimatedBalanceUSD {
                    print("estimated_prepaid_balance=\(String(format: "%.2f", balance))")
                } else {
                    print("estimated_prepaid_balance=not_set")
                }
                for line in snapshot.byLineItem {
                    print(String(format: "  %@: $%.2f", line.lineItem, line.spendUSD))
                }
            case .failure(let error):
                print("FAILED — \(error.userMessage)")
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 45) == .timedOut {
            print("TIMED OUT after 45s waiting for OpenAI Organization Costs")
            exit(1)
        }
        exit(succeeded ? 0 : 1)
    }

    // Same path as Options › Reset to defaults…, for support and for anyone
    // whose stored layout leaves the menu bar unreadable.
    if CommandLine.arguments.contains("--reset-options") {
        // A running instance holds these keys in its own UserDefaults cache and
        // can write them back after an outside deletion, undoing the reset.
        let mine = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.kris.tokenpulse")
            .filter { $0.processIdentifier != mine }
        if !running.isEmpty {
            print("Quit TokenPulse first — a running instance can restore its cached settings.")
            exit(1)
        }
        Prefs.resetToDefaults()
        UserDefaults.standard.synchronize()
        print("Options reset to defaults. Saved API keys were kept.")
        print("  display: \(Prefs.presentationMode.rawValue)")
        print("  spend colors: \(Prefs.spendColorsEnabled)")
        print("  dark menu-bar background: \(Prefs.darkBarBackground)")
        print("  showing: Cursor=\(Prefs.showCursorInBar) Claude=\(Prefs.showClaudeInBar) "
              + "ChatGPT=\(Prefs.showChatGPTInBar) OpenAI=\(Prefs.showOpenAIInBar)")
        exit(0)
    }

    // Offline checks (same suite as Tests/TokenPulseCoreTests via SelfChecks).
    if CommandLine.arguments.contains("--selftest") {
        exit(TokenPulseSelfChecks.runAll(printResults: true) == 0 ? 0 : 1)
    }


    // Debug: dump per-session model-fit classification for the current month.
    if CommandLine.arguments.contains("--debug-sessions") {
        let pricing = Pricing()
        let scan = TranscriptParser().scan()
        let aggs = sessionAggregates(scan, pricing: pricing).sorted { $0.opusCost > $1.opusCost }
        print("turns | light | opus$ | lightSave | label")
        for a in aggs where a.opusCost > 0 {
            let line = "\(a.turns) | \(a.lightTurns) | "
                + String(format: "$%.2f | $%.2f", a.opusCost, a.lightSavings)
                + " | \(ContextResult.label(for: a))"
            print(line)
        }

        // Turn-level lightweight-Opus analysis (what session-level misses).
        let cal = Calendar.current
        let now = Date()
        var opusTurns = 0, lightTurns = 0
        var opusCost = 0.0, lightAtSonnet = 0.0, lightAtOpus = 0.0
        for r in scan.records where r.model.contains("opus")
            && cal.isDate(r.date, equalTo: now, toGranularity: .month) {
            opusTurns += 1
            let c = pricing.cost(input: r.input, cacheWrite: r.cacheWrite, cacheRead: r.cacheRead, output: r.output, model: r.model)
            opusCost += c
            if r.output < 250 && r.toolUseCount == 0 {     // lightweight: tiny output, no tools
                lightTurns += 1
                lightAtOpus += c
                lightAtSonnet += pricing.cost(input: r.input, cacheWrite: r.cacheWrite, cacheRead: r.cacheRead, output: r.output, model: "claude-sonnet-5")
            }
        }
        print("opus turns: \(opusTurns)  lightweight(no-tool,<250 out): \(lightTurns) (\(opusTurns>0 ? lightTurns*100/opusTurns : 0)%)")
        print(String(format: "lightweight opus $: %.2f of %.2f  (%.0f%% of opus $)", lightAtOpus, opusCost, opusCost>0 ? lightAtOpus/opusCost*100 : 0))
        print(String(format: "  would cost at Sonnet: %.2f  → save %.2f", lightAtSonnet, lightAtOpus - lightAtSonnet))
        exit(0)
    }

    // Offscreen render of the dropdown rows to a PNG — deterministic proof of the
    // menu rendering (colors, layout) without needing the live menu open.
    switch outputPath(forFlag: "--menu-preview", in: CommandLine.arguments) {
    case .failure(let err):
        fputs("error: --menu-preview \(err.message), e.g. TokenPulse --menu-preview /tmp/out.png\nWithout a path this used to launch the GUI and hang.\n", stderr)
        exit(2)
    case .success(nil):
        break
    case .success(let outPath?):
        _ = NSApplication.shared   // init AppKit for offscreen drawing
        let cfg = Config.load()
        let store = SpendStore(pricing: Pricing())
        let scan = TranscriptParser().scan()
        let r = store.rollup(from: scan.records)
        let eff = EfficiencyResult.compute(rollup: r, scan: scan, pricing: Pricing(), config: cfg)
        let rows = tokenpulseMenuRows(r, eff, cfg)

        let width: CGFloat = 360, padX: CGFloat = 14
        // Measure total height.
        var labels: [(NSTextField?, CGFloat)] = []  // nil = separator
        var total: CGFloat = 12
        for row in rows {
            switch row {
            case .separator:
                labels.append((nil, 9)); total += 9
            case .submenu(let title, let titleTints, _):
                // Preview shows the collapsed parent only (live menu uses a real submenu).
                let text = "\(title)  ›"
                let tf = NSTextField(labelWithString: text)
                tf.font = .systemFont(ofSize: 13)
                tf.textColor = .labelColor
                tf.attributedStringValue = MenuText.attributed(
                    text, font: .systemFont(ofSize: 13), tints: titleTints)
                tf.sizeToFit()
                labels.append((tf, 22)); total += 22
            case .header(let s):
                let tf = NSTextField(labelWithString: s)
                tf.font = .boldSystemFont(ofSize: 13)
                tf.textColor = .labelColor
                tf.sizeToFit()
                labels.append((tf, 22)); total += 22
            case .body(let s, let tints):
                let tf = NSTextField(labelWithString: s)
                tf.font = .systemFont(ofSize: 13)
                tf.textColor = .labelColor
                tf.attributedStringValue = MenuText.attributed(
                    s, font: .systemFont(ofSize: 13), tints: tints)
                tf.sizeToFit()
                labels.append((tf, 22)); total += 22
            }
        }
        total += 12

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        // The preview paints a dark background, so resolve labelColor and the
        // spend tints against the dark appearance rather than the host's.
        container.appearance = NSAppearance(named: .darkAqua)
        var y = total - 12
        for (tf, h) in labels {
            y -= h
            if let tf = tf {
                tf.setFrameOrigin(NSPoint(x: padX, y: y + (h - tf.frame.height) / 2))
                container.addSubview(tf)
            } else {
                let line = NSView(frame: NSRect(x: padX, y: y + h / 2, width: width - 2 * padX, height: 1))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor
                container.addSubview(line)
            }
        }

        if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
            container.cacheDisplay(in: container.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: outPath))
                print("wrote \(outPath)")
            }
        }
        exit(0)
    }

    // Offscreen render of the scoreboard window to PNG — visual proof.
    switch outputPath(forFlag: "--scoreboard-preview", in: CommandLine.arguments) {
    case .failure(let err):
        fputs("error: --scoreboard-preview \(err.message), e.g. TokenPulse --scoreboard-preview /tmp/out.png\nWithout a path this used to launch the GUI and hang.\n", stderr)
        exit(2)
    case .success(nil):
        break
    case .success(let outPath?):
        _ = NSApplication.shared
        let cfg = Config.load()
        let pricing = Pricing()
        let scan = TranscriptParser().scan()
        let r = SpendStore(pricing: pricing).rollup(from: scan.records)
        let eff = EfficiencyResult.compute(rollup: r, scan: scan, pricing: pricing, config: cfg)
        let model = ScoreboardModel.build(eff: eff, rollup: r, history: History())
        ScoreboardController.renderPNG(model, to: outPath)
        exit(0)
    }

    if !CommandLine.arguments.contains("--mission-preview") { BrandMigration.run() }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu-bar-only: no Dock icon, no main window.
    app.setActivationPolicy(.accessory)
    app.run()
    }
}
