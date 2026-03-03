import Foundation

struct LLMProcessResult: Equatable {
    let outputText: String
    let usedFallback: Bool
    let httpStatusCode: Int?
    let actionableHint: String?
    let errorReason: String?
}

/// 调用 OpenAI-compatible chat/completions 接口，对语音识别结果进行后处理。
/// 优化标点、断句、去除结巴/重复等口语问题。
enum LLMPostProcessor {
    typealias RequestExecutor = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

    // MARK: - 默认提示词

    static let defaultSystemPrompt = """
    你是一个语音识别文本后处理助手。你的任务是修正语音识别的原始输出，使其更加准确、自然、易读。

    请遵循以下规则：
    1. 修正标点符号：添加或纠正逗号、句号、问号、感叹号等，使断句自然。
    2. 去除口语结巴和重复：例如"我我我想要"应修正为"我想要"，"就是就是说"应修正为"就是说"。
    3. 去除口语填充词：删除无意义的"嗯"、"啊"、"那个"、"然后"等口语填充词，但保留有语义的部分。
    4. 修正明显的同音字错误（如果上下文能明确判断）。
    5. 保持原文的核心意思不变，不添加、不删减实质内容。
    6. 不要改变专有名词、人名、地名等。
    7. 如果原文已经很流畅，只需微调标点即可，不要过度修改。

    只输出修正后的文本，不要输出任何解释或额外内容。
    """

    private static let apiKeyStorageKey = "llm_post_api_key"
    private static var defaults: UserDefaults = .standard
    private static let liveRequestExecutor: RequestExecutor = { request, completion in
        URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
    }
    private static var requestExecutor: RequestExecutor = liveRequestExecutor

    // MARK: - 配置读写

    static var enabled: Bool {
        get { defaults.bool(forKey: "llm_post_enabled") }
        set { defaults.set(newValue, forKey: "llm_post_enabled") }
    }

    static var baseURL: String {
        get { defaults.string(forKey: "llm_post_base_url") ?? "" }
        set { defaults.set(newValue, forKey: "llm_post_base_url") }
    }

    static var model: String {
        get { defaults.string(forKey: "llm_post_model") ?? "" }
        set { defaults.set(newValue, forKey: "llm_post_model") }
    }

    static var apiKey: String {
        get { KeychainHelper.load(key: apiKeyStorageKey) ?? "" }
        set { KeychainHelper.save(key: apiKeyStorageKey, value: newValue) }
    }

    /// 用户自定义提示词，为空时使用默认值
    static var systemPrompt: String {
        get {
            let custom = defaults.string(forKey: "llm_post_system_prompt") ?? ""
            return custom.isEmpty ? defaultSystemPrompt : custom
        }
        set { defaults.set(newValue, forKey: "llm_post_system_prompt") }
    }

    /// 重置提示词为默认值
    static func resetSystemPrompt() {
        defaults.removeObject(forKey: "llm_post_system_prompt")
    }

    /// 配置是否齐全（启用时才检查）
    static var isConfigured: Bool {
        !baseURL.isEmpty && !model.isEmpty && !apiKey.isEmpty
    }

    // MARK: - 测试连接

