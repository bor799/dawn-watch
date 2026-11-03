# Dawn · Apple Watch Ultra 2 睡眠与晨间激活系统

产品方案 / 技术可行性沙盘 / MVP SPEC v0.1  
日期：2026-11-02  
设备：Apple Watch Ultra 2（含 2024 年在售版本）+ 配对 iPhone；开发环境：Mac + Xcode  
阶段：**设计及待验证**（尚未构建、签名、安装或完成真机实测）

## 0. 一页结论

**产品愿景**：让用户通过手腕上低打扰的触觉引导，完成“夜间放松—短时感知—清晨唤醒—晨间激活—反馈改进”的闭环。不是医疗诊断产品，也不宣称识别了真实脑电睡眠分期、保证深睡或治愈失眠。

**第一版目标**：在用户现有 Apple Watch Ultra 2 上安装原生 watchOS App，完成 (1) 前台 4-6/4-7-8 呼吸训练；(2) 授权并读取 Apple Health 睡眠/心率/呼吸频率的**已有记录**；(3) 设置未来一次闹钟，实测 Smart Alarm 后台会话能否按期启动、持续采集短时运动数据并发出系统级触觉提醒；(4) 提供起床后反馈与本地实验日志。

**核心技术抉择**：MVP 首选一个原生 watchOS SwiftUI App，配置 `WKBackgroundModes = alarm`；呼吸练习只在前台运行。Apple Watch 读取历史 HealthKit 数据；Core Motion 仅在清晨短窗口运行。iPhone 端仪表盘、音频集成、ML、云端同步、个体化睡眠模型暂缓。

**为什么不能同时用 Mindfulness 扩展会话？** Apple 文档说明，每个 watchOS App 只能配置一个扩展运行类型（self-care/mindfulness/physical-therapy/alarm）。因此先为 Smart Alarm 保留后台执行模式，呼吸通过普通前台交互完成。腕部屏幕熄灭/应用不再前台时的触觉引导持续性不保证，需实测后确定是否另起 app/设计替代交互。

**产品胜负手**：用户是否更容易、舒服地入睡或起床；使用是否足够省事；安全、可靠、不增加明显耗电。**算法准确率不是第一优先级**。

## 1. 用户场景与产品边界

- 晚间：睡前手表选“呼吸 3 分钟”，按照温和节律放松；结束即停止所有提示，避免整夜干预。
- 夜间：默认 Apple 系统睡眠监测；App 不保持整夜自定义高频传感器采集。
- 早晨：设置如 07:30 最晚起床。短时智能唤醒会话在最后约 28 分钟内运行；先比较系统准时提醒与运动状态提示。睡眠数据不及时则按预定时间唤醒，不凭空推断“浅睡眠”。
- 醒后：可选择“起床了/稍后”，提示拉开窗帘、喝水、离床活动 2–5 分钟、选定音频（V0.1 仅外部打开或提示，不自动控制第三方播客）。
- 反馈：记录是否按时醒、再次入睡、醒后困倦（0–10）、训练舒适度（0–10），逐渐评估价值。

**不做**：呼吸治疗/呼吸异常诊断、无实证“恢复度”评分、原始 PPG/连续 EEG、云端大模型调用、长期录音、整夜传感器常开、假冒 Apple 官方睡眠算法的实时分期。

## 2. Apple 硬件/API 能力矩阵

| 任务 | SDK/系统 | MVP 使用方法 | 限制与不确定性 |
|---|---|---|---|
| 触觉呼吸 | WatchKit `WKInterfaceDevice.current().play(_:)` | 前台定时单次轻触，配合屏幕文字/圆环 | 后台/非活跃通常无效；不可自定义连续振幅；密集播放耗电并可能影响心率采集 |
| 呼吸界面 | SwiftUI | 4-6 为默认；4-7-8 为可选；3/5 分钟定时；暂停/退出 | 自然舒适优先，避免强迫屏息 |
| 睡眠历史 | HealthKit `HKCategoryType(.sleepAnalysis)` | 读取昨晚已写入的 Core/Deep/REM/Awake 及时间戳 | 不等于实时睡眠阶段；读取权限需用户允许；缺失可正常运行 |
| 生理历史 | HealthKit 心率、呼吸频率、HRV（可选） | 查看已有值、采样时间、距离现在多久 | 样本稀疏/延迟；不能假设秒级实时心率、呼吸节律 |
| 运动 | CoreMotion `CMMotionManager` | 智能唤醒窗口内低频或间歇性加速度采样；聚合波动量 | 必须实测后台持续性、功耗、实际采样间隔 |
| Smart Alarm | WatchKit `WKExtendedRuntimeSession` | `start(at:)` 预约、delegate 处理重新启动，`notifyUser` 输出系统触觉提醒 | 最长 30 分钟、最多未来 36 小时预约、一次一个会话、必须在到期前触发提醒 |
| 历史/日志 | App 本地文件（JSONL）/UserDefaults | 存配置和事件，不上传健康数据 | 不能把 UserDefaults 当高频日志数据库 |
| iPhone 同步 | WatchConnectivity `WCSession` | V0.2 再做历史摘要发送 | 后台传输不保证立即送达；不能用于唤醒实时决策 |

