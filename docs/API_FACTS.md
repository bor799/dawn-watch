# API 事实清单（2026-11-03 从 Apple 官方文档 JSON 端点核实）

来源：`https://developer.apple.com/tutorials/data/documentation/...`（文档正文 JSON，非模型记忆）。
用途：AlarmCoordinator / MotionSampler 的每个 WatchKit 调用都以本清单为准；有出入时以官方文档为准并更新本文件。

## 1. WKExtendedRuntimeSession.notifyUser（已核实）

```swift
// watchOS 6.0+
func notifyUser(hapticType: WKHapticType,
                repeatHandler: ((UnsafeMutablePointer<WKHapticType>) -> TimeInterval)? = nil)
```

官方原文摘录：
- "Play a repeating haptic alert."
- "For schedulable sessions such as smart alarms, call this method during the session to alert the user."
- "If the app isn't active, the system also displays a system alarm alert on the watch."（用户可点 Stop 失效会话 / Open 激活 App）
- "If the app is active, the app must invalidate the session by calling its `invalidate()` method."
- **"Only call this method on a schedulable session that's running: you must schedule the session using the `start(at:)` method, and the session's state must equal `WKExtendedRuntimeSessionState.running`. During a smart alarm session, your app must call this method before the session expires."**
- repeatHandler 返回下一个重复间隔，**必须 >0.0 且 ≤60.0**；nil 时默认 3.0 秒。可通过 out 参数改下一次的 haptic 类型。

→ 实现对应：`AlarmCoordinator.fire()` 只在 `session.state == .running` 时调用；间隔 2.0 秒；App 活跃时由 `dismiss()` 调 `invalidate()`。

## 2. WKExtendedRuntimeSession 成员（已核实）

| 成员 | 签名 |
|---|---|
| 启动 | `func start()` / `func start(at: Date)`（预约未来会话） |
| 停止 | `func invalidate()` |
| 状态 | `var state: WKExtendedRuntimeSessionState` |
| 过期 | `var expirationDate: Date?` |
| 代理 | `var delegate: (any WKExtendedRuntimeSessionDelegate)?` |
| 自动启动授权 | `class func requestAutoLaunchAuthorizationStatus(completion:)` |

## 3. WKExtendedRuntimeSessionDelegate（已核实，全部三个方法）

```swift
func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession)
func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession)
func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                            error: (any Error)?)
```

注意：**没有** `didExpire`，只有 `willExpire`。错误经由 `didInvalidateWith:error:` 交付。

## 4. WKExtendedRuntimeSessionErrorCode（已核实，原始数值未公开）

`unknown` / `scheduledTooFarInAdvance` / `mustBeActiveToStartOrSchedule` / `notYetStarted` / `exceededResourceLimits` / `barDisabled` / `notApprovedToStartSession` / `notApprovedToSchedule` / `mustBeActiveToPrompt` / `unsupportedSessionType`

→ 数字 rawValue 文档未公布，`degradationHint` 不做数字→含义映射，原样呈现 domain#code + 通用行动建议（SPEC §11）。

## 5. WKBackgroundModes（已核实）

- 允许值含 `"alarm"`（"Enables extended runtime sessions for smart alarms."）
- **每个 watchOS App 只能配置一个 extended-runtime 模式**（self-care / mindfulness / physical-therapy / alarm 四选一）→ 呼吸只能前台做，SPEC §0 的抉择正确。
- → Info.plist：`WKBackgroundModes = ["alarm"]`。

## 6. 会话硬约束（文档核实 + SPEC 沙盘假设）

- 最长 30 分钟 → `WakePolicy.Config.maxSessionDuration = 1800`
- notifyUser 重复间隔 (0, 60] → 实现取 2.0
- 会话运行期间必须至少 notifyUser 一次，否则系统可能警告用户
- 一次只能有一个会话；新预约前先 invalidate 旧的（`AlarmCoordinator.cancel`）
- SPEC 假设的"最多提前 36 小时预约"未在本次抓取中核实到具体数字——超远预约的错误路径已按 `scheduledTooFarInAdvance` 原样记录

## 7. 未核实项（显式清单，真机验证时确认）

1. ~~`WKExtendedRuntimeSession(delegate:)` 初始化器~~ **已解决（2026-11-03 评审核实）**：文档 JSON 无任何初始化器记载，真实开源智能闹钟 App（Silent Bell 等）使用 `WKExtendedRuntimeSession()` + `session.delegate = self`。代码已改为该模式（delegate 必须在 `start(at:)` 之前赋好）。
2. `WKExtendedRuntimeSessionState` 的 case 名（`none` / `running`）——真机确认。
3. **App 被系统杀死后，预约会话到期时系统如何重新交付 delegate 回调**——文档未明说；TEST_PLAN D2 专门测这个（这是 SPEC F05 明确要求"待验证"的核心问题）。另：`invalidate()` 的失效回调确实会异步送达（"when a session fails to start and when a session stops running"，错误码 `notYetStarted` 即为此设计）——因此代码在全部三个 delegate 方法加了会话身份守卫，防止重预约后被旧会话的迟到回调摧毁新状态。
4. HealthKit `HKCategoryValueSleepAnalysis` 各 case 的 watchOS 9 可用性（asleepCore/Deep/REM 为 watchOS 9 / iOS 16 新命名，部署目标 9.0 应覆盖，真机确认）。