    /// 测试 API 连通性。使用传入的配置（不需要先保存）。
    /// 回调在主线程，success=true 时 message 为模型回复，否则为错误描述。
    static func testConnection(
        baseURL: String, model: String, apiKey: String,
        completion: @escaping (_ success: Bool, _ message: String) -> Void
    ) {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmedBase)/chat/completions") else {
            DispatchQueue.main.async { completion(false, "无效的 Base URL") }
            return
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "你好"]
            ],
            "temperature": 0.3,
            "max_tokens": 50
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(false, "JSON 序列化失败") }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = RuntimeTuning.llmConnectionTestTimeoutSeconds

        requestExecutor(request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(false, "请求失败: \(error.localizedDescription)") }
                return
            }

            // 检查 HTTP 状态码
            if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                let body = summarizeBody(data)
                let hint = actionableHint(for: httpResp.statusCode)
                DispatchQueue.main.async {
                    completion(false, "HTTP \(httpResp.statusCode): \(body)\n建议：\(hint)")
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async { completion(false, "无响应数据") }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                let responseStr = String(data: data, encoding: .utf8) ?? "无法解析"
                DispatchQueue.main.async { completion(false, "响应格式异常: \(responseStr)") }
                return
            }

            DispatchQueue.main.async { completion(true, content.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    // MARK: - 后处理

    /// 对语音识别文本进行 LLM 后处理。
    /// 如果未启用或配置不完整，直接返回原文。
    static func process(_ text: String, completion: @escaping (String) -> Void) {
        processDetailed(text) { result in
            completion(result.outputText)
        }
    }

    /// 带诊断信息的正式处理路径。
    /// - 返回：无论成功/失败都返回可继续执行的文本；失败时附带状态码与可执行提示。
    static func processDetailed(_ text: String, completion: @escaping (LLMProcessResult) -> Void) {
        guard enabled, isConfigured, !text.isEmpty else {
            completion(
                LLMProcessResult(
                    outputText: text,
                    usedFallback: false,
                    httpStatusCode: nil,
                    actionableHint: nil,
                    errorReason: nil
                )
            )
            return
        }

        let startedAt = Date()
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmedBase)/chat/completions") else {
            let reason = "无效的 Base URL: \(baseURL)"
            print("[LLM] ❌ \(reason)")
            completeProcess(
                completion: completion,
                startedAt: startedAt,
                result: LLMProcessResult(
                    outputText: text,
                    usedFallback: true,
                    httpStatusCode: nil,
                    actionableHint: "请检查 LLM Base URL（需包含协议和有效主机）。",
                    errorReason: reason
                ),
                failed: true
            )
            return
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3,
            "max_tokens": 2048
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            let reason = "JSON 序列化失败"
            print("[LLM] ❌ \(reason)")
            completeProcess(
                completion: completion,
                startedAt: startedAt,
                result: LLMProcessResult(
                    outputText: text,
                    usedFallback: true,
                    httpStatusCode: nil,
                    actionableHint: "请检查模型参数与请求体字段是否有效。",
                    errorReason: reason
                ),
                failed: true
            )
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = RuntimeTuning.llmProcessTimeoutSeconds

        print("[LLM] 发送后处理请求...")

        requestExecutor(request) { data, response, error in
            if let error = error {
                let reason = "请求失败: \(error.localizedDescription)"
                print("[LLM] ❌ \(reason)")
                completeProcess(
                    completion: completion,
                    startedAt: startedAt,
                    result: LLMProcessResult(
                        outputText: text,
                        usedFallback: true,
                        httpStatusCode: nil,
                        actionableHint: "请检查网络连接，并确认 API 服务可访问。",
                        errorReason: reason
                    ),
                    failed: true
                )
                return
            }

            if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                let statusCode = httpResp.statusCode
                let responseBody = summarizeBody(data)
                let hint = actionableHint(for: statusCode)
                let reason = "HTTP \(statusCode): \(responseBody)"
                print("[LLM] ❌ \(reason) | 建议: \(hint)")
                completeProcess(
                    completion: completion,
                    startedAt: startedAt,
                    result: LLMProcessResult(
                        outputText: text,
                        usedFallback: true,
                        httpStatusCode: statusCode,
                        actionableHint: hint,
                        errorReason: reason
                    ),
                    failed: true
                )
                return
            }

            guard let data = data else {
                let reason = "无响应数据"
                print("[LLM] ❌ \(reason)")
                completeProcess(
                    completion: completion,
                    startedAt: startedAt,
                    result: LLMProcessResult(
                        outputText: text,
                        usedFallback: true,
                        httpStatusCode: nil,
                        actionableHint: "请稍后重试；若持续失败请检查服务端日志。",
                        errorReason: reason
                    ),
                    failed: true
                )
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                let responseStr = summarizeBody(data)
                let reason = "响应格式异常: \(responseStr)"
                print("[LLM] ❌ \(reason)")
                completeProcess(
                    completion: completion,
                    startedAt: startedAt,
                    result: LLMProcessResult(
                        outputText: text,
                        usedFallback: true,
                        httpStatusCode: nil,
                        actionableHint: "请检查模型 API 返回格式，需包含 choices[0].message.content。",
                        errorReason: reason
                    ),
                    failed: true
                )
                return
            }

            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isEmpty {
                let reason = "LLM 返回空内容"
                print("[LLM] ⚠️ \(reason)，使用原文")
                completeProcess(
                    completion: completion,
                    startedAt: startedAt,
                    result: LLMProcessResult(
                        outputText: text,
                        usedFallback: true,
                        httpStatusCode: nil,
                        actionableHint: "请调整提示词或模型参数，避免返回空文本。",
                        errorReason: reason
                    ),
                    failed: true
                )
            } else {
                let logResult = HistoryLogger.enabled ? result : "<redacted>"
                print("[LLM] ✅ 后处理完成: \(logResult)")
                completeProcess(
                    completion: completion,
                    startedAt: startedAt,
                    result: LLMProcessResult(
                        outputText: result,
                        usedFallback: false,
                        httpStatusCode: nil,
                        actionableHint: nil,
                        errorReason: nil
                    ),
                    failed: false
                )
            }
        }
    }

    static func setRequestExecutorForTesting(_ executor: @escaping RequestExecutor) {
        requestExecutor = executor
    }

    static func resetRequestExecutorForTesting() {
        requestExecutor = liveRequestExecutor
    }

    static func setUserDefaultsForTesting(_ userDefaults: UserDefaults) {
        defaults = userDefaults
    }

    static func resetUserDefaultsForTesting() {
        defaults = .standard
    }

    private static func completeProcess(
        completion: @escaping (LLMProcessResult) -> Void,
        startedAt: Date,
        result: LLMProcessResult,
        failed: Bool
    ) {
        let latency = Date().timeIntervalSince(startedAt)
        HealthMonitor.record(
            latency: latency,
            failed: failed,
            fallbackUsed: result.usedFallback,
            errorReason: result.errorReason
        )
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private static func actionableHint(for statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return "认证失败（401）：请检查并更新 API Key。"
        case 429:
            return "请求受限（429）：请稍后重试，或检查额度与频率限制。"
        case 500...599:
            return "服务异常（\(statusCode)）：上游服务暂时不可用，请稍后重试。"
        default:
            return "请求失败（HTTP \(statusCode)）：请检查 Base URL、模型名称和服务端配置。"
        }
    }

    private static func summarizeBody(_ data: Data?) -> String {
        guard let data,
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "<empty>"
        }
        if raw.count <= 300 {
            return raw
        }
        let end = raw.index(raw.startIndex, offsetBy: 300)
        return "\(raw[..<end])..."
    }
}