**硬约束细节**：`notifyUser(hapticType:repeatHandler:)` 需要对已使用 `start(at:)` 预约且正在 running 的会话调用。重复间隔必须 >0 且 ≤60 秒；调用后系统持续提醒直至会话被处理或失效。若会话运行期间未发出提醒，watchOS 可能警告用户并建议关闭未来会话。可用系统级触觉类型而不是自定义振动波形。Apple 普通 `play(_:)` 不等同后台智能闹钟提醒。

## 3. 最小技术架构

```text
Apple Watch Ultra 2 (watchOS SwiftUI)
├── HomeView             ：呼吸 / 智能闹钟 / 数据 / 反馈
├── BreathSessionView    ：4-6 和 4-7-8 训练，暂停/结束
├── AlarmSetupView       ：设置最终时间、提前窗口、试响
├── HealthSummaryView    ：展示已读取历史样本和采样时间
├── MorningFeedbackView  ：醒后困倦评分、是否离床
├── BreathEngine         ：明确状态机与本地时间调度
├── HealthStore          ：授权、样本读取、异常/缺失处理
├── MotionSampler        ：仅在唤醒会话中低功耗采样
├── AlarmCoordinator     ：预约/启动/恢复/提醒/过期处理
├── WakePolicy           ：固定截止模式 + 待验证的运动触发模式
└── LocalExperimentLog   ：本地事件和耗电日志

Future iPhone Companion (不在 V0.1)
└── WatchConnectivity -> 分析/可视化/长期模型/音频设置
```

**状态机**：`IDLE → BREATHING → FINISHED`；`ALARM_SCHEDULED → WINDOW_RUNNING → ALARM_FIRED → DISMISSED/INVALIDATED`；`SESSION_ERROR/NO_DATA → DEFAULT_ALARM_POLICY`。必须把 App 被杀、后台启动、时区变化、重复预约、已存在会话和权限失效纳入测试。

## 4. MVP P0 功能清单（第一版必须全部做到）

| ID | 功能 | 操作与交互 | 验收标准 |
|---|---|---|---|
| F01 | 手表原生安装 | 通过 Xcode 将 watchOS App 部署到个人 Ultra 2 | 可从手表独立打开；退出后可再次打开 |
| F02 | 两种呼吸训练 | 默认 4 秒吸+6 秒呼，3 分钟；可选 4-7-8，初学限 4 个周期；可暂停退出 | 视觉节奏正确；前台触觉能响应；按结束会停止 |
| F03 | 健康授权读取 | 申请 HealthKit 只读权限；读取最近 7 夜睡眠与心率/呼吸样本 | 正确显示最近样本及**样本时间**；拒绝授权不崩溃 |
| F04 | 试验闹钟 | 可设 2–5 分钟后触发的 Smart Alarm 测试会话 | 真实手表后台可启动，系统触觉提醒可见；成功/失败都记录日志 |
| F05 | 明日唤醒 | 用户设置 07:30 等截止时刻，预约约 28 分钟窗口 | 后台会话状态及触发原因完整可追踪；尽可能到最终时刻前提醒 |
| F06 | 运动采样探针 | 会话内低频或间歇读取加速度；仅计算窗口级运动波动 | 导出或本地查看样本数量、采样间隔、缺口、耗电 |
| F07 | 安全降级 | 缺失 HealthKit / Motion / 会话异常时不做错误早醒 | 用户得到明确提示；测试期独立设置 Apple 原生闹钟保底 |
| F08 | 晨间反馈 | 记录困倦 0–10、离床/再次入睡、训练主观舒适度 | 记录在本地并可查看最近 7 条 |

**重要**：P0 的“智能”主要是成功安排并执行清晨窗口、获取可靠的实际数据。**不要求**准确识别 Core/REM，也不要求第一版能依赖运动信号自动提前唤醒。没有可靠证据时默认到截止时间再提醒。呼吸与闹钟必须在同一项目内能工作，但不要求“躺着关屏继续呼吸触觉”已经解决。

