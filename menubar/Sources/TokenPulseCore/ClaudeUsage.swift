import Foundation

/// One server-reported Claude subscription window from the official Claude
/// CLI's `/usage` view. Percentages are quota remaining, not API-dollar spend.
struct ClaudeUsageWindow: Equatable {
    let percentLeft: Int
    let resetDescription: String

    /// Bar fragment for this window: `98%`, or `0% Sep 20` when exhausted and a
    /// calendar reset date is present (time-only session resets stay `0%`).
    var personalBarPercent: String {
        if percentLeft == 0,
           let date = ClaudeUsageParse.shortBarResetDate(from: resetDescription) {
            return "0% \(date)"
        }
        return "\(percentLeft)%"
    }
}

struct ClaudeUsageSnapshot: Equatable {
    let session: ClaudeUsageWindow?
    let weekly: ClaudeUsageWindow?
    let fetchedAt: Date
    let claudePath: String

    /// Single fallback meter when a caller only wants one number (weekly first).
    var menuPercentLeft: Int? { weekly?.percentLeft ?? session?.percentLeft }

    /// Personal menu-bar copy: five-hour then weekly remaining, e.g. `5H 98% W 38%`
    /// or `5H 0% W 0% Sep 20` when a window is exhausted.
    var personalBarLabel: String? {
        switch (session, weekly) {
        case let (session?, weekly?):
            return "5H \(session.personalBarPercent) W \(weekly.personalBarPercent)"
        case let (session?, nil):
            return "5H \(session.personalBarPercent)"
        case let (nil, weekly?):
            return "W \(weekly.personalBarPercent)"
        case (nil, nil):
            return nil
        }
    }
}

enum ClaudeUsageError: Error, Equatable {
    case claudeNotFound
    case launchFailed
    case timedOut
    case notSignedIn
    case invalidResponse

    var userMessage: String {
        switch self {
        case .claudeNotFound:
            return "Claude CLI was not found. Claude Desktop alone is not enough — "
                + "install Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`), "
                + "run `claude` once to finish setup + /login, then Options → Refresh now."
        case .launchFailed:
            return "The Claude CLI could not be launched."
        case .timedOut:
            return "Timed out waiting for Claude /usage. Open a terminal, run `claude`, "
                + "finish first-run setup and /login with your Pro/Max account, then try again."
        case .notSignedIn:
            return "Claude CLI is not signed in. Claude Desktop Pro does not share login "
                + "with Claude Code — run `claude` and complete /login once."
        case .invalidResponse:
            return "Claude /usage did not include a readable session or weekly limit."
        }
    }
}

enum ClaudeUsageParse {
    static func stripTerminalSequences(_ raw: String) -> String {
        var out = raw
        // Claude Code's TUI often spaces words with cursor-to-column moves
        // (`ESC[nG`) instead of literal spaces: "Current\u{001B}[12Gsession".
        // Turn those into spaces before stripping the rest of the CSI stream.
        out = out.replacingOccurrences(of: "\u{001B}\\[[0-9]*G", with: " ",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{001B}\\[[0-9]+C", with: " ",
                                       options: .regularExpression)
        for pattern in [
            "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
        ] {
            out = out.replacingOccurrences(of: pattern, with: "",
                                           options: .regularExpression)
        }
        // TUI redraws use carriage returns and occasionally backspace over a
        // previous cell. Keeping them as line boundaries makes section regexes
        // robust without interpreting the entire terminal screen protocol.
        out = out.replacingOccurrences(of: "\r", with: "\n")
        while out.contains("\u{0008}") {
            out = out.replacingOccurrences(of: #"[^\n]\u{0008}"#, with: "",
                                           options: .regularExpression)
        }
        // Collapse runs of spaces introduced by cursor addressing, but keep
        // newlines so "Current session" / "Resets …" stay on readable lines.
        out = out.replacingOccurrences(of: #"[^\S\n]+"#, with: " ",
                                       options: .regularExpression)
        return out
    }

    static func snapshot(from raw: String, now: Date = Date(),
                         claudePath: String = "claude") -> ClaudeUsageSnapshot? {
        let clean = stripTerminalSequences(raw)
        let session = window(named: #"Current\s+session"#, in: clean, literal: false)
        let weekly = window(named: #"Current\s+week\s*\(\s*all\s+models\s*\)"#,
                            in: clean, literal: false)
            ?? window(named: #"Weekly\s+limits\s*[—\-]\s*All\s+models"#,
                      in: clean, literal: false)
        guard session != nil || weekly != nil else { return nil }
        return ClaudeUsageSnapshot(session: session, weekly: weekly,
                                   fetchedAt: now, claudePath: claudePath)
    }

    private static func window(named name: String, in text: String,
                               literal: Bool = true) -> ClaudeUsageWindow? {
        let label = literal ? NSRegularExpression.escapedPattern(for: name) : name
        let pattern = "(?is)\(label).*?([0-9]{1,3})%\\s*used.*?Resets\\s+([^\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
              let usedRange = Range(match.range(at: 1), in: text),
              let used = Int(text[usedRange]), (0...100).contains(used),
              let resetRange = Range(match.range(at: 2), in: text)
        else { return nil }

        let reset = text[resetRange]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "│┆┊")))
        // Claude paints reset labels word-by-word ("Sep" then "16" then "at…").
        // Reject half-drawn frames so we do not freeze "Resets: Sep" in the menu.
        guard isCompleteResetDescription(reset) else { return nil }
        return ClaudeUsageWindow(percentLeft: 100 - used,
                                 resetDescription: reset)
    }

    /// A finished reset label ends in a clock time or Claude's `(Zone/Name)`
    /// suffix. Mid-paint frames stop anywhere ("Sep", "Oct 3 a").
    static func isCompleteResetDescription(_ raw: String) -> Bool {
        let reset = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reset.count >= 4 else { return false }
        if reset.hasSuffix(")") { return reset.contains("(") }
        return reset.range(of: #"\d(?::\d{2})?\s*(am|pm)$"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Compact calendar date for the menu bar (`Sep 20`). Returns nil for
    /// time-only labels like `3:30pm (America/Denver)`.
    static func shortBarResetDate(from raw: String) -> String? {
        let reset = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: reset, range: NSRange(reset.startIndex..., in: reset)),
              let monthRange = Range(match.range(at: 1), in: reset),
              let dayRange = Range(match.range(at: 2), in: reset)
        else { return nil }
        let month = reset[monthRange]
        // Preserve Claude's casing (usually Title case) but normalize day width.
        let day = Int(reset[dayRange]).map(String.init) ?? String(reset[dayRange])
        return "\(month) \(day)"
    }
}

