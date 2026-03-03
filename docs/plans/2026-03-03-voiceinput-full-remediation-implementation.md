# VoiceInput 全量修复与扩展 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 一次性完成 15 个工程问题与 8 个产品扩展，在 6 实施代理 + 6 验收代理并行流程下，通过完整测试后完成构建签名。  
**Architecture:** 采用三波次执行：波次 1 先清除 P0 与会话污染类 P1，波次 2 完成剩余 P1/P2/P3 与产品扩展，波次 3 用 6 个独立验收代理并行把关。核心通过 `sessionId` 会话隔离、统一状态模型、协议解析安全化和可观测性增强，确保链路收敛与可回归。  
**Tech Stack:** Swift 6.2, Swift Package Manager, AppKit (Cocoa), Network.framework, Security.framework, Swift Testing (`import Testing`)

---

## 执行前约束

1. 使用技能：`@superpowers/test-driven-development`、`@superpowers/systematic-debugging`、`@superpowers/verification-before-completion`、`@superpowers/subagent-driven-development`。  
2. 所有任务都遵循：先写失败测试 -> 运行确认失败 -> 最小实现 -> 运行确认通过 -> 提交。  
3. 并行规则：同一时间最多 6 个实施代理，且每个代理只改自己的文件所有权范围。  
4. 全局共享文件 `Sources/AppDelegate.swift` 由会话控制代理（A3）负责最终整合。  

## 波次 1（P0 + 关键 P1）

### Task 1: A1 - Volcengine 安全字节解码与异常包保护

**Files:**
- Modify: `Sources/VolcengineASR.swift`
- Test: `Tests/VolcengineASRParsingTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct VolcengineASRParsingTests {
    @Test("parseServerResponse handles unaligned/truncated payload safely")
    func parseUnalignedPayload() {
        let sut = VolcengineASR(appId: "a", token: "b", cluster: "c")
        let malformed = Data([0x11, 0x90, 0x01, 0x00, 0x00, 0x00, 0x00])
        // 目标：不崩溃且不会触发非法 load(as:)
        sut._test_parseServerResponse(malformed)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter VolcengineASRParsingTests/parseUnalignedPayload -v`  
Expected: FAIL（当前实现可能崩溃或测试辅助入口缺失）

**Step 3: Write minimal implementation**

```swift
private func readBEUInt32(_ data: Data, _ offset: Int) -> UInt32? {
    guard data.count >= offset + 4 else { return nil }
    let b0 = UInt32(data[offset]) << 24
    let b1 = UInt32(data[offset + 1]) << 16
    let b2 = UInt32(data[offset + 2]) << 8
    let b3 = UInt32(data[offset + 3])
    return b0 | b1 | b2 | b3
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter VolcengineASRParsingTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/VolcengineASR.swift Tests/VolcengineASRParsingTests.swift
git commit -m "fix(asr): harden volcengine binary parsing with safe byte decoding"
```

### Task 2: A1 - definite 文本去重，避免重复累计

**Files:**
- Modify: `Sources/VolcengineASR.swift`
- Test: `Tests/VolcengineASRParsingTests.swift`

**Step 1: Write the failing test**

```swift
@Test("definite utterance should not duplicate when server retries same id")
func definiteDedup() {
    let sut = VolcengineASR(appId: "a", token: "b", cluster: "c")
    sut._test_applyDefinite(id: "utt-1", text: "你好")
    sut._test_applyDefinite(id: "utt-1", text: "你好")
    #expect(sut._test_confirmedText() == "你好")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter VolcengineASRParsingTests/definiteDedup -v`  
Expected: FAIL（当前实现会重复追加）

**Step 3: Write minimal implementation**

```swift
private var seenDefiniteUtteranceIds: Set<String> = []
// definite=true 时优先用 utterance_id 去重，无 id 时 fallback 到 text 去重
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter VolcengineASRParsingTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/VolcengineASR.swift Tests/VolcengineASRParsingTests.swift
git commit -m "fix(asr): deduplicate definite volcengine utterances"
```

### Task 3: A2 - LocalASR 连接结束兜底 final/error