## 5. P1 运动触发的谨慎规则（仅在 P0 数据确认可用后打开）

1. 进入预定窗口后观察首段运动作为同一晚的个体基线。
2. 每隔一段时间收集短批次加速度，聚合 `motion_variability` 与持续运动比例，而不是把单次翻身当作“醒来”。采样如 5 Hz、每 60 秒观察 10 秒属于**实验参数**，非系统保证。
3. 只有在用户**明确允许提前唤醒**、且睡眠时间已充分/没有明显睡眠不足证据、信号持续满足条件时才触发；缺失记录一律延后至截止时间。
4. 任一时刻均不得晚于会话到期安全余量，建议使用 `expirationDate - 1~2 分钟` 作为最后触发门槛。实际截止时间的预约方式需让会话覆盖最后时刻且留出安全余量。
5. 记录每次触发 `reason=motion_candidate/deadline/session_expiring/manual_test`，严禁将 `motion_candidate` 标为“已识别浅睡眠”。

这里不建议用 `HKWorkoutSession` 冒充睡眠监测以获取心率实时数据；它有 workout 语义与日志副作用，且可能额外耗电。第一版用运动数据验证实时性，并把 HealthKit 心率列为**可用性测试**；没有及时样本就不参与决策。

## 6. 性能、功耗与安全策略

- 夜间非窗口：只读系统已有 HealthKit 数据，不运行用户自定义的整夜高速传感器服务。
- 智能唤醒窗口：不超过系统允许的 30 分钟，传感器间歇采样、减少高频界面刷新，不发网络请求。
- 心率和触觉：苹果说明普通触觉播放可能暂停 HealthKit 正在进行的心率采集；避免一边高频触觉一边声称心率连续可靠。
- 本地优先：原始运动片段和健康日志保留在设备，允许清空，不接第三方 analytics。
- 安全：关闭“智能提前”不影响基本闹钟测试；不要冒充医疗提醒。P0 期间 Apple 原生闹钟一定要作为独立保底。
- 计量：每次记录 `startBattery`, `endBattery`, `session_duration`, `samples_count`, `P50/P95 actual_interval`, `error_code`, `triggerReason`，与同等佩戴的无 App 实验夜做对照。

## 7. 实施顺序：可以直接下发给 Coding Agent

### Sprint 0：开发环境/快速证明

1. 在 Mac 安装兼容当前 iPhone/watchOS 的 Xcode，iPhone 与手表配对，开启开发者模式，配置个人团队签名、Watch Target 和部署设备。
2. 创建 Native watchOS SwiftUI 项目 `DawnWatch`，在真机显示首页（呼吸/闹钟/健康/日志）。不先搭后端。
3. 配置 `HealthKit` 能力与只读用途说明，先证明能读取 7 晚历史，不要编造实时性。
4. 配置 Watch Background Modes 为 `alarm`；不用 `mindfulness` 作为同 App 的另一扩展模式。

### Sprint 1：能用的呼吸 + 系统能力

5. 实现 4-6 呼吸状态机（吸/呼/暂停/结束），前台触觉 + 屏幕提示，3/5 分钟控制。4-7-8 作为第二预设。
6. 实现授权页、睡眠/心率/呼吸率历史摘要，显示记录时间和数据缺失状态。
7. 实现本地 JSONL 日志和人工反馈页。

### Sprint 2：智能闹钟真机 Proof of Capability

8. 实现 `AlarmCoordinator`：只允许一个预约会话，持久化预约信息，使用 `start(at:)`，处理自动启动、恢复 delegate、到期与失败。
9. 设置短间隔（2–5 分钟）试响：真实手表后台触发 `notifyUser`，人工确认提醒行为和页面。
10. 实现 `MotionSampler`，验证会话进入后台后能否按指定频率获得有效数据；输出 sample timestamp/age 和错误原因。
11. 实现最晚时间提醒、会话过期安全余量；原生闹钟测试期保底。

### Sprint 3：用户体验与实验

12. 尝试完整睡前 + 清晨流程；晨间反馈输入。
13. 收集若干晚日志：包括有 App 和无 App 的耗电差异，以及信号、提醒准确性。
14. 只有完成可靠性和数据可用性验证后，再添加保守运动触发规则，并与固定闹钟、渐进触觉对照。

## 8. 验证关卡 / 决策门槛

