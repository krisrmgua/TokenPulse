import XCTest
@testable import TokenPulseCore

final class GrokBotUsageTests: XCTestCase {
    func testPercentLeftInvertsUsagePercent() {
        XCTAssertEqual(GrokBotUsageParse.percentLeft(from: 39), 61)
        XCTAssertEqual(GrokBotUsageParse.percentLeft(from: 34.595012), 65)
        XCTAssertEqual(GrokBotUsageParse.percentLeft(from: 0), 100)
        XCTAssertEqual(GrokBotUsageParse.percentLeft(from: 100), 0)
        XCTAssertEqual(GrokBotUsageParse.percentLeft(from: -5), 100)
        XCTAssertEqual(GrokBotUsageParse.percentLeft(from: 150), 0)
    }

    func testParsesSandUsageStatus() throws {
        let obj: [String: Any] = [
            "usagePercent": 39.0,
            "nextResetTimestampUtc": "2026-09-16T20:30:58.668Z",
            "grokPlanLabel": "Grok Bot Plan",
            "cursorPlanName": "Pro",
            "hasNonZeroIncludedLimit": true,
        ]
        let snap = try XCTUnwrap(GrokBotUsageParse.snapshot(from: obj))
        XCTAssertEqual(snap.percentLeft, 61)
        XCTAssertEqual(snap.percentUsed, 39.0, accuracy: 0.001)
        XCTAssertEqual(snap.planLabel, "Grok Bot Plan")
        XCTAssertEqual(snap.cursorPlanName, "Pro")
        XCTAssertNotNil(snap.resetAt)
        XCTAssertEqual(snap.personalBarPercent, "61%")
        let zero = GrokBotUsageSnapshot(
            percentLeft: 0, percentUsed: 100,
            resetAt: snap.resetAt,
            planLabel: nil, cursorPlanName: nil, fetchedAt: Date())
        XCTAssertEqual(
            zero.personalBarPercent,
            "0% \(ChatGPTUsageParse.shortBarResetDate(from: snap.resetAt!))")
        XCTAssertEqual(
            GrokBotUsageSnapshot(
                percentLeft: 0, percentUsed: 100, resetAt: nil,
                planLabel: nil, cursorPlanName: nil, fetchedAt: Date()
            ).personalBarPercent,
            "0%")
    }

    func testPooledEnterpriseReturnsNil() {
        let obj: [String: Any] = [
            "usagePercent": 10.0,
            "usesPooledEnterpriseAllowance": true,
        ]
        XCTAssertNil(GrokBotUsageParse.snapshot(from: obj))
        XCTAssertTrue(GrokBotUsageParse.isPooledEnterprise(obj))
    }

    func testMissingUsagePercentReturnsNil() {
        XCTAssertNil(GrokBotUsageParse.snapshot(from: ["grokPlanLabel": "Grok Bot Plan"]))
    }

    func testMenuRowShowsPercentLeft() {
        var rollup = Rollup()
        let efficiency = EfficiencyResult.compute(
            rollup: rollup, scan: ScanResult(records: [], sessions: [:]),
            pricing: Pricing(), config: Config())
        let grok = GrokBotUsageSnapshot(
            percentLeft: 61, percentUsed: 39,
            resetAt: Date(timeIntervalSince1970: 1_784_000_000),
            planLabel: "Grok Bot Plan", cursorPlanName: "Pro",
            fetchedAt: Date())
        let rows = tokenpulseMenuRows(
            rollup, efficiency, Config(), grokBot: grok,
            visibility: MenuSourceVisibility(
                chatGPT: false, cursor: false, openAI: false, claude: false,
                grokBot: true),
            presentation: .perSource)
        XCTAssertTrue(rows.contains { row in
            if case .submenu(let title, _, _) = row {
                return title == "Grok Bot · 61% left"
            }
            return false
        })
    }
}
