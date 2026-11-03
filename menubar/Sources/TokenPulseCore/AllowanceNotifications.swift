import Foundation
import UserNotifications

struct AllowanceObservation {
    let providerID: String
    let provider: String
    let windowID: String
    let window: String
    let percent: Int
    let cycle: String
    let reset: String?
    var key: String { providerID + "/" + windowID }
}

/// Persisted per-provider AND per-window, so a restart/poll cannot repeat alerts.
/// A drop across several levels produces only the most urgent current alert.
struct AllowanceAlertLedger: Codable {
    struct Entry: Codable { var cycle: String; var percent: Int; var sent: Set<Int> }
    var entries: [String: Entry] = [:]
    mutating func observe(_ observation: AllowanceObservation, thresholds: [Int]) -> Int? {
        guard (0...100).contains(observation.percent), let top = thresholds.max() else { return nil }
        var entry = entries[observation.key] ?? Entry(cycle: observation.cycle, percent: 100, sent: [])
        if entry.cycle != observation.cycle || (entry.percent <= top && observation.percent > top) {
            entry = Entry(cycle: observation.cycle, percent: observation.percent, sent: [])
        }
        entry.percent = observation.percent
        let crossed = thresholds.filter { observation.percent <= $0 }
        let mostUrgentSent = entry.sent.min()
        let next = crossed.filter { !entry.sent.contains($0) && (mostUrgentSent == nil || $0 < mostUrgentSent!) }.min()
        if next != nil { entry.sent.formUnion(crossed) }
        entries[observation.key] = entry
        return next
    }
    static func parseThresholds(_ text: String) -> [Int]? {
        let parts = text.replacingOccurrences(of: "%", with: "").split { $0 == "," || $0 == ";" || $0.isWhitespace }
        guard !parts.isEmpty, parts.count <= 10 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, values.allSatisfy({ (1...99).contains($0) }) else { return nil }
        return Array(Set(values)).sorted(by: >)
    }
    static func load() -> Self {
        UserDefaults.standard.data(forKey: "allowanceAlertLedger").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "allowanceAlertLedger") } }
}

enum AllowanceNotification {
    static let category = "tokenpulse.allowance"
    static func content(_ observation: AllowanceObservation, threshold: Int, sound: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let headline = "\(observation.provider) · \(observation.percent)% left"
        let scope = observation.window + " allowance"
        content.title = "TokenPulse"
        content.subtitle = headline
        content.body = observation.reset.map { "\(scope). Resets \($0)." } ?? "Open TokenPulse to review your remaining allowance."
        content.threadIdentifier = "tokenpulse.allowance." + observation.key
        content.categoryIdentifier = category
        content.sound = sound ? .default : nil
        content.userInfo = ["provider": observation.provider, "providerID": observation.providerID,
                            "scope": scope, "advisoryTitle": headline, "threshold": threshold]
        return content
    }
}

/// Convert Claude's source time/zone into a stable reset instant. Preserve raw
/// source copy when no exact date is available rather than inventing a reset.
enum AllowanceReset {
    static func claudeDate(_ raw: String, fetchedAt now: Date) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if let start = text.lastIndex(of: "("), text.hasSuffix(")") {
            let zone = String(text[text.index(after: start)..<text.index(before: text.endIndex)])
            if let timeZone = TimeZone(identifier: zone) { calendar.timeZone = timeZone }
            text = String(text[..<start]).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: " at ", with: ", ", options: .caseInsensitive)
        let tomorrow = text.lowercased().hasPrefix("tomorrow")
        text = text.replacingOccurrences(of: #"(?i)^(today|tomorrow)\s*[·,]?\s*"#, with: "", options: .regularExpression)
        let hasMonth = text.range(of: #"^[A-Za-z]{3} \d"#, options: .regularExpression) != nil
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.defaultDate = now
        for format in hasMonth ? ["MMM d, h:mma", "MMM d, ha", "MMM d h:mma", "MMM d ha"] : ["h:mma", "ha", "h:mm a", "h a"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: text) else { continue }
            var parts = calendar.dateComponents([.year, .month, .day], from: now)
            let time = calendar.dateComponents([.hour, .minute], from: parsed)
            parts.hour = time.hour; parts.minute = time.minute; parts.second = 0
            if hasMonth { let date = calendar.dateComponents([.month, .day], from: parsed); parts.month = date.month; parts.day = date.day }
            guard var result = calendar.date(from: parts) else { continue }
            if tomorrow { result = calendar.date(byAdding: .day, value: 1, to: result) ?? result }
            else if result < now.addingTimeInterval(-60) { result = calendar.date(byAdding: hasMonth ? .year : .day, value: 1, to: result) ?? result }
            return result
        }
        return nil
    }
}
