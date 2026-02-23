import Cocoa
import Carbon.HIToolbox

/// Main application controller.
/// Manages the menu bar icon, global hotkey, and coordinates recording → ASR → paste.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayPanel()
    private let recorder = AudioRecorder()
    private let inlineInjector = InlineTextInjector()
    private var asr: ASRService?
    private var hotkeyManager: HotkeyManager!
    private var previousApp: NSRunningApplication?
    private var modeMenuItem: NSMenuItem!
    private var providerMenuItem: NSMenuItem!
    private var privacyMenuItem: NSMenuItem!
    private var holdHotkeyMenuItem: NSMenuItem!
    private var freeHotkeyMenuItem: NSMenuItem!
    private var llmMenuItem: NSMenuItem!

    private var isInlineMode: Bool {
        get { UserDefaults.standard.bool(forKey: "inline_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "inline_mode") }
    }

    // API credentials (stored in Keychain)
    private var appId: String {
        get { KeychainHelper.load(key: "volcengine_app_id") ?? "" }
        set { KeychainHelper.save(key: "volcengine_app_id", value: newValue) }
    }
    private var token: String {
        get { KeychainHelper.load(key: "volcengine_token") ?? "" }
        set { KeychainHelper.save(key: "volcengine_token", value: newValue) }
    }
    private var cluster: String {
        get { UserDefaults.standard.string(forKey: "volcengine_cluster") ?? "volc.seedasr.sauc.duration" }
        set { UserDefaults.standard.set(newValue, forKey: "volcengine_cluster") }
    }

    /// ASR provider: "volcengine" or "local"
    private var asrProvider: String {
        get { UserDefaults.standard.string(forKey: "asr_provider") ?? "volcengine" }
        set { UserDefaults.standard.set(newValue, forKey: "asr_provider") }
    }

    private var localASRHost: String {
        get { UserDefaults.standard.string(forKey: "local_asr_host") ?? "127.0.0.1" }
        set { UserDefaults.standard.set(newValue, forKey: "local_asr_host") }
    }

    private var localASRPort: UInt16 {
        get {
            let val = UserDefaults.standard.integer(forKey: "local_asr_port")
            return val > 0 ? UInt16(val) : 8000
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "local_asr_port") }
    }

    private var privacyMode: Bool {
        get { UserDefaults.standard.bool(forKey: "privacy_mode") }
        set {
            UserDefaults.standard.set(newValue, forKey: "privacy_mode")
            applyPrivacyMode()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DataPaths.ensureDataDirectory()
        migrateCredentialsToKeychain()
        applyPrivacyMode()
        hotkeyManager = HotkeyManager()
        setupMenuBar()
        setupHotkeyManager()
        print("[AppDelegate] VoiceInput ready.")

        if asrProvider != "local" && (appId.isEmpty || token.isEmpty) {
            print("[AppDelegate] ⚠️ API credentials not configured. Use the menu bar to set them.")
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceInput")
            button.image?.size = NSSize(width: 16, height: 16)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "VoiceInput", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        modeMenuItem = NSMenuItem(title: isInlineMode ? "切换到浮窗模式" : "切换到内联模式", action: #selector(toggleMode), keyEquivalent: "")
        modeMenuItem.target = self
        menu.addItem(modeMenuItem)

        providerMenuItem = NSMenuItem(
            title: asrProvider == "local" ? "切换到云端识别" : "切换到本地识别",
            action: #selector(toggleProvider), keyEquivalent: "")
        providerMenuItem.target = self
        menu.addItem(providerMenuItem)

        menu.addItem(NSMenuItem.separator())

        let configItem = NSMenuItem(title: "设置火山引擎 API Key...", action: #selector(showApiKeyDialog), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        let localConfigItem = NSMenuItem(title: "设置本地识别服务...", action: #selector(showLocalASRDialog), keyEquivalent: "")
        localConfigItem.target = self
        menu.addItem(localConfigItem)

        menu.addItem(NSMenuItem.separator())

        let llmConfigItem = NSMenuItem(title: "设置 LLM 后处理...", action: #selector(showLLMSettingsDialog), keyEquivalent: "")
        llmConfigItem.target = self
        menu.addItem(llmConfigItem)

        llmMenuItem = NSMenuItem(title: "LLM 后处理", action: #selector(toggleLLMPost), keyEquivalent: "")
        llmMenuItem.target = self
        llmMenuItem.state = LLMPostProcessor.enabled ? .on : .off
        menu.addItem(llmMenuItem)

        let llmPromptItem = NSMenuItem(title: "编辑 LLM 提示词...", action: #selector(showLLMPromptEditor), keyEquivalent: "")
        llmPromptItem.target = self
        menu.addItem(llmPromptItem)

        menu.addItem(NSMenuItem.separator())

        let replacementsItem = NSMenuItem(title: "编辑词汇替换表...", action: #selector(openReplacementsFile), keyEquivalent: "")
        replacementsItem.target = self
        menu.addItem(replacementsItem)

        let hotwordsItem = NSMenuItem(title: "编辑热词表...", action: #selector(openHotwordsFile), keyEquivalent: "")
        hotwordsItem.target = self
        menu.addItem(hotwordsItem)

        let historyItem = NSMenuItem(title: "查看输入历史...", action: #selector(openHistoryFile), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        privacyMenuItem = NSMenuItem(title: "隐私模式", action: #selector(togglePrivacy), keyEquivalent: "")
        privacyMenuItem.target = self
        privacyMenuItem.state = privacyMode ? .on : .off
        menu.addItem(privacyMenuItem)

        menu.addItem(NSMenuItem.separator())

        let holdLabel = hotkeyManager.holdToTalkConfig?.displayString ?? "未设置"
        holdHotkeyMenuItem = NSMenuItem(
            title: "按住说话快捷键: \(holdLabel)",
            action: #selector(showHoldHotkeyDialog), keyEquivalent: "")
        holdHotkeyMenuItem.target = self
        menu.addItem(holdHotkeyMenuItem)

        let freeLabel = hotkeyManager.handsFreeConfig?.displayString ?? "鼠标中键"
        freeHotkeyMenuItem = NSMenuItem(
            title: "免提快捷键: \(freeLabel)",
            action: #selector(showFreeHotkeyDialog), keyEquivalent: "")
        freeHotkeyMenuItem.target = self
        menu.addItem(freeHotkeyMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func showApiKeyDialog() {
        let alert = NSAlert()
        alert.messageText = "火山引擎设置"
        alert.informativeText = "请输入 App ID、Access Token 和 Resource ID\n(控制台-应用管理中获取)"

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 92))
        stackView.orientation = .vertical
        stackView.spacing = 8

        let appIdField = EditableTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        appIdField.placeholderString = "App ID (如: 5956285917)"
        appIdField.stringValue = appId
        stackView.addArrangedSubview(appIdField)

        let tokenField = EditableSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tokenField.placeholderString = "Access Token"
        tokenField.stringValue = token
        stackView.addArrangedSubview(tokenField)

        let clusterField = EditableTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        clusterField.placeholderString = "Resource ID (如: volc.seedasr.sauc.duration)"
        clusterField.stringValue = cluster
        stackView.addArrangedSubview(clusterField)

        alert.accessoryView = stackView
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            appId = appIdField.stringValue
            token = tokenField.stringValue
            cluster = clusterField.stringValue
            print("[AppDelegate] Credentials saved (resourceId=\(cluster))")
        }
    }

    @objc private func openReplacementsFile() {
        DataPaths.ensureFileExists(
            at: DataPaths.replacementsFile,
            defaultContent: "# 词汇替换表\n# 格式: 原词:替换词 或 原词→替换词\n# 每行一条，#开头为注释\n"
        )
        NSWorkspace.shared.open(DataPaths.replacementsFile)
    }

    @objc private func openHotwordsFile() {
        DataPaths.ensureFileExists(
            at: DataPaths.hotwordsFile,
            defaultContent: "# 热词表 (每行一个，最多100个，#开头为注释)\n# 用于提升人名、产品名等专有词汇的识别准确率\n"
        )
        NSWorkspace.shared.open(DataPaths.hotwordsFile)
    }

    private func loadHotwords() -> [String] {
        guard let content = try? String(contentsOf: DataPaths.hotwordsFile, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    @objc private func openHistoryFile() {
        DataPaths.ensureFileExists(at: DataPaths.historyFile)
        NSWorkspace.shared.open(DataPaths.historyFile)
    }

    @objc private func toggleMode() {
        guard !recorder.recording else {
            print("[AppDelegate] Cannot switch mode while recording")
            return
        }
        isInlineMode.toggle()
        modeMenuItem.title = isInlineMode ? "切换到浮窗模式" : "切换到内联模式"
        print("[AppDelegate] Mode: \(isInlineMode ? "inline" : "overlay")")
    }

    @objc private func toggleProvider() {
        guard !recorder.recording else {
            print("[AppDelegate] Cannot switch provider while recording")
            return
        }
        asrProvider = (asrProvider == "local") ? "volcengine" : "local"
        providerMenuItem.title = asrProvider == "local" ? "切换到云端识别" : "切换到本地识别"
        print("[AppDelegate] ASR provider: \(asrProvider)")
    }

    @objc private func togglePrivacy() {
        privacyMode.toggle()
        privacyMenuItem.state = privacyMode ? .on : .off
        print("[AppDelegate] Privacy mode: \(privacyMode ? "ON" : "OFF")")
    }

    private func applyPrivacyMode() {
        HistoryLogger.enabled = !privacyMode
    }

    @objc private func showLLMSettingsDialog() {
        let alert = NSAlert()
        alert.messageText = "LLM 后处理设置"
        alert.informativeText = "配置 LLM API 以优化语音识别结果（标点、断句、去结巴等）"

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 350, height: 92))
        stackView.orientation = .vertical
        stackView.spacing = 8

        let baseURLField = EditableTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 24))
        baseURLField.placeholderString = "Base URL (如: https://api.openai.com/v1)"
        baseURLField.stringValue = LLMPostProcessor.baseURL
        stackView.addArrangedSubview(baseURLField)

        let modelField = EditableTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 24))
        modelField.placeholderString = "模型名称 (如: gpt-4o-mini)"
        modelField.stringValue = LLMPostProcessor.model
        stackView.addArrangedSubview(modelField)

        let keyField = EditableSecureTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 24))
        keyField.placeholderString = "API Key"
        keyField.stringValue = LLMPostProcessor.apiKey
        stackView.addArrangedSubview(keyField)

        alert.accessoryView = stackView
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "测试")
        alert.addButton(withTitle: "取消")

        // 循环处理：点击「测试」后显示结果，对话框保持打开
        var shouldContinue = true
        while shouldContinue {
            let result = alert.runModal()
            switch result {
            case .alertFirstButtonReturn:
                // 保存
                LLMPostProcessor.baseURL = baseURLField.stringValue
                LLMPostProcessor.model = modelField.stringValue
                LLMPostProcessor.apiKey = keyField.stringValue
                print("[AppDelegate] LLM 设置已保存 (model=\(LLMPostProcessor.model))")
                shouldContinue = false

            case .alertSecondButtonReturn:
                // 测试连接
                let testBase = baseURLField.stringValue
                let testModel = modelField.stringValue
                let testKey = keyField.stringValue

                guard !testBase.isEmpty, !testModel.isEmpty, !testKey.isEmpty else {
                    let warn = NSAlert()
                    warn.messageText = "❌ 配置不完整"
                    warn.informativeText = "请填写 Base URL、模型名称和 API Key"
                    warn.runModal()
                    continue
                }

                // 使用信号量等待异步结果
                let semaphore = DispatchSemaphore(value: 0)
                var testSuccess = false
                var testMessage = ""
                LLMPostProcessor.testConnection(baseURL: testBase, model: testModel, apiKey: testKey) { success, message in
                    testSuccess = success
                    testMessage = message
                    semaphore.signal()
                }

                // 在后台等待，避免阻塞主线程 UI
                DispatchQueue.global().async {
                    semaphore.wait()
                    DispatchQueue.main.async {
                        let resultAlert = NSAlert()
                        if testSuccess {
                            resultAlert.messageText = "✅ 连接成功"
                            resultAlert.informativeText = "模型回复: \(testMessage)"
                        } else {
                            resultAlert.messageText = "❌ 连接失败"
                            resultAlert.informativeText = testMessage
                        }
                        resultAlert.runModal()
                    }
                }
                // 继续循环，回到主对话框
                continue

            default:
                // 取消
                shouldContinue = false
            }
        }
    }

    @objc private func toggleLLMPost() {
        LLMPostProcessor.enabled.toggle()
        llmMenuItem.state = LLMPostProcessor.enabled ? .on : .off
        print("[AppDelegate] LLM 后处理: \(LLMPostProcessor.enabled ? "ON" : "OFF")")
    }

    @objc private func showLLMPromptEditor() {
        let alert = NSAlert()
        alert.messageText = "编辑 LLM 提示词"
        alert.informativeText = "自定义系统提示词，用于指导 LLM 如何优化语音识别结果"

        // 使用 NSTextView + NSScrollView 实现多行编辑
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 250))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 250))
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isRichText = false
        textView.string = LLMPostProcessor.systemPrompt
        textView.autoresizingMask = [.width, .height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        alert.accessoryView = scrollView

        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "重置为默认")
        alert.addButton(withTitle: "取消")

        var shouldContinue = true
        while shouldContinue {
            let result = alert.runModal()
            switch result {
            case .alertFirstButtonReturn:
                // 保存
                let newPrompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if newPrompt.isEmpty || newPrompt == LLMPostProcessor.defaultSystemPrompt {
                    LLMPostProcessor.resetSystemPrompt()
                    print("[AppDelegate] LLM 提示词已重置为默认")
                } else {
                    LLMPostProcessor.systemPrompt = newPrompt
                    print("[AppDelegate] LLM 提示词已保存")
                }
                shouldContinue = false

            case .alertSecondButtonReturn:
                // 重置为默认
                textView.string = LLMPostProcessor.defaultSystemPrompt
                // 继续循环，保持对话框打开
                continue

            default:
                // 取消
                shouldContinue = false
            }
        }
    }

    @objc private func showLocalASRDialog() {
        let alert = NSAlert()
        alert.messageText = "本地识别服务设置"
        alert.informativeText = "请输入本地 ASR 服务的地址和端口"

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        stackView.orientation = .vertical
        stackView.spacing = 8

        let hostField = EditableTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        hostField.placeholderString = "Host (如: 127.0.0.1)"
        hostField.stringValue = localASRHost
        stackView.addArrangedSubview(hostField)

        let portField = EditableTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        portField.placeholderString = "Port (如: 8000)"
        portField.stringValue = String(localASRPort)
        stackView.addArrangedSubview(portField)

        alert.accessoryView = stackView
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            localASRHost = hostField.stringValue.isEmpty ? "127.0.0.1" : hostField.stringValue
            if let port = UInt16(portField.stringValue), port > 0 {
                localASRPort = port
            }
            print("[AppDelegate] Local ASR: \(localASRHost):\(localASRPort)")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Hotkey Manager

    private func setupHotkeyManager() {
        hotkeyManager = HotkeyManager()
        hotkeyManager.onRecordStart = { [weak self] mode in
            guard let self = self, !self.recorder.recording else { return }
            self.startRecording()
        }
        hotkeyManager.onRecordStop = { [weak self] in
            guard let self = self, self.recorder.recording else { return }
            self.stopRecording()
        }
        if !hotkeyManager.install() {
            holdHotkeyMenuItem.title = "按住说话快捷键: ⚠️ 需授权"
            freeHotkeyMenuItem.title = "免提快捷键: ⚠️ 需授权"
        }
    }

    @objc private func showHoldHotkeyDialog() {
        showHotkeyConfigDialog(
            title: "设置“按住说话”快捷键",
            info: "按住开始录音，松开停止。\n点击下方输入框，然后按下快捷键组合。",
            current: hotkeyManager.holdToTalkConfig
        ) { [weak self] config in
            self?.hotkeyManager.setHoldToTalk(config)
            self?.holdHotkeyMenuItem.title = "按住说话快捷键: \(config?.displayString ?? "未设置")"
        }
    }

    @objc private func showFreeHotkeyDialog() {
        showHotkeyConfigDialog(
            title: "设置“免提”快捷键",
            info: "按一次开始录音，再按一次停止。\n鼠标中键始终可用。\n点击下方输入框，然后按下快捷键组合。",
            current: hotkeyManager.handsFreeConfig
        ) { [weak self] config in
            self?.hotkeyManager.setHandsFree(config)
            self?.freeHotkeyMenuItem.title = "免提快捷键: \(config?.displayString ?? "鼠标中键")"
        }
    }

    private func showHotkeyConfigDialog(title: String, info: String, current: HotkeyConfig?,
                                         onSave: @escaping (HotkeyConfig?) -> Void) {
        // Suspend hotkey handling so key presses go to the recorder, not the app
        hotkeyManager.suspended = true

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info

        let recorder = HotkeyRecorderView(frame: NSRect(x: 0, y: 0, width: 250, height: 28))
        if let c = current { recorder.display(c) }

        var pendingKeyCode: Int64?
        var pendingModifiers: CGEventFlags?

        recorder.onHotkeyRecorded = { keyCode, modifiers in
            pendingKeyCode = keyCode
            pendingModifiers = modifiers
        }

        alert.accessoryView = recorder
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let result = alert.runModal()
        hotkeyManager.suspended = false

        if result == .alertFirstButtonReturn,
           let kc = pendingKeyCode, let mods = pendingModifiers {
            let config = HotkeyConfig(keyCode: kc, modifiers: mods)
            onSave(config)
        }
    }

    private func startRecording() {
        // Cancel any previous ASR session to prevent stale results
        asr?.onError = nil
        asr?.onFinalResult = nil
        asr?.onPartialResult = nil
        asr?.cancel()
        asr = nil

        // Capture the frontmost app BEFORE anything else
        previousApp = NSWorkspace.shared.frontmostApplication
        print("[AppDelegate] Captured target app: \(previousApp?.localizedName ?? "unknown")")

        // Create the appropriate ASR service
        if asrProvider == "local" {
            asr = LocalASR(host: localASRHost, port: localASRPort)
        } else {
            guard !appId.isEmpty, !token.isEmpty else {
                print("[AppDelegate] Credentials not set!")
                hotkeyManager.resetState()
                showApiKeyDialog()
                return
            }
            let volcASR = VolcengineASR(appId: appId, token: token, cluster: cluster)
            volcASR.hotwords = loadHotwords()
            asr = volcASR
        }

        if isInlineMode {
            setupInlineModeCallbacks()
        } else {
            setupOverlayModeCallbacks()
        }

        // Start ASR connection
        asr?.startStreaming()

        // Stream audio chunks to ASR in real-time
        recorder.onAudioChunk = { [weak self] chunk in
            self?.asr?.sendAudioChunk(chunk)
        }

        // Feed audio levels to overlay waveform (inline mode only)
        if isInlineMode {
            recorder.onAudioLevel = { [weak self] level in
                DispatchQueue.main.async {
                    self?.overlay.updateAudioLevel(level)
                }
            }
        } else {
            recorder.onAudioLevel = nil
        }

        do {
            try recorder.start()
        } catch {
            print("[AppDelegate] Failed to start recording: \(error)")
            asr?.cancel()
            hotkeyManager.resetState()
            return
        }

        // Show overlay (minimal in inline mode)
        overlay.minimal = isInlineMode
        overlay.isLocal = (asrProvider == "local")
        overlay.setState(.recording)
        overlay.updateText("")
        overlay.show()

        if isInlineMode {
            inlineInjector.reset()
        }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.badge.plus", accessibilityDescription: "Recording")
        }
    }

    private func setupOverlayModeCallbacks() {
        asr?.onPartialResult = { [weak self] (text: String) in
            self?.overlay.updateText(text)
        }

        asr?.onFinalResult = { [weak self] (text: String) in
            let replacedText = text.isEmpty ? text : WordReplacer.applyReplacements(to: text)

            // LLM 后处理（异步），完成后再粘贴
            let finalize = { (processedText: String) in
                if !processedText.isEmpty {
                    HistoryLogger.log(processedText)
                }

                self?.overlay.setState(.done)
                self?.overlay.updateText(processedText.isEmpty ? "无输入" : processedText)

                let targetApp = self?.previousApp
                if !processedText.isEmpty {
                    TextInjector.paste(processedText, targetApp: targetApp)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.overlay.hide()
                }
            }

            if LLMPostProcessor.enabled && LLMPostProcessor.isConfigured && !replacedText.isEmpty {
                self?.overlay.updateText("正在优化文本...")
                LLMPostProcessor.process(replacedText) { result in
                    finalize(result)
                }
            } else {
                finalize(replacedText)
            }
        }

        asr?.onError = { [weak self] (msg: String) in
            self?.cleanupAfterError()
            self?.overlay.setState(.error(msg))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.overlay.hide()
            }
        }
    }

    private func setupInlineModeCallbacks() {
        asr?.onPartialResult = { [weak self] (text: String) in
            self?.inlineInjector.update(to: text)
        }

        asr?.onFinalResult = { [weak self] (text: String) in
            let replacedText = text.isEmpty ? text : WordReplacer.applyReplacements(to: text)

            // LLM 后处理（异步），完成后再注入
            let finalize = { (processedText: String) in
                if !processedText.isEmpty {
                    self?.inlineInjector.finalize(with: processedText)
                    HistoryLogger.log(processedText)
                } else {
                    // 无识别文本 — 清理输入框中残留的部分文本
                    self?.inlineInjector.deleteAll()
                }

                self?.overlay.setState(.done)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.overlay.hide()
                }
            }

            if LLMPostProcessor.enabled && LLMPostProcessor.isConfigured && !replacedText.isEmpty {
                LLMPostProcessor.process(replacedText) { result in
                    finalize(result)
                }
            } else {
                finalize(replacedText)
            }
        }

        asr?.onError = { [weak self] (msg: String) in
            self?.cleanupAfterError()
            self?.inlineInjector.deleteAll()
            self?.overlay.setState(.error(msg))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.overlay.hide()
            }
        }
    }

    private func stopRecording() {
        // Stop recording first
        _ = recorder.stop()
        recorder.onAudioChunk = nil
        recorder.onAudioLevel = nil

        // Update menu bar icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceInput")
        }

        // Signal end of audio to ASR
        overlay.setState(.transcribing)
        if !isInlineMode {
            overlay.updateText("正在识别...")
        }
        asr?.endStreaming()
    }

    /// Clean up recording and ASR state after an error to prevent
    /// stale mic usage and data accumulation.
    private func cleanupAfterError() {
        if recorder.recording {
            _ = recorder.stop()
        }
        recorder.onAudioChunk = nil
        recorder.onAudioLevel = nil
        asr?.cancel()
        asr = nil
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceInput")
        }
        hotkeyManager?.resetState()
    }

    /// One-time migration: move credentials from UserDefaults to Keychain.
    private func migrateCredentialsToKeychain() {
        let defaults = UserDefaults.standard
        if let oldAppId = defaults.string(forKey: "volcengine_app_id"), !oldAppId.isEmpty,
           KeychainHelper.load(key: "volcengine_app_id") == nil {
            KeychainHelper.save(key: "volcengine_app_id", value: oldAppId)
            defaults.removeObject(forKey: "volcengine_app_id")
            print("[AppDelegate] Migrated appId to Keychain")
        }
        if let oldToken = defaults.string(forKey: "volcengine_token"), !oldToken.isEmpty,
           KeychainHelper.load(key: "volcengine_token") == nil {
            KeychainHelper.save(key: "volcengine_token", value: oldToken)
            defaults.removeObject(forKey: "volcengine_token")
            print("[AppDelegate] Migrated token to Keychain")
        }
    }
}