**Files:**
- Modify: `Sources/LocalASR.swift`
- Test: `Tests/LocalASRStreamTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct LocalASRStreamTests {
    @Test("emit fallback final when connection completes without done")
    func fallbackFinalOnComplete() async {
        let sut = LocalASR(host: "127.0.0.1", port: 9000)
        var finalText = ""
        sut.onFinalResult = { finalText = $0 }
        sut._test_onStreamCompleteWithoutDone(lastNonEmptyText: "abc")
        #expect(finalText == "abc")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter LocalASRStreamTests/fallbackFinalOnComplete -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
private var lastNonEmptyText = ""
// 收到 partial 时更新 lastNonEmptyText
// isComplete 且未 done：若 lastNonEmptyText 非空 -> onFinalResult；否则 -> onError
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter LocalASRStreamTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/LocalASR.swift Tests/LocalASRStreamTests.swift
git commit -m "fix(local-asr): add completion fallback for missing done event"
```

### Task 4: A2 - LocalASR 握手合法性校验（HTTP 2xx + Content-Type）

**Files:**
- Modify: `Sources/LocalASR.swift`
- Test: `Tests/LocalASRHandshakeTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct LocalASRHandshakeTests {
    @Test("fail fast when response status is not 2xx")
    func rejectNon2xx() {
        let header = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\n"
        #expect(LocalASR._test_validateHandshake(header) == .failure)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter LocalASRHandshakeTests/rejectNon2xx -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
enum HandshakeValidationResult { case success, failure }
// 仅接受 HTTP/1.1 2xx 且 Content-Type 包含 text/event-stream
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter LocalASRHandshakeTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/LocalASR.swift Tests/LocalASRHandshakeTests.swift
git commit -m "fix(local-asr): validate response status and content type before SSE parsing"
```

### Task 5: A3 - stopRecording 全局 watchdog，确保会话收敛

**Files:**
- Modify: `Sources/AppDelegate.swift`
- Test: `Tests/SessionLifecycleTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct SessionLifecycleTests {
    @Test("stopRecording triggers timeout cleanup when no final/error arrives")
    func stopRecordingWatchdog() async {
        let sut = AppDelegate()
        sut._test_beginSession()
        sut._test_stopRecordingForWatchdog()
        try? await Task.sleep(for: .seconds(9))
        #expect(sut._test_isSessionClosed())
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SessionLifecycleTests/stopRecordingWatchdog -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
private var finalWatchdogTask: DispatchWorkItem?
// stopRecording 后启动 8-15s watchdog，超时统一 cleanupAfterError/cleanupAfterFinal
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SessionLifecycleTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/AppDelegate.swift Tests/SessionLifecycleTests.swift
git commit -m "fix(session): add final watchdog to guarantee session closure"
```

### Task 6: A4 - 剪贴板恢复竞态与空剪贴板恢复

**Files:**
- Modify: `Sources/TextInjector.swift`
- Test: `Tests/TextInjectorPasteboardTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
import Cocoa
@testable import VoiceInput

struct TextInjectorPasteboardTests {
    @Test("restore should skip overwrite when user copied new content")
    func restoreRespectsChangeCount() {
        let snap = TextInjector._test_snapshotPasteboard()
        let token = TextInjector._test_writeTempText("voice")
        _ = TextInjector._test_writeTempText("user-new-copy")
        TextInjector._test_restore(snap, token: token)
        #expect(TextInjector._test_currentString() == "user-new-copy")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter TextInjectorPasteboardTests/restoreRespectsChangeCount -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
struct PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    let changeCount: Int
}
// restore 前校验当前 changeCount 是否等于写入时记录值；空 items 也执行 clearContents()
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter TextInjectorPasteboardTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/TextInjector.swift Tests/TextInjectorPasteboardTests.swift
git commit -m "fix(injector): protect pasteboard restore with changeCount and empty-state restore"
```

### Task 7: A3 - sessionId 隔离，阻断旧回调污染

**Files:**
- Modify: `Sources/AppDelegate.swift`
- Create: `Sources/SessionController.swift`
- Test: `Tests/SessionIsolationTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct SessionIsolationTests {
    @Test("stale callback from old session is ignored")
    func staleCallbackIgnored() {
        let sut = SessionController()
        let s1 = sut.beginSession()
        let s2 = sut.beginSession()
        #expect(s1 != s2)
        #expect(!sut.acceptsCallback(for: s1))
        #expect(sut.acceptsCallback(for: s2))
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SessionIsolationTests/staleCallbackIgnored -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
final class SessionController {
    private(set) var currentSessionId = UUID()
    func beginSession() -> UUID { currentSessionId = UUID(); return currentSessionId }
    func acceptsCallback(for id: UUID) -> Bool { id == currentSessionId }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SessionIsolationTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SessionController.swift Sources/AppDelegate.swift Tests/SessionIsolationTests.swift
git commit -m "fix(session): gate callbacks by session id to prevent cross-session contamination"
```

