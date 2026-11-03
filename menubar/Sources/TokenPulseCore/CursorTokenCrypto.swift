import Foundation
import Security
import CommonCrypto

/// Cursor encrypts its auth tokens in state.vscdb (`cursor-safe-storage:v1:` + base64).
/// The payload is Electron safeStorage output: optional "v10" prefix, then AES-128-CBC
/// ciphertext. The key is PBKDF2-SHA1(password, "saltysalt", 1003 iterations, 16 bytes),
/// where password is the "Cursor Safe Storage" item in the login Keychain.
/// Older Cursor builds stored plaintext, so unprefixed values pass through unchanged.
enum CursorTokenCrypto {
    static let prefix = "cursor-safe-storage:v1:"
    static let keychainService = "Cursor Safe Storage"

    /// Plaintext token, the input unchanged when it isn't encrypted, or nil if decryption fails.
    static func decode(_ stored: String) -> String? {
        guard stored.hasPrefix(prefix) else { return stored }
        guard let blob = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
              let password = keychainPassword(),
              let key = derivedKey(password: password) else { return nil }
        var cipher = [UInt8](blob)
        if cipher.count > 3, cipher[0] == 0x76, cipher[1] == 0x31, cipher[2] == 0x30 {  // "v10"
            cipher.removeFirst(3)
        }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)  // Electron uses 16 spaces
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                             CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv,
                             cipher, cipher.count,
                             &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return String(bytes: out[0..<moved], encoding: .utf8)
    }

    /// The Cursor Safe Storage password from the login Keychain (may prompt once for access).
    static func keychainPassword() -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return [UInt8](data)
    }

    static func derivedKey(password: [UInt8]) -> [UInt8]? {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &key, key.count)
        return status == kCCSuccess ? key : nil
    }
}
