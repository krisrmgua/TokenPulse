import Foundation

/// Remaining ChatGPT/Codex subscription allowance reported by the signed-in
/// Codex CLI's interactive `/status` command. This is intentionally separate
/// from OpenAI Platform API spend: the two products have different meters.
/// One Codex rate-limit window: how much is left and when it resets.
struct ChatGPTUsageWindow: Equatable {
    let percentLeft: Int
    let resetAt: Date
}

struct ChatGPTUsageSnapshot: Equatable {
    /// Weekly window.
    let percentLeft: Int
    let resetAt: Date
    let fetchedAt: Date
    let codexPath: String
    /// The 5-hour window, when Codex reports one.
    var session: ChatGPTUsageWindow? = nil

    var resetDescription: String {
        ChatGPTUsageParse.displayDate(resetAt)
    }

    /// What the menu bar shows: the 5-hour window when there is one, else the weekly one.
    var barPercentLeft: Int { session?.percentLeft ?? percentLeft }
    var barResetAt: Date { session?.resetAt ?? resetAt }

    /// Menu-bar fragment: `64%`, or `0% Sep 20` when exhausted.
    var personalBarPercent: String {
        if barPercentLeft == 0 {
            return "0% \(ChatGPTUsageParse.shortBarResetDate(from: barResetAt))"
        }
        return "\(barPercentLeft)%"
    }
}

enum ChatGPTUsageError: Error, Equatable {
    case codexNotFound
    case launchFailed
    case timedOut
    case notSignedIn
    case invalidResponse

    var userMessage: String {
        switch self {
        case .codexNotFound:
            return "Codex CLI was not found. Install it from chatgpt.com/codex or set TOKENPULSE_CODEX_PATH."
        case .launchFailed:
            return "The Codex app server could not be launched."
        case .timedOut:
            return "Timed out waiting for Codex account usage."
        case .notSignedIn:
            return "Codex CLI is not signed in with ChatGPT."
        case .invalidResponse:
            return "Codex /status did not include a readable weekly limit."
        }
    }
}

enum ChatGPTUsageParse {
    static func snapshot(fromAppServerData data: Data, now: Date = Date(),
                         codexPath: String = "codex") -> ChatGPTUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? NSNumber, id.intValue == 2,
              let result = object["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any],
              let weekly = weeklyWindow(in: limits),
              let used = weekly["usedPercent"] as? NSNumber,
              let reset = weekly["resetsAt"] as? NSNumber
        else { return nil }

        let percentLeft = max(0, min(100, 100 - Int(used.doubleValue.rounded())))
        return ChatGPTUsageSnapshot(
            percentLeft: percentLeft,
            resetAt: Date(timeIntervalSince1970: reset.doubleValue),
            fetchedAt: now,
            codexPath: codexPath,
            session: sessionWindow(in: limits)
        )
    }

    /// The 5-hour window (300 minutes), if Codex reports one.
    static func sessionWindow(in limits: [String: Any]) -> ChatGPTUsageWindow? {
        let windows = [limits["primary"], limits["secondary"]].compactMap { $0 as? [String: Any] }
        guard let w = windows.first(where: { ($0["windowDurationMins"] as? NSNumber)?.intValue == 300 }),
              let used = w["usedPercent"] as? NSNumber,
              let reset = w["resetsAt"] as? NSNumber else { return nil }
        return ChatGPTUsageWindow(
            percentLeft: max(0, min(100, 100 - Int(used.doubleValue.rounded()))),
            resetAt: Date(timeIntervalSince1970: reset.doubleValue))
    }

    /// The weekly limit is the window that lasts 10080 minutes. `primary` is not always it:
    /// on some plans `primary` is the 5-hour window and the weekly one is `secondary`.
    static func weeklyWindow(in limits: [String: Any]) -> [String: Any]? {
        let windows = [limits["primary"], limits["secondary"]].compactMap { $0 as? [String: Any] }
        if let weekly = windows.first(where: { ($0["windowDurationMins"] as? NSNumber)?.intValue == 10080 }) {
            return weekly
        }
        return limits["secondary"] as? [String: Any]
    }

