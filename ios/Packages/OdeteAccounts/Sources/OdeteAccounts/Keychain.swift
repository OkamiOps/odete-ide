import Foundation
import Security
import Synchronization

/// Onde os tokens moram. Em produção é o Keychain; nos testes, memória.
public protocol SecretStore: Sendable {
    func set(_ value: String, for key: String) throws
    func get(_ key: String) -> String?
    func delete(_ key: String)
}

/// Segredos em memória, só para testes e previews.
public final class MemorySecrets: SecretStore {
    private let store = Mutex<[String: String]>([:])
    public init() {}
    public func set(_ value: String, for key: String) throws {
        store.withLock { $0[key] = value }
    }

    public func get(_ key: String) -> String? {
        store.withLock { $0[key] }
    }

    public func delete(_ key: String) {
        store.withLock { _ = $0.removeValue(forKey: key) }
    }
}

/// Segredos no Keychain do app (kSecClassGenericPassword), acessíveis após o primeiro desbloqueio.
public struct Keychain: SecretStore {
    public let service: String
    public init(service: String = "com.okamiops.odete") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        var q = query(key)
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecSuccess {
            let st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard st == errSecSuccess else { throw KeychainError(status: st) }
        } else {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let st = SecItemAdd(q as CFDictionary, nil)
            guard st == errSecSuccess else { throw KeychainError(status: st) }
        }
    }

    public func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

public struct KeychainError: LocalizedError {
    public var status: OSStatus
    public var errorDescription: String? {
        "Keychain: \(SecCopyErrorMessageString(status, nil).map { String($0) } ?? "\(status)")"
    }
}
