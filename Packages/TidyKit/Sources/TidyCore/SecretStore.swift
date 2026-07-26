import Foundation
import Security

/// The ONLY accessor for secrets (API tokens/keys, OAuth refresh tokens). Guardrail G6: secrets
/// live here (Keychain) and never in config, the DB, logs, or fixtures. `allKeys()` returns names
/// only — never values — so diagnostics can report "which credentials are present" safely.
public protocol SecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ key: String, _ value: String) throws
    func delete(_ key: String) throws
    func allKeys() throws -> [String]
}

/// Well-known secret keys. Centralized so ingest clients and setup agree on names.
public enum SecretKey {
    public static let productiveToken = "productive.token"
    public static let fathomKey = "fathom.api_key"
    /// Desktop-type OAuth clients still send a client secret in the token exchange, even though
    /// Google documents it as "not treated as a secret" for installed apps. Kept in the Keychain
    /// anyway — it costs nothing and keeps credential-shaped things out of a plaintext file (G6).
    public static let googleClientSecret = "google.client_secret"
    /// OUTPUT of the OAuth flow, not something you paste by hand.
    public static let googleRefreshToken = "google.refresh_token"
    public static let slackUserToken = "slack.user_token"
    public static let fireworksKey = "fireworks.api_key"
    public static let anthropicKey = "anthropic.api_key"

    public static let all = [
        productiveToken, fathomKey, googleClientSecret, googleRefreshToken, slackUserToken,
        fireworksKey, anthropicKey,
    ]
}

/// macOS Keychain-backed store (generic password items, keyed by `service` + account).
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = TidyTime.bundleIdentifier) { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func get(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw TidyError.secretStore("read failed for \(key): OSStatus \(status)")
        }
        return string
    }

    public func set(_ key: String, _ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw TidyError.secretStore("encode failed for \(key)")
        }
        let query = baseQuery(key)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }

        // Not present yet → plain add.
        if updateStatus == errSecItemNotFound {
            try add(query, data, key)
            return
        }

        // The item exists but we couldn't update it. The common cause is an **ACL mismatch**: the
        // item was created by a differently-signed build of this app (e.g. an unsigned preview, or
        // before DEVELOPMENT_TEAM was set), so this binary isn't on its trusted-application list.
        // Without this branch the user would be stuck — unable to read the token AND unable to
        // overwrite it from Settings. Replace the item outright instead.
        if updateStatus == errSecAuthFailed || updateStatus == errSecInteractionNotAllowed
            || updateStatus == errSecDuplicateItem {
            _ = SecItemDelete(query as CFDictionary)
            do {
                try add(query, data, key)
                return
            } catch {
                throw TidyError.secretStore("""
                    could not replace \(key) (OSStatus \(updateStatus)). This usually means the \
                    Keychain item belongs to a differently-signed build. Delete the "\(service)" \
                    entry for "\(key)" in Keychain Access.app and try again.
                    """)
            }
        }
        throw TidyError.secretStore("update failed for \(key): OSStatus \(updateStatus)")
    }

    private func add(_ query: [String: Any], _ data: Data, _ key: String) throws {
        var add = query
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TidyError.secretStore("add failed for \(key): OSStatus \(addStatus)")
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TidyError.secretStore("delete failed for \(key): OSStatus \(status)")
        }
    }

    public func allKeys() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        query[kSecReturnData as String] = false
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw TidyError.secretStore("list failed: OSStatus \(status)")
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

/// In-memory store for tests (the real Keychain is not exercised in unit tests — it would prompt
/// and is environment-dependent; see docs/build/testing-strategy.md).
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    public init(_ initial: [String: String] = [:]) { self.storage = initial }

    public func get(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }; return storage[key]
    }
    public func set(_ key: String, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }; storage[key] = value
    }
    public func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }; storage[key] = nil
    }
    public func allKeys() throws -> [String] {
        lock.lock(); defer { lock.unlock() }; return storage.keys.sorted()
    }
}
