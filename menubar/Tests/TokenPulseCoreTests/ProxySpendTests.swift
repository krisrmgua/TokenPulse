import XCTest
@testable import TokenPulseCore

final class ProxySpendTests: XCTestCase {
    func testDecodeSpendEndUserResponse() throws {
        let json = """
        {
          "end_user_id": "user@example.com",
          "start_date": "2026-08-01",
          "end_date": "2026-08-17",
          "total_spend": 12.34,
          "daily_spend": 3.21,
          "total_requests": 9,
          "by_model": [
            {"model": "claude-opus-4-8", "spend": 10.0, "api_requests": 5},
            {"model": "claude-sonnet-5", "spend": 2.34, "api_requests": 4}
          ]
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ProxySpendResponse.self, from: json)
        XCTAssertEqual(resp.totalSpend, 12.34, accuracy: 0.001)
        XCTAssertEqual(resp.dailySpend ?? -1, 3.21, accuracy: 0.001)
        XCTAssertEqual(resp.byModel.count, 2)
        XCTAssertEqual(resp.byModel.first?.apiRequests, 5)
    }

    func testReconcileOverwritesMonthAndMarksProxy() {
        var local = Rollup()
        local.todayUSD = 1.5
        local.monthUSD = 99
        local.byModelUSD = ["local-only": 99]
        let proxy = ProxySpendResponse(
            endUserId: "u", startDate: "2026-08-01", endDate: "2026-08-17",
            totalSpend: 42, dailySpend: 7, totalRequests: 3,
            byModel: [
                ProxyByModel(model: "claude-opus-4-8", spend: 30, apiRequests: 2),
                ProxyByModel(model: "claude-sonnet-5", spend: 12, apiRequests: 1),
            ])
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 17))!
        let r = local.reconciled(with: proxy, now: now)
        XCTAssertTrue(r.proxyReconciled)
        XCTAssertEqual(r.monthUSD, 42, accuracy: 0.001)
        XCTAssertEqual(r.todayUSD, 7, accuracy: 0.001)
        XCTAssertEqual(r.opusUSD, 30, accuracy: 0.001)
        XCTAssertNil(r.byModelUSD["local-only"])
    }

    func testReconcileKeepsLocalTodayForOlderProxyResponse() {
        var local = Rollup()
        local.todayUSD = 1.5
        let proxy = ProxySpendResponse(
            endUserId: "u", startDate: "2026-08-01", endDate: "2026-08-17",
            totalSpend: 5, totalRequests: 1,
            byModel: [ProxyByModel(model: "claude-sonnet-5", spend: 5, apiRequests: 1)])
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 17))!
        XCTAssertEqual(local.reconciled(with: proxy, now: now).todayUSD,
                       1.5, accuracy: 0.001)
    }
}