| Gate | 问题 | 建议通过条件 | 不通过处理 |
|---|---|---|---|
| G0 环境 | 能安装到 Ultra 2 吗？ | 真机运行、签名和权限可正常工作 | 先修复工程，不做算法 |
| G1 交互 | 呼吸体验有用吗？ | 3–5 分钟顺畅、可退出、无明显不适或误触 | 仅调整节律与触觉，不加功能 |
| G2 后台 | Smart Alarm 真的按时触发吗？ | 连续 20 次计划触发测试**目标**无漏响（非可靠性保证） | 暂停智能唤醒方向，优先重构系统会话 |
| G3 数据 | 能抓到可用短时运动信号吗？ | 记录时间戳、缺失率和真实频率；证明后台可用 | 改成时间/渐进触觉唤醒，保留长期分析 |
| G4 功耗 | 是否值得持续佩戴？ | 智能窗口额外耗电可接受，具体阈值由个人基线实测确定 | 降采样、缩短会话、放弃高频信号 |
| G5 用户价值 | 比原生闹钟改善了吗？ | A/B 观察困倦评分、实际离床时间、总睡眠时长不减少 | 停止复杂建模，改进体验或停止方向 |

实验方法：先 7 夜可行性测试；之后 2–4 周交叉比较“系统固定闹钟 / 渐进触觉 / 运动触发”（最后一种仅在数据足够时）。不要混淆技术成功、睡眠阶段预测准确、真实健康收益三种证据。

## 9. MVP 绝对不实现

- 实时睡眠四阶段分类或医学级恢复评分。
- 长期持续播放声音/采集麦克风进行睡眠监测。
- 自定义实时大模型推理、后端、账户体系或订阅。
- 自动控制 Apple Music / Spotify / 播客等第三方 App（可后续提供快捷方式）。
- 复杂睡眠建议、药物建议、呼吸治疗方案。
- 依赖手机在线才会触发的闹钟。

## 10. 推荐代码结构

```text
Dawn/
  README.md
  docs/
    SPEC.md
    TEST_PLAN.md
  DawnWatch/
    DawnWatchApp.swift
    Views/
      HomeView.swift
      BreathSessionView.swift
      AlarmSetupView.swift
      HealthSummaryView.swift
      MorningFeedbackView.swift
    Services/
      BreathEngine.swift
      HealthStore.swift
      MotionSampler.swift
      AlarmCoordinator.swift
      WakePolicy.swift
      ExperimentLogger.swift
    Models/
      BreathPattern.swift
      AlarmSettings.swift
      ExperimentEvent.swift
```

先单 watchOS target。添加 iPhone Companion 时再拆共享 Models/、Data/ 与 WatchConnectivity。不要为“以后扩展到云端”提前引入服务器或微服务。

## 11. 交给 Coding Agent 的执行约束

> 基于本 SPEC 创建可由 Xcode 打开的原生 watchOS SwiftUI 项目，目标设备 Apple Watch Ultra 2。优先最小可安装可运行工程，完成前台 4-6 呼吸、HealthKit 已有数据只读、Smart Alarm 预约与系统触觉试响、本地实验日志。明确标注每一项 SDK API 的可用性与权限配置；不能假定睡眠阶段或 HRV 能实时读取。每实现一个模块就给出真机操作步骤与验收方式。**没有 Mac/Xcode/真机时，不要声称已编译、安装、测试或唤醒成功。** 若 `WKExtendedRuntimeSession` 自动启动/授权受设备或签名限制，必须返回原始错误和日志，不得偷偷改成普通计时器冒充后台闹钟。先不要开发 iPhone 配套、云端服务或 ML 模型。

## 官方参考资料

1. [Apple — Using extended runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions)
2. [Apple — WKExtendedRuntimeSession](https://developer.apple.com/documentation/watchkit/wkextendedruntimesession/)
3. [Apple — notifyUser(hapticType:repeatHandler:)](https://developer.apple.com/documentation/watchkit/wkextendedruntimesession/notifyuser%28haptictype%3Arepeathandler%3A%29)
4. [Apple — WKBackgroundModes](https://developer.apple.com/documentation/BundleResources/Information-Property-List/WKBackgroundModes)
5. [Apple — WKInterfaceDevice.play(_:) limitations](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play%28_%3A%29)
6. [Apple — Core Motion CMMotionManager](https://developer.apple.com/documentation/coremotion/cmmotionmanager)
7. [Apple — HealthKit sleep stages](https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis)
8. [Apple — HealthKit overview](https://developer.apple.com/documentation/healthkit)
9. [Apple — Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
10. [Apple — Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/wcsession)