/// Reads subscription quota through the official Claude CLI itself. TokenPulse
/// intentionally does not extract Claude OAuth credentials or call the private
/// `/api/oauth/usage` endpoint. `/usr/bin/script` supplies the pseudo-terminal
/// required by Claude's interactive `/usage` command.
final class ClaudeUsageClient {
    private static let staleAfter: TimeInterval = 30 * 60
    private var minRefreshInterval: TimeInterval
    private let stateQueue = DispatchQueue(label: "com.kris.tokenpulse.claude-usage")
    private var lastAttempt: Date?
    private var lastSuccess: ClaudeUsageSnapshot?

    init(minRefreshInterval: TimeInterval = 5 * 60) {
        self.minRefreshInterval = minRefreshInterval
    }

    func setMinRefreshInterval(_ interval: TimeInterval) {
        stateQueue.async { self.minRefreshInterval = interval }
    }

    func currentUsage(now: Date = Date(), force: Bool = false,
                      completion: @escaping (ClaudeUsageSnapshot?) -> Void) {
        stateQueue.async {
            let due = force
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
                        completion: @escaping (Result<ClaudeUsageSnapshot, ClaudeUsageError>) -> Void) {
        stateQueue.async { completion(self.fetch(now: now)) }
    }

    static func claudeExecutable(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            environment["TOKENPULSE_CLAUDE_PATH"],
            "\(home)/.local/bin/claude",
            "\(home)/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].compactMap { $0 }
        // Claude Desktop ships Claude Code under Application Support with a
        // versioned path (…/claude-code/<ver>/claude.app/Contents/MacOS/claude).
        // Prefer the newest install so Desktop-only users still work after a
        // one-time `claude` /login — Desktop Pro auth is not reused automatically.
        candidates.append(contentsOf: desktopBundledClaudeCodePaths(fileManager: fileManager))
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Newest → oldest Claude Code binaries bundled inside Claude Desktop.
    static func desktopBundledClaudeCodePaths(
        fileManager: FileManager = .default
    ) -> [String] {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claude/claude-code",
                isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let sorted = versions
            .filter { ($0.lastPathComponent as NSString).pathExtension.isEmpty }
            .sorted { $0.lastPathComponent.compare(
                $1.lastPathComponent, options: .numeric) == .orderedDescending }

        return sorted.map {
            $0.appendingPathComponent("claude.app/Contents/MacOS/claude").path
        }
    }

    private func freshEnough(now: Date) -> ClaudeUsageSnapshot? {
        guard let snapshot = lastSuccess,
              now.timeIntervalSince(snapshot.fetchedAt) < Self.staleAfter
        else { return nil }
        return snapshot
    }

    private func fetch(now: Date) -> Result<ClaudeUsageSnapshot, ClaudeUsageError> {
        guard let claude = Self.claudeExecutable() else { return .failure(.claudeNotFound) }
        let workDir = Self.prepareUsageWorkingDirectory()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", claude]
        process.currentDirectoryURL = workDir
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["NO_COLOR"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return .failure(.launchFailed) }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffered = Data()
        var completed: ClaudeUsageSnapshot?
        var signalled = false
        var usageSent = false
        var trustAccepted = false
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            buffered.append(chunk)
            let raw = Self.lossyUTF8(buffered)
            let lower = raw.lowercased()
            // Claude may still show the workspace trust sheet for a brand-new
            // cwd; answer Yes (second option) once so /usage can proceed.
            if !trustAccepted,
               lower.contains("trust this folder") || lower.contains("quick safety check") {
                trustAccepted = true
                // Default selection is "No, exit"; move down to Yes and confirm.
                try? input.fileHandleForWriting.write(contentsOf: Data("\u{001B}[B\r".utf8))
            }
            if let snapshot = ClaudeUsageParse.snapshot(
                from: raw, now: now, claudePath: claude),
               Self.isCompleteUsageFrame(snapshot, raw: raw) {
                completed = snapshot
                if !signalled {
                    signalled = true
                    semaphore.signal()
                }
            }
            lock.unlock()
        }

        // Give the TUI a beat to paint (and optionally clear trust) before
        // typing /usage — sending immediately can be eaten by the trust sheet.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            lock.lock()
            let already = usageSent
            usageSent = true
            lock.unlock()
            guard !already, process.isRunning else { return }
            try? input.fileHandleForWriting.write(contentsOf: Data("/usage\r".utf8))
        }
        let wait = semaphore.wait(timeout: .now() + 28)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        // Non-blocking drain after exit — never readDataToEndOfFile while the
        // Claude TUI is still alive (that hung the whole fetch and left the
        // menu stuck on session-only after a partial parse).
        let drained = output.fileHandleForReading.availableData
        if !drained.isEmpty {
            lock.lock()
            buffered.append(drained)
            lock.unlock()
        }

        lock.lock()
        let raw = Self.lossyUTF8(buffered)
        let snapshot = completed ?? ClaudeUsageParse.snapshot(
            from: raw, now: now, claudePath: claude)
        lock.unlock()
        // Do not publish session-only when the TUI painted a weekly section —
        // that is what made the menu drop to "hourly" after a mid-paint timeout.
        if let snapshot, Self.isCompleteUsageFrame(snapshot, raw: raw) {
            return .success(snapshot)
        }
        if raw.localizedCaseInsensitiveContains("login")
            || raw.localizedCaseInsensitiveContains("sign in") {
            return .failure(.notSignedIn)
        }
        return wait == .timedOut ? .failure(.timedOut) : .failure(.invalidResponse)
    }

