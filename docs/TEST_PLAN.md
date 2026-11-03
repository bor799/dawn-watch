# Dawn 真机测试计划（对应 SPEC §8 验证关卡）

前提：装好完整 Xcode → `sudo xcode-select -s /Applications/Xcode.app` → `./logic-check/run.sh` 出 `RESULT: passed=N failed=0` → 打开 `DawnWatch.xcodeproj` 签个人团队 → 真机安装。

每次实验守则：**手表上同时保留一个系统原生闹钟保底（F07），直到 G2 连续通过。**

## T0 · 环境与安装（G0）

| # | 步骤 | 通过条件 | 失败处理 |
|---|---|---|---|
| T0.1 | Xcode 选 Ultra 2，Cmd+R | App 出现在表上、可独立打开、退出后再开正常 | 修签名/开发者模式，不进入下一步 |
| T0.2 | 首页四入口可用 | 呼吸/闹钟/健康/反馈都能进 | — |
| T0.3 | `docs/API_FACTS.md` §7 未核实项逐条确认 | init(delegate:)、state case 名与预期一致 | 按 API_FACTS 预案改代码 |

## T1 · 呼吸训练（G1，F02）

| # | 步骤 | 通过条件 |
|---|---|---|
| T1.1 | 选 4-6、3 分钟，开始 | 圆环随吸/呼涨缩；每相位切换有触觉；文字与秒数同步 |
| T1.2 | 中途按暂停/继续 | 节律从暂停处恢复，不跳段 |
| T1.3 | 4-7-8 模式 | 显示"4 个周期约 76 秒"；有屏息段；到 4 周期自动结束 |
| T1.4 | 训练中手腕放下/屏幕熄灭 | 触觉停止或继续都如实记录（后台不承诺）；回到前台状态正确 |
| T1.5 | 结束按钮 | 立即停止；日志有 breathStart/breathEnd（completed 字段正确） |

通过标准（G1）：3–5 分钟流程顺畅可退出、无不适或误触；否则只调节律与触觉，不加功能。

## T2 · 健康授权与读取（F03）

| # | 步骤 | 通过条件 |
|---|---|---|
| T2.1 | 健康页点"读取健康数据" | 弹出权限框（只读三项）；同意后出现最近 7 晚摘要 |
| T2.2 | 检查样本时间 | 每条显示"采样于 MM-DD HH:mm（N 小时前）"，与手机健康 App 对得上 |
| T2.3 | 拒绝授权路径 | 手表 设置>健康 里拒绝后回 App：不崩溃，显示未授权提示，其余功能正常 |
| T2.4 | 无数据路径 | 新表/未开启睡眠监测：显示"无睡眠记录"，不推断 |

## T3 · Smart Alarm 试响（G2 前哨，F04）

| # | 步骤 | 通过条件 |
|---|---|---|
| T3.1 | 预约 2 分钟试响，立刻回到表盘（App 退后台） | 约 2 分钟后会话自动启动（日志 alarmSessionStarted），再约 45 秒后触觉+系统提醒（alarmFired, trigger=manual_test） |
| T3.2 | 提醒出现时 App 不在前台 | 系统闹钟样式横幅出现；点 Stop 会话失效；点 Open 进 App |
| T3.3 | App 在前台收到提醒 | App 内出现"已提醒"；点反馈保存后 dismiss，会话 invalidate |
| T3.4 | 连做 3 次 | 每次日志链完整：alarmScheduled → alarmSessionStarted → alarmFired → (dismissed/invalidated) |
| T3.5 | 采样探针 | 每个窗口日志 motionWindow 有 samplesCount≈50、p50≈0.2s；缺口率如实记录 |

**D2 · 杀 App 测试（SPEC F05 待验证核心）**：预约 3 分钟试响后，在表盘长按强行关闭 App（或经 Xcode 停止）。观察：会话到点是否重新拉起 App 并触发提醒？日志里 alarmScheduled 与后续事件是否衔接？结果无论好坏都写入实验记录——这决定"被杀进程的预约会话"是否可用，是 G2 的关键未知项。

**D3 · 时区/重复预约**：预约后再次预约（应先失效旧会话）；预约后改时区（记录 deadline 计算是否仍正确）。

## T4 · 明晨完整流程（F05/F08，连续多晚）

1. 睡前：呼吸 3 分钟 → 闹钟页预约 07:30（28 分钟窗口，起点 07:02）。
2. 清晨：观察窗口内日志（motionWindow 每 60 秒一条）与触发（默认 trigger=deadline）。
3. 醒后在反馈页记录困倦/舒适/离床 → 保存（生成 alarmDismissed + feedback）。
4. 连续 7 晚后导出 `experiment.jsonl`（App 支持 clear；导出经 Xcode Devices 容器下载）。

**G2 通过条件**：连续 20 次计划触发（T3 试响 + T4 正式）无漏响。任何一次漏响 → 暂停智能唤醒方向，重构会话处理，不动算法。

**G4 功耗**：对照"戴表无 App 晚" vs "戴表有 App 晚"，比较 `startBattery/endBattery` 与 `sessionDuration`；额外耗电超过个人可接受阈值 → 降采样（10s 窗口→5s）或缩短会话。

**G5 用户价值**（2–4 周交叉）：系统固定闹钟 vs Dawn 截止唤醒 vs（数据充分后）运动候选；比较困倦评分、离床时间、总睡眠不减少。

## 日志字段对照

| 关心的实验问题 | 日志字段 |
|---|---|
| 会话是否按时启动 | alarmScheduled.scheduledStart vs alarmSessionStarted.time |
| 提醒是否真的发生、为何 | alarmFired.triggerReason + note |
| 后台采样是否可用 | motionWindow.samplesCount / p50Interval / p95Interval |
| 缺口 | p95Interval 与 p50 的偏离 |
| 功耗 | startBattery / endBattery / sessionDuration |
| 用户价值 | feedback.sleepiness / outOfBed / comfort |

## 绝对红线

- 触发原因只允许四种字符串；`motion_candidate` 不得在任何 UI/记录中被描述为"识别了浅睡眠"。
- 任何会话错误原样记录 domain#code，不翻译成猜测的含义。
- P1 提前唤醒开关默认关；开启后若睡眠数据缺失/不足，必须等到 deadline。
