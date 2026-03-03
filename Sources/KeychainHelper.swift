import Foundation
import Security

protocol KeychainBackend {
    func add(_ query: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct LiveKeychainBackend: KeychainBackend {
    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Thin wrapper around the macOS Keychain for storing sensitive strings.
enum KeychainHelper {
    enum KeychainError: Error, Equatable {
        case osStatus(OSStatus)
        case invalidData(status: OSStatus)

        var status: OSStatus {
            switch self {
            case .osStatus(let status):
                status
            case .invalidData(let status):
                status
            }
        }
    }

    private static let service = "com.voiceinput.credentials"
    private static var backend: KeychainBackend = LiveKeychainBackend()

    @discardableResult
    static func saveResult(key: String, value: String) -> Result<OSStatus, KeychainError> {
        guard let data = value.data(using: .utf8) else {
            return .failure(.invalidData(status: errSecParam))
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        _ = backend.delete(deleteQuery)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        let status = backend.add(addQuery)
        guard status == errSecSuccess else {
            return .failure(.osStatus(status))
        }
        return .success(status)
    }

    static func loadResult(key: String) -> Result<(value: String, status: OSStatus), KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = backend.copyMatching(query, result: &result)
        guard status == errSecSuccess else {
            return .failure(.osStatus(status))
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .failure(.invalidData(status: status))
        }
        return .success((value: value, status: status))
    }

    @discardableResult
    static func deleteResult(key: String) -> Result<OSStatus, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = backend.delete(query)
        if status == errSecSuccess || status == errSecItemNotFound {
            return .success(status)
        }
        return .failure(.osStatus(status))
    }

    /// Save a string value to the Keychain.
    static func save(key: String, value: String) {
        _ = saveResult(key: key, value: value)
    }

    /// Load a string value from the Keychain. Returns nil if not found.
    static func load(key: String) -> String? {
        switch loadResult(key: key) {
        case .success(let payload):
            payload.value
        case .failure:
            nil
        }
    }

    /// Delete a key from the Keychain.
    static func delete(key: String) {
        _ = deleteResult(key: key)
    }

    static func setBackendForTesting(_ newBackend: KeychainBackend) {
        backend = newBackend
    }

    static func resetBackendForTesting() {
        backend = LiveKeychainBackend()
    }
}