## 波次 2（剩余 P1/P2/P3 + 产品扩展）

### Task 8: A5 - modifier-only hold-to-talk 独立状态机

**Files:**
- Modify: `Sources/HotkeyManager.swift`
- Test: `Tests/HotkeyManagerModifierOnlyTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
import Cocoa
@testable import VoiceInput

struct HotkeyManagerModifierOnlyTests {
    @Test("modifier-only hold does not stop immediately on flagsChanged noise")
    func modifierOnlyHoldStateMachine() {
        let sut = HotkeyManager()
        #expect(sut._test_modifierOnlyShouldStop(current: .maskAlternate, target: .maskAlternate) == false)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter HotkeyManagerModifierOnlyTests/modifierOnlyHoldStateMachine -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
private enum ModifierOnlyState { case idle, armed, recording }
// 为 keyCode == -1 单独维护状态，不复用普通 keyDown/keyUp 分支
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter HotkeyManagerModifierOnlyTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/HotkeyManager.swift Tests/HotkeyManagerModifierOnlyTests.swift
git commit -m "fix(hotkey): add dedicated state machine for modifier-only hold-to-talk"
```

### Task 9: A6 - LLM HTTP 状态码分支 + 可执行错误提示

**Files:**
- Modify: `Sources/LLMPostProcessor.swift`
- Modify: `Sources/OverlayPanel.swift`
- Test: `Tests/LLMPostProcessorHTTPTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct LLMPostProcessorHTTPTests {
    @Test("returns actionable message for 429")
    func status429Message() {
        let msg = LLMPostProcessor._test_mapHTTPStatus(429)
        #expect(msg.contains("稍后重试"))
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter LLMPostProcessorHTTPTests/status429Message -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
static func mapHTTPStatus(_ code: Int) -> String {
    switch code {
    case 401: return "LLM 鉴权失败，请检查 API Key"
    case 429: return "LLM 请求过快，请稍后重试或切换引擎"
    case 500...599: return "LLM 服务异常，请稍后重试或切换本地引擎"
    default: return "LLM 请求失败 (HTTP \(code))"
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter LLMPostProcessorHTTPTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/LLMPostProcessor.swift Sources/OverlayPanel.swift Tests/LLMPostProcessorHTTPTests.swift
git commit -m "fix(llm): classify http status codes with actionable fallback guidance"
```

### Task 10: A6 - Keychain 错误可见化（Result + OSStatus）

**Files:**
- Modify: `Sources/KeychainHelper.swift`
- Modify: `Sources/AppDelegate.swift`
- Test: `Tests/KeychainHelperTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct KeychainHelperTests {
    @Test("save returns failure with status when SecItemAdd fails")
    func keychainSaveFailure() {
        let result = KeychainHelper._test_saveResult(key: "k", value: "v", forceStatus: errSecAuthFailed)
        switch result {
        case .failure(let status): #expect(status == errSecAuthFailed)
        default: #expect(Bool(false))
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter KeychainHelperTests/keychainSaveFailure -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
enum KeychainError: Error { case osStatus(OSStatus) }
static func saveResult(key: String, value: String) -> Result<Void, KeychainError>
static func loadResult(key: String) -> Result<String?, KeychainError>
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter KeychainHelperTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/KeychainHelper.swift Sources/AppDelegate.swift Tests/KeychainHelperTests.swift
git commit -m "fix(keychain): return Result with OSStatus and surface errors to ui"
```

### Task 11: A4 - 注入前预览与撤销上次注入

