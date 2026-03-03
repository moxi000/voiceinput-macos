# VoiceInput 全量修复与扩展设计（方案 A）

## 1. 背景与目标

本轮目标是一次性完成以下内容：

1. 修复已识别的 15 个工程问题（P0/P1/P2/P3）。
2. 落地产品经理提出的 8 项 UI 与功能扩展。
3. 在全部验收通过后，执行最终构建与签名。

核心成功标准：

1. 录音会话必须稳定闭环：每次会话最终进入 `final`、`error` 或 `timeout`，不可悬挂。
2. 不允许旧会话异步回调污染新会话。
3. 协议解析、剪贴板恢复、热键状态机、LLM 错误分支均有测试覆盖。
4. 发布前验收全部通过后才允许签名产物输出。

## 2. 设计约束

1. 执行模型：`6 个实施子代理并行` + `6 个验收子代理并行`。
2. 顺序约束：先波次 1（P0+关键 P1），后波次 2（剩余项与扩展），最后波次 3（验收）。
3. 质量约束：改动必须同步补测试，不允许“代码先改完再补”。
4. 发布约束：任一 P0/P1 回归失败即阻断构建签名。
5. 文件冲突约束：共享文件以所有权机制合并，`AppDelegate.swift` 由会话控制代理主导整合。

## 3. 总体架构设计

### 3.1 会话隔离主线

1. 每次录音创建 `sessionId`。
2. 所有异步回调（ASR partial/final/error、LLM completion、watchdog、注入）先校验 `sessionId`。
3. 会话结束后统一清理回调与状态，禁止旧回调继续生效。

### 3.2 稳定性主线

1. `VolcengineASR` 二进制解析统一改为安全字节解码，移除潜在未对齐读取。
2. `LocalASR` 在连接结束且未收到 `done` 时，执行 final/error 兜底。
3. `AppDelegate.stopRecording` 增加全局 `final watchdog`（8-15s）确保会话收敛。
4. `TextInjector` 增加 `changeCount` 竞争保护并支持空剪贴板正确恢复。

### 3.3 体验与可观测性主线

1. 统一状态模型：录音中、识别中、后处理中、完成、失败（失败态带 CTA）。
2. 增加自动降级（云失败回本地/本地失败回云，受配置控制）并显式提示。
3. 增加健康面板：延迟、失败率、回退率、最近错误。
4. 设置中心改为单窗口异步反馈，减少阻塞弹窗。

## 4. 并行实施拆分（6 子代理）

### A1 协议解析代理

职责：

1. 修复 Volcengine 安全解码（P0）。
2. 修复 definite 文本重复累计（P1）。
3. 推进 LocalASR 协议语义统一（P2）。

文件：

1. `Sources/VolcengineASR.swift`
2. `Sources/LocalASR.swift`（协议统一部分）
3. `Tests/*ASR*`

### A2 本地 ASR 代理

职责：

1. `readSSEData` 连接结束兜底 final/error（P0）。
2. `readUntilHeaderEnd` 严格校验 `HTTP 2xx + Content-Type`（P1）。
3. 补握手与 SSE 异常流测试（P1/P2）。

文件：

1. `Sources/LocalASR.swift`
2. `Tests/*LocalASR*`

### A3 会话控制代理

职责：

1. `stopRecording` watchdog（P0）。
2. `setupOverlayModeCallbacks/setupInlineModeCallbacks` 引入 `sessionId` 隔离（P1）。
3. 初步拆出 `SessionController`（P2，薄封装）。

文件：

1. `Sources/AppDelegate.swift`
2. `Sources/SessionController.swift`（新增）
3. `Tests/*Session*`

### A4 注入与剪贴板代理

职责：

1. `restorePasteboard` 竞态修复与空状态恢复（P0）。
2. 注入前预览（可开关）与撤销上次注入（产品项）。
3. 注入链路并发与恢复测试（P0/P2）。

文件：

1. `Sources/TextInjector.swift`
2. `Sources/InlineTextInjector.swift`
3. `Tests/*Injector*`

### A5 热键与交互代理

职责：

1. modifier-only 独立状态机（P1）。
2. 热键配置增强：禁用、未录入不可保存、冲突检测（产品项）。
3. 首次引导向导（权限检查、连通性测试、快捷键录制、试录）。

文件：

1. `Sources/HotkeyManager.swift`
2. `Sources/HotkeyRecorderView.swift`
3. `Sources/AppDelegate.swift`（入口与流程串接）
4. `Tests/*Hotkey*`

### A6 设置与后处理代理

职责：

1. LLM 正式处理路径补 HTTP 状态分支及可执行提示（P1）。
2. Keychain 返回 `Result/OSStatus` 并上抛 UI（P1）。
3. 设置中心单窗口异步反馈、按应用配置档案、自动降级、健康面板、隐私模式语义修正、`RuntimeTuning`（P2/P3/产品项）。

文件：

1. `Sources/LLMPostProcessor.swift`
2. `Sources/KeychainHelper.swift`
3. `Sources/AppDelegate.swift`
4. `Sources/OverlayPanel.swift`
5. `Sources/HistoryLogger.swift`
6. `Tests/*LLM*`、`Tests/*Settings*`

## 5. 并行验收拆分（6 子代理）

### V1 协议解析验收

1. 验证二进制解码安全性、异常包容错、截断包处理。
2. 验证 Local 握手 fail-fast 规则。

### V2 会话状态机验收

1. 验证 `sessionId` 全链路隔离。
2. 验证 `final/error/timeout` 闭环与 cleanup。

### V3 注入链路验收

1. 验证 `changeCount` 防覆盖。
2. 验证空剪贴板恢复和撤销注入。

### V4 热键行为验收

1. 验证 modifier-only 双击状态机。
2. 验证冲突检测和禁用场景。

### V5 设置与降级验收

1. 验证 LLM 401/429/5xx 提示分支。
2. 验证自动降级策略和按应用配置生效。

### V6 发布前综合验收

1. 完整测试矩阵与关键 UI 流程。
2. 健康面板指标采样正确。
3. 构建与签名前检查清单完整。

## 6. 分阶段执行计划

### 波次 1（高风险先行）

1. 完成全部 P0。
2. 完成“会话污染/错误注入”相关关键 P1。
3. 同步补充最小可用测试集合并跑通。

### 波次 2（扩展与结构优化）

1. 完成剩余 P1/P2/P3。
2. 完成 8 项产品扩展。
3. 扩展回归测试矩阵。

### 波次 3（并行验收）

1. 启动 6 个验收代理并行检查。
2. 任一阻断项失败即回退修复并重验。
3. 全部通过后进入构建签名。

## 7. 阻断与回退机制

阻断条件：

1. 任一 P0/P1 测试失败或复现回归。
2. 会话未闭环或出现跨会话串台。
3. 关键用户流程（录音、识别、注入、失败 CTA）不可用。

回退策略：

1. 仅回退故障代理负责改动，避免全局回滚。
2. 修复后必须重跑对应验收代理与全量关键路径测试。
3. 通过后再恢复后续波次。

## 8. 构建与签名准入条件

1. 单元与集成测试全绿。
2. 并行验收报告 6/6 通过。
3. 版本与签名配置一致（entitlements、证书、bundle 元数据）。
4. 产物可启动并完成一次端到端语音输入验证。

---

本设计文档对应用户确认的方案 A，作为后续 implementation plan 的输入基线。
