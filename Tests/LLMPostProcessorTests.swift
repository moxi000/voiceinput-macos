import Foundation
import Security
import Testing
@testable import VoiceInput

private final class LLMKeychainBackend: KeychainBackend {
    var storage: [String: Data] = [:]

    func add(_ query: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String,
              let value = query[kSecValueData as String] as? Data else {
            return errSecParam
        }
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
        storage.removeValue(forKey: account)
        return errSecSuccess
    }
}

@Suite(.serialized)
struct LLMPostProcessorTests {
    @Test("401: 返回原文并给出 API Key 可执行提示")
    func processHandles401() async {
        let (defaults, suiteName) = testDefaults()
        _ = configureLLM(defaults: defaults)
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        LLMPostProcessor.setRequestExecutorForTesting { request, completion in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)
            completion(Data("{\"error\":\"invalid key\"}".utf8), response, nil)
        }

        let result = await process("原始文本")
        #expect(result.outputText == "原始文本")
        #expect(result.usedFallback)
        #expect(result.httpStatusCode == 401)
        #expect(result.actionableHint?.contains("API Key") == true)
        #expect(result.errorReason?.contains("401") == true)
    }

    @Test("429: 返回原文并给出限流/配额提示")
    func processHandles429() async {
        let (defaults, suiteName) = testDefaults()
        _ = configureLLM(defaults: defaults)
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        LLMPostProcessor.setRequestExecutorForTesting { request, completion in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)
            completion(Data("{\"error\":\"rate limit\"}".utf8), response, nil)
        }

        let result = await process("原始文本")
        #expect(result.outputText == "原始文本")
        #expect(result.usedFallback)
        #expect(result.httpStatusCode == 429)
        #expect(result.actionableHint?.contains("稍后") == true)
        #expect(result.errorReason?.contains("429") == true)
    }

    @Test("5xx: 返回原文并给出服务端重试提示")
    func processHandles5xx() async {
        let (defaults, suiteName) = testDefaults()
        _ = configureLLM(defaults: defaults)
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        LLMPostProcessor.setRequestExecutorForTesting { request, completion in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)
            completion(Data("{\"error\":\"unavailable\"}".utf8), response, nil)
        }

        let result = await process("原始文本")
        #expect(result.outputText == "原始文本")
        #expect(result.usedFallback)
        #expect(result.httpStatusCode == 503)
        #expect(result.actionableHint?.contains("服务") == true)
        #expect(result.errorReason?.contains("503") == true)
    }

    @Test("其他 HTTP 状态码: 返回原文并保留状态")
    func processHandlesOtherStatus() async {
        let (defaults, suiteName) = testDefaults()
        _ = configureLLM(defaults: defaults)
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        LLMPostProcessor.setRequestExecutorForTesting { request, completion in
            let response = HTTPURLResponse(url: request.url!, statusCode: 418, httpVersion: nil, headerFields: nil)
            completion(Data("{\"error\":\"teapot\"}".utf8), response, nil)
        }

        let result = await process("原始文本")
        #expect(result.outputText == "原始文本")
        #expect(result.usedFallback)
        #expect(result.httpStatusCode == 418)
        #expect(result.actionableHint?.contains("HTTP 418") == true)
        #expect(result.errorReason?.contains("418") == true)
    }

    @Test("成功时返回 LLM 内容且不回退")
    func processSuccess() async {
        let (defaults, suiteName) = testDefaults()
        _ = configureLLM(defaults: defaults)
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        let responseJSON = """
        {
          "choices": [
            {
              "message": {
                "content": "修正后文本"
              }
            }
          ]
        }
        """

        LLMPostProcessor.setRequestExecutorForTesting { request, completion in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
            completion(Data(responseJSON.utf8), response, nil)
        }

        let result = await process("原始文本")
        #expect(result.outputText == "修正后文本")
        #expect(result.usedFallback == false)
        #expect(result.httpStatusCode == nil)
        #expect(result.actionableHint == nil)
        #expect(result.errorReason == nil)
    }

    private func process(_ text: String) async -> LLMProcessResult {
        await withCheckedContinuation { continuation in
            LLMPostProcessor.processDetailed(text) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func testDefaults() -> (UserDefaults, String) {
        let suiteName = "LLMPostProcessorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @discardableResult
    private func configureLLM(defaults: UserDefaults) -> LLMKeychainBackend {
        let backend = LLMKeychainBackend()
        KeychainHelper.setBackendForTesting(backend)
        LLMPostProcessor.setUserDefaultsForTesting(defaults)

        LLMPostProcessor.enabled = true
        LLMPostProcessor.baseURL = "https://api.example.com"
        LLMPostProcessor.model = "gpt-test"
        LLMPostProcessor.apiKey = "secret"
        HealthMonitor.reset()

        return backend
    }

    private func cleanup(defaults: UserDefaults, suiteName: String) {
        LLMPostProcessor.resetRequestExecutorForTesting()
        LLMPostProcessor.resetUserDefaultsForTesting()
        KeychainHelper.resetBackendForTesting()
        HealthMonitor.reset()
        defaults.removePersistentDomain(forName: suiteName)
    }
}
