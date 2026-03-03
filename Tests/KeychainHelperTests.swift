import Foundation
import Security
import Testing
@testable import VoiceInput

private final class InMemoryKeychainBackend: KeychainBackend {
    var storage: [String: Data] = [:]
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess

    func add(_ query: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String,
              let value = query[kSecValueData as String] as? Data else {
            return errSecParam
        }
        guard addStatus == errSecSuccess else { return addStatus }
        storage[account] = value
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        guard let data = storage[account] else {
            return errSecItemNotFound
        }
        result?.pointee = data as AnyObject
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        guard deleteStatus == errSecSuccess else { return deleteStatus }
        storage.removeValue(forKey: account)
        return errSecSuccess
    }
}

@Suite(.serialized)
struct KeychainHelperTests {
    @Test("Result API 在 save 失败时携带 OSStatus")
    func saveResultIncludesStatusOnFailure() {
        let backend = InMemoryKeychainBackend()
        backend.addStatus = errSecAuthFailed
        KeychainHelper.setBackendForTesting(backend)
        defer { KeychainHelper.resetBackendForTesting() }

        let result = KeychainHelper.saveResult(key: "k", value: "v")
        switch result {
        case .success:
            Issue.record("saveResult 应该失败")
        case .failure(let error):
            #expect(error == .osStatus(errSecAuthFailed))
            #expect(error.status == errSecAuthFailed)
        }
    }

    @Test("Result API 在 key 不存在时返回 errSecItemNotFound")
    func loadResultIncludesStatusWhenMissing() {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.setBackendForTesting(backend)
        defer { KeychainHelper.resetBackendForTesting() }

        let result = KeychainHelper.loadResult(key: "missing")
        switch result {
        case .success:
            Issue.record("loadResult 应该失败")
        case .failure(let error):
            #expect(error == .osStatus(errSecItemNotFound))
            #expect(error.status == errSecItemNotFound)
        }
    }

    @Test("兼容旧接口 save/load/delete 仍可用")
    func legacyApiRemainsCompatible() {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.setBackendForTesting(backend)
        defer { KeychainHelper.resetBackendForTesting() }

        KeychainHelper.save(key: "legacy", value: "token")
        #expect(KeychainHelper.load(key: "legacy") == "token")

        KeychainHelper.delete(key: "legacy")
        #expect(KeychainHelper.load(key: "legacy") == nil)
    }
}
