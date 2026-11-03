import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let mission = MissionModel()
    private let popover = NSPopover()
    private var reviewWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var allowanceLedger = AllowanceAlertLedger.load()
    private var allowanceInFlight: Set<String> = []
    private var notificationPermission = false
    private var notificationStatus = "Checking macOS notification permission…"
    private var lastPermissionCheck = Date.distantPast

    private var visibleUnitRects: [String: NSRect] = [:]
    private var timer: Timer?

    private let config: Config = {
        var config = Config.load()
        if CommandLine.arguments.contains("--mission-preview") { config.showEfficiencyDetails = true }
        return config
    }()
    private let parser = TranscriptParser()
    private let pricing = Pricing()
    private lazy var store = SpendStore(pricing: pricing)

    /// Most recent efficiency result — used by the scoreboard window action.
    private var lastEfficiency: EfficiencyResult?
    private var lastRollup: Rollup?
    private var history = History()
    private var spendLedger = SpendLedger()

    /// Last day (yyyy-ddd) we fired the Opus alert — rate-limits to ~1/day.
    private var lastOpusAlertKey: String?

    /// UserNotifications crashes when the process has no bundle identifier
    /// (e.g. a bare `swift run` binary). Only use it from a real .app bundle.
    private let notificationsAvailable = Bundle.main.bundleIdentifier != nil

    /// Separate fast watchdog so a culled item is restored within seconds,
    /// independent of the (slower) transcript-scan poll.
    private var watchdog: Timer?

    /// GET /spend/end_user is the source of truth for Month/By-model when a
    /// valid personal-key credential exists — see ProxySpend.swift and the
    /// README's "Local vs proxy spend" section. Its own timer, decoupled
    /// from the fast local-scan poll — shares `config.remotePollInterval`
    /// with Cursor.
    private lazy var proxyReconciler = ProxyReconciler(
        minRefreshInterval: Prefs.usageRefreshInterval)
    private var proxyTimer: Timer?
    private var lastProxySpend: ProxySpendResponse?

    /// Personal Cursor Dashboard spend (separate from Claude/proxy). Same
    /// remote courtesy throttle as the proxy — see CursorSpend.swift.
    private lazy var cursorClient = CursorSpendClient(
        minRefreshInterval: Prefs.usageRefreshInterval)
    private var cursorTimer: Timer?
    private var lastCursorSpend: CursorSpendSnapshot?

    /// OpenAI Platform API organization costs. Auth lives only in Keychain.
    private lazy var openAIClient = OpenAISpendClient(
        minRefreshInterval: Prefs.usageRefreshInterval)
    private var openAITimer: Timer?
    private var lastOpenAISpend: OpenAISpendSnapshot?

    /// ChatGPT/Codex subscription allowance from the signed-in Codex CLI's
    /// app-server account usage. This is a percentage/reset meter, not API
    /// spend, and is rendered as its own menu-bar block.
    private lazy var chatGPTClient = ChatGPTUsageClient(
        minRefreshInterval: Prefs.usageRefreshInterval)
    private lazy var chatGPTWorkClient = ChatGPTWorkUsageClient(
        minRefreshInterval: Prefs.usageRefreshInterval)
    private var chatGPTTimer: Timer?
    private var lastChatGPTUsage: ChatGPTUsageSnapshot?
    private var lastChatGPTWorkUsage: ChatGPTWorkUsageSnapshot?

    /// Claude Pro/Max subscription allowance from the signed-in official
    /// Claude CLI's `/usage` view. Work mode continues to use transcript/proxy
    /// spend; personal mode uses this percentage meter instead.
    private lazy var claudeUsageClient = ClaudeUsageClient(
        minRefreshInterval: Prefs.usageRefreshInterval)
    private var claudeUsageTimer: Timer?
    private var lastClaudeUsage: ClaudeUsageSnapshot?

    /// Grok Bot weekly Sand allowance via Cursor Dashboard GetSandUsageStatus.
    private lazy var grokBotClient = GrokBotUsageClient(
        minRefreshInterval: Prefs.usageRefreshInterval)
    private var grokBotTimer: Timer?
    private var lastGrokBotUsage: GrokBotUsageSnapshot?

    /// Transcript scan can take longer than `pollInterval` on a full
    /// ~/.claude tree — without this, overlapping utility-queue scans peg
    /// a core at ~100% and starve UI updates (menu-bar icon never settles).
    private var refreshInFlight = false

    /// Failed refreshes keep the last snapshot; once it outlives a couple of
    /// poll cycles its bar segment fades in and out slowly instead of vanishing.
    private var staleBlinkTimer: Timer?
    private var staleBlinkDimmed = false
    private var lastBarSegments: [StatusSegment] = []
    private var lastBarChatGPT: (personal: ChatGPTUsageSnapshot?,
                                 work: ChatGPTWorkUsageSnapshot?, stale: Bool) = (nil, nil, false)

    private func isStale(_ fetchedAt: Date) -> Bool {
        Date().timeIntervalSince(fetchedAt) > Prefs.usageRefreshInterval * 2.5
    }

    /// Menu-bar-only app: closing the Scoreboard window must NOT quit it.
    /// Without this, closing the last window terminates the process and the icon
    /// vanishes for good.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ note: Notification) {
        Prefs.retireCombinedPresentation()
        if CommandLine.arguments.contains("--mission-preview") {
            configureMissionControl()
            installStatusItem()
            seedMissionFixtures()
            return
        }
        configureMissionControl()
        installStatusItem()

        if notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
            let open = UNNotificationAction(identifier: "open-tokenpulse", title: "Review usage", options: [.foreground])
            UNUserNotificationCenter.current().setNotificationCategories([
                UNNotificationCategory(identifier: "tokenpulse.opus", actions: [open], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: AllowanceNotification.category, actions: [open], intentIdentifiers: [], options: [])])
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
                    if let error { NSLog("TokenPulse notification authorization failed: %@", error.localizedDescription) }
                    DispatchQueue.main.async {
                    self?.checkNotificationPermission(force: true)
                    if granted && CommandLine.arguments.contains("--notification-preview") { self?.sendTestNotification() }
                } }
            checkNotificationPermission(force: true)
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: config.pollInterval,
                                     repeats: true) { [weak self] _ in self?.refresh() }

        // Self-heal: macOS (esp. for ad-hoc-signed accessory apps) can quietly
        // pull a status item from the bar. Re-add it if that happens.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) {
            [weak self] _ in self?.ensureStatusItem()
        }

        refreshProxySpend()

        // Defer Cursor fetch one run-loop turn so the status item paints
        // before any Dashboard network work begins.
        DispatchQueue.main.async { [weak self] in self?.refreshCursorSpend() }

        DispatchQueue.main.async { [weak self] in
            OpenAIKeychain.migrateFromKeychainIfNeeded()
            self?.promptOpenAIKeyMigrationIfNeeded()
            self?.refreshOpenAISpend()
        }

        DispatchQueue.main.async { [weak self] in self?.refreshChatGPTUsage() }
        DispatchQueue.main.async { [weak self] in self?.refreshClaudeUsage() }
        DispatchQueue.main.async { [weak self] in self?.refreshGrokBotUsage() }
        scheduleUsageTimers()

        staleBlinkTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) {
            [weak self] _ in self?.tickStaleBlink()
        }
    }

    /// Repeating checks for ChatGPT, Claude, Cursor, Grok, OpenAI, and proxy usage.
    private func scheduleUsageTimers() {
        let interval = Prefs.usageRefreshInterval
        proxyReconciler.setMinRefreshInterval(interval)
        cursorClient.setMinRefreshInterval(interval)
        openAIClient.setMinRefreshInterval(interval)
        chatGPTClient.setMinRefreshInterval(interval)
        chatGPTWorkClient.setMinRefreshInterval(interval)
        claudeUsageClient.setMinRefreshInterval(interval)
        grokBotClient.setMinRefreshInterval(interval)
        proxyTimer?.invalidate()
        cursorTimer?.invalidate()
        openAITimer?.invalidate()
        chatGPTTimer?.invalidate()
        claudeUsageTimer?.invalidate()
        grokBotTimer?.invalidate()
        proxyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refreshProxySpend() }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refreshCursorSpend() }
        openAITimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refreshOpenAISpend() }
        chatGPTTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refreshChatGPTUsage() }
        claudeUsageTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refreshClaudeUsage() }
        grokBotTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refreshGrokBotUsage() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { completionHandler(); return }
        DispatchQueue.main.async {
            let content = response.notification.request.content
            let title = content.userInfo["advisoryTitle"] as? String ?? content.title
            if !self.mission.advisories.contains(where: { $0.title == title && $0.body == content.body }) {
                self.mission.advisories.insert(MissionAdvisory(provider: content.userInfo["provider"] as? String ?? (content.categoryIdentifier == "tokenpulse.opus" ? "Claude" : "Unknown provider"), scope: content.userInfo["scope"] as? String ?? "Local Claude Code sessions · this month", title: title, body: content.body), at: 0)
            }
            self.mission.show(content.userInfo["providerID"] as? String ?? "alerts")
            if !self.popover.isShown { self.toggleMissionControl() }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }

    private func tickStaleBlink() {
        let anyStale = lastBarSegments.contains { $0.stale } || lastBarChatGPT.stale
        guard anyStale || staleBlinkDimmed else { return }
        staleBlinkDimmed = anyStale ? !staleBlinkDimmed : false
        applyStatusTitle()
    }

    private func applyStatusTitle() {
        guard let button = statusItem?.button else { return }
        let blocks = statusBarBlocks()
        if !blocks.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = StatusBarArtwork.image(blocks: blocks, design: Prefs.statusBarDesign, dimStale: staleBlinkDimmed)
            button.image?.isTemplate = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.setAccessibilityLabel(blocks.map(\.accessibilityLabel).joined(separator: "; "))
            button.toolTip = blocks.map(\.accessibilityLabel).joined(separator: "\n")
            return
        }
        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = statusTitle(
            lastBarSegments,
            chatGPT: lastBarChatGPT.personal,
            chatGPTWork: lastBarChatGPT.work,
            chatGPTStale: lastBarChatGPT.stale,
            dimStale: staleBlinkDimmed)
    }

    private func statusBarBlocks() -> [StatusBarBlock] {
        func color(_ tint: SpendTint, _ style: GoodZoneStyle) -> NSColor {
            Prefs.spendColorsEnabled ? tint.barColor(goodStyle: style) ?? MenuBarPalette.label : MenuBarPalette.label
        }
        func quota(_ label: String, _ percent: Int, _ colors: RemainingColorConfig, value: String? = nil) -> StatusBarMetric {
            StatusBarMetric(label: label, value: value ?? "\(percent)%", percent: Double(percent), color: color(colors.level(for: Double(percent)), colors.goodStyle))
        }
        func spend(_ today: Double, _ month: Double, _ colors: SpendUpColorConfig, _ policy: Double, _ source: BarSpendSource, pending: Bool = false) -> [StatusBarMetric] {
            let cap = colors.effectiveCap(policyUSD: policy)
            var metrics: [StatusBarMetric] = []
            if Prefs.showDailyInBar(for: source) {
                metrics.append(StatusBarMetric(label: "D", value: pending ? "—" : Fmt.money(today), color: pending ? MenuBarPalette.secondaryLabel : color(SpendTint.levelSpendUp(today, cap: SpendTint.dailyCap(cap), orangePercent: colors.orangePercent, yellowPercent: colors.yellowPercent), colors.goodStyle)))
            }
            if Prefs.showMonthlyInBar(for: source) { metrics.append(StatusBarMetric(label: "M", value: Fmt.money(month), color: color(colors.level(for: month, policyUSD: policy), colors.goodStyle))) }
            return metrics
        }
        var blocks: [StatusBarBlock] = []
        let chatIcon = ProviderArtwork.image("ChatGPT", original: chatGPTIcon() ?? glyphImage(Self.openAIGlyphs))
        if let work = lastBarChatGPT.work {
            blocks.append(StatusBarBlock(provider: "ChatGPT work estimate", icon: chatIcon, metrics: spend(work.todayEstimatedUSD, work.estimatedUSD, Prefs.chatGPTWorkColors(), ChatGPTWorkUsageSnapshot.proPlanMonthlyUSD, .chatGPTWork, pending: work.todayIsPending), stale: lastBarChatGPT.stale))
        } else if let personal = lastBarChatGPT.personal {
            var metrics: [StatusBarMetric] = []
            if let session = personal.session { metrics.append(quota("5H", session.percentLeft, Prefs.chatGPTColors())) }
            metrics.append(quota("W", personal.percentLeft, Prefs.chatGPTColors()))
            blocks.append(StatusBarBlock(provider: "ChatGPT", icon: chatIcon, metrics: metrics, stale: lastBarChatGPT.stale))
        }
        for segment in lastBarSegments {
            let provider = segment.glyphNames == Self.cursorGlyphs ? "Cursor" : segment.glyphNames == Self.claudeGlyphs ? "Claude" : segment.glyphNames == Self.grokBotGlyphs ? "Grok Bot" : "OpenAI API"
            let original = provider == "Grok Bot" ? grokBotIcon() ?? glyphImage(segment.glyphNames) : provider == "OpenAI API" && Prefs.themedProviderLogos ? chatGPTIcon() ?? glyphImage(segment.glyphNames) : glyphImage(segment.glyphNames)
            var metrics: [StatusBarMetric] = []
            switch segment.display {
            case .spend(let today, let month, let colors, let policy, let source): metrics = spend(today, month, colors, policy, source)
            case .remainingPercent(let percent, let colors): metrics = [quota("", percent, colors)]
            case .remainingPercentLabel(let value, let percent, let colors): metrics = [quota(provider == "Grok Bot" ? "W" : "Pro", percent, colors, value: value)]
            case .remainingSessionAndWeekly(let session, let weekly, let colors):
                if let session { metrics.append(quota("5H", session.percentLeft, colors, value: session.personalBarPercent)) }
                if let weekly { metrics.append(quota("W", weekly.percentLeft, colors, value: weekly.personalBarPercent)) }
            case .remainingBalance(let balance, let colors): metrics = [StatusBarMetric(label: "B", value: balance.map(Fmt.money) ?? "—", color: balance.map { color(colors.level(for: $0), colors.goodStyle) } ?? MenuBarPalette.secondaryLabel)]
            }
            blocks.append(StatusBarBlock(provider: provider, icon: ProviderArtwork.image(provider, original: original), metrics: metrics, stale: segment.stale))
        }
        return blocks
    }

    /// Create the status item and seed it so it has width immediately.
    private func installStatusItem() {
        let autosaveName = "com.kris.tokenpulse.status.v3"
        let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"

        // AppKit's saved positions on this display are a few hundred points
        // from the right edge. Older builds forced 10,000, which put the item
        // off-screen; leaving the key absent can also place a newly rebuilt
        // item at the far-left edge behind a MacBook notch. Seed a conservative
        // visible position, but preserve positions users set by Command-dragging.
        let savedPosition = UserDefaults.standard.object(forKey: preferredPositionKey) as? NSNumber
        if savedPosition == nil || savedPosition?.doubleValue == 10_000.0 {
            UserDefaults.standard.set(350.0, forKey: preferredPositionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = NSStatusItem.AutosaveName(autosaveName)
        statusItem.isVisible = true
        // Non-empty title immediately so the item has width before the first
        // async scan finishes (otherwise it can be culled as empty).
        seedStatusButton()
        statusItem.button?.title = " $…"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleMissionControl)
    }

    private func seedStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.imagePosition = .noImage
    }

    /// Re-pin visibility if the system hid us. Do NOT treat a nil
    /// `button.window` as "dropped" — on recent macOS that property can stay
    /// nil (or lag) while the item is still in the bar; remove+recreate in
    /// that case prevents the icon from ever sticking.
    private func ensureStatusItem() {
        if statusItem == nil {
            installStatusItem()
            if let r = lastRollup, let eff = lastEfficiency {
                render(displayRollup(for: r), eff)
            }
            return
        }
        if !statusItem.isVisible {
            statusItem.isVisible = true
        }
    }

    private func configureMissionControl() {
        popover.behavior = .transient
        popover.delegate = self
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, self.popover.isShown, let clicked = event.window,
               clicked !== self.popover.contentViewController?.view.window,
               clicked !== self.statusItem.button?.window,
               clicked.level.rawValue < NSWindow.Level.popUpMenu.rawValue, NSApp.modalWindow == nil {
                self.popover.performClose(nil)
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        popover.contentSize = NSSize(width: 780, height: 620)
        popover.contentViewController = NSHostingController(rootView: MissionControlView(model: mission))
        popover.contentViewController?.view.appearance = NSAppearance(named: .darkAqua)
        mission.refresh = { [weak self] in self?.refreshNow() }
        mission.invoke = { [weak self] item in
            guard let self, let action = item.action, item.isEnabled else { return }
            let name = NSStringFromSelector(action)
            if name.hasPrefix("custom") || ["setOpenAIKey", "testOpenAIConnection", "setOpenAIEstimatedBalance", "removeOpenAIKey", "resetOptionsToDefaults"].contains(name) {
                self.popover.performClose(nil)
            }
            NSApp.sendAction(action, to: item.target, from: item)
            self.rerender()
        }
        mission.resize = { [weak self] size in
            guard let self else { return }
            self.popover.contentSize = size
            if let window = self.reviewWindow {
                let top = window.frame.maxY
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
            }
        }
        if CommandLine.arguments.contains("--mission-preview") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "TokenPulse — Mission Control review"
            window.contentView = NSHostingView(rootView: MissionControlView(model: mission))
            window.appearance = NSAppearance(named: .darkAqua)
            reviewWindow = window
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else if CommandLine.arguments.contains("--mission-review") {
            // Live review uses the production popover, so it cannot leave an
            // always-open debug window on the user's desktop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.toggleMissionControl()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if !Prefs.rememberPanelPlace { mission.show("overview") }
        if CommandLine.arguments.contains("--mission-review") { NSLog("Mission Control popover closed") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    /// Deterministic visual review: no provider requests, transcript scan, history writes,
    /// key edits or persistent preference changes. Actions below are intercepted locally.
    private func seedMissionFixtures() {
        var defaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in ["enabledChatGPT", "enabledCursor", "enabledGrokBot", "enabledOpenAI", "enabledClaude", "spendColorsEnabled"] { defaults[key] = true }
        defaults["presentationMode"] = "perSource"
        for prefix in ["chatGPT", "claudePersonal", "cursorPersonal", "grokBot"] {
            defaults[prefix + "RedRemaining"] = 10.0; defaults[prefix + "OrangeRemaining"] = 25.0; defaults[prefix + "YellowRemaining"] = 50.0
        }
        defaults["openAIRedRemaining"] = 5.0; defaults["openAIOrangeRemaining"] = 20.0; defaults["openAIYellowRemaining"] = 50.0
        for key in ["chatGPTAccountMode", "cursorAccountMode", "claudeAccountMode"] {
            if defaults[key] == nil { defaults[key] = CommandLine.arguments.contains("--mission-work") ? "work" : "personal" }
        }
        UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
        let now = Date()
        let exhausted = CommandLine.arguments.contains("--mission-exhausted")
        let fetched = CommandLine.arguments.contains("--mission-stale") ? now.addingTimeInterval(-10000) : now
        let reset = now.addingTimeInterval(5 * 86400)
        lastChatGPTUsage = ChatGPTUsageSnapshot(percentLeft: exhausted ? 0 : 44, resetAt: reset, fetchedAt: fetched, codexPath: "Preview", session: ChatGPTUsageWindow(percentLeft: exhausted ? 0 : 97, resetAt: now.addingTimeInterval(4 * 3600)))
        lastChatGPTWorkUsage = ChatGPTWorkUsageSnapshot(todayCredits: CommandLine.arguments.contains("--mission-pending") ? 0 : 180, monthCredits: 2100, byProduct: ["codex": 1450, "chatgpt": 650], fetchedAt: now, dataFreshnessAt: now, serverEstimatedUSD: nil)
        lastCursorSpend = CursorSpendSnapshot(totalSpendUSD: 71.8, todaySpendUSD: 5.6, byModel: [CursorUsageAgg(model: "claude-sonnet", spendUSD: 42, inputTokens: 1000000, outputTokens: 200000, cacheWriteTokens: 200000, cacheReadTokens: 1000000), CursorUsageAgg(model: "claude-opus", spendUSD: 24.8, inputTokens: 400000, outputTokens: 40000, cacheWriteTokens: 100000, cacheReadTokens: 300000), CursorUsageAgg(model: "claude-haiku", spendUSD: 5, inputTokens: 200000, outputTokens: 30000, cacheWriteTokens: 50000, cacheReadTokens: 300000)], fetchedAt: now, userId: 0, planUsage: CursorPlanUsage(limitUSD: 20, includedSpendUSD: 1.6, totalPercentUsed: 8, percentLeft: 92, billingCycleEnd: reset))
        lastGrokBotUsage = GrokBotUsageSnapshot(percentLeft: 45, percentUsed: 55, resetAt: reset, planLabel: "Weekly plan", cursorPlanName: nil, fetchedAt: now)
        lastOpenAISpend = OpenAISpendSnapshot(todaySpendUSD: 0, monthSpendUSD: 0, estimatedBalanceUSD: CommandLine.arguments.contains("--mission-no-balance") ? nil : 9.27, byLineItem: [], fetchedAt: now)
        let resetFormat = DateFormatter(); resetFormat.locale = Locale(identifier: "en_US_POSIX")
        resetFormat.timeZone = TimeZone(identifier: "America/Denver"); resetFormat.dateFormat = "MMM d, h:mma"
        lastClaudeUsage = ClaudeUsageSnapshot(session: ClaudeUsageWindow(percentLeft: 65, resetDescription: resetFormat.string(from: now.addingTimeInterval(4 * 3600)) + " (America/Denver)"), weekly: ClaudeUsageWindow(percentLeft: 94, resetDescription: resetFormat.string(from: reset) + " (America/Denver)"), fetchedAt: now, claudePath: "Preview")
        var rollup = Rollup(); rollup.todayUSD = 12.8; rollup.monthUSD = 212.4
        rollup.sessions = CommandLine.arguments.contains("--mission-no-sessions") ? 0 : 8
        rollup.byModelUSD = ["claude-sonnet": 112.4, "claude-opus": 86, "claude-haiku": 14]
        rollup.projectedMonthEndUSD = 424.8
        let efficiency = EfficiencyResult.compute(rollup: rollup, scan: ScanResult(records: [], sessions: [:]), pricing: pricing, config: config)
        lastRollup = rollup; lastEfficiency = efficiency
        if CommandLine.arguments.contains("--mission-empty") {
            lastChatGPTUsage = nil; lastChatGPTWorkUsage = nil; lastCursorSpend = nil
            lastClaudeUsage = nil; lastGrokBotUsage = nil; lastOpenAISpend = nil
        }
        render(rollup, efficiency)
        mission.score = ScoreboardModel(score: 86, grade: "A", modelFitPoints: 44, contextPoints: 29, costPoints: 13, rightModelPct: 0.91, recoverableUSD: 18.4, contextPerTurn: 48000, churn: 0.12, contextShare: 0.34, cacheHitPct: 0.92, offenders: [ModelFitOffender(label: "Routine refactor · sample", reason: "Lightweight Opus turns", opusUSD: 28, sonnetUSD: 9.6)], bloated: [BloatedSession(label: "Long debug session · sample", contextPerTurn: 142000, costUSD: 16.8)], badges: [Badge(name: "Cache Master", earned: true, detail: "92% cache hits", emoji: ""), Badge(name: "Sonnet Saver", earned: true, detail: "Opus ≤40%", emoji: ""), Badge(name: "Right Model", earned: true, detail: "91% model fit", emoji: ""), Badge(name: "Lean Context", earned: true, detail: "48k context/turn", emoji: ""), Badge(name: "7-Day Streak", earned: true, detail: "8 days", emoji: ""), Badge(name: "30-Day Streak", earned: false, detail: "30 days at ≥80", emoji: ""), Badge(name: "Personal Best", earned: false, detail: "Best 92", emoji: "")], sparkScores: [62,68,65,73,78,76,82,86], streak: 8, best: 92, trend: 7)
        mission.advisories = [MissionAdvisory(title: "Opus is 35% of your spend", body: "Use Sonnet for routine work; reserve Opus for hard problems. Opus costs ~5× Sonnet per token.")]
        mission.invoke = { [weak self] item in
            guard let self, let action = item.action else { return }
            let name = NSStringFromSelector(action)
            if name == "setStatusBarDesign:", let raw = item.representedObject as? String {
                var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                domain["statusBarDesign"] = raw
                UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
                self.seedMissionFixtures()
            } else if name == "toggleThemedProviderLogos" {
                var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                domain["themedProviderLogos"] = !Prefs.themedProviderLogos
                UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
                self.seedMissionFixtures()
            } else if name.hasPrefix("set"), name.hasSuffix("Account") {
                var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                let source = name.contains("ChatGPT") ? "chatGPT" : name.contains("Cursor") ? "cursor" : "claude"
                domain[source + "AccountMode"] = name.contains("Work") ? "work" : "personal"
                UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
                self.seedMissionFixtures()
            } else if name.hasPrefix("custom") || name.contains("OpenAI") || name.contains("reset") {
                let alert = MissionAlert()
                alert.messageText = item.title
                alert.informativeText = "Preview only · no credentials, balance, or preferences will be saved."
                if name.hasPrefix("custom") || name == "setOpenAIKey" || name == "setOpenAIEstimatedBalance" {
                    alert.accessoryView = name == "setOpenAIKey" ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
                }
                alert.addButton(withTitle: "Done"); alert.addButton(withTitle: "Cancel")
                _ = alert.runModal()
            } else { item.state = item.state == .on ? .off : .on; self.mission.objectWillChange.send() }
        }
        mission.refresh = { [weak self] in self?.seedMissionFixtures() }
        if let i = CommandLine.arguments.firstIndex(of: "--mission-screen"), i + 1 < CommandLine.arguments.count {
            let route = CommandLine.arguments[i + 1].components(separatedBy: "/")
            mission.show(route[0])
            for component in route.dropFirst() {
                if let row = mission.currentRows.first(where: { $0.title.hasPrefix(component) }) { mission.path.append(row.id) }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--mission-capture"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let view = self?.reviewWindow?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func toggleMissionControl() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            mission.maximumHeight = min(700, (button.window?.screen?.visibleFrame.height ?? 800) - 40)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateMissionControl(_ r: Rollup, _ eff: EfficiencyResult) {
        let rows = MissionRow.read(buildMenu(r, eff))
        mission.rows = rows
        let sources: [(String, String, String, String?, Bool, Date?)] = [
            ("chatgpt", "ChatGPT", "sparkle", "icon-chatgpt", Prefs.enabledChatGPT, lastChatGPTWorkUsage?.fetchedAt ?? lastChatGPTUsage?.fetchedAt),
            ("cursor", "Cursor", "cube", nil, Prefs.enabledCursor, lastCursorSpend?.fetchedAt),
            ("grok", "Grok Bot", "circle.lefthalf.filled", "icon-grokbot", Prefs.enabledGrokBot, lastGrokBotUsage?.fetchedAt),
            ("openai", "OpenAI API", "brain.head.profile", nil, Prefs.enabledOpenAI, lastOpenAISpend?.fetchedAt),
            ("claude", "Claude", "asterisk", nil, Prefs.enabledClaude, Prefs.claudeIsPersonal ? lastClaudeUsage?.fetchedAt : nil)
        ]
        mission.providers = sources.map { id, name, symbol, resource, enabled, fetched in
            var provider = MissionProvider(id: id, name: name, symbol: symbol, resource: resource,
                            enabled: enabled, stale: fetched.map(isStale) ?? false,
                            row: rows.first { !$0.children.isEmpty && $0.title.hasPrefix(name) })
            switch id {
            case "cursor": provider.amounts = ["Today": lastCursorSpend?.todaySpendUSD ?? 0, "Month": lastCursorSpend?.totalSpendUSD ?? 0]
            case "claude": provider.amounts = ["Today": r.todayUSD, "Month": r.monthUSD]
            case "openai":
                if let balance = lastOpenAISpend?.estimatedBalanceUSD { provider.amounts["Estimated prepaid balance"] = balance }
            default: break
            }
            if id == "openai", let balance = lastOpenAISpend?.estimatedBalanceUSD, enabled { provider.headline = Fmt.money(balance) }
            if id == "chatgpt", Prefs.chatGPTIsPersonal, let usage = lastChatGPTUsage {
                if let session = usage.session { provider.meters.append(MissionMeter(id: "session", label: "5-hour window", percent: session.percentLeft, reset: ChatGPTUsageParse.displayDate(session.resetAt), resetAt: session.resetAt)) }
                provider.meters.append(MissionMeter(id: "weekly", label: "Weekly window", percent: usage.percentLeft, reset: usage.resetDescription, resetAt: usage.resetAt))
            }
            if id == "claude", Prefs.claudeIsPersonal, let usage = lastClaudeUsage {
                for (windowID, label, window) in [("session", "5-hour window", usage.session), ("weekly", "Weekly window", usage.weekly)] {
                    if let window {
                        let reset = AllowanceReset.claudeDate(window.resetDescription, fetchedAt: usage.fetchedAt)
                        provider.meters.append(MissionMeter(id: windowID, label: label, percent: window.percentLeft, reset: reset.map { ChatGPTUsageParse.displayDate($0) } ?? window.resetDescription, resetAt: reset))
                    }
                }
            }
            if id == "cursor", Prefs.cursorIsPersonal, let cursor = lastCursorSpend {
                provider.meters.append(MissionMeter(id: "included", label: "Included usage remaining", percent: cursorPersonalRemainingPercent(cursor: cursor, allowanceUSD: Prefs.cursorPersonalAllowanceUSD), reset: cursor.planUsage?.resetDescription, resetAt: cursor.planUsage?.billingCycleEnd))
            }
            if id == "grok", let grok = lastGrokBotUsage { provider.meters.append(MissionMeter(id: "weekly", label: "Weekly window", percent: grok.percentLeft, reset: grok.resetDescription, resetAt: grok.resetAt)) }
            if provider.meters.isEmpty {
                if id == "openai" { provider.resetNote = "Prepaid balance has no scheduled reset." }
                else if id == "cursor", let reset = lastCursorSpend?.planUsage?.resetDescription { provider.resetNote = "Billing cycle resets " + reset }
                else if id == "claude", !Prefs.claudeIsPersonal {
                    let calendar = Calendar.current
                    if let end = calendar.dateInterval(of: .month, for: Date())?.end { provider.resetNote = "Monthly totals reset " + ChatGPTUsageParse.displayDate(end) }
                } else { provider.resetNote = "Reset time not reported by provider." }
            }
            if Prefs.spendColorsEnabled {
                if id == "claude", !Prefs.claudeIsPersonal {
                    let colors = Prefs.claudeColors(policyUSD: config.spendRedUSD)
                    provider.spendTint = colors.level(for: r.monthUSD, policyUSD: config.spendRedUSD).menuColor(goodStyle: colors.goodStyle)
                }
                if id == "cursor", !Prefs.cursorIsPersonal, let cursor = lastCursorSpend {
                    let colors = Prefs.cursorWorkColors(policyUSD: config.spendRedUSD)
                    provider.spendTint = colors.level(for: cursor.totalSpendUSD, policyUSD: config.spendRedUSD).menuColor(goodStyle: colors.goodStyle)
                }
                if id == "chatgpt", !Prefs.chatGPTIsPersonal, let work = lastChatGPTWorkUsage {
                    let colors = Prefs.chatGPTWorkColors()
                    provider.spendTint = colors.level(for: work.estimatedUSD, policyUSD: ChatGPTWorkUsageSnapshot.proPlanMonthlyUSD).menuColor(goodStyle: colors.goodStyle)
                }
            }
            return provider
        }
        let claudeWork = Prefs.enabledClaude && !Prefs.claudeIsPersonal
        let cursorWork = Prefs.enabledCursor && !Prefs.cursorIsPersonal
        let chatGPTWork = Prefs.enabledChatGPT && !Prefs.chatGPTIsPersonal
        mission.showsCombinedSpend = claudeWork || cursorWork || chatGPTWork
        let cursorSpend = cursorWork ? lastCursorSpend : nil
        let chatSpend = chatGPTWork ? lastChatGPTWorkUsage : nil
        let chatToday = chatSpend?.todayIsPending == false ? chatSpend?.todayEstimatedUSD ?? 0 : 0
        let today = (claudeWork ? r.todayUSD : 0) + (cursorSpend?.todaySpendUSD ?? 0) + chatToday
        let month = (claudeWork ? r.monthUSD : 0) + (cursorSpend?.totalSpendUSD ?? 0) + (chatSpend?.estimatedUSD ?? 0)
        let hasWorkSpend = claudeWork || cursorSpend != nil || chatSpend != nil
        let projected = projectedMonthEnd(monthUSD: month)
        mission.combinedAmounts = hasWorkSpend ? [today, month, projected] : []
        mission.combinedLines = hasWorkSpend ? ["Today: \(Fmt.money(today))", "Month: \(Fmt.money(month))", "Projected month-end: \(Fmt.money(projected))"] : []
        if hasWorkSpend {
            spendLedger.record(dayUSD: today, monthUSD: month)
        }
        mission.spendChart = hasWorkSpend
            ? spendLedger.monthChart(todayUSD: today, monthUSD: month, projectedMonthEndUSD: projected)
            : []
        mission.efficiencyEnabled = Prefs.enabledClaude && (lastRollup?.sessions ?? 0) > 0
        mission.efficiencyMessage = Prefs.enabledClaude ? "No local Claude Code sessions found this month. Use Claude Code, then refresh to see Efficiency and Scoreboard. Personal allowance percentages alone cannot produce an efficiency score." : "Enable Claude in provider options to analyze local Claude Code sessions."
        if let raw = lastRollup { mission.score = ScoreboardModel.build(eff: eff, rollup: raw, history: history) }
        mission.workCredits = Prefs.enabledChatGPT && !Prefs.chatGPTIsPersonal ? lastChatGPTWorkUsage : nil
        mission.balance = Prefs.enabledOpenAI ? lastOpenAISpend?.estimatedBalanceUSD : nil
        mission.balanceNeedsAttention = mission.balance.map { [SpendTint.caution, .warning, .over].contains(Prefs.openAIColors().level(for: $0)) } ?? false
        mission.updated = Date()
        if !CommandLine.arguments.contains("--mission-preview") {
            checkNotificationPermission()
            evaluateAllowanceAlerts()
        }
    }

    private func checkNotificationPermission(force: Bool = false) {
        guard notificationsAvailable, force || Date().timeIntervalSince(lastPermissionCheck) > 30 else { return }
        lastPermissionCheck = Date()
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                let allowed = settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
                if self.notificationPermission != allowed || CommandLine.arguments.contains("--notification-preview") { NSLog("TokenPulse notification permission enabled: %@", String(allowed)) }
                self.notificationPermission = allowed
                self.notificationStatus = self.notificationPermission ? "macOS notifications: enabled" : "macOS notifications: not enabled — open notification settings"
            }
        }
    }

    private func evaluateAllowanceAlerts() {
        guard notificationPermission, Prefs.notificationsEnabled, Prefs.allowanceAlertsEnabled else { return }
        for provider in mission.providers where provider.enabled && !provider.stale {
            if provider.id == "cursor" && lastCursorSpend?.planUsage == nil { continue }
            for meter in provider.meters {
                if let reset = meter.resetAt, reset <= Date() { continue }
                let observation = AllowanceObservation(providerID: provider.id, provider: provider.name, windowID: meter.id,
                    window: meter.id == "session" ? "5-hour" : meter.id == "weekly" ? "Weekly" : "Included Pro",
                    percent: meter.percent, cycle: meter.resetAt.map { String(Int($0.timeIntervalSince1970)) } ?? meter.reset ?? "unknown", reset: meter.reset)
                guard !allowanceInFlight.contains(observation.key) else { continue }
                var candidate = allowanceLedger
                guard let threshold = candidate.observe(observation, thresholds: Prefs.activeAlertThresholds) else { allowanceLedger = candidate; continue }
                allowanceInFlight.insert(observation.key)
                let content = AllowanceNotification.content(observation, threshold: threshold, sound: Prefs.notificationSounds)
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.allowanceInFlight.remove(observation.key)
                        if let error {
                            NSLog("TokenPulse notification delivery failed: %@", error.localizedDescription)
                        } else {
                            self.allowanceLedger.entries[observation.key] = candidate.entries[observation.key]
                            self.allowanceLedger.save()
                            self.mission.advisories.insert(MissionAdvisory(provider: provider.name, scope: observation.window + " allowance", title: content.userInfo["advisoryTitle"] as? String ?? content.subtitle, body: content.body), at: 0)
                            self.mission.advisories = Array(self.mission.advisories.prefix(30))
                        }
                    }
                }
            }
        }
        allowanceLedger.save()
    }

    // MARK: - Refresh

    private func refresh() {
        // Parse off the main thread; update UI on main. Skip if a scan is
        // already running — overlapping full-tree walks peg CPU and delay
        // the first menu-bar paint.
        if refreshInFlight { return }
        refreshInFlight = true
        mission.refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async { self.refreshInFlight = false; self.mission.refreshing = false }
            }
            let scan = self.parser.scan()
            let r = self.store.rollup(from: scan.records)
            let eff = EfficiencyResult.compute(rollup: r, scan: scan,
                                              pricing: self.pricing, config: self.config)
            DispatchQueue.main.async {
                self.lastEfficiency = eff
                self.lastRollup = r
                self.history.record(eff, rollup: r)   // upsert today's snapshot — local-only, unaffected by proxy reconciliation
                self.render(self.displayRollup(for: r), eff)
                self.maybeAlertOpus(r)
            }
        }
    }

    /// GET /spend/end_user (when available) is the source of truth for
    /// Month/By-model/opus-share; the local transcript scan (`r`) is the
    /// fallback. EfficiencyScore/History/Achievements/Scoreboard keep using
    /// the raw local `r` unchanged — see ProxySpend.swift's Rollup.reconciled
    /// doc comment for why those can't move off local data.
    private func displayRollup(for r: Rollup) -> Rollup {
        guard let proxy = lastProxySpend else { return r }
        return r.reconciled(with: proxy)
    }

    /// Independent remote cycle — never call this from the fast local-scan
    /// timer. Falls back silently (no UI error state) if there's no valid
    /// cached llm-proxy-keys credential or the request fails.
    private func refreshProxySpend() {
        proxyReconciler.currentSpend { [weak self] resp in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastProxySpend = resp
                if let r = self.lastRollup, let eff = self.lastEfficiency {
                    self.render(self.displayRollup(for: r), eff)
                }
            }
        }
    }

    /// Independent remote cycle for personal Cursor spend. Silent no-op
    /// when Cursor isn't installed / signed in or the API call fails.
    /// Pass `force: true` from Refresh now so the menu isn't stuck on a
    /// throttled snapshot (e.g. Today $0 from before morning usage).
    private func refreshCursorSpend(force: Bool = false) {
        guard Prefs.enabledCursor else { lastCursorSpend = nil; return }
        cursorClient.currentSpend(force: force) { [weak self] snap in
            DispatchQueue.main.async {
                guard let self else { return }
                if let snap { self.lastCursorSpend = snap }
                if let r = self.lastRollup, let eff = self.lastEfficiency {
                    self.render(self.displayRollup(for: r), eff)
                }
            }
        }
    }

    private func refreshOpenAISpend(force: Bool = false) {
        guard Prefs.enabledOpenAI else { lastOpenAISpend = nil; return }
        openAIClient.currentSpend(force: force) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshot { self.lastOpenAISpend = snapshot }
                if let r = self.lastRollup, let eff = self.lastEfficiency {
                    self.render(self.displayRollup(for: r), eff)
                }
            }
        }
    }

    private func refreshChatGPTUsage(force: Bool = false) {
        guard Prefs.enabledChatGPT else {
            lastChatGPTUsage = nil
            lastChatGPTWorkUsage = nil
            return
        }
        guard Prefs.chatGPTIsPersonal else {
            lastChatGPTUsage = nil
            chatGPTWorkClient.currentUsage(force: force) { [weak self] snapshot in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let snapshot { self.lastChatGPTWorkUsage = snapshot }
                    if let r = self.lastRollup, let eff = self.lastEfficiency {
                        self.render(self.displayRollup(for: r), eff)
                    }
                }
            }
            return
        }
        lastChatGPTWorkUsage = nil
        chatGPTClient.currentUsage(force: force) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshot { self.lastChatGPTUsage = snapshot }
                if let r = self.lastRollup, let eff = self.lastEfficiency {
                    self.render(self.displayRollup(for: r), eff)
                }
            }
        }
    }

    private func refreshClaudeUsage(force: Bool = false) {
        guard Prefs.enabledClaude, Prefs.claudeIsPersonal else {
            lastClaudeUsage = nil
            return
        }
        claudeUsageClient.currentUsage(force: force) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshot { self.lastClaudeUsage = snapshot }
                if let r = self.lastRollup, let eff = self.lastEfficiency {
                    self.render(self.displayRollup(for: r), eff)
                }
            }
        }
    }

    private func refreshGrokBotUsage(force: Bool = false) {
        guard Prefs.enabledGrokBot else {
            lastGrokBotUsage = nil
            return
        }
        grokBotClient.currentUsage(force: force) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshot { self.lastGrokBotUsage = snapshot }
                if let r = self.lastRollup, let eff = self.lastEfficiency {
                    self.render(self.displayRollup(for: r), eff)
                }
            }
        }
    }

    // MARK: - Menu bar title

    /// One source's menu-bar block: brand glyph plus spend, remaining %, or balance.
    private enum StatusDisplay {
        case spend(todayUSD: Double, monthUSD: Double,
                   colors: SpendUpColorConfig, policyUSD: Double,
                   barSource: BarSpendSource)
        case remainingPercent(Int, colors: RemainingColorConfig)
        /// Percent meter with a custom bar label (e.g. ChatGPT/Grok `0% Sep 20`).
        case remainingPercentLabel(String, percentLeft: Int, colors: RemainingColorConfig)
        /// Claude personal: five-hour session % and weekly % side by side.
        case remainingSessionAndWeekly(session: ClaudeUsageWindow?,
                                       weekly: ClaudeUsageWindow?,
                                       colors: RemainingColorConfig)
        case remainingBalance(Double?, colors: RemainingColorConfig)
    }

    private struct StatusSegment {
        let glyphNames: [String]
        let display: StatusDisplay
        var stale = false
    }

    /// Anthropic's mark is a burst; Cursor's is a cube; OpenAI uses a brain/
    /// compute fallback.
    private static let claudeGlyphs = ["asterisk", "sparkle", "sparkles"]
    private static let cursorGlyphs = ["cube", "cursorarrow", "arrow.up.left"]
    private static let openAIGlyphs = ["brain.head.profile", "circle.hexagongrid", "cpu"]
    private static let grokBotGlyphs = ["bolt.fill", "bolt", "hare"]

    private func render(_ r: Rollup, _ eff: EfficiencyResult) {
        guard let button = statusItem.button else { return }

        let cursor = lastCursorSpend
        let openAI = lastOpenAISpend
        let includeCursor = Prefs.includeCursorInBar && cursor != nil
        let includeOpenAI = Prefs.includeOpenAIInBar && openAI != nil
        let includeClaude = Prefs.includeClaudeInBar
        let cursorIsPersonal = Prefs.cursorIsPersonal
        let claudeIsPersonal = Prefs.claudeIsPersonal
        let claudeColors = Prefs.claudeColors(policyUSD: config.spendRedUSD)
        let cursorWorkColors = Prefs.cursorWorkColors(policyUSD: config.spendRedUSD)
        let cursorPersonalColors = Prefs.cursorPersonalColors()
        let claudePersonalColors = Prefs.claudePersonalColors()
        let openAIColors = Prefs.openAIColors()
        let grokBotColors = Prefs.grokBotColors()
        let allowance = Prefs.cursorPersonalAllowanceUSD

        var segments: [StatusSegment] = []
        if includeCursor, let cursor {
            if cursorIsPersonal {
                let remaining = cursorPersonalRemainingPercent(
                    cursor: cursor, allowanceUSD: allowance)
                segments.append(StatusSegment(
                    glyphNames: Self.cursorGlyphs,
                    display: .remainingPercentLabel(
                        cursor.personalBarPercent(allowanceUSD: allowance),
                        percentLeft: remaining,
                        colors: cursorPersonalColors),
                    stale: isStale(cursor.fetchedAt)))
            } else {
                segments.append(StatusSegment(
                    glyphNames: Self.cursorGlyphs,
                    display: .spend(todayUSD: cursor.todaySpendUSD,
                                    monthUSD: cursor.totalSpendUSD,
                                    colors: cursorWorkColors,
                                    policyUSD: config.spendRedUSD,
                                    barSource: .cursorWork),
                    stale: isStale(cursor.fetchedAt)))
            }
        }
        if Prefs.includeGrokBotInBar, let grok = lastGrokBotUsage {
            segments.append(StatusSegment(
                glyphNames: Self.grokBotGlyphs,
                display: .remainingPercentLabel(
                    grok.personalBarPercent,
                    percentLeft: grok.percentLeft,
                    colors: grokBotColors),
                stale: isStale(grok.fetchedAt)))
        }
        if includeOpenAI, let openAI {
            segments.append(StatusSegment(
                glyphNames: Self.openAIGlyphs,
                display: .remainingBalance(openAI.estimatedBalanceUSD,
                                             colors: openAIColors),
                stale: isStale(openAI.fetchedAt)))
        }
        if includeClaude {
            if claudeIsPersonal, let usage = lastClaudeUsage,
               usage.session != nil || usage.weekly != nil {
                segments.append(StatusSegment(
                    glyphNames: Self.claudeGlyphs,
                    display: .remainingSessionAndWeekly(
                        session: usage.session,
                        weekly: usage.weekly,
                        colors: claudePersonalColors),
                    stale: isStale(usage.fetchedAt)))
            } else if !claudeIsPersonal {
                segments.append(StatusSegment(
                    glyphNames: Self.claudeGlyphs,
                    display: .spend(todayUSD: r.todayUSD, monthUSD: r.monthUSD,
                                    colors: claudeColors, policyUSD: config.spendRedUSD,
                                    barSource: .claudeWork)))
            }
        }

        // Glyphs ride inside the title as text attachments: a status item has a
        // single `image` slot, which can't carry one glyph per source.
        button.image = nil
        button.imagePosition = .noImage
        let chatGPT = Prefs.enabledChatGPT && Prefs.showChatGPTInBar ? lastChatGPTUsage : nil
        let chatGPTWork = Prefs.enabledChatGPT && Prefs.showChatGPTInBar ? lastChatGPTWorkUsage : nil
        let chatGPTFetchedAt = chatGPTWork?.fetchedAt ?? chatGPT?.fetchedAt
        lastBarSegments = segments
        lastBarChatGPT = (chatGPT, chatGPTWork, chatGPTFetchedAt.map(isStale) ?? false)
        applyStatusTitle()
        applyBarBackground(to: button)

        // Keep it pinned on every render — defends against the OS hiding it.
        statusItem.isVisible = true
        updateMissionControl(r, eff)
    }

    private func applyBarBackground(to button: NSStatusBarButton) {
        // Each provider's rendered capsule owns its own background.
        button.layer?.backgroundColor = nil
        button.layer?.cornerRadius = 0
    }

    private func statusTitle(_ segments: [StatusSegment],
                             chatGPT: ChatGPTUsageSnapshot?,
                             chatGPTWork: ChatGPTWorkUsageSnapshot?,
                             chatGPTStale: Bool = false,
                             dimStale: Bool = false) -> NSAttributedString {
        let moneyFont = NSFont.monospacedDigitSystemFont(ofSize: Prefs.barSizes.money, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: Prefs.barSizes.label, weight: .semibold)
        let chatGPTColors = Prefs.chatGPTColors()
        let chatGPTWorkColors = Prefs.chatGPTWorkColors()

        let out = NSMutableAttributedString()
        var hasContent = false
        if let work = chatGPTWork {
            if let icon = chatGPTIcon() {
                out.append(glyphRun(icon, font: moneyFont))
            } else if let glyph = glyphImage(Self.openAIGlyphs) {
                out.append(glyphRun(glyph, font: moneyFont))
            }
            let cap = ChatGPTWorkUsageSnapshot.proPlanMonthlyUSD
            appendSpend(to: out, todayUSD: work.todayEstimatedUSD,
                        monthUSD: work.estimatedUSD, colors: chatGPTWorkColors,
                        policyUSD: cap, barSource: .chatGPTWork,
                        moneyFont: moneyFont, labelFont: labelFont,
                        todayPending: work.todayIsPending)
            hasContent = true
        } else if let chatGPT {
            if let icon = chatGPTIcon() {
                out.append(glyphRun(icon, font: moneyFont))
            } else if let glyph = glyphImage(Self.openAIGlyphs) {
                out.append(glyphRun(glyph, font: moneyFont))
            }
            // Same layout as Claude's bar: `5H 96% W 98%`.
            if let session = chatGPT.session {
                out.append(run(" 5H ", font: labelFont, color: MenuBarPalette.secondaryLabel))
                out.append(tintedRun("\(session.percentLeft)%", font: moneyFont,
                                     tint: chatGPTColors.level(for: Double(session.percentLeft)),
                                     goodStyle: chatGPTColors.goodStyle))
            }
            out.append(run(" W ", font: labelFont, color: MenuBarPalette.secondaryLabel))
            out.append(tintedRun("\(chatGPT.percentLeft)%", font: moneyFont,
                                 tint: chatGPTColors.level(for: Double(chatGPT.percentLeft)),
                                 goodStyle: chatGPTColors.goodStyle))
            hasContent = true
        }
        if dimStale && chatGPTStale {
            dimRun(out, from: 0)
        }
        for (i, seg) in segments.enumerated() {
            if hasContent || i > 0 {
                out.append(run("   ", font: moneyFont, color: MenuBarPalette.label))
            }
            let segmentStart = out.length
            defer { if dimStale && seg.stale { dimRun(out, from: segmentStart) } }
            let glyph: NSImage?
            if seg.glyphNames == Self.grokBotGlyphs {
                glyph = grokBotIcon() ?? glyphImage(seg.glyphNames)
            } else {
                glyph = glyphImage(seg.glyphNames)
            }
            if let glyph {
                out.append(glyphRun(glyph, font: moneyFont))
            }
            switch seg.display {
            case .spend(let todayUSD, let monthUSD, let colors, let policyUSD, let barSource):
                appendSpend(to: out, todayUSD: todayUSD, monthUSD: monthUSD,
                            colors: colors, policyUSD: policyUSD, barSource: barSource,
                            moneyFont: moneyFont, labelFont: labelFont)
            case .remainingPercent(let pct, let colors):
                let tint = colors.level(for: Double(pct))
                out.append(tintedRun(" \(pct)%", font: moneyFont, tint: tint,
                                   goodStyle: colors.goodStyle))
            case .remainingPercentLabel(let label, let pct, let colors):
                let tint = colors.level(for: Double(pct))
                out.append(tintedRun(" \(label)", font: moneyFont, tint: tint,
                                   goodStyle: colors.goodStyle))
            case .remainingSessionAndWeekly(let session, let weekly, let colors):
                appendClaudePersonalBar(to: out, session: session, weekly: weekly,
                                        colors: colors, moneyFont: moneyFont,
                                        labelFont: labelFont)
            case .remainingBalance(let balance, let colors):
                out.append(run(" B ", font: labelFont, color: MenuBarPalette.secondaryLabel))
                if let balance {
                    let tint = colors.level(for: balance)
                    out.append(tintedRun(Fmt.money(balance), font: moneyFont, tint: tint,
                                       goodStyle: colors.goodStyle))
                } else {
                    out.append(run("—", font: moneyFont, color: MenuBarPalette.secondaryLabel))
                }
            }
            hasContent = true
        }
        if !hasContent, let glyph = glyphImage(["chart.bar.xaxis", "circle.grid.2x2"]) {
            out.append(glyphRun(glyph, font: moneyFont))
        }
        return out
    }

    /// The same logo the menu bar uses for each AI, shown at the start of its dropdown row.
    /// Dropdown rows keep the standard size whatever the menu-bar size option says.
    private func sourceIcon(forRowTitle title: String) -> NSImage? {
        let sizes = BarSizes.standard
        if title.hasPrefix("ChatGPT") {
            return chatGPTIcon(size: sizes.icon) ?? glyphImage(Self.openAIGlyphs, pointSize: sizes.symbol)
        }
        if title.hasPrefix("Grok Bot") {
            return grokBotIcon(size: sizes.icon) ?? glyphImage(Self.grokBotGlyphs, pointSize: sizes.symbol)
        }
        if title.hasPrefix("Cursor") { return glyphImage(Self.cursorGlyphs, pointSize: sizes.symbol) }
        if title.hasPrefix("Claude") { return glyphImage(Self.claudeGlyphs, pointSize: sizes.symbol) }
        if title.hasPrefix("OpenAI") { return glyphImage(Self.openAIGlyphs, pointSize: sizes.symbol) }
        return nil
    }

    /// Prefer the real ChatGPT icon copied into the TokenPulse bundle during
    /// local installation. Fall back to a live ChatGPT app resource when the
    /// bundle was assembled manually before that copy step.
    private func chatGPTIcon(size: CGFloat? = nil) -> NSImage? {
        let bundled = Bundle.main.path(forResource: "icon-chatgpt", ofType: "png")
        let paths = [
            bundled,
            "/Applications/AI:Coding/ChatGPT.app/Contents/Resources/icon-chatgpt.png",
            "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.png",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.png").path,
        ].compactMap { $0 }
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let image = NSImage(contentsOfFile: path) else { return nil }
        let side = size ?? Prefs.barSizes.icon
        image.size = NSSize(width: side, height: side)
        return size == nil && Prefs.barSizes.trimIcons ? visibleMark(of: image, key: path) : image
    }

    /// Prefer Grok Bot's app icon (bundled PNG from `make-app.sh`, or the live
    /// `.icns` next to `/Applications/Grok Bot.app`). SF Symbol bolt is fallback.
    private func grokBotIcon(size: CGFloat? = nil) -> NSImage? {
        let bundled = Bundle.main.path(forResource: "icon-grokbot", ofType: "png")
        let paths = [
            bundled,
            "/Applications/Grok Bot.app/Contents/Resources/icon.icns",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Grok Bot.app/Contents/Resources/icon.icns").path,
        ].compactMap { $0 }
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let image = NSImage(contentsOfFile: path) else { return nil }
        let side = size ?? Prefs.barSizes.icon
        image.size = NSSize(width: side, height: side)
        return size == nil && Prefs.barSizes.trimIcons ? visibleMark(of: image, key: path) : image
    }

    /// Fades text from `start` to the end; glyph attachments keep full opacity.
    private func dimRun(_ out: NSMutableAttributedString, from start: Int) {
        guard start < out.length else { return }
        let range = NSRange(location: start, length: out.length - start)
        out.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
            let color = (value as? NSColor) ?? MenuBarPalette.label
            out.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.3), range: sub)
        }
    }

    private func run(_ s: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    private func tintedRun(_ s: String, font: NSFont, tint: SpendTint,
                           goodStyle: GoodZoneStyle) -> NSAttributedString {
        let color = Prefs.spendColorsEnabled ? tint.barColor(goodStyle: goodStyle) : nil
        return run(s, font: font, color: color ?? MenuBarPalette.label)
    }

    private func appendSpend(to out: NSMutableAttributedString,
                              todayUSD: Double, monthUSD: Double,
                              colors: SpendUpColorConfig, policyUSD: Double,
                              barSource: BarSpendSource,
                              moneyFont: NSFont, labelFont: NSFont,
                              todayPending: Bool = false) {
        let cap = colors.effectiveCap(policyUSD: policyUSD)
        let dayCap = SpendTint.dailyCap(cap)
        let showDaily = Prefs.showDailyInBar(for: barSource)
        let showMonthly = Prefs.showMonthlyInBar(for: barSource)
        if showDaily {
            out.append(run(" D ", font: labelFont, color: MenuBarPalette.secondaryLabel))
            if todayPending {
                // An em dash reads as "not known yet"; a $0.00 would claim the
                // provider had confirmed an idle day.
                out.append(run("—", font: moneyFont, color: MenuBarPalette.secondaryLabel))
            } else {
                out.append(moneyRun(todayUSD, colors: colors, policyUSD: policyUSD,
                                      dayCap: dayCap, font: moneyFont))
            }
        }
        if showMonthly {
            out.append(run(" M ", font: labelFont, color: MenuBarPalette.secondaryLabel))
            out.append(moneyRun(monthUSD, colors: colors, policyUSD: policyUSD,
                                  dayCap: cap, font: moneyFont))
        }
    }

    /// Claude personal bar: `5H 98% W 38%`, or `0% Sep 20` when exhausted.
    private func appendClaudePersonalBar(to out: NSMutableAttributedString,
                                         session: ClaudeUsageWindow?,
                                         weekly: ClaudeUsageWindow?,
                                         colors: RemainingColorConfig,
                                         moneyFont: NSFont, labelFont: NSFont) {
        if let session {
            out.append(run(" 5H ", font: labelFont, color: MenuBarPalette.secondaryLabel))
            let tint = colors.level(for: Double(session.percentLeft))
            out.append(tintedRun(session.personalBarPercent, font: moneyFont, tint: tint,
                               goodStyle: colors.goodStyle))
        }
        if let weekly {
            out.append(run(" W ", font: labelFont, color: MenuBarPalette.secondaryLabel))
            let tint = colors.level(for: Double(weekly.percentLeft))
            out.append(tintedRun(weekly.personalBarPercent, font: moneyFont, tint: tint,
                               goodStyle: colors.goodStyle))
        }
    }

    private func moneyRun(_ v: Double, colors: SpendUpColorConfig, policyUSD: Double,
                          dayCap: Double, font: NSFont) -> NSAttributedString {
        let cap = colors.effectiveCap(policyUSD: policyUSD)
        let tint = dayCap == cap
            ? colors.level(for: v, policyUSD: policyUSD)
            : SpendTint.levelSpendUp(v, cap: dayCap,
                                     orangePercent: colors.orangePercent,
                                     yellowPercent: colors.yellowPercent)
        return tintedRun(Fmt.money(v), font: font, tint: tint, goodStyle: colors.goodStyle)
    }

    /// The icon cropped to its non-transparent part, redrawn at the same size. The bar redraws
    /// often, so each icon's visible area is worked out once and remembered.
    private func visibleMark(of image: NSImage, key: String) -> NSImage {
        let unit = visibleUnitRects[key] ?? visibleUnitRect(of: image)
        visibleUnitRects[key] = unit
        let size = image.size
        let source = NSRect(x: unit.minX * size.width, y: unit.minY * size.height,
                            width: unit.width * size.width, height: unit.height * size.height)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    /// The non-transparent bounds as fractions of the image, measured on a small copy.
    /// The result is square so the mark is not stretched.
    private func visibleUnitRect(of image: NSImage) -> NSRect {
        let n = 64
        let whole = NSRect(x: 0, y: 0, width: 1, height: 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return whole }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        var minX = n, maxX = -1, minY = n, maxY = -1
        for y in 0..<n {
            for x in 0..<n where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.06 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return whole }
        let span = CGFloat(max(maxX - minX, maxY - minY) + 1) / CGFloat(n)
        let centerX = CGFloat(minX + maxX + 1) / 2 / CGFloat(n)
        // Bitmap rows run top to bottom; image coordinates run bottom to top.
        let centerY = 1 - CGFloat(minY + maxY + 1) / 2 / CGFloat(n)
        return NSRect(x: centerX - span / 2, y: centerY - span / 2, width: span, height: span)
    }

    private func glyphImage(_ names: [String], pointSize: CGFloat? = nil) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize ?? Prefs.barSizes.symbol, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [MenuBarPalette.label]))
        for name in names {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return img.withSymbolConfiguration(cfg)
            }
        }
        return nil
    }

    private func glyphRun(_ img: NSImage, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = img
        let size = img.size
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2,
                                   width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Dropdown

    /// Info rows must be custom-view items. A plain NSMenuItem with no action
    /// is "disabled" and macOS dims it grey; a view item renders at full color.
    private func makeRow(_ s: String, bold: Bool, tints: [MoneyTint] = []) -> NSMenuItem {
        let label = NSTextField(labelWithString: s)
        let font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
        label.font = font
        // Full label color (not secondary) — readable in both themes; the
        // disabled-item dimming that greyed everything out is gone now that
        // rows are custom views.
        label.textColor = .labelColor
        if !tints.isEmpty {
            label.attributedStringValue = MenuText.attributed(s, font: font, tints: tints)
        }
        label.sizeToFit()

        let pad = NSEdgeInsets(top: 3, left: 14, bottom: 3, right: 16)
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: label.frame.width + pad.left + pad.right,
            height: label.frame.height + pad.top + pad.bottom))
        label.setFrameOrigin(NSPoint(x: pad.left, y: pad.bottom))
        container.addSubview(label)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func buildMenu(_ r: Rollup, _ eff: EfficiencyResult) -> NSMenu {
        let menu = NSMenu()
        let visibility = MenuSourceVisibility(
            chatGPT: Prefs.enabledChatGPT,
            cursor: Prefs.enabledCursor,
            openAI: Prefs.enabledOpenAI,
            claude: Prefs.enabledClaude,
            grokBot: Prefs.enabledGrokBot)
        let infoRows = tokenpulseMenuRows(
            r, eff, config, cursor: lastCursorSpend, openAI: lastOpenAISpend,
            chatGPT: lastChatGPTUsage, chatGPTWork: lastChatGPTWorkUsage,
            claudeUsage: lastClaudeUsage, grokBot: lastGrokBotUsage,
            visibility: visibility)
        appendRows(infoRows, to: menu)
        if !infoRows.isEmpty { menu.addItem(.separator()) }
        menu.addItem(optionsItem())

        menu.addItem(.separator())
        if config.showEfficiencyDetails {
            menu.addItem(NSMenuItem(title: "Open Scoreboard…", action: #selector(openScoreboard),
                                    keyEquivalent: "s"))
        }

        menu.addItem(NSMenuItem(title: "Refresh now", action: #selector(refreshNow),
                                keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit TokenPulse", action: #selector(quit),
                                keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    /// Collapsed "Options ›" submenu. Targets are set here rather than by the
    /// caller's sweep, which only walks the root menu's items.
    private func optionsItem() -> NSMenuItem {
        func toggle(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.state = on ? .on : .off
            item.target = self
            return item
        }

        let sub = NSMenu(title: "Options")
        let refreshItem = NSMenuItem(title: "Check usage every", action: nil, keyEquivalent: "")
        let refreshMenu = NSMenu(title: "Check usage every")
        for minutes in Prefs.usageRefreshChoices {
            let title = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            let choice = NSMenuItem(title: title, action: #selector(setUsageRefreshMinutes(_:)), keyEquivalent: "")
            choice.representedObject = minutes
            choice.state = Prefs.usageRefreshMinutes == minutes ? .on : .off
            choice.target = self
            refreshMenu.addItem(choice)
        }
        refreshItem.submenu = refreshMenu
        sub.addItem(refreshItem)
        let notifications = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        let notificationMenu = NSMenu(title: "Notifications")
        notificationMenu.addItem(toggle("Enable notifications", #selector(toggleNotifications), Prefs.notificationsEnabled))
        notificationMenu.addItem(toggle("Low allowance alerts", #selector(toggleAllowanceAlerts), Prefs.allowanceAlertsEnabled))
        for threshold in Prefs.alertThresholds {
            let item = toggle("At \(threshold)% remaining", #selector(toggleAlertThreshold(_:)), !Prefs.disabledAlertThresholds.contains(threshold))
            item.representedObject = threshold
            item.isEnabled = Prefs.notificationsEnabled && Prefs.allowanceAlertsEnabled
            notificationMenu.addItem(item)
        }
        notificationMenu.addItem(NSMenuItem(title: "Customize thresholds…", action: #selector(customAlertThresholds), keyEquivalent: ""))
        notificationMenu.addItem(.separator())
        notificationMenu.addItem(toggle("Claude model-spend advisories", #selector(toggleOpusAlerts), Prefs.opusAlertsEnabled))
        notificationMenu.addItem(toggle("Notification sounds", #selector(toggleNotificationSounds), Prefs.notificationSounds))
        notificationMenu.addItem(.separator())
        notificationMenu.addItem(makeRow(CommandLine.arguments.contains("--mission-preview") ? "Preview · no notifications sent" : notificationStatus, bold: false))
        notificationMenu.addItem(NSMenuItem(title: "Send test notification", action: #selector(sendTestNotification), keyEquivalent: ""))
        notificationMenu.addItem(NSMenuItem(title: "Open macOS notification settings", action: #selector(openNotificationSettings), keyEquivalent: ""))
        for item in notificationMenu.items where item.action != nil { item.target = self }
        notifications.submenu = notificationMenu
        sub.addItem(notifications)
        let designItem = NSMenuItem(title: "Menu bar style", action: nil, keyEquivalent: "")
        let designMenu = NSMenu(title: "Menu bar style")
        for design in StatusBarDesign.allCases {
            let choice = NSMenuItem(title: design.title, action: #selector(setStatusBarDesign(_:)), keyEquivalent: "")
            choice.representedObject = design.rawValue
            choice.state = Prefs.statusBarDesign == design ? .on : .off
            choice.target = self
            designMenu.addItem(choice)
        }
        designItem.submenu = designMenu
        sub.addItem(designItem)
        sub.addItem(toggle("Themed provider logos", #selector(toggleThemedProviderLogos), Prefs.themedProviderLogos))
        sub.addItem(.separator())
        sub.addItem(toggle("Spend colors",
                           #selector(toggleSpendColors), Prefs.spendColorsEnabled))
        sub.addItem(toggle("Dark menu-bar background",
                           #selector(toggleDarkBarBackground), Prefs.darkBarBackground))
        let pastel = toggle("Pastel menu-bar colors",
                            #selector(togglePastelBarColors), Prefs.pastelBarColors)
        // Nothing to soften while every figure is drawn in the label color.
        pastel.isEnabled = Prefs.spendColorsEnabled
        sub.addItem(pastel)
        sub.addItem(toggle("Reopen where I left off", #selector(toggleRememberPanelPlace), Prefs.rememberPanelPlace))
        sub.addItem(.separator())
        sub.addItem(chatGPTOptionsItem(toggle: toggle))
        sub.addItem(cursorOptionsItem(toggle: toggle))
        sub.addItem(grokBotOptionsItem(toggle: toggle))
        sub.addItem(openAIOptionsItem(toggle: toggle))
        sub.addItem(claudeOptionsItem(toggle: toggle))
        sub.addItem(.separator())
        let reset = NSMenuItem(title: "Reset to defaults…",
                               action: #selector(resetOptionsToDefaults), keyEquivalent: "")
        reset.target = self
        sub.addItem(reset)

        let item = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func chatGPTOptionsItem(
        toggle: (String, Selector, Bool) -> NSMenuItem
    ) -> NSMenuItem {
        let sub = NSMenu(title: "ChatGPT")
        sub.addItem(toggle("Enable",
                           #selector(toggleEnableChatGPT), Prefs.enabledChatGPT))
        let showItem = toggle("Show in Menu",
                              #selector(toggleShowChatGPTInBar), Prefs.showChatGPTInBar)
        showItem.isEnabled = Prefs.enabledChatGPT
        sub.addItem(showItem)
        sub.addItem(.separator())

        let account = NSMenuItem(title: "Account", action: nil, keyEquivalent: "")
        let accountMenu = NSMenu(title: "Account")
        let personal = NSMenuItem(title: "Personal (% remaining)",
                                  action: #selector(setChatGPTPersonalAccount),
                                  keyEquivalent: "")
        personal.state = Prefs.chatGPTIsPersonal ? .on : .off
        personal.target = self
        accountMenu.addItem(personal)
        let work = NSMenuItem(title: "Work credits (D/M estimate)",
                              action: #selector(setChatGPTWorkAccount),
                              keyEquivalent: "")
        work.state = Prefs.chatGPTIsPersonal ? .off : .on
        work.target = self
        accountMenu.addItem(work)
        account.submenu = accountMenu
        sub.addItem(account)

        if !Prefs.chatGPTIsPersonal {
            sub.addItem(.separator())
            addBarSpendToggles(to: sub, source: .chatGPTWork)
        }

        sub.addItem(.separator())
        sub.addItem(colorsMenuItem(for: Prefs.chatGPTIsPersonal ? .chatGPT : .chatGPTWork))
        let modeLabel = Prefs.chatGPTIsPersonal ? "Personal" : "Work"
        let item = NSMenuItem(title: "ChatGPT · \(modeLabel)", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func cursorOptionsItem(
        toggle: (String, Selector, Bool) -> NSMenuItem
    ) -> NSMenuItem {
        let sub = NSMenu(title: "Cursor")
        sub.addItem(toggle("Enable",
                           #selector(toggleEnableCursor), Prefs.enabledCursor))
        let showItem = toggle("Show in Menu",
                              #selector(toggleShowCursorInBar), Prefs.showCursorInBar)
        showItem.isEnabled = Prefs.enabledCursor
        sub.addItem(showItem)
        sub.addItem(.separator())

        let account = NSMenuItem(title: "Account", action: nil, keyEquivalent: "")
        let accountMenu = NSMenu(title: "Account")
        let work = NSMenuItem(title: "Work spend (D/M)",
                              action: #selector(setCursorWorkAccount), keyEquivalent: "")
        work.state = Prefs.cursorAccountMode == .work ? .on : .off
        work.target = self
        accountMenu.addItem(work)
        let personal = NSMenuItem(title: "Personal $20 Pro (% remaining)",
                                  action: #selector(setCursorPersonalAccount), keyEquivalent: "")
        personal.state = Prefs.cursorAccountMode == .personal ? .on : .off
        personal.target = self
        accountMenu.addItem(personal)
        account.submenu = accountMenu
        sub.addItem(account)

        if Prefs.cursorIsPersonal {
            let allowance = NSMenuItem(
                title: "Pro allowance · \(Fmt.exactMoney(Prefs.cursorPersonalAllowanceUSD))",
                action: #selector(customCursorAllowance), keyEquivalent: "")
            allowance.target = self
            sub.addItem(allowance)
        } else {
            sub.addItem(.separator())
            addBarSpendToggles(to: sub, source: .cursorWork)
        }

        sub.addItem(.separator())
        sub.addItem(colorsMenuItem(for: Prefs.cursorIsPersonal ? .cursorPersonal : .cursorWork))

        let modeLabel = Prefs.cursorIsPersonal ? "Personal" : "Work"
        let item = NSMenuItem(title: "Cursor · \(modeLabel)", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func grokBotOptionsItem(
        toggle: (String, Selector, Bool) -> NSMenuItem
    ) -> NSMenuItem {
        let sub = NSMenu(title: "Grok Bot")
        sub.addItem(toggle("Enable",
                           #selector(toggleEnableGrokBot), Prefs.enabledGrokBot))
        let showItem = toggle("Show in Menu",
                              #selector(toggleShowGrokBotInBar), Prefs.showGrokBotInBar)
        showItem.isEnabled = Prefs.enabledGrokBot
        sub.addItem(showItem)
        let note = NSMenuItem(
            title: "Needs Cursor login (same account as Grok Bot)",
            action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        sub.addItem(.separator())
        sub.addItem(colorsMenuItem(for: .grokBot))
        let item = NSMenuItem(title: "Grok Bot", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func claudeOptionsItem(
        toggle: (String, Selector, Bool) -> NSMenuItem
    ) -> NSMenuItem {
        let sub = NSMenu(title: "Claude")
        sub.addItem(toggle("Enable",
                           #selector(toggleEnableClaude), Prefs.enabledClaude))
        let showItem = toggle("Show in Menu",
                              #selector(toggleShowClaudeInBar), Prefs.showClaudeInBar)
        showItem.isEnabled = Prefs.enabledClaude
        sub.addItem(showItem)
        sub.addItem(.separator())

        let account = NSMenuItem(title: "Account", action: nil, keyEquivalent: "")
        let accountMenu = NSMenu(title: "Account")
        let work = NSMenuItem(title: "Work spend (D/M)",
                              action: #selector(setClaudeWorkAccount), keyEquivalent: "")
        work.state = Prefs.claudeAccountMode == .work ? .on : .off
        work.target = self
        accountMenu.addItem(work)
        let personal = NSMenuItem(title: "Personal Pro/Max (% remaining)",
                                  action: #selector(setClaudePersonalAccount), keyEquivalent: "")
        personal.state = Prefs.claudeAccountMode == .personal ? .on : .off
        personal.target = self
        accountMenu.addItem(personal)
        account.submenu = accountMenu
        sub.addItem(account)

        let cliNote = NSMenuItem(
            title: "Personal needs Claude Code CLI + /login",
            action: nil, keyEquivalent: "")
        cliNote.isEnabled = false
        sub.addItem(cliNote)

        if !Prefs.claudeIsPersonal {
            sub.addItem(.separator())
            addBarSpendToggles(to: sub, source: .claudeWork)
        }

        sub.addItem(.separator())
        sub.addItem(colorsMenuItem(for: Prefs.claudeIsPersonal ? .claudePersonal : .claude))
        let modeLabel = Prefs.claudeIsPersonal ? "Personal" : "Work"
        let item = NSMenuItem(title: "Claude · \(modeLabel)", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func openAIOptionsItem(
        toggle: (String, Selector, Bool) -> NSMenuItem
    ) -> NSMenuItem {
        let configured = OpenAIKeychain.isConfigured
        let sub = NSMenu(title: "OpenAI API")
        sub.addItem(toggle("Enable",
                           #selector(toggleEnableOpenAI), Prefs.enabledOpenAI))
        let showItem = toggle("Show in Menu",
                              #selector(toggleShowOpenAIInBar), Prefs.showOpenAIInBar)
        showItem.isEnabled = Prefs.enabledOpenAI
        sub.addItem(showItem)
        sub.addItem(.separator())

        let set = NSMenuItem(title: configured ? "Replace Admin API key…"
                                               : "Set Admin API key…",
                             action: #selector(setOpenAIKey), keyEquivalent: "")
        set.target = self
        sub.addItem(set)

        let test = NSMenuItem(title: "Test connection",
                              action: #selector(testOpenAIConnection), keyEquivalent: "")
        test.target = self
        test.isEnabled = configured
        sub.addItem(test)

        sub.addItem(.separator())
        let balanceText = lastOpenAISpend?.estimatedBalanceUSD.map {
            "Estimated prepaid balance · \(Fmt.money($0))"
        } ?? (OpenAIBalancePrefs.baseline() == nil
              ? "Estimated prepaid balance · not set"
              : "Estimated prepaid balance · refreshing")
        let balance = NSMenuItem(title: balanceText, action: nil, keyEquivalent: "")
        balance.isEnabled = false
        sub.addItem(balance)

        let setBalance = NSMenuItem(
            title: OpenAIBalancePrefs.baseline() == nil
                ? "Set current prepaid balance…" : "Reset current prepaid balance…",
            action: #selector(setOpenAIEstimatedBalance), keyEquivalent: "")
        setBalance.target = self
        setBalance.isEnabled = configured
        sub.addItem(setBalance)

        let clearBalance = NSMenuItem(title: "Clear estimated balance",
                                      action: #selector(clearOpenAIEstimatedBalance),
                                      keyEquivalent: "")
        clearBalance.target = self
        clearBalance.isEnabled = OpenAIBalancePrefs.baseline() != nil
        sub.addItem(clearBalance)

        sub.addItem(.separator())
        sub.addItem(colorsMenuItem(for: .openAI))

        let remove = NSMenuItem(title: "Remove Admin API key",
                                action: #selector(removeOpenAIKey), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = configured
        sub.addItem(remove)

        let item = NSMenuItem(title: configured ? "OpenAI API · configured"
                                                : "OpenAI API · not configured",
                              action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// Work-mode D/M visibility for the compact menu-bar title. Dropdown
    /// today/month rows stay visible regardless of these toggles.
    private func addBarSpendToggles(to menu: NSMenu, source: BarSpendSource) {
        let daily = NSMenuItem(title: "Show daily in menu bar",
                                action: #selector(toggleShowDailyInBar(_:)),
                                keyEquivalent: "")
        daily.representedObject = source.rawValue
        daily.state = Prefs.showDailyInBar(for: source) ? .on : .off
        daily.target = self
        menu.addItem(daily)

        let monthly = NSMenuItem(title: "Show monthly in menu bar",
                                  action: #selector(toggleShowMonthlyInBar(_:)),
                                  keyEquivalent: "")
        monthly.representedObject = source.rawValue
        monthly.state = Prefs.showMonthlyInBar(for: source) ? .on : .off
        monthly.target = self
        menu.addItem(monthly)
    }

    /// Per-source Colors submenu with good-zone style and threshold pickers.
    private func colorsMenuItem(for source: ColorSource) -> NSMenuItem {
        let menu = NSMenu(title: "Colors")
        let goodStyle: GoodZoneStyle = {
            switch source {
            case .chatGPT: return Prefs.chatGPTColors().goodStyle
            case .chatGPTWork: return Prefs.chatGPTWorkColors().goodStyle
            case .claude: return Prefs.claudeColors(policyUSD: config.spendRedUSD).goodStyle
            case .claudePersonal: return Prefs.claudePersonalColors().goodStyle
            case .cursorWork: return Prefs.cursorWorkColors(policyUSD: config.spendRedUSD).goodStyle
            case .cursorPersonal: return Prefs.cursorPersonalColors().goodStyle
            case .openAI: return Prefs.openAIColors().goodStyle
            case .grokBot: return Prefs.grokBotColors().goodStyle
            }
        }()

        let green = NSMenuItem(title: "Good: Green",
                               action: #selector(setGoodGreen(_:)), keyEquivalent: "")
        green.representedObject = source.rawValue
        green.state = goodStyle == .green ? .on : .off
        green.target = self
        menu.addItem(green)

        let white = NSMenuItem(title: "Good: White (original)",
                               action: #selector(setGoodWhite(_:)), keyEquivalent: "")
        white.representedObject = source.rawValue
        white.state = goodStyle == .white ? .on : .off
        white.target = self
        menu.addItem(white)
        menu.addItem(.separator())

        switch source {
        case .chatGPT, .claudePersonal, .cursorPersonal, .openAI, .grokBot:
            let cfg: RemainingColorConfig = {
                switch source {
                case .chatGPT: return Prefs.chatGPTColors()
                case .claudePersonal: return Prefs.claudePersonalColors()
                case .cursorPersonal: return Prefs.cursorPersonalColors()
                case .openAI: return Prefs.openAIColors()
                case .grokBot: return Prefs.grokBotColors()
                default: return Prefs.chatGPTColors()
                }
            }()
            menu.addItem(remainingThresholdItem(
                label: "Red", value: cfg.red, source: source, step: "red",
                presets: source == .openAI ? [2, 5, 10, 20] : [5, 10, 15, 20]))
            menu.addItem(remainingThresholdItem(
                label: "Orange", value: cfg.orange, source: source, step: "orange",
                presets: source == .openAI ? [10, 20, 30, 50] : [15, 25, 33, 40]))
            menu.addItem(remainingThresholdItem(
                label: "Yellow", value: cfg.yellow, source: source, step: "yellow",
                presets: source == .openAI ? [25, 50, 75, 100] : [40, 50, 60, 75]))
            let off = NSMenuItem(title: "Off (no tinting)",
                                 action: #selector(disableRemainingTint(_:)), keyEquivalent: "")
            off.representedObject = source.rawValue
            off.state = cfg.isEnabled ? .off : .on
            off.target = self
            menu.addItem(off)
        case .chatGPTWork, .claude, .cursorWork:
            let policyUSD = source == .chatGPTWork
                ? ChatGPTWorkUsageSnapshot.proPlanMonthlyUSD : config.spendRedUSD
            let cfg: SpendUpColorConfig
            switch source {
            case .chatGPTWork: cfg = Prefs.chatGPTWorkColors()
            case .claude: cfg = Prefs.claudeColors(policyUSD: policyUSD)
            default: cfg = Prefs.cursorWorkColors(policyUSD: policyUSD)
            }
            let cap = cfg.effectiveCap(policyUSD: policyUSD)
            let red = NSMenuItem(
                title: cap > 0
                    ? "Red at \(Fmt.exactMoney(cap)) / month"
                    : "Red threshold: off (no tinting)",
                action: nil, keyEquivalent: "")
            red.submenu = spendRedMenu(source: source, cap: cap,
                                       usePolicyDefault: source == .claude)
            menu.addItem(red)
            menu.addItem(spendPercentMenuItem(
                label: "Orange", percent: cfg.orangePercent, cap: cap,
                source: source, step: "orange",
                presets: [60, 70, 75, 80, 90]))
            menu.addItem(spendPercentMenuItem(
                label: "Yellow", percent: cfg.yellowPercent, cap: cap,
                source: source, step: "yellow",
                presets: [25, 33, 40, 50, 60]))
        }

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset colors",
                               action: #selector(resetSourceColors(_:)), keyEquivalent: "")
        reset.representedObject = source.rawValue
        reset.target = self
        menu.addItem(reset)

        let item = NSMenuItem(title: "Colors", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func remainingThresholdItem(label: String, value: Double, source: ColorSource,
                                        step: String, presets: [Double]) -> NSMenuItem {
        let suffix = source == .openAI ? "" : "%"
        let formatted = source == .openAI ? Fmt.exactMoney(value) : "\(Int(value))\(suffix)"
        let title = source == .openAI
            ? "\(label) below \(formatted)"
            : "\(label) at \(formatted) remaining"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: label)
        var matched = false
        for preset in presets {
            let child = NSMenuItem(
                title: source == .openAI ? Fmt.exactMoney(preset) : "\(Int(preset))%",
                action: #selector(setRemainingThreshold(_:)), keyEquivalent: "")
            child.representedObject = "\(source.rawValue):\(step):\(preset)"
            child.state = (source == .openAI
                ? moneyPresetMatches(value, preset)
                : percentPresetMatches(value, preset)) ? .on : .off
            if child.state == .on { matched = true }
            child.target = self
            menu.addItem(child)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(
            title: matched ? "Custom…" : "Custom (\(formatted))…",
            action: #selector(customRemainingThreshold(_:)), keyEquivalent: "")
        custom.representedObject = "\(source.rawValue):\(step)"
        custom.state = matched ? .off : .on
        custom.target = self
        menu.addItem(custom)
        item.submenu = menu
        return item
    }

    private func spendRedMenu(source: ColorSource, cap: Double,
                              usePolicyDefault: Bool) -> NSMenu {
        let menu = NSMenu(title: "Red threshold")
        let cfg = source == .claude
            ? Prefs.claudeColors(policyUSD: config.spendRedUSD)
            : Prefs.cursorWorkColors(policyUSD: config.spendRedUSD)
        let override = cfg.redOverrideUSD

        if usePolicyDefault {
            let policy = NSMenuItem(
                title: "Use policy default (\(Fmt.exactMoney(config.spendRedUSD)))",
                action: #selector(usePolicySpendRed(_:)), keyEquivalent: "")
            policy.representedObject = source.rawValue
            policy.state = override == nil ? .on : .off
            policy.target = self
            menu.addItem(policy)
            menu.addItem(.separator())
        }

        var matched = usePolicyDefault ? override == nil : false
        for value in [500.0, 750, 1000, 1500, 2000, 3000] {
            let item = NSMenuItem(title: Fmt.exactMoney(value),
                                  action: #selector(setSpendRed(_:)), keyEquivalent: "")
            item.representedObject = "\(source.rawValue):\(value)"
            item.state = moneyPresetMatches(override ?? -1, value) && override != nil ? .on : .off
            if override != nil && item.state == .on { matched = true }
            item.target = self
            menu.addItem(item)
        }

        let off = NSMenuItem(title: "Off (no tinting)",
                             action: #selector(setSpendRed(_:)), keyEquivalent: "")
        off.representedObject = "\(source.rawValue):0"
        off.state = (override == 0) ? .on : .off
        if off.state == .on { matched = true }
        off.target = self
        menu.addItem(off)

        menu.addItem(.separator())
        let custom = NSMenuItem(
            title: matched ? "Custom…" : "Custom (\(Fmt.exactMoney(cap)))…",
            action: #selector(customSpendRed(_:)), keyEquivalent: "")
        custom.representedObject = source.rawValue
        custom.state = matched ? .off : .on
        custom.target = self
        menu.addItem(custom)
        return menu
    }

    private func spendPercentMenuItem(label: String, percent: Double, cap: Double,
                                      source: ColorSource, step: String,
                                      presets: [Double]) -> NSMenuItem {
        let at = cap > 0 ? " (\(Fmt.exactMoney(cap * percent / 100)))" : ""
        let item = NSMenuItem(title: "\(label) at \(Int(percent))% of red\(at)",
                              action: nil, keyEquivalent: "")
        let menu = NSMenu(title: label)
        var matched = false
        for value in presets {
            let child = NSMenuItem(title: "\(Int(value))%",
                                   action: #selector(setSpendPercent(_:)), keyEquivalent: "")
            child.representedObject = "\(source.rawValue):\(step):\(value)"
            child.state = percentPresetMatches(percent, value) ? .on : .off
            if child.state == .on { matched = true }
            child.target = self
            menu.addItem(child)
        }
        menu.addItem(.separator())
        let customItem = NSMenuItem(
            title: matched ? "Custom…" : "Custom (\(Int(percent))%)…",
            action: #selector(customSpendPercent(_:)), keyEquivalent: "")
        customItem.representedObject = "\(source.rawValue):\(step)"
        customItem.state = matched ? .off : .on
        customItem.target = self
        menu.addItem(customItem)
        item.submenu = menu
        return item
    }

    private func colorSource(from raw: String?) -> ColorSource? {
        guard let raw, let source = ColorSource(rawValue: raw) else { return nil }
        return source
    }

    private func parseTagged(_ tag: String) -> (source: ColorSource, rest: String)? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let source = ColorSource(rawValue: String(parts[0])) else {
            return nil
        }
        return (source, String(parts[1]))
    }

    private func percentPresetMatches(_ value: Double, _ preset: Double) -> Bool {
        Int(value.rounded()) == Int(preset.rounded())
    }

    private func moneyPresetMatches(_ value: Double, _ preset: Double) -> Bool {
        abs(value - preset) < 0.005
    }

    /// Shared by the root menu and nested Cursor submenus.
    private func appendRows(_ rows: [MenuRow], to menu: NSMenu) {
        for row in rows {
            switch row {
            case .header(let s): menu.addItem(makeRow(s, bold: true))
            case .body(let s, let tints): menu.addItem(makeRow(s, bold: false, tints: tints))
            case .separator:     menu.addItem(.separator())
            case .submenu(let title, let titleTints, let children):
                // Standard NSMenuItem (not a custom view) so the submenu
                // disclosure works — collapsed until the user hovers/clicks.
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = sourceIcon(forRowTitle: title)
                let menuSize = NSFont.menuFont(ofSize: 0).pointSize
                let attr = NSMutableAttributedString(attributedString: MenuText.attributed(
                    title, font: NSFont.menuFont(ofSize: menuSize), tints: titleTints))
                var styled = !titleTints.isEmpty
                for prefix in ["ChatGPT", "Claude", "Cursor", "OpenAI"] where title.hasPrefix(prefix) {
                    attr.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: menuSize),
                                      range: NSRange(location: 0, length: (prefix as NSString).length))
                    styled = true
                    break
                }
                if styled { item.attributedTitle = attr }
                let sub = NSMenu(title: title)
                appendRows(children, to: sub)
                item.submenu = sub
                menu.addItem(item)
            }
        }
    }

    // MARK: - Opus alert

    private func maybeAlertOpus(_ r: Rollup) {
        guard Prefs.notificationsEnabled, Prefs.opusAlertsEnabled, notificationPermission else { return }
        guard r.opusShare > config.opusAlertShare else { return }
        let cal = Calendar.current
        let key = "\(cal.component(.year, from: Date()))-\(cal.ordinality(of: .day, in: .year, for: Date()) ?? 0)"
        guard lastOpusAlertKey != key else { return }   // ~1/day
        guard UserDefaults.standard.string(forKey: "opusLastAlertDay") != key else { return }
        lastOpusAlertKey = key

        let title = "Opus is \(Fmt.pct(r.opusShare)) of your spend"
        let body = "Use Sonnet for routine work; reserve Opus for hard problems. "
            + "Opus costs ~5× Sonnet per token."

        mission.advisories.insert(MissionAdvisory(title: title, body: body), at: 0)
        mission.advisories = Array(mission.advisories.prefix(30))
        guard notificationsAvailable else {
            // Unbundled (swift run): the red flame in the menu bar is the signal.
            NSLog("[TokenPulse] ALERT: \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "TokenPulse"
        content.subtitle = "Claude · " + title
        content.body = body
        content.sound = Prefs.notificationSounds ? .default : nil
        content.userInfo = ["provider": "Claude", "advisoryTitle": title]
        content.categoryIdentifier = "tokenpulse.opus"
        content.threadIdentifier = "tokenpulse-opus"
        let req = UNNotificationRequest(identifier: "opus-share-\(key)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if error == nil { UserDefaults.standard.set(key, forKey: "opusLastAlertDay") }
            else { NSLog("TokenPulse notification delivery failed: %@", error!.localizedDescription) }
        }
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        refresh()
        refreshProxySpend()
        refreshCursorSpend(force: true)
        refreshOpenAISpend(force: true)
        refreshChatGPTUsage(force: true)
        refreshClaudeUsage(force: true)
        refreshGrokBotUsage(force: true)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func setUsageRefreshMinutes(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        Prefs.usageRefreshMinutes = minutes
        scheduleUsageTimers()
        rerender()
    }

    @objc private func setStatusBarDesign(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let design = StatusBarDesign(rawValue: raw) else { return }
        Prefs.statusBarDesign = design
        rerender()
    }

    @objc private func toggleThemedProviderLogos() {
        Prefs.themedProviderLogos.toggle()
        rerender()
    }

    @objc private func toggleRememberPanelPlace() {
        Prefs.rememberPanelPlace.toggle()
        rerender()
    }

    @objc private func toggleNotifications() { Prefs.notificationsEnabled.toggle(); rerender() }
    @objc private func toggleAllowanceAlerts() { Prefs.allowanceAlertsEnabled.toggle(); rerender() }
    @objc private func toggleOpusAlerts() { Prefs.opusAlertsEnabled.toggle(); rerender() }
    @objc private func toggleNotificationSounds() { Prefs.notificationSounds.toggle(); rerender() }
    @objc private func toggleAlertThreshold(_ sender: NSMenuItem) {
        guard let threshold = sender.representedObject as? Int else { return }
        var disabled = Set(Prefs.disabledAlertThresholds)
        if disabled.contains(threshold) { disabled.remove(threshold) } else { disabled.insert(threshold) }
        Prefs.disabledAlertThresholds = Array(disabled)
        rerender()
    }
    @objc private func customAlertThresholds() {
        let alert = MissionAlert()
        alert.messageText = "Low allowance thresholds"
        alert.informativeText = "Enter 1–10 percent-left levels between 1 and 99, separated by commas. Each level alerts once per provider window until it resets or recovers."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        field.stringValue = Prefs.alertThresholds.map(String.init).joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let values = AllowanceAlertLedger.parseThresholds(field.stringValue) else {
            showMessage(title: "Invalid thresholds", message: "Use whole percentages from 1 to 99, for example 15, 10, 5.", style: .warning); return
        }
        Prefs.alertThresholds = values
        Prefs.disabledAlertThresholds = []
        rerender()
    }
    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    @objc private func sendTestNotification() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.checkNotificationPermission(force: true)
                guard granted else { self?.openNotificationSettings(); return }
                let sample = AllowanceObservation(providerID: "chatgpt", provider: "ChatGPT", windowID: "session", window: "Preview · 5-hour", percent: 15, cycle: "preview", reset: "example · 10:00 PM")
                let content = AllowanceNotification.content(sample, threshold: 15, sound: false)
                content.subtitle = "Notification preview"
                content.body = "Allowance alerts use this icon and include the provider, window and reset time."
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "tokenpulse.preview", content: content, trigger: nil))
            }
        }
    }

    /// Both toggles re-render rather than patching the status item in place:
    /// that also rebuilds the menu, so the checkmarks match the new state.
    @objc private func toggleDarkBarBackground() {
        Prefs.darkBarBackground.toggle()
        rerender()
    }

    @objc private func toggleSpendColors() {
        Prefs.spendColorsEnabled.toggle()
        rerender()
    }

    @objc private func togglePastelBarColors() {
        Prefs.pastelBarColors.toggle()
        rerender()
    }

    /// Confirm first: this discards every Options choice at once, and menu-bar
    /// clicks are easy to make by accident.
    @objc private func resetOptionsToDefaults() {
        let alert = MissionAlert()
        alert.messageText = "Reset all options to defaults?"
        alert.informativeText = """
            Layout, colors, visibility, account modes, and thresholds go back to \
            their first-launch values. Saved API keys are kept.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Prefs.resetToDefaults()
        scheduleUsageTimers()
        rerender()
    }

    @objc private func toggleEnableCursor() {
        Prefs.enabledCursor.toggle()
        if Prefs.enabledCursor {
            if confirmCursorLoginAccess(for: "Cursor") {
                refreshCursorSpend(force: true)
            } else {
                Prefs.enabledCursor = false
            }
        } else {
            lastCursorSpend = nil
        }
        rerender()
    }

    @objc private func toggleShowCursorInBar() {
        Prefs.showCursorInBar.toggle()
        rerender()
    }

    @objc private func toggleEnableChatGPT() {
        Prefs.enabledChatGPT.toggle()
        if Prefs.enabledChatGPT {
            refreshChatGPTUsage(force: true)
        } else {
            lastChatGPTUsage = nil; lastChatGPTWorkUsage = nil
        }
        rerender()
    }

    @objc private func toggleShowChatGPTInBar() {
        Prefs.showChatGPTInBar.toggle()
        rerender()
    }

    @objc private func toggleEnableOpenAI() {
        Prefs.enabledOpenAI.toggle()
        if Prefs.enabledOpenAI {
            if OpenAIKeychain.isConfigured {
                refreshOpenAISpend(force: true)
            } else {
                setOpenAIKey()
                if !OpenAIKeychain.isConfigured {
                    Prefs.enabledOpenAI = false
                    lastOpenAISpend = nil
                }
            }
        } else {
            lastOpenAISpend = nil
        }
        rerender()
    }

    @objc private func toggleShowOpenAIInBar() {
        Prefs.showOpenAIInBar.toggle()
        rerender()
    }

    @objc private func toggleEnableGrokBot() {
        Prefs.enabledGrokBot.toggle()
        if Prefs.enabledGrokBot {
            if confirmCursorLoginAccess(for: "Grok Bot") {
                refreshGrokBotUsage(force: true)
            } else {
                Prefs.enabledGrokBot = false
            }
        } else {
            lastGrokBotUsage = nil
        }
        rerender()
    }

    @objc private func toggleShowGrokBotInBar() {
        Prefs.showGrokBotInBar.toggle()
        if Prefs.showGrokBotInBar {
            refreshGrokBotUsage(force: true)
        } else {
            lastGrokBotUsage = nil
        }
        rerender()
    }

    @objc private func toggleEnableClaude() {
        Prefs.enabledClaude.toggle()
        if Prefs.enabledClaude {
            refreshClaudeUsage(force: true)
        } else {
            lastClaudeUsage = nil
        }
        rerender()
    }

    @objc private func toggleShowClaudeInBar() {
        Prefs.showClaudeInBar.toggle()
        rerender()
    }

    /// Cursor and Grok Bot share Cursor's existing sign-in. Explain that before
    /// the Mac password sheet, and leave Enable off if the user backs out.
    private var explainedCursorLoginAccess = false

    private func confirmCursorLoginAccess(for name: String) -> Bool {
        switch CursorAuthCache.loginAvailability() {
        case .missing:
            showMessage(
                title: "Sign in to Cursor first",
                message: "\(name) uses the Cursor login already on this Mac. "
                    + "TokenPulse does not keep a separate key. Sign in to Cursor, "
                    + "then turn \(name) on again.",
                style: .informational)
            return false
        case .ready:
            return true
        case .needsKeychain:
            if explainedCursorLoginAccess { return true }
            let alert = MissionAlert()
            alert.messageText = "Allow TokenPulse to use the Cursor login"
            alert.informativeText = "\(name) uses the Cursor sign-in already on this Mac. "
                + "TokenPulse does not ask you to paste a key. macOS will ask for your "
                + "Mac password so this app can read it. Always Allow keeps that until "
                + "TokenPulse is reinstalled."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            explainedCursorLoginAccess = true
            return true
        }
    }

    // MARK: - OpenAI Admin key

    private static let openAIKeyMigrationPromptedKey = "openAIKeyFileMigrationPrompted"

    private func promptOpenAIKeyMigrationIfNeeded() {
        guard OpenAIKeychain.needsKeyMigration else { return }
        guard !UserDefaults.standard.bool(forKey: Self.openAIKeyMigrationPromptedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.openAIKeyMigrationPromptedKey)
        let alert = MissionAlert()
        alert.messageText = "Re-enter your OpenAI Admin API key once"
        alert.informativeText = "TokenPulse now stores this key locally (not Keychain) so "
            + "macOS stops asking for your password on every launch. Open "
            + "Options → OpenAI API → Set Admin API key… and paste the same sk-admin- key."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    @objc private func setOpenAIKey() {
        let alert = MissionAlert()
        alert.messageText = "OpenAI Admin API key"
        alert.informativeText = "Create an sk-admin- key under OpenAI Platform → "
            + "Organization → Admin keys. It is stored only on this Mac."
        alert.addButton(withTitle: "Save and test")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-admin-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch OpenAIKeychain.save(field.stringValue) {
        case .failure(let error):
            showMessage(title: "OpenAI key was not saved", message: error.userMessage,
                        style: .warning)
        case .success:
            openAIClient.clearCache()
            testOpenAIConnection()
        }
    }

    @objc private func testOpenAIConnection() {
        openAIClient.testConnection { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.lastOpenAISpend = snapshot
                    self.rerender()
                    self.showMessage(
                        title: "OpenAI API connected",
                        message: "Today \(Fmt.money(snapshot.todaySpendUSD)) · "
                            + "Month \(Fmt.money(snapshot.monthSpendUSD))"
                            + (snapshot.estimatedBalanceUSD.map {
                                " · Est. balance \(Fmt.money($0))"
                            } ?? ""),
                        style: .informational)
                case .failure(let error):
                    if error == .invalidKey {
                        _ = OpenAIKeychain.delete()
                        self.lastOpenAISpend = nil
                        self.openAIClient.clearCache()
                        self.rerender()
                    }
                    self.showMessage(title: "OpenAI connection failed",
                                     message: error.userMessage, style: .warning)
                }
            }
        }
    }

    @objc private func setOpenAIEstimatedBalance() {
        openAIClient.testConnection { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.showMessage(title: "Could not set estimated balance",
                                     message: error.userMessage, style: .warning)
                case .success(let snapshot):
                    let current = snapshot.estimatedBalanceUSD ?? 0
                    guard let entered = self.promptNumber(
                        title: "Current OpenAI prepaid balance",
                        message: "Enter the balance shown in OpenAI Billing now. "
                            + "TokenPulse will subtract newly reported API costs. "
                            + "Reset this value after adding credits.",
                        current: max(0, current)) else { return }
                    OpenAIBalancePrefs.save(
                        currentBalanceUSD: max(0, entered),
                        todaySpendUSD: snapshot.todaySpendUSD,
                        now: snapshot.fetchedAt)
                    self.openAIClient.clearCache()
                    self.refreshOpenAISpend(force: true)
                }
            }
        }
    }

    @objc private func clearOpenAIEstimatedBalance() {
        OpenAIBalancePrefs.clear()
        openAIClient.clearCache()
        refreshOpenAISpend(force: true)
    }

    @objc private func removeOpenAIKey() {
        let alert = MissionAlert()
        alert.messageText = "Remove OpenAI Admin API key?"
        alert.informativeText = "This removes the credential from this Mac. "
            + "Revoke it in OpenAI Platform too if it should no longer be valid."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch OpenAIKeychain.delete() {
        case .failure(let error):
            showMessage(title: "Could not remove OpenAI key",
                        message: error.userMessage, style: .warning)
        case .success:
            OpenAIBalancePrefs.clear()
            lastOpenAISpend = nil
            openAIClient.clearCache()
            rerender()
        }
    }

    private func showMessage(title: String, message: String, style: NSAlert.Style) {
        let alert = MissionAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    @objc private func setChatGPTPersonalAccount() {
        Prefs.chatGPTAccountMode = .personal
        lastChatGPTWorkUsage = nil
        chatGPTWorkClient.clearCache()
        rerender()
        refreshChatGPTUsage(force: true)
    }

    @objc private func setChatGPTWorkAccount() {
        Prefs.chatGPTAccountMode = .work
        lastChatGPTUsage = nil
        rerender()
        refreshChatGPTUsage(force: true)
    }

    @objc private func toggleShowDailyInBar(_ sender: NSMenuItem) {
        guard let source = barSpendSource(from: sender.representedObject as? String) else { return }
        Prefs.setShowDailyInBar(!Prefs.showDailyInBar(for: source), for: source)
        rerender()
    }

    @objc private func toggleShowMonthlyInBar(_ sender: NSMenuItem) {
        guard let source = barSpendSource(from: sender.representedObject as? String) else { return }
        Prefs.setShowMonthlyInBar(!Prefs.showMonthlyInBar(for: source), for: source)
        rerender()
    }

    private func barSpendSource(from raw: String?) -> BarSpendSource? {
        raw.flatMap(BarSpendSource.init(rawValue:))
    }

    @objc private func setCursorWorkAccount() {
        Prefs.cursorAccountMode = .work
        rerender()
    }

    @objc private func setClaudeWorkAccount() {
        Prefs.claudeAccountMode = .work
        lastClaudeUsage = nil
        rerender()
    }

    @objc private func setClaudePersonalAccount() {
        Prefs.claudeAccountMode = .personal
        rerender()
        refreshClaudeUsage(force: true)
    }

    @objc private func setCursorPersonalAccount() {
        Prefs.cursorAccountMode = .personal
        rerender()
    }

    @objc private func customCursorAllowance() {
        guard let v = promptNumber(
            title: "Cursor Pro allowance",
            message: "Monthly included usage for your personal Cursor Pro account.",
            current: Prefs.cursorPersonalAllowanceUSD) else { return }
        Prefs.cursorPersonalAllowanceUSD = max(0.01, v)
        rerender()
    }

    // MARK: - Per-source colors

    @objc private func setGoodGreen(_ sender: NSMenuItem) {
        guard let source = colorSource(from: sender.representedObject as? String) else { return }
        Prefs.setGoodStyle(.green, for: source)
        rerender()
    }

    @objc private func setGoodWhite(_ sender: NSMenuItem) {
        guard let source = colorSource(from: sender.representedObject as? String) else { return }
        Prefs.setGoodStyle(.white, for: source)
        rerender()
    }

    @objc private func resetSourceColors(_ sender: NSMenuItem) {
        guard let source = colorSource(from: sender.representedObject as? String) else { return }
        Prefs.resetColors(for: source)
        rerender()
    }

    @objc private func disableRemainingTint(_ sender: NSMenuItem) {
        guard let source = colorSource(from: sender.representedObject as? String) else { return }
        Prefs.disableRemainingTinting(for: source)
        rerender()
    }

    @objc private func setRemainingThreshold(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let parts = tag.split(separator: ":")
        guard parts.count == 3,
              let source = ColorSource(rawValue: String(parts[0])),
              let value = Double(parts[2]) else { return }
        let step = String(parts[1])
        switch step {
        case "red": Prefs.setRemainingRed(value, for: source)
        case "orange": Prefs.setRemainingOrange(value, for: source)
        case "yellow": Prefs.setRemainingYellow(value, for: source)
        default: return
        }
        rerender()
    }

    @objc private func customRemainingThreshold(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String,
              let parsed = parseTagged(tag) else { return }
        let cfg: RemainingColorConfig = {
            switch parsed.source {
            case .chatGPT: return Prefs.chatGPTColors()
            case .claudePersonal: return Prefs.claudePersonalColors()
            case .cursorPersonal: return Prefs.cursorPersonalColors()
            case .openAI: return Prefs.openAIColors()
            case .grokBot: return Prefs.grokBotColors()
            default: return Prefs.chatGPTColors()
            }
        }()
        let isMoney = parsed.source == .openAI
        let current: Double = {
            switch parsed.rest {
            case "red": return cfg.red
            case "orange": return cfg.orange
            case "yellow": return cfg.yellow
            default: return 0
            }
        }()
        guard let v = promptNumber(
            title: "\(parsed.rest.capitalized) threshold",
            message: isMoney
                ? "Remaining balance below this turns red (OpenAI estimated prepaid balance)."
                : "Remaining percentage at or below this step.",
            current: current) else { return }
        switch parsed.rest {
        case "red": Prefs.setRemainingRed(max(0, v), for: parsed.source)
        case "orange": Prefs.setRemainingOrange(max(0, v), for: parsed.source)
        case "yellow": Prefs.setRemainingYellow(max(0, v), for: parsed.source)
        default: return
        }
        rerender()
    }

    @objc private func usePolicySpendRed(_ sender: NSMenuItem) {
        guard let source = colorSource(from: sender.representedObject as? String) else { return }
        Prefs.setSpendRedOverride(nil, for: source)
        rerender()
    }

    @objc private func setSpendRed(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let parts = tag.split(separator: ":")
        guard parts.count == 2,
              let source = ColorSource(rawValue: String(parts[0])),
              let value = Double(parts[1]) else { return }
        Prefs.setSpendRedOverride(value, for: source)
        rerender()
    }

    @objc private func customSpendRed(_ sender: NSMenuItem) {
        guard let source = colorSource(from: sender.representedObject as? String) else { return }
        let policyUSD = source == .chatGPTWork
            ? ChatGPTWorkUsageSnapshot.proPlanMonthlyUSD : config.spendRedUSD
        let cfg: SpendUpColorConfig
        switch source {
        case .chatGPTWork: cfg = Prefs.chatGPTWorkColors()
        case .claude: cfg = Prefs.claudeColors(policyUSD: policyUSD)
        default: cfg = Prefs.cursorWorkColors(policyUSD: policyUSD)
        }
        guard let v = promptNumber(
            title: "Red threshold",
            message: "Month spend that paints a figure red. Orange and yellow are "
                + "percentages of this. 0 turns tinting off.",
            current: cfg.effectiveCap(policyUSD: policyUSD)) else { return }
        Prefs.setSpendRedOverride(max(0, v), for: source)
        rerender()
    }

    @objc private func setSpendPercent(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let parts = tag.split(separator: ":")
        guard parts.count == 3,
              let source = ColorSource(rawValue: String(parts[0])),
              let value = Double(parts[2]) else { return }
        switch String(parts[1]) {
        case "orange": Prefs.setSpendOrangePercent(value, for: source)
        case "yellow": Prefs.setSpendYellowPercent(value, for: source)
        default: return
        }
        rerender()
    }

    @objc private func customSpendPercent(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String,
              let parsed = parseTagged(tag) else { return }
        let cfg: SpendUpColorConfig
        switch parsed.source {
        case .chatGPTWork: cfg = Prefs.chatGPTWorkColors()
        case .claude: cfg = Prefs.claudeColors(policyUSD: config.spendRedUSD)
        default: cfg = Prefs.cursorWorkColors(policyUSD: config.spendRedUSD)
        }
        let current = parsed.rest == "orange" ? cfg.orangePercent : cfg.yellowPercent
        let label = parsed.rest == "orange" ? "Orange step" : "Yellow step"
        guard let v = promptNumber(
            title: label,
            message: "Percent of the red threshold at which figures turn \(parsed.rest).",
            current: current) else { return }
        if parsed.rest == "orange" {
            Prefs.setSpendOrangePercent(v, for: parsed.source)
        } else {
            Prefs.setSpendYellowPercent(v, for: parsed.source)
        }
        rerender()
    }

    /// nil on cancel or unparseable input, which leaves the current value alone.
    /// Activates first: as an accessory app there is no frontmost window to
    /// carry the sheet, so the alert would otherwise open behind other apps.
    private func promptNumber(title: String, message: String, current: Double) -> Double? {
        let alert = MissionAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = current == current.rounded()
            ? String(format: "%.0f", current) : String(format: "%.2f", current)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let cleaned = field.stringValue.filter { $0.isNumber || $0 == "." }
        return Double(cleaned)
    }

    private func rerender() {
        if let r = lastRollup, let eff = lastEfficiency {
            render(displayRollup(for: r), eff)
        } else if let button = statusItem?.button {
            applyBarBackground(to: button)
        }
    }

    private let scoreboard = ScoreboardController()
    @objc private func openScoreboard() {
        guard let eff = lastEfficiency, let r = lastRollup else { return }
        let model = ScoreboardModel.build(eff: eff, rollup: r, history: history)
        scoreboard.show(model)
    }

}
