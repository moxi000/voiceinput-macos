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

        let appIdField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        appIdField.placeholderString = "App ID (如: 5956285917)"
        appIdField.stringValue = appId
        stackView.addArrangedSubview(appIdField)

        let tokenField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tokenField.placeholderString = "Access Token"
        tokenField.stringValue = token
        stackView.addArrangedSubview(tokenField)

        let clusterField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
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

    @objc private func showLocalASRDialog() {
        let alert = NSAlert()
        alert.messageText = "本地识别服务设置"
        alert.informativeText = "请输入本地 ASR 服务的地址和端口"

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        stackView.orientation = .vertical
        stackView.spacing = 8

        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        hostField.placeholderString = "Host (如: 127.0.0.1)"
        hostField.stringValue = localASRHost
        stackView.addArrangedSubview(hostField)

        let portField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
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
        _ = hotkeyManager.install()
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

        if alert.runModal() == .alertFirstButtonReturn,
           let kc = pendingKeyCode, let mods = pendingModifiers {
            let config = HotkeyConfig(keyCode: kc, modifiers: mods)
            onSave(config)
        }
    }

    private func startRecording() {
        // Cancel any previous ASR session to prevent stale results
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
            let processedText = text.isEmpty ? text : WordReplacer.applyReplacements(to: text)

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
            let processedText = text.isEmpty ? text : WordReplacer.applyReplacements(to: text)

            if !processedText.isEmpty {
                self?.inlineInjector.finalize(with: processedText)
                HistoryLogger.log(processedText)
            } else {
                // No recognized text — clean up any partial text left in the field
                self?.inlineInjector.deleteAll()
            }

            self?.overlay.setState(.done)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.overlay.hide()
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