    /// TUI output includes CSI cursor/style sequences and OSC hyperlinks.
    /// Remove both before looking for the human-readable `/status` lines.
    static func stripTerminalSequences(_ raw: String) -> String {
        var out = raw
        let patterns = [
            "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "",
                                           options: .regularExpression)
        }
        return out
    }

    static func snapshot(from raw: String, now: Date = Date(),
                         calendar inputCalendar: Calendar = .current,
                         codexPath: String = "codex") -> ChatGPTUsageSnapshot? {
        let clean = stripTerminalSequences(raw)
        guard let percentMatch = clean.firstMatch(#"([0-9]{1,3})%\s+left"#),
              let percent = Int(percentMatch[1]), (0...100).contains(percent),
              let resetMatch = clean.firstMatch(
                #"\(resets\s+([0-9]{1,2}):([0-9]{2})\s+on\s+([0-9]{1,2})\s+([A-Za-z]{3,9})(?:\s+([0-9]{4}))?\)"#),
              let hour = Int(resetMatch[1]), let minute = Int(resetMatch[2]),
              let day = Int(resetMatch[3]),
              let month = monthNumber(resetMatch[4]),
              (0...23).contains(hour), (0...59).contains(minute),
              (1...31).contains(day)
        else { return nil }

        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone
        var year = Int(resetMatch[5]) ?? calendar.component(.year, from: now)
        var components = DateComponents(timeZone: calendar.timeZone, year: year,
                                        month: month, day: day, hour: hour, minute: minute)
        guard var resetAt = calendar.date(from: components) else { return nil }

        // `/status` normally omits the year. Around New Year's, interpret a
        // January reset shown in December as the next calendar year.
        if resetMatch[5].isEmpty && resetAt < now {
            year += 1
            components.year = year
            guard let nextYear = calendar.date(from: components) else { return nil }
            resetAt = nextYear
        }

        return ChatGPTUsageSnapshot(percentLeft: percent, resetAt: resetAt,
                                    fetchedAt: now, codexPath: codexPath)
    }

    /// Today and tomorrow lead with the day: `Today at 4:15 PM MST`,
    /// `Tomorrow at 4:15 PM MST`. Every other reset keeps the previous
    /// calendar form, `Nov 7, 2026 at 2:58 PM MST`.
    static func displayDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayDelta = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day
        if dayDelta == 0 || dayDelta == 1 {
            formatter.dateFormat = "h:mm a z"
            let time = formatter.string(from: date)
            return dayDelta == 0 ? "Today at \(time)" : "Tomorrow at \(time)"
        }

        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a z"
        return formatter.string(from: date)
    }

    /// Compact calendar date for exhausted meters in the menu bar (`Sep 20`).
    static func shortBarResetDate(from date: Date,
                                  calendar: Calendar = .current,
                                  locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func monthNumber(_ raw: String) -> Int? {
        let key = String(raw.prefix(3)).lowercased()
        return ["jan": 1, "feb": 2, "mar": 3, "apr": 4,
                "may": 5, "jun": 6, "jul": 7, "aug": 8,
                "sep": 9, "oct": 10, "nov": 11, "dec": 12][key]
    }
}

final class ChatGPTUsageClient {
    private static let staleAfter: TimeInterval = 30 * 60
    private var minRefreshInterval: TimeInterval
    private let stateQueue = DispatchQueue(label: "com.kris.tokenpulse.chatgpt-usage")
    private var lastAttempt: Date?
    private var lastSuccess: ChatGPTUsageSnapshot?

    init(minRefreshInterval: TimeInterval = 5 * 60) {
        self.minRefreshInterval = minRefreshInterval
    }

    func setMinRefreshInterval(_ interval: TimeInterval) {
        stateQueue.async { self.minRefreshInterval = interval }
    }

    func currentUsage(now: Date = Date(), force: Bool = false,
                      completion: @escaping (ChatGPTUsageSnapshot?) -> Void) {
        stateQueue.async {
            // A limit whose reset time has passed is stale: fetch now rather than waiting for the interval.
            let due = force
                || self.resetPassed(now: now)
                || (self.lastAttempt.map { now.timeIntervalSince($0) >= self.minRefreshInterval } ?? true)
            guard due else {
                completion(self.freshEnough(now: now))
                return
            }
            self.lastAttempt = now
            let result = self.fetch(now: now)
            if case .success(let snapshot) = result { self.lastSuccess = snapshot }
            completion((try? result.get()) ?? self.freshEnough(now: now))
        }
    }

    func testConnection(now: Date = Date(),
                        completion: @escaping (Result<ChatGPTUsageSnapshot, ChatGPTUsageError>) -> Void) {
        stateQueue.async { completion(self.fetch(now: now)) }
    }

    static func codexExecutable(fileManager: FileManager = .default,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configured = environment["TOKENPULSE_CODEX_PATH"]
        let candidates = [
            configured,
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/AI:Coding/ChatGPT.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func resetPassed(now: Date) -> Bool {
        guard let s = lastSuccess else { return false }
        return ([s.session?.resetAt, s.resetAt].compactMap { $0 }).contains { $0 <= now }
    }

    private func freshEnough(now: Date) -> ChatGPTUsageSnapshot? {
        guard let snapshot = lastSuccess,
              now.timeIntervalSince(snapshot.fetchedAt) < Self.staleAfter
        else { return nil }
        return snapshot
    }

    private func fetch(now: Date) -> Result<ChatGPTUsageSnapshot, ChatGPTUsageError> {
        guard let codex = Self.codexExecutable() else { return .failure(.codexNotFound) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return .failure(.launchFailed) }

        let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tokenpulse","title":"TokenPulse","version":"1.0.0"}}}"#
        let initialized = #"{"method":"initialized","params":{}}"#
        let request = #"{"id":2,"method":"account/rateLimits/read","params":{}}"#
        guard let requestData = ([initialize, initialized, request].joined(separator: "\n") + "\n")
            .data(using: .utf8)
        else {
            process.terminate()
            return .failure(.launchFailed)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffered = Data()
        var result: Result<ChatGPTUsageSnapshot, ChatGPTUsageError>?
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            buffered.append(chunk)
            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered.prefix(upTo: newline)
                buffered.removeSubrange(...newline)
                if let snapshot = ChatGPTUsageParse.snapshot(
                    fromAppServerData: Data(line), now: now, codexPath: codex
                ) {
                    result = .success(snapshot)
                    lock.unlock()
                    semaphore.signal()
                    return
                }
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = object["id"] as? NSNumber, id.intValue == 2,
                   object["error"] != nil {
                    let serialized = String(data: Data(line), encoding: .utf8) ?? ""
                    result = serialized.localizedCaseInsensitiveContains("auth")
                        ? .failure(.notSignedIn) : .failure(.invalidResponse)
                    lock.unlock()
                    semaphore.signal()
                    return
                }
            }
            lock.unlock()
        }

        input.fileHandleForWriting.write(requestData)
        let wait = semaphore.wait(timeout: .now() + 30)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        guard wait == .success else { return .failure(.timedOut) }
        lock.lock()
        let completed = result
        lock.unlock()
        return completed ?? .failure(.invalidResponse)
    }
}

private extension String {
    func firstMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: self) else {
                return ""
            }
            return String(self[swiftRange])
        }
    }
}