    private static func lossyUTF8(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Prefer a finished weekly row. Session-only is ready only when the TUI
    /// never paints a weekly section (some accounts omit it).
    private static func isCompleteUsageFrame(_ snapshot: ClaudeUsageSnapshot,
                                             raw: String) -> Bool {
        if snapshot.weekly != nil { return true }
        guard snapshot.session != nil else { return false }
        // Match against stripped text — raw TUI frames are `Current\u{001B}[12Gweek`
        // and would miss a literal "Current week" substring, causing a premature
        // session-only exit before the weekly row paints.
        let clean = ClaudeUsageParse.stripTerminalSequences(raw)
        let mentionsWeek = clean.localizedCaseInsensitiveContains("Current week")
            || clean.localizedCaseInsensitiveContains("Weekly limits")
        return !mentionsWeek
    }

    /// Empty cwd used only for `/usage` probes. Pre-marked trusted in
    /// `~/.claude.json` so Claude Code does not block on the safety sheet when
    /// TokenPulse launches from LaunchAgent/`~/Applications`.
    static func prepareUsageWorkingDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let dir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/TokenPulse/claude-usage-cwd",
                isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        acceptTrust(for: dir.path, fileManager: fileManager)
        return dir
    }

    private static func acceptTrust(for path: String, fileManager: FileManager) {
        let configURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[path] as? [String: Any] ?? [:]
        if entry["hasTrustDialogAccepted"] as? Bool == true { return }
        entry["hasTrustDialogAccepted"] = true
        if entry["allowedTools"] == nil { entry["allowedTools"] = [String]() }
        projects[path] = entry
        root["projects"] = projects
        guard let updated = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? updated.write(to: configURL, options: .atomic)
    }
}
