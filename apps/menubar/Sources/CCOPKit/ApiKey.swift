import Foundation
import Security

/// What `ANTHROPIC_API_KEY` is when ccop runs `claude -p /usage`.
/// With an API key, Claude Code's `/usage` shows only the cost of the
/// session, not the plan limits; an empty key makes it use the login.
public enum ApiKeySetting: Equatable, Sendable {
    /// The shell's own value, if it has one. ccop changes nothing.
    case shell
    /// `ANTHROPIC_API_KEY=""`: Claude Code uses the subscription login.
    case empty
    /// A key the person typed. It is kept in the Keychain.
    case key(String)

    public enum Mode: String, CaseIterable, Sendable {
        case shell, empty, key
    }

    public var mode: Mode {
        switch self {
        case .shell: .shell
        case .empty: .empty
        case .key: .key
        }
    }

    /// The value to give `ANTHROPIC_API_KEY`; nil leaves the shell's value.
    public var value: String? {
        switch self {
        case .shell: nil
        case .empty: ""
        case let .key(k): k
        }
    }
}

public enum ApiKeyStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Could not use the Keychain: \(text)"
        }
    }
}

/// The mode is in the app's defaults; the key itself is only in the Keychain
/// (a generic password: `service`, account `ANTHROPIC_API_KEY`).
public struct ApiKeyStore: Sendable {
    public static let modeDefaultsKey = "anthropicApiKeyMode"
    static let account = "ANTHROPIC_API_KEY"

    public var service: String
    public var defaultsSuite: String?

    /// A dev build and a release have their own bundle id, so their own key.
    public init(service: String = (Bundle.main.bundleIdentifier ?? "dev.ccop.app") + ".anthropic-api-key", defaultsSuite: String? = nil) {
        self.service = service
        self.defaultsSuite = defaultsSuite
    }

    private var defaults: UserDefaults { defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// A saved key that the Keychain no longer has counts as no setting.
    public func load() -> ApiKeySetting {
        switch ApiKeySetting.Mode(rawValue: defaults.string(forKey: Self.modeDefaultsKey) ?? "") {
        case .empty: return .empty
        case .key: return (try? readKey()).flatMap { $0 }.map(ApiKeySetting.key) ?? .shell
        case .shell, nil: return .shell
        }
    }

    /// A key is written to the Keychain; any other setting removes it.
    public func save(_ setting: ApiKeySetting) throws {
        if case let .key(k) = setting {
            try writeKey(k)
        } else {
            try deleteKey()
        }
        defaults.set(setting.mode.rawValue, forKey: Self.modeDefaultsKey)
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    func readKey() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ApiKeyStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    private func writeKey(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ApiKeyStoreError.keychain(status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "CCOP: ANTHROPIC_API_KEY for claude -p /usage"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw ApiKeyStoreError.keychain(added) }
    }

    private func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ApiKeyStoreError.keychain(status) }
    }
}
