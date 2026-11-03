import Foundation

/// Legacy names live only here so a rename does not
/// strand saved preferences, local history, credentials, or environment overrides.
enum BrandMigration {
    static let legacyName = "Tokenomics"
    static let domain = "com.kris.tokenpulse"

    static func run() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "brandMigrationComplete")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent(legacyName), new = base.appendingPathComponent("TokenPulse")
        if FileManager.default.fileExists(atPath: old.path) {
            do {
                if !FileManager.default.fileExists(atPath: new.path) { try FileManager.default.moveItem(at: old, to: new) }
                else {
                    for child in try FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
                        let target = new.appendingPathComponent(child.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: child, to: target) }
                    }
                    if try FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty { try FileManager.default.removeItem(at: old) }
                }
            }
            catch { NSLog("TokenPulse data migration failed: %@", error.localizedDescription) }
        }
        // Preserve existing overrides while documenting the new environment names.
        for suffix in ["CODEX_PATH", "CLAUDE_PATH", "PRICING"] {
            let key = "TOKENPULSE_" + suffix
            if ProcessInfo.processInfo.environment[key] == nil,
               let value = ProcessInfo.processInfo.environment["TOKENOMICS_" + suffix] { setenv(key, value, 0) }
        }
    }
}
