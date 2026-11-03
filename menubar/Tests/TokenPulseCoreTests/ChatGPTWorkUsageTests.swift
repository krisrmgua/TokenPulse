import XCTest
@testable import TokenPulseCore

final class ChatGPTWorkUsageTests: XCTestCase {
    private var denverCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }

    func testParsesWorkspaceCreditsAndPublicEstimate() throws {
        let now = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 8, day: 31, hour: 10)))
        let json = """
        {
          "data": [
            {"date":"2026-08-30","values":{"codex":100.25,"chatgpt":10,"work":2.5}},
            {"date":"2026-08-31","values":{"codex":5,"chatgpt":1,"work":0.5}}
          ],
          "data_freshness_ts":"2026-08-31T14:00:00Z"
        }
        """
        let snapshot = try XCTUnwrap(ChatGPTWorkUsageParse.snapshot(
            from: Data(json.utf8), now: now, calendar: denverCalendar))

        XCTAssertEqual(snapshot.todayCredits, 6.5, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.monthCredits, 119.25, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.byProduct["codex"], 105.25, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.byProduct["chatgpt"], 11, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.byProduct["work"], 3, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.estimatedUSD, 4.77, accuracy: 0.000_001)
        XCTAssertTrue(snapshot.estimateUsesPublicRateCard)
    }

    func testServerEstimateWinsWhenWorkspaceProvidesOne() throws {
        let json = #"{"data":[{"date":"2026-08-31","values":{"codex":100}}]}"#
        let snapshot = try XCTUnwrap(ChatGPTWorkUsageParse.snapshot(
            from: Data(json.utf8), serverEstimatedUSD: 3.25))
        XCTAssertEqual(snapshot.estimatedUSD, 3.25)
        XCTAssertFalse(snapshot.estimateUsesPublicRateCard)
    }

    func testDecodesServerEstimateMicros() {
        XCTAssertEqual(ChatGPTWorkUsageParse.estimatedUSD(
            from: Data(#"{"estimated_usage_usd_micros":1505539800}"#.utf8)),
                       1505.5398, accuracy: 0.000_001)
        XCTAssertNil(ChatGPTWorkUsageParse.estimatedUSD(
            from: Data(#"{"estimated_usage_usd_micros":null}"#.utf8)))
    }

    func testBuildsCalendarMonthRequest() throws {
        let now = try XCTUnwrap(denverCalendar.date(
            from: DateComponents(year: 2026, month: 8, day: 31, hour: 10)))
        let url = try XCTUnwrap(ChatGPTWorkUsageClient.requestURL(
            now: now, calendar: denverCalendar))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["start_date"], "2026-08-01")
        XCTAssertEqual(query["end_date"], "2026-08-31")
        XCTAssertEqual(query["group_by"], "day")
    }
}