**Files:**
- Modify: `Sources/InlineTextInjector.swift`
- Modify: `Sources/TextInjector.swift`
- Modify: `Sources/AppDelegate.swift`
- Test: `Tests/InlineInjectorPreviewTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct InlineInjectorPreviewTests {
    @Test("undo last injection restores previous text state")
    func undoInjection() {
        let sut = InlineTextInjector()
        sut._test_setCurrentText("before")
        sut._test_finalize("after")
        sut.undoLastInjection()
        #expect(sut._test_currentText() == "before")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter InlineInjectorPreviewTests/undoInjection -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
private var lastCommittedText: String = ""
func undoLastInjection() { update(to: lastCommittedText) }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter InlineInjectorPreviewTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/InlineTextInjector.swift Sources/TextInjector.swift Sources/AppDelegate.swift Tests/InlineInjectorPreviewTests.swift
git commit -m "feat(injector): add pre-injection preview toggle and undo last injection"
```

### Task 12: A5 - 首次引导向导 + 热键配置增强

**Files:**
- Create: `Sources/OnboardingCoordinator.swift`
- Modify: `Sources/HotkeyRecorderView.swift`
- Modify: `Sources/AppDelegate.swift`
- Test: `Tests/OnboardingCoordinatorTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct OnboardingCoordinatorTests {
    @Test("wizard blocks finish when hotkey not recorded")
    func wizardRequiresHotkey() {
        let sut = OnboardingCoordinator()
        sut.permissionGranted = true
        sut.providerConnected = true
        sut.hotkeyRecorded = false
        #expect(!sut.canFinish)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter OnboardingCoordinatorTests/wizardRequiresHotkey -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
final class OnboardingCoordinator {
    var permissionGranted = false
    var providerConnected = false
    var hotkeyRecorded = false
    var canFinish: Bool { permissionGranted && providerConnected && hotkeyRecorded }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter OnboardingCoordinatorTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/OnboardingCoordinator.swift Sources/HotkeyRecorderView.swift Sources/AppDelegate.swift Tests/OnboardingCoordinatorTests.swift
git commit -m "feat(onboarding): add first-run wizard and stricter hotkey configuration validation"
```

### Task 13: A6 - 按应用配置档案 + 自动降级 + 隐私语义修正 + RuntimeTuning

