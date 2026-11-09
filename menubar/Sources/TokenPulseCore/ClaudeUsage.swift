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
/// `/api/oauth/usage` endpoint. We open the pseudo-terminal ourselves because
/// Claude's interactive `/usage` command needs one, and it must be sized up
/// front or Claude clips the Resets and weekly rows.
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

        // A new pty has no size, so Claude lays /usage out for a tiny screen and
        // clips the Resets and weekly rows. Size it to a real terminal up front.
        var size = winsize(ws_row: 60, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            return .failure(.launchFailed)
        }
        let terminal = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.currentDirectoryURL = workDir
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["NO_COLOR"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do {
            try process.run()
        } catch {
            close(masterFD)
            close(slaveFD)
            return .failure(.launchFailed)
        }
        // The child owns the slave end now. Closing ours lets reads on the master
        // see EOF once Claude exits.
        close(slaveFD)

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffered = Data()
        var completed: ClaudeUsageSnapshot?
        var signalled = false
        var usageSent = false
        var trustAccepted = false
        master.readabilityHandler = { handle in
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
                try? master.write(contentsOf: Data("\u{001B}[B\r".utf8))
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
            try? master.write(contentsOf: Data("/usage\r".utf8))
        }
        let wait = semaphore.wait(timeout: .now() + 28)
        master.readabilityHandler = nil
        Self.stopProcess(process)
        // Non-blocking drain after exit. A blocking read on the pty master
        // hangs while anything still holds the slave open, which is why the
        // old readDataToEndOfFile-style drain left the menu stuck.
        let drained = Self.drainAvailable(masterFD)
        if !drained.isEmpty {
            lock.lock()
            buffered.append(drained)
            lock.unlock()
        }
        close(masterFD)

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

    /// Ends the Claude TUI: interrupt, then terminate, then kill if it still runs.
    /// Claude does not always exit on SIGINT, so an unbounded wait can hang.
    private static func stopProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        waitForExit(process, seconds: 2)
        if process.isRunning { process.terminate() }
        waitForExit(process, seconds: 1)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Reads whatever is buffered on the pty master without blocking.
    private static func drainAvailable(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            out.append(contentsOf: buffer[0..<count])
        }
        return out
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
