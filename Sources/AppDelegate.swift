import Cocoa
import Carbon.HIToolbox

/// Main application controller.
/// Manages the menu bar icon, global hotkey, and coordinates recording → ASR → paste.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayPanel()
    private let recorder = AudioRecorder()
    private let inlineInjector = InlineTextInjector()
    private var asr: VolcengineASR?
    private var eventTap: CFMachPort?
    private var previousApp: NSRunningApplication?  // app that was focused before recording
    private var modeMenuItem: NSMenuItem!

    private var isInlineMode: Bool {
        get { UserDefaults.standard.bool(forKey: "inline_mode") }
        set { UserDefaults.standard.set(newValue, forKey: "inline_mode") }
    }

    // API credentials (stored in UserDefaults)
    private var appId: String {
        get { UserDefaults.standard.string(forKey: "volcengine_app_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "volcengine_app_id") }
    }
    private var token: String {
        get { UserDefaults.standard.string(forKey: "volcengine_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "volcengine_token") }
    }
    private var cluster: String {
        get { UserDefaults.standard.string(forKey: "volcengine_cluster") ?? "volc.seedasr.sauc.duration" }
        set { UserDefaults.standard.set(newValue, forKey: "volcengine_cluster") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DataPaths.ensureDataDirectory()
        setupMenuBar()
        setupGlobalHotkey()
        print("[AppDelegate] VoiceInput ready. Press Option+Z to start/stop recording.")

        if appId.isEmpty || token.isEmpty {
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

        menu.addItem(NSMenuItem.separator())

        let configItem = NSMenuItem(title: "设置 API Key...", action: #selector(showApiKeyDialog), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

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
            print("[AppDelegate] Credentials saved (appId=\(appId), resourceId=\(cluster))")
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Global Hotkey (Option+Z via CGEvent tap)

    private func setupGlobalHotkey() {
        // We need accessibility permissions for CGEvent tap
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            print("[AppDelegate] ⚠️ Accessibility permission required. Please grant it in System Preferences.")
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()

            // Middle mouse button (button 2)
            if type == .otherMouseDown && event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                DispatchQueue.main.async { delegate.toggleRecording() }
                return nil
            }

            // Option+Z: keyCode 6 = Z
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == 6 && event.flags.contains(.maskAlternate) {
                    DispatchQueue.main.async { delegate.toggleRecording() }
                    return nil
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            print("[AppDelegate] ❌ Failed to create event tap. Grant accessibility permissions.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[AppDelegate] Global hotkey Option+Z registered")
    }

    // MARK: - Recording Toggle

    private func toggleRecording() {
        if recorder.recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // Cancel any previous ASR session to prevent stale results
        asr?.cancel()
        asr = nil

        // Capture the frontmost app BEFORE anything else
        previousApp = NSWorkspace.shared.frontmostApplication
        print("[AppDelegate] Captured target app: \(previousApp?.localizedName ?? "unknown")")

        guard !appId.isEmpty, !token.isEmpty else {
            print("[AppDelegate] Credentials not set!")
            showApiKeyDialog()
            return
        }

        // Create ASR and connect WebSocket BEFORE recording starts
        asr = VolcengineASR(appId: appId, token: token, cluster: cluster)
        asr?.hotwords = loadHotwords()

        if isInlineMode {
            setupInlineModeCallbacks()
        } else {
            setupOverlayModeCallbacks()
        }

        // Start WebSocket connection
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
        asr?.onPartialResult = { [weak self] text in
            self?.overlay.updateText(text)
        }

        asr?.onFinalResult = { [weak self] text in
            let processedText = text.isEmpty ? text : WordReplacer.applyReplacements(to: text)

            if !processedText.isEmpty {
                HistoryLogger.log(processedText)
            }

            self?.overlay.setState(.done)
            self?.overlay.updateText(processedText.isEmpty ? "无输入" : processedText)

            let targetApp = self?.previousApp
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.overlay.hide()
                if !processedText.isEmpty {
                    TextInjector.paste(processedText, targetApp: targetApp)
                }
            }
        }

        asr?.onError = { [weak self] msg in
            self?.overlay.setState(.error(msg))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.overlay.hide()
            }
        }
    }

    private func setupInlineModeCallbacks() {
        asr?.onPartialResult = { [weak self] text in
            self?.inlineInjector.update(to: text)
        }

        asr?.onFinalResult = { [weak self] text in
            let processedText = text.isEmpty ? text : WordReplacer.applyReplacements(to: text)

            if !processedText.isEmpty {
                self?.inlineInjector.finalize(with: processedText)
                HistoryLogger.log(processedText)
            } else {
                // No recognized text — clean up any partial text left in the field
                self?.inlineInjector.deleteAll()
            }

            self?.overlay.setState(.done)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.overlay.hide()
            }
        }

        asr?.onError = { [weak self] msg in
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
}
