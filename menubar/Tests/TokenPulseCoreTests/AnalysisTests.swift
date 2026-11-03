import XCTest
@testable import TokenPulseCore

final class AnalysisTests: XCTestCase {
    func testModelFitContextAndHistory() {
        XCTAssertEqual(TokenPulseSelfChecks.runAll(printResults: false), 0)
    }
}
