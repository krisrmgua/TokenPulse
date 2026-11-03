import XCTest
@testable import TokenPulseCore

final class ChatGPTUsageTests: XCTestCase {
    private var denverCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }

    func testParsesWeeklyLimitAndResetFromStatusTUI() throws {
        let now = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 8, day: 26, hour: 9)))
        let raw = """
        \u{001B}[2m│ Weekly limit: \u{001B}[22m[█████████████░░░░░░░] 64% left
        \u{001B}[2m│               (resets 11:00 on 1 Sep)
        """
        let snapshot = try XCTUnwrap(ChatGPTUsageParse.snapshot(
            from: raw, now: now, calendar: denverCalendar, codexPath: "/tmp/codex"))

        XCTAssertEqual(snapshot.percentLeft, 64)
        XCTAssertEqual(snapshot.codexPath, "/tmp/codex")
        XCTAssertEqual(denverCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: snapshot.resetAt),
                       DateComponents(year: 2026, month: 9, day: 1, hour: 11, minute: 0))
    }

    func testInfersNextYearForJanuaryResetShownInDecember() throws {
        let now = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 12, day: 29, hour: 9)))
        let snapshot = try XCTUnwrap(ChatGPTUsageParse.snapshot(
            from: "Weekly limit: 20% left (resets 08:30 on 2 Jan)",
            now: now, calendar: denverCalendar))
        XCTAssertEqual(denverCalendar.component(.year, from: snapshot.resetAt), 2027)
    }

    func testRejectsIncompleteOrOutOfRangeStatus() {
        XCTAssertNil(ChatGPTUsageParse.snapshot(from: "Weekly limit unavailable"))
        XCTAssertNil(ChatGPTUsageParse.snapshot(
            from: "Weekly limit: 101% left (resets 11:00 on 1 Sep)"))
        XCTAssertNil(ChatGPTUsageParse.snapshot(
            from: "Weekly limit: 64% left (resets 11:00 on 00 Sep)"))
        XCTAssertNil(ChatGPTUsageParse.snapshot(
            from: "Weekly limit: 64% left (resets 11:00 on 99 Sep)"))
    }

    func testConfiguredCodexPathWins() {
        XCTAssertEqual(ChatGPTUsageClient.codexExecutable(
            environment: ["TOKENPULSE_CODEX_PATH": "/bin/sh"]), "/bin/sh")
    }

    func testParsesStructuredAppServerRateLimits() throws {
        // Real shape: primary is the 5-hour window, secondary is the weekly one.
        let json = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":67,"windowDurationMins":300,"resetsAt":1793501921},"secondary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1794088721}}}}"#
        let snapshot = try XCTUnwrap(ChatGPTUsageParse.snapshot(
            fromAppServerData: Data(json.utf8), codexPath: "/tmp/codex"))
        XCTAssertEqual(snapshot.percentLeft, 89)
        XCTAssertEqual(snapshot.resetAt.timeIntervalSince1970, 1_794_088_721)
        XCTAssertEqual(snapshot.codexPath, "/tmp/codex")
        XCTAssertEqual(snapshot.session?.percentLeft, 33)
        XCTAssertEqual(snapshot.personalBarPercent, "33%")   // the menu bar shows the 5-hour window
    }

    func testWeeklyWindowCanBePrimaryWhenItIsTheWeeklyOne() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1788282000}}}}"#
        let snapshot = try XCTUnwrap(ChatGPTUsageParse.snapshot(
            fromAppServerData: Data(json.utf8), codexPath: "/tmp/codex"))
        XCTAssertEqual(snapshot.percentLeft, 64)
        XCTAssertEqual(snapshot.resetAt.timeIntervalSince1970, 1_788_282_000)
    }

    func testDisplayDateLeadsWithTimeAndUsesRelativeDays() throws {
        let now = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 11, day: 2, hour: 21, minute: 1)))
        let today = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 11, day: 2, hour: 22, minute: 40)))
        let tomorrow = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 11, day: 3, hour: 1, minute: 57)))
        let later = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 11, day: 7, hour: 14, minute: 58)))
        let nextYear = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2027, month: 1, day: 2, hour: 8, minute: 30)))

        XCTAssertEqual(ChatGPTUsageParse.displayDate(today, now: now, calendar: denverCalendar),
                       "Today at 10:40 PM MST")
        XCTAssertEqual(ChatGPTUsageParse.displayDate(tomorrow, now: now, calendar: denverCalendar),
                       "Tomorrow at 1:57 AM MST")
        XCTAssertEqual(ChatGPTUsageParse.displayDate(later, now: now, calendar: denverCalendar),
                       "Nov 7, 2026 at 2:58 PM MST")
        XCTAssertEqual(ChatGPTUsageParse.displayDate(nextYear, now: now, calendar: denverCalendar),
                       "Jan 2, 2027 at 8:30 AM MST")
    }

    func testZeroPercentBarIncludesShortResetDate() throws {
        let reset = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 9, day: 20, hour: 11)))
        let usage = ChatGPTUsageSnapshot(percentLeft: 0, resetAt: reset,
                                         fetchedAt: reset, codexPath: "codex")
        XCTAssertEqual(
            usage.personalBarPercent,
            "0% \(ChatGPTUsageParse.shortBarResetDate(from: reset, calendar: denverCalendar))")
    }

    func testMenuRowsContainChatGPTSection() throws {
        let reset = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 9, day: 1, hour: 11)))
        let usage = ChatGPTUsageSnapshot(percentLeft: 64, resetAt: reset,
                                         fetchedAt: reset, codexPath: "codex")
        let rollup = Rollup()
        let efficiency = EfficiencyResult.compute(
            rollup: rollup, scan: ScanResult(records: [], sessions: [:]),
            pricing: Pricing(), config: Config())
        let rows = tokenpulseMenuRows(
            rollup, efficiency, Config(), chatGPT: usage,
            visibility: MenuSourceVisibility(
                chatGPT: true, cursor: false, openAI: false, claude: false))
        XCTAssertTrue(rows.contains { row in
            if case .submenu(let title, _, let children) = row {
                return title == "ChatGPT · 64% left" && children.count == 2
            }
            return false
        })
    }

    func testHiddenClaudeDoesNotContributeRowsOrSpendTotals() {
        var rollup = Rollup()
        rollup.todayUSD = 3
        rollup.monthUSD = 40
        let efficiency = EfficiencyResult.compute(
            rollup: rollup, scan: ScanResult(records: [], sessions: [:]),
            pricing: Pricing(), config: Config())
        let rows = tokenpulseMenuRows(
            rollup, efficiency, Config(),
            visibility: MenuSourceVisibility(
                chatGPT: false, cursor: false, openAI: false, claude: false))

        XCTAssertTrue(rows.isEmpty)
    }
}
