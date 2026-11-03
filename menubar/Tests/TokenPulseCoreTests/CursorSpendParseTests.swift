import XCTest
@testable import TokenPulseCore

final class CursorSpendParseTests: XCTestCase {
    func testFieldCoercion() {
        XCTAssertEqual(CursorSpendParse.doubleField(["totalCents": 250], "totalCents"), 250, accuracy: 0.001)
        XCTAssertEqual(CursorSpendParse.doubleField(["totalCents": "99.5"], "totalCents"), 99.5, accuracy: 0.001)
        XCTAssertEqual(CursorSpendParse.intField(["inputTokens": "42"], "inputTokens"), 42)
    }

    func testAggregationsParseSortAndSum() {
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
        XCTAssertEqual(aggs.count, 2)
        XCTAssertEqual(aggs.first?.model, "claude-4-opus")
        XCTAssertEqual(aggs.reduce(0.0) { $0 + $1.spendUSD }, 18.0, accuracy: 0.001)
        XCTAssertNil(CursorSpendParse.aggregations(from: [:]))
    }

    func testWindowTotalUsesChargedCents() {
        XCTAssertEqual(CursorSpendParse.totalSpendUSD(from: ["totalCostCents": 7338.0]),
                       73.38, accuracy: 0.001)
        XCTAssertEqual(CursorSpendParse.totalSpendUSD(from: ["totalCostCents": "10071.426999"]),
                       100.714, accuracy: 0.001)
        XCTAssertEqual(CursorSpendParse.totalSpendUSD(from: [:]), 0, accuracy: 0.001)
    }

    func testPlanUsageParse() {
        let obj: [String: Any] = [
            "billingCycleStart": "1789535837000",
            "billingCycleEnd": "1792127837000",
            "planUsage": [
                "limit": 2000,
                "includedSpend": 1234,
                "totalPercentUsed": 42.5,
            ] as [String: Any],
        ]
        let plan = CursorSpendParse.planUsage(from: obj)
        XCTAssertEqual(plan?.limitUSD, 20, accuracy: 0.001)
        XCTAssertEqual(plan?.includedSpendUSD, 12.34, accuracy: 0.001)
        XCTAssertEqual(plan?.percentLeft, 58)
        XCTAssertEqual(plan?.billingCycleStart?.timeIntervalSince1970, 1_789_535_837.0, accuracy: 0.001)
        XCTAssertEqual(plan?.billingCycleEnd?.timeIntervalSince1970, 1_792_127_837.0, accuracy: 0.001)
        XCTAssertNotNil(plan?.resetDescription)
        XCTAssertNil(CursorSpendParse.planUsage(from: [:]))
        XCTAssertNil(CursorSpendParse.planUsage(from: ["planUsage": ["limit": 0]]))
    }

    func testPersonalBarPercentIncludesBillingCycleEndAtZero() {
        let end = Date(timeIntervalSince1970: 1_792_127_837)
        let snap = CursorSpendSnapshot(
            totalSpendUSD: 0, todaySpendUSD: 0, byModel: [],
            fetchedAt: Date(), userId: 1,
            planUsage: CursorPlanUsage(
                limitUSD: 20, includedSpendUSD: 20,
                totalPercentUsed: 100, percentLeft: 0,
                billingCycleEnd: end))
        XCTAssertEqual(
            snap.personalBarPercent(allowanceUSD: 20),
            "0% \(ChatGPTUsageParse.shortBarResetDate(from: end))")
        let healthy = CursorSpendSnapshot(
            totalSpendUSD: 0, todaySpendUSD: 0, byModel: [],
            fetchedAt: Date(), userId: 1,
            planUsage: CursorPlanUsage(
                limitUSD: 20, includedSpendUSD: 5,
                totalPercentUsed: 25, percentLeft: 75,
                billingCycleEnd: end))
        XCTAssertEqual(healthy.personalBarPercent(allowanceUSD: 20), "75%")
    }

    func testRemainingOrangeCanDropBelowPriorCustom() {
        let updated = RemainingColorConfig.applyingOrange(33, to: (10, 51, 50))
        XCTAssertEqual(updated.orange, 33)
        XCTAssertLessThan(updated.red, updated.orange)
        XCTAssertLessThan(updated.orange, updated.yellow)
    }

    func testSpendUpYellowCanExceedPriorOrange() {
        let updated = SpendUpColorConfig.applyingYellow(60, to: (51, 50))
        XCTAssertEqual(updated.yellow, 60)
        XCTAssertLessThan(updated.yellow, updated.orange)
    }
}
