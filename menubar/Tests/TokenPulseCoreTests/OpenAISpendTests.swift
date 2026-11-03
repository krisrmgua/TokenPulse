import XCTest
@testable import TokenPulseCore

final class OpenAISpendTests: XCTestCase {
    private let pageJSON = """
    {
      "object": "page",
      "data": [
        {
          "object": "bucket",
          "start_time": 1730419200,
          "end_time": 1730505600,
          "results": [
            {
              "object": "organization.costs.result",
              "amount": {"value": 1.25, "currency": "usd"},
              "line_item": "Responses API"
            },
            {
              "object": "organization.costs.result",
              "amount": {"value": 0.75, "currency": "usd"},
              "line_item": "Responses API"
            },
            {
              "object": "organization.costs.result",
              "amount": {"value": 3.50, "currency": "usd"},
              "line_item": "Images"
            },
            {
              "object": "organization.costs.result",
              "amount": {"value": 99, "currency": "eur"},
              "line_item": "Ignored"
            }
          ]
        }
      ],
      "has_more": true,
      "next_page": "next/cursor"
    }
    """

    func testDecodesCostsPageAndPaginationCursor() throws {
        let page = try XCTUnwrap(OpenAISpendParse.decode(Data(pageJSON.utf8)))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextPage, "next/cursor")
        XCTAssertEqual(page.data.count, 1)
        XCTAssertEqual(page.data[0].results.count, 4)
    }

    func testSumsUSDAndGroupsLineItems() throws {
        let page = try XCTUnwrap(OpenAISpendParse.decode(Data(pageJSON.utf8)))
        XCTAssertEqual(OpenAISpendParse.total(page.data), 5.50, accuracy: 0.001)
        XCTAssertEqual(OpenAISpendParse.lines(page.data), [
            OpenAICostLine(lineItem: "Images", spendUSD: 3.50),
            OpenAICostLine(lineItem: "Responses API", spendUSD: 2.00),
        ])
    }

    func testRequestURLContainsRangeLimitGroupingAndPage() throws {
        let url = try XCTUnwrap(OpenAISpendClient.requestURL(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200.2),
            limit: 32,
            page: "next/cursor"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["start_time"], "100")
        XCTAssertEqual(values["end_time"], "201")
        XCTAssertEqual(values["bucket_width"], "1d")
        XCTAssertEqual(values["limit"], "32")
        XCTAssertEqual(values["group_by"], "line_item")
        XCTAssertEqual(values["page"], "next/cursor")
    }

    func testAdminKeyValidationDoesNotTouchKeychain() {
        XCTAssertTrue(OpenAIKeychain.isValidAdminKeyFormat("sk-admin-example"))
        XCTAssertTrue(OpenAIKeychain.isValidAdminKeyFormat("  sk-admin-example\n"))
        XCTAssertFalse(OpenAIKeychain.isValidAdminKeyFormat("sk-project-example"))
        XCTAssertFalse(OpenAIKeychain.isValidAdminKeyFormat("sk-admin-"))
        if case .failure(.invalidKey) = OpenAIKeychain.save("not-an-admin-key") {
            // expected; invalid format returns before any Keychain call
        } else {
            XCTFail("A normal project key must be rejected")
        }
    }

    func testKeychainUsesDedicatedServiceAndAccount() {
        XCTAssertEqual(OpenAIKeychain.service, "com.kris.tokenpulse.openai")
        XCTAssertEqual(OpenAIKeychain.account, "admin-api-key")
    }

    func testEstimatedBalanceSubtractsOnlySpendAfterAnchor() {
        let baseline = OpenAIBalanceBaseline(
            enteredBalanceUSD: 20,
            baselineDayStart: Date(timeIntervalSince1970: 0),
            spendAlreadyReportedThatDayUSD: 3)
        XCTAssertEqual(baseline.estimate(reportedSpendSinceDayStart: 5), 18,
                       accuracy: 0.001)
        XCTAssertEqual(baseline.estimate(reportedSpendSinceDayStart: 2), 20,
                       accuracy: 0.001)
        XCTAssertEqual(baseline.estimate(reportedSpendSinceDayStart: 25), -2,
                       accuracy: 0.001)
    }

    func testEstimatedBalancePreferencesRoundTrip() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "OpenAIBalanceTests-\(UUID())"))
        defer { suite.removePersistentDomain(forName: suite.volatileDomainNames.first ?? "") }
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        OpenAIBalancePrefs.save(currentBalanceUSD: 17.50, todaySpendUSD: 2.25,
                                now: now, defaults: suite)
        let saved = try XCTUnwrap(OpenAIBalancePrefs.baseline(defaults: suite))
        XCTAssertEqual(saved.enteredBalanceUSD, 17.50, accuracy: 0.001)
        XCTAssertEqual(saved.spendAlreadyReportedThatDayUSD, 2.25, accuracy: 0.001)
        OpenAIBalancePrefs.clear(defaults: suite)
        XCTAssertNil(OpenAIBalancePrefs.baseline(defaults: suite))
    }
}