**Files:**
- Create: `Sources/AppProfileStore.swift`
- Create: `Sources/RuntimeTuning.swift`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/HistoryLogger.swift`
- Test: `Tests/AppProfileStoreTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct AppProfileStoreTests {
    @Test("profile-specific mode overrides global mode")
    func profileOverride() {
        let store = AppProfileStore()
        store.saveProfile(bundleId: "com.test.app", profile: .init(inlineMode: false, llmEnabled: false, historyEnabled: false))
        let p = store.profile(for: "com.test.app")
        #expect(p?.inlineMode == false)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppProfileStoreTests/profileOverride -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
struct AppProfile: Codable, Equatable {
    var inlineMode: Bool
    var llmEnabled: Bool
    var historyEnabled: Bool
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AppProfileStoreTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/AppProfileStore.swift Sources/RuntimeTuning.swift Sources/AppDelegate.swift Sources/HistoryLogger.swift Tests/AppProfileStoreTests.swift
git commit -m "feat(settings): add per-app profiles, runtime tuning, and explicit privacy semantics"
```

### Task 14: A6 + A3 - 健康面板与统一状态模型（录音/识别/后处理/完成/失败）

**Files:**
- Create: `Sources/HealthMonitor.swift`
- Modify: `Sources/OverlayPanel.swift`
- Modify: `Sources/AppDelegate.swift`
- Test: `Tests/HealthMonitorTests.swift` (Create)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct HealthMonitorTests {
    @Test("failure rate and fallback rate are tracked")
    func trackRates() {
        let sut = HealthMonitor()
        sut.recordSuccess(latencyMs: 120)
        sut.recordFailure(reason: "429")
        sut.recordFallback()
        #expect(sut.failureRate > 0)
        #expect(sut.fallbackRate > 0)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter HealthMonitorTests/trackRates -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
final class HealthMonitor {
    private(set) var total = 0
    private(set) var failures = 0
    private(set) var fallbacks = 0
    var failureRate: Double { total == 0 ? 0 : Double(failures) / Double(total) }
    var fallbackRate: Double { total == 0 ? 0 : Double(fallbacks) / Double(total) }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter HealthMonitorTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/HealthMonitor.swift Sources/OverlayPanel.swift Sources/AppDelegate.swift Tests/HealthMonitorTests.swift
git commit -m "feat(observability): add health panel metrics and unified runtime status model"
```

### Task 15: A1 + A2 - LocalASR 协议语义统一（chunked 与长度帧二选一）

**Files:**
- Modify: `Sources/LocalASR.swift`
- Test: `Tests/LocalASRProtocolTests.swift` (Create)
- Docs: `README.md` (if protocol note exists)

**Step 1: Write the failing test**

```swift
import Testing
@testable import VoiceInput

struct LocalASRProtocolTests {
    @Test("audio framing matches declared transport protocol")
    func protocolConsistency() {
        let sut = LocalASR(host: "127.0.0.1", port: 9000)
        #expect(sut._test_protocolConsistencyCheck())
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter LocalASRProtocolTests/protocolConsistency -v`  
Expected: FAIL

**Step 3: Write minimal implementation**

```swift
// 方案固定为：去掉 Transfer-Encoding: chunked，保留自定义 4-byte length frame
// 或相反；必须只保留一种语义并保持请求头/帧格式一致
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter LocalASRProtocolTests -v`  
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/LocalASR.swift Tests/LocalASRProtocolTests.swift README.md
git commit -m "refactor(local-asr): unify transport protocol semantics"
```

## 波次 3（6 并行验收代理）

### Task 16: V1-V6 并行验收执行

**Files:**
- Modify: `docs/plans/2026-03-03-voiceinput-full-remediation-qa-report.md` (Create)
- Test: `Tests/*` (no ownership change, only验证)

**Step 1: Write the failing test**

```swift
// 本任务是验收执行，不新增功能测试代码。
// 失败定义：任一验收项未通过即标记失败。
```

**Step 2: Run test to verify it fails**

Run: `swift test -v`  
Expected: 若有回归则 FAIL，并记录到 qa report

**Step 3: Write minimal implementation**

```text
创建 QA 报告模板，按 V1-V6 记录：
- 验收范围
- 结果（PASS/FAIL）
- 证据（命令、日志、截图路径）
- 阻断级别
```

**Step 4: Run test to verify it passes**

Run: `swift test -v`  
Expected: PASS（并行验收全部通过）

**Step 5: Commit**

```bash
git add docs/plans/2026-03-03-voiceinput-full-remediation-qa-report.md
git commit -m "test(qa): add parallel verification report for v1-v6 gates"
```

### Task 17: 发布前构建与签名

**Files:**
- Modify: `docs/plans/2026-03-03-voiceinput-full-remediation-release-checklist.md` (Create)
- Modify: `VoiceInput.entitlements` (only if signing requires adjustment)

**Step 1: Write the failing test**

```bash
# 构建与签名准入失败示例：缺失签名身份
test -n "$SIGNING_IDENTITY"
```

**Step 2: Run test to verify it fails**

Run: `test -n "$SIGNING_IDENTITY" && echo OK || echo MISSING`  
Expected: MISSING（若环境未配置）

**Step 3: Write minimal implementation**

```bash
swift build -c release
codesign --force --sign "$SIGNING_IDENTITY" \
  --entitlements VoiceInput.entitlements \
  --options runtime \
  .build/release/VoiceInput
```

**Step 4: Run test to verify it passes**

Run: `codesign --verify --verbose=2 .build/release/VoiceInput && spctl --assess --type execute --verbose=4 .build/release/VoiceInput`  
Expected: PASS（verify/assess 通过）

**Step 5: Commit**

```bash
git add docs/plans/2026-03-03-voiceinput-full-remediation-release-checklist.md VoiceInput.entitlements
git commit -m "build(release): verify signed release artifact and checklist"
```

## 并行编排建议（执行时）

1. 波次 1 并行发给 A1/A2/A3/A4/A5/A6：Task 1-7（其中 A5/A6 可先接入测试脚手架，不改主链路行为）。  
2. 波次 2 并行发给 A1/A2/A3/A4/A5/A6：Task 8-15。  
3. 波次 3 并行发给 V1-V6：Task 16。  
4. 全绿后由主代理执行 Task 17。  

## 最终完成定义

1. `swift test -v` 全量通过。  
2. QA 报告 V1-V6 均 PASS。  
3. 会话闭环、注入安全、协议一致性、降级策略、健康面板可在手工流程复现。  
4. release 签名验证命令通过并产出 checklist。  

---

Plan complete and saved to `docs/plans/2026-03-03-voiceinput-full-remediation-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
