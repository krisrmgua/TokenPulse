import XCTest
@testable import TokenPulseCore

final class SpendProjectionTests: XCTestCase {
    func testMonthProjection() {
        let cal = Calendar.current
        let projNow = cal.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let days = cal.range(of: .day, in: .month, for: projNow)?.count ?? 31
        XCTAssertEqual(projectedMonthEnd(monthUSD: 25.0, now: projNow),
                       25.0 * Double(days) / 10.0, accuracy: 0.001)
    }

    func testCombinedPresentationRemainsTheDefault() {
        var rollup = Rollup()
        rollup.todayUSD = 3
        rollup.monthUSD = 40
        let cursor = CursorSpendSnapshot(
            totalSpendUSD: 10, todaySpendUSD: 1.5, byModel: [],
            fetchedAt: Date(), userId: 1,
            planUsage: CursorPlanUsage(limitUSD: 20, includedSpendUSD: 5,
                                       totalPercentUsed: 25, percentLeft: 75))
        let efficiency = EfficiencyResult.compute(
            rollup: rollup, scan: ScanResult(records: [], sessions: [:]),
            pricing: Pricing(), config: Config())
        let rows = tokenpulseMenuRows(
            rollup, efficiency, Config(), cursor: cursor,
            cursorAccountMode: .work, claudeAccountMode: .work,
            visibility: MenuSourceVisibility(
                chatGPT: false, cursor: true, openAI: false, claude: true),
            presentation: .combined)

        XCTAssertTrue(rows.contains { row in
            if case .header(let title) = row { return title == "Your spend" }
            return false
        })
        XCTAssertTrue(rows.contains { row in
            if case .body(let text, _) = row {
                return text.contains("Today: $4.50") && text.contains("Month: $50")
            }
            return false
        })
    }

    func testPerSourcePresentationOmitsCrossProviderSummary() {
        var rollup = Rollup()
        rollup.todayUSD = 3
        rollup.monthUSD = 40
        let cursor = CursorSpendSnapshot(
            totalSpendUSD: 10, todaySpendUSD: 1.5, byModel: [],
            fetchedAt: Date(), userId: 1,
            planUsage: CursorPlanUsage(limitUSD: 20, includedSpendUSD: 5,
                                       totalPercentUsed: 25, percentLeft: 75))
        let efficiency = EfficiencyResult.compute(
            rollup: rollup, scan: ScanResult(records: [], sessions: [:]),
            pricing: Pricing(), config: Config())
        let rows = tokenpulseMenuRows(
            rollup, efficiency, Config(), cursor: cursor,
            visibility: MenuSourceVisibility(
                chatGPT: false, cursor: true, openAI: false, claude: true),
            presentation: .perSource)

        XCTAssertFalse(rows.contains { row in
            if case .header(let title) = row { return title == "Your spend" }
            return false
        })
    }

    func testRemotePollIntervalDefaultShared() {
        XCTAssertEqual(Config().remotePollInterval, 5 * 60)
    }

    func testRemotePollIntervalBounds() {
        XCTAssertEqual(Config.acceptedRemotePollInterval(60), 60)
        XCTAssertEqual(Config.acceptedRemotePollInterval(3600), 3600)
        XCTAssertNil(Config.acceptedRemotePollInterval(0.001))
        XCTAssertNil(Config.acceptedRemotePollInterval(3601))
    }
}
