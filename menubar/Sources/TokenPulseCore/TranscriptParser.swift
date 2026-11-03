import Foundation

/// One assistant message's token usage, parsed from a transcript line.
struct UsageRecord {
    let date: Date
    let model: String
    let input: Int
    let cacheWrite: Int
    let cacheRead: Int
    let output: Int
    let sessionId: String
    /// Number of tool_use blocks in this assistant message — a complexity signal
    /// for the model-fit advisor.
    let toolUseCount: Int
    /// message.id + requestId — the dedupe key (same as ccusage). The same
    /// message reappears across resumed sessions; counting it twice inflates $.
    let dedupeKey: String
}

/// Per-session metadata (not token usage) used by the model-fit advisor to name
/// the actual task. Captured locally; never leaves the device.
struct SessionMeta {
    var cwd: String = ""
    var firstPrompt: String = ""
}

/// Everything one scan produces.
struct ScanResult {
    let records: [UsageRecord]
    let sessions: [String: SessionMeta]   // keyed by sessionId
}

/// Scans ~/.claude/projects/**/*.jsonl for assistant-message usage + per-session
/// task metadata. v1 rescans fully each poll (cheap at this scale).
struct TranscriptParser {
    let root: URL

    init() {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Returns deduped assistant usage records + per-session metadata.
    /// Walks the tree RECURSIVELY — transcripts nest several levels deep
    /// (project/<subdir>/<subdir>/*.jsonl); a one-level scan drops most files.
    func scan() -> ScanResult {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else {
            return ScanResult(records: [], sessions: [:])
        }
        var seen = Set<String>()
        var records: [UsageRecord] = []
        var sessions: [String: SessionMeta] = [:]

        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any] else { continue }

                let sessionId = obj["sessionId"] as? String ?? ""

                // Session metadata: cwd appears on every line; first user prompt
                // labels the task. Captured local-only.
                if !sessionId.isEmpty {
                    var meta = sessions[sessionId] ?? SessionMeta()
                    if meta.cwd.isEmpty, let cwd = obj["cwd"] as? String { meta.cwd = cwd }
                    if meta.firstPrompt.isEmpty, (obj["type"] as? String) == "user",
                       let p = Self.userText(obj), !p.isEmpty {
                        meta.firstPrompt = String(p.prefix(120))
                    }
                    sessions[sessionId] = meta
                }

                // Assistant usage record (deduped).
                guard let rec = Self.parseLine(obj) else { continue }
                guard !seen.contains(rec.dedupeKey) else { continue }
                seen.insert(rec.dedupeKey)
                records.append(rec)
            }
        }
        return ScanResult(records: records, sessions: sessions)
    }

    /// Extracts plain text from a user line's message.content (string or blocks).
    static func userText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let blocks = message["content"] as? [[String: Any]] {
            for b in blocks where (b["type"] as? String) == "text" {
                if let t = b["text"] as? String { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return nil
    }

    static func parseLine(_ obj: [String: Any]) -> UsageRecord? {
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = message["model"] as? String ?? "unknown"
        let input = usage["input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0

        if input == 0 && cacheWrite == 0 && cacheRead == 0 && output == 0 { return nil }

        // Count tool_use blocks in the assistant message content.
        var tools = 0
        if let blocks = message["content"] as? [[String: Any]] {
            tools = blocks.filter { ($0["type"] as? String) == "tool_use" }.count
        }

        let date = parseDate(obj["timestamp"] as? String ?? "") ?? Date()
        let sessionId = obj["sessionId"] as? String ?? ""
        let messageId = message["id"] as? String ?? UUID().uuidString
        let requestId = obj["requestId"] as? String ?? ""

        return UsageRecord(
            date: date, model: model,
            input: input, cacheWrite: cacheWrite, cacheRead: cacheRead, output: output,
            sessionId: sessionId, toolUseCount: tools,
            dedupeKey: messageId + ":" + requestId
        )
    }
}
