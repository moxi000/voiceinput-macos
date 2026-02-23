import Foundation

/// 调用 OpenAI-compatible chat/completions 接口，对语音识别结果进行后处理。
/// 优化标点、断句、去除结巴/重复等口语问题。
enum LLMPostProcessor {

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

    // MARK: - 配置读写

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "llm_post_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "llm_post_enabled") }
    }

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "llm_post_base_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "llm_post_base_url") }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: "llm_post_model") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "llm_post_model") }
    }

    static var apiKey: String {
        get { KeychainHelper.load(key: "llm_post_api_key") ?? "" }
        set { KeychainHelper.save(key: "llm_post_api_key", value: newValue) }
    }

    /// 用户自定义提示词，为空时使用默认值
    static var systemPrompt: String {
        get {
            let custom = UserDefaults.standard.string(forKey: "llm_post_system_prompt") ?? ""
            return custom.isEmpty ? defaultSystemPrompt : custom
        }
        set { UserDefaults.standard.set(newValue, forKey: "llm_post_system_prompt") }
    }

    /// 重置提示词为默认值
    static func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: "llm_post_system_prompt")
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
        request.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(false, "请求失败: \(error.localizedDescription)") }
                return
            }

            // 检查 HTTP 状态码
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    completion(false, "HTTP \(httpResp.statusCode): \(body)")
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
        task.resume()
    }

    // MARK: - 后处理

    /// 对语音识别文本进行 LLM 后处理。
    /// 如果未启用或配置不完整，直接返回原文。
    static func process(_ text: String, completion: @escaping (String) -> Void) {
        guard enabled, isConfigured, !text.isEmpty else {
            completion(text)
            return
        }

        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmedBase)/chat/completions") else {
            print("[LLM] ❌ 无效的 Base URL: \(baseURL)")
            completion(text)
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
            print("[LLM] ❌ JSON 序列化失败")
            completion(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        print("[LLM] 发送后处理请求...")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[LLM] ❌ 请求失败: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(text) }
                return
            }

            guard let data = data else {
                print("[LLM] ❌ 无响应数据")
                DispatchQueue.main.async { completion(text) }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                // 尝试打印错误信息
                if let responseStr = String(data: data, encoding: .utf8) {
                    print("[LLM] ❌ 解析失败，响应: \(responseStr)")
                }
                DispatchQueue.main.async { completion(text) }
                return
            }

            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isEmpty {
                print("[LLM] ⚠️ LLM 返回空内容，使用原文")
                DispatchQueue.main.async { completion(text) }
            } else {
                let logResult = HistoryLogger.enabled ? result : "<redacted>"
                print("[LLM] ✅ 后处理完成: \(logResult)")
                DispatchQueue.main.async { completion(result) }
            }
        }
        task.resume()
    }
}
