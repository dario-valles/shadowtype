// APIKeyStore — Keychain wrapper for the two secrets the M1+M4 surfaces own:
//   - `apiKey` (Local API Bearer): 32 bytes of random data hex-encoded. Auto-generated on first
//     server enable. Used by `Authorization: Bearer <key>` on the TCP transport. UDS bypasses
//     auth (filesystem-perm gate), so even with the server on the key is only required for cross-
//     machine / browser clients. Regenerate-button rotates it (invalidates all existing clients).
//   - `huggingfaceToken` (M4 BYOM): optional HF Bearer token the user pastes once when importing a
//     gated/private GGUF repo. Stays in Keychain; never crosses the wire except as the
//     `Authorization` header on a download URLRequest; never logged (`Diag` redaction).
//
// Both items are stored as generic passwords in the user's default (login) keychain. We do NOT
// set `kSecAttrSynchronizable` — these secrets are machine-local by design (per-Mac API key, HF
// token tied to the machine that imported the model).
import Foundation
import Security

enum APIKeyStore {
    private static let service = "com.shadowtype.app"

    enum Item: String {
        case apiKey = "shadowtype.apiKey"
        case huggingfaceToken = "shadowtype.huggingfaceToken"
    }

    // Read the stored value, or nil when no item exists yet.
    static func read(_ item: Item) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    // Write a value; updates an existing item or inserts a new one. Returns true on success.
    @discardableResult
    static func write(_ item: Item, value: String) -> Bool {
        let data = Data(value.utf8)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
        ]
        let update: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(attrs as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var insert = attrs
            insert[kSecValueData] = data
            // Default accessibility matches the login keychain's default behaviour — unlocked
            // session only. Don't downgrade to AfterFirstUnlock; this isn't a daemon.
            insert[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(_ item: Item) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // Read the API key, auto-generating + persisting one on first use so the server never starts
    // without a key configured. The returned key is the hex of 32 random bytes (64 hex chars).
    static func ensureAPIKey() -> String {
        if let existing = read(.apiKey), !existing.isEmpty { return existing }
        let fresh = randomHex(byteCount: 32)
        write(.apiKey, value: fresh)
        return fresh
    }

    // Rotate the API key — used by the settings panel "Regenerate" button. Invalidates all
    // existing client configurations using the prior value.
    @discardableResult
    static func regenerateAPIKey() -> String {
        let fresh = randomHex(byteCount: 32)
        write(.apiKey, value: fresh)
        return fresh
    }

    // Cryptographically random hex string. SecRandomCopyBytes is the platform's CSPRNG; on macOS
    // it pulls from `/dev/urandom`. We never seed `arc4random_*` from this — predictable secrets
    // are worse than no secrets.
    static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // SecRandom should never fail on macOS. If it does, abort rather than fall back to a
            // weaker source — silent insecurity is worse than a crash the user can report.
            preconditionFailure("APIKeyStore: SecRandomCopyBytes failed with status \(status)")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
