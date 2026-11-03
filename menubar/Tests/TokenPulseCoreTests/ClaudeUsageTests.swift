import XCTest
@testable import TokenPulseCore

final class ClaudeUsageTests: XCTestCase {
    func testParsesSessionAndWeeklyUsage() throws {
        let raw = """
        \u{001B}[2mCurrent session\u{001B}[0m
        ████▌                                              9% used
        Resets 3:30pm (America/Los_Angeles)

        Current week (all models)
        ███████████████████▌                               39% used
        Resets May 17, 10am (America/Los_Angeles)
        """
        let snapshot = try XCTUnwrap(ClaudeUsageParse.snapshot(
            from: raw, claudePath: "/tmp/claude"))
        XCTAssertEqual(snapshot.session?.percentLeft, 91)
        XCTAssertEqual(snapshot.session?.resetDescription,
                       "3:30pm (America/Los_Angeles)")
        XCTAssertEqual(snapshot.weekly?.percentLeft, 61)
        XCTAssertEqual(snapshot.weekly?.resetDescription,
                       "May 17, 10am (America/Los_Angeles)")
        XCTAssertEqual(snapshot.menuPercentLeft, 61)
        XCTAssertEqual(snapshot.personalBarLabel, "5H 91% W 61%")
        XCTAssertEqual(snapshot.claudePath, "/tmp/claude")
    }

    func testFallsBackToSessionWhenWeeklyIsMissing() throws {
        let raw = "Current session\n25% used\nResets 8pm (America/Denver)"
        let snapshot = try XCTUnwrap(ClaudeUsageParse.snapshot(from: raw))
        XCTAssertEqual(snapshot.menuPercentLeft, 75)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.personalBarLabel, "5H 75%")
    }

    func testRejectsIncompleteUsage() {
        XCTAssertNil(ClaudeUsageParse.snapshot(from: "Usage is unavailable"))
        XCTAssertNil(ClaudeUsageParse.snapshot(
            from: "Current week (all models)\n101% used\nResets tomorrow"))
    }

    func testRejectsHalfPaintedMonthOnlyReset() {
        XCTAssertFalse(ClaudeUsageParse.isCompleteResetDescription("Sep"))
        XCTAssertTrue(ClaudeUsageParse.isCompleteResetDescription(
            "Sep 16 at 11am (America/Denver)"))
        let raw = """
        Current session
        9% used
        Resets 3:30pm (America/Denver)
        Current week (all models)
        59% used
        Resets Sep
        """
        let snapshot = ClaudeUsageParse.snapshot(from: raw)
        XCTAssertEqual(snapshot?.session?.percentLeft, 91)
        XCTAssertNil(snapshot?.weekly)
    }

    func testParsesCursorAddressedTUIFrames() throws {
        // Claude Code 2.1+ often inserts ESC[nG between words instead of spaces.
        let raw = "Current\u{001B}[12Gsession\r"
            + "█████████\u{001B}[55G18%\u{001B}[59Gused\r"
            + "Resets\u{001B}[11G3am\u{001B}[15G(America/Denver)\r"
            + "Current\u{001B}[12Gweek\u{001B}[17G(all\u{001B}[22Gmodels)\r"
            + "█▌\u{001B}[55G3%\u{001B}[58Gused\r"
            + "Resets\u{001B}[11GSep\u{001B}[15G5\u{001B}[17Gat\u{001B}[20G11am"
        let snapshot = try XCTUnwrap(ClaudeUsageParse.snapshot(from: raw))
        XCTAssertEqual(snapshot.session?.percentLeft, 82)
        XCTAssertEqual(snapshot.weekly?.percentLeft, 97)
        XCTAssertEqual(snapshot.menuPercentLeft, 97)
        XCTAssertEqual(snapshot.personalBarLabel, "5H 82% W 97%")
    }

    func testShortBarResetDateAndZeroPercent() {
        XCTAssertEqual(
            ClaudeUsageParse.shortBarResetDate(from: "Sep 20 at 10:59am (America/Denver)"),
            "Sep 20")
        XCTAssertEqual(
            ClaudeUsageParse.shortBarResetDate(from: "May 17, 10am (America/Los_Angeles)"),
            "May 17")
        XCTAssertNil(ClaudeUsageParse.shortBarResetDate(from: "3:30pm (America/Denver)"))
        let weekly = ClaudeUsageWindow(
            percentLeft: 0, resetDescription: "Sep 20 at 11am (America/Denver)")
        XCTAssertEqual(weekly.personalBarPercent, "0% Sep 20")
        let session = ClaudeUsageWindow(
            percentLeft: 0, resetDescription: "1:50pm (America/Denver)")
        XCTAssertEqual(session.personalBarPercent, "0%")
        let snap = ClaudeUsageSnapshot(
            session: ClaudeUsageWindow(percentLeft: 0,
                                       resetDescription: "3pm (America/Denver)"),
            weekly: weekly, fetchedAt: Date(), claudePath: "/tmp/claude")
        XCTAssertEqual(snap.personalBarLabel, "5H 0% W 0% Sep 20")
    }

    func testConfiguredClaudePathWins() {
        XCTAssertEqual(ClaudeUsageClient.claudeExecutable(
            environment: ["TOKENPULSE_CLAUDE_PATH": "/bin/sh"]), "/bin/sh")
    }
}
