import Foundation
import WatchKit
import Combine

/// Smart Alarm 编排层（F04/F05/F07）。
/// 只允许一个预约会话；所有状态变化写入实验日志；任何失败如实上报，
/// 绝不用普通计时器冒充后台闹钟（SPEC §11）。
final class AlarmCoordinator: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case scheduled(start: Date, deadline: Date, kind: AlarmSettings.ScheduleKind)
        case windowRunning(start: Date, deadline: Date, kind: AlarmSettings.ScheduleKind)
        case fired(trigger: ExperimentEvent.WakeTrigger, at: Date)
        case invalidated(reason: String, errorCode: String?)
    }

    @Published private(set) var phase: Phase = .idle
    /// 给 UI 的降级提示（F07：明确告知 + 建议保底）。
    @Published var userNotice: String?

    private let logger: ExperimentLogger
    private let sampler = MotionSampler()
    private var session: WKExtendedRuntimeSession?
    private var plan: WakePolicy.SchedulePlan?
    private var reports: [MotionAnalysis.WindowReport] = []
    private var decisionTimer: Timer?
    private var startBattery: Double?
    private var settings: AlarmSettings
    /// 本会话是否已成功 notifyUser（didInvalidate 时决定要不要给降级提示）。
    private var firedInCurrentSession = false
    /// App 层注入的"睡眠是否充分"提供者（P1 用；nil = 一律视为不充分）。
    var sleepSufficientProvider: (() async -> Bool)?
    private var cachedSleepSufficient = false
    private var allowsEarlyWake = false

    init(logger: ExperimentLogger, settings: AlarmSettings = .load()) {
        self.logger = logger
        self.settings = settings
        super.init()
        sampler.onWindow = { [weak self] report in
            self?.handleWindowReport(report)
        }
        sampler.onError = { [weak self] message in
            self?.logError("motion_sampler", message)
        }
        // 重启恢复：只恢复显示状态。被杀进程的预约会话能否重新交付回调
        // 属未验证行为（TEST_PLAN D2）——不伪造会话对象、不重发 start(at:)，
        // 提示用户系统会话状态未知，保底靠系统闹钟。
        if let kind = settings.lastScheduleKind,
           let start = settings.lastScheduledStart,
           let deadline = settings.lastScheduledDeadline,
           deadline > Date() {
            phase = .scheduled(start: start, deadline: deadline, kind: kind)
            userNotice = "App 曾重启：预约记录仍在；系统会话是否存活未知，请确认系统闹钟保底已设。"
        }
    }

    // MARK: - 排程

    /// 预约明晨唤醒。窗口起点若已过去（现在离截止太近）→ 不动现有预约并提示。
    @discardableResult
    func scheduleMorning(deadlineHourMinute now: Date = Date()) -> Bool {
        settings = AlarmSettings.load()   // 设置页可能刚保存新钟点/开关，禁止用旧快照回写
        let deadline = settings.nextDeadline(after: now)
        guard let plan = WakePolicy.morningPlan(
            deadline: deadline, windowSeconds: settings.windowSeconds, now: now)
        else {
            userNotice = "距截止时刻不足一个完整窗口，未改动现有预约。今晚请用系统闹钟保底。"
            logError("schedule", "窗口起点已过，跳过今日")
            return false
        }
        cancel(notice: nil)
        settings.enabled = true
        settings.lastScheduleKind = .morning
        settings.lastScheduledStart = plan.start
        settings.lastScheduledDeadline = plan.deadline
        settings.save()
        schedule(plan: plan)
        return true
    }

    /// F04 试响：delaySeconds（2–5 分钟）后开始会话，45 秒后提醒。
    @discardableResult
    func scheduleTest(delaySeconds: TimeInterval, now: Date = Date()) -> Bool {
        settings = AlarmSettings.load()   // 同上：避免旧快照回写
        cancel(notice: nil)
        let plan = WakePolicy.testPlan(now: now, delaySeconds: delaySeconds)
        settings.lastScheduleKind = .test
        settings.lastScheduledStart = plan.start
        settings.lastScheduledDeadline = plan.deadline
        settings.save()
        schedule(plan: plan)
        return true
    }

    private func schedule(plan: WakePolicy.SchedulePlan) {
        self.plan = plan
        allowsEarlyWake = plan.kind == .morning && settings.allowsEarlyWake
        reports.removeAll()
        startBattery = nil
        firedInCurrentSession = false
        // 官方文档只记载无参创建 + delegate 属性（init(delegate:) 不存在）。
        // delegate 必须在 start(at:) 之前赋好。
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.session = session
        session.start(at: plan.start)
        phase = .scheduled(start: plan.start, deadline: plan.deadline, kind: plan.kind)
        logger.log(ExperimentEvent(kind: .alarmScheduled)
            .withScheduled(start: plan.start, deadline: plan.deadline))
        userNotice = plan.kind == .test
            ? "已预约试响：\(ExperimentEvent.timeLabel(plan.start)) 前后提醒，保持手表佩戴。"
            : "已预约：\(ExperimentEvent.timeLabel(plan.start)) 进入窗口，\(ExperimentEvent.timeLabel(plan.deadline)) 前提醒。"
    }

    func cancel(notice: String? = nil) {
        if let session {
            session.invalidate()
        }
        teardown(notice: notice)
    }

    // MARK: - 会话生命周期

    private func beginWindowIfNeeded() {
        guard let plan, session?.state == .running else { return }
        sampler.start()
        cachedSleepSufficient = false
        if allowsEarlyWake, let provider = sleepSufficientProvider {
            Task { [weak self] in
                let sufficient = await provider()
                await MainActor.run { [weak self] in self?.cachedSleepSufficient = sufficient }
            }
        }
        startBattery = Self.batteryLevel()
        phase = .windowRunning(start: plan.start, deadline: plan.deadline, kind: plan.kind)
        decisionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        decisionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        evaluate()
    }

    private func handleWindowReport(_ report: MotionAnalysis.WindowReport) {
        guard phase.isWindowRunning else { return }
        reports.append(report)
        var event = ExperimentEvent(kind: .motionWindow)
        event.samplesCount = report.samplesCount
        event.p50Interval = report.p50Interval
        event.p95Interval = report.p95Interval
        event.motionVariability = report.variability
        event.sustainedMotionRatio = report.sustainedMotionRatio
        logger.log(event)
        evaluate()
    }

    /// 决策循环：窗口内每 15 秒 + 每个观察窗口完成时各评估一次。
    private func evaluate() {
        guard let plan, let session, phase.isWindowRunning else { return }
        let decision = WakePolicy.decide(
            now: Date(),
            deadline: plan.deadline,
            sessionExpiration: session.expirationDate ?? plan.expectedExpiration,
            reports: reports,
            sleepSufficient: cachedSleepSufficient,
            allowsEarlyWake: allowsEarlyWake)
        guard decision.shouldFire else { return }
        fire(trigger: mappedTrigger(for: decision.trigger), rationale: decision.rationale)
    }

    private func mappedTrigger(for trigger: ExperimentEvent.WakeTrigger) -> ExperimentEvent.WakeTrigger {
        // 试响会话的"到点"记录为人工测试
        if plan?.kind == .test, trigger == .deadline { return .manualTest }
        return trigger
    }

    private func fire(trigger: ExperimentEvent.WakeTrigger, rationale: String) {
        guard let session, session.state == .running, !phase.isFired else { return }
        session.notifyUser(hapticType: .notification, repeatHandler: { pointer in
            pointer.pointee = .notification
            return 2.0   // 秒；必须 >0 且 ≤60
        })
        firedInCurrentSession = true
        phase = .fired(trigger: trigger, at: Date())
        sampler.stop()
        decisionTimer?.invalidate()
        logger.log(ExperimentEvent(kind: .alarmFired)
            .withTrigger(trigger, rationale: rationale)
            .withBattery(start: startBattery, end: Self.batteryLevel()))
    }

    /// 用户点"起床了/稍后"（App 活跃时必须由 App 失效会话）。
    func dismiss() {
        guard phase.isFired else { return }
        let trigger = phase.triggerValue
        session?.invalidate()
        var event = ExperimentEvent(kind: .alarmDismissed)
        event.triggerReason = trigger
        event.sessionDuration = sessionDuration()
        event.startBattery = startBattery
        event.endBattery = Self.batteryLevel()
        logger.log(event)
        teardown(notice: "记得拉开窗帘、喝水、离床活动 2–5 分钟。")
        // firedInCurrentSession 保持 true：随后到达的失效回调不再弹降级提示
    }

    private func teardown(notice: String?) {
        sampler.stop()
        decisionTimer?.invalidate()
        decisionTimer = nil
        session = nil
        plan = nil
        reports.removeAll()
        phase = .idle
        if let notice { userNotice = notice }
    }

    private func sessionDuration() -> Double? {
        guard let plan else { return nil }
        return Date().timeIntervalSince(plan.start)
    }

    private func logError(_ code: String, _ message: String) {
        var event = ExperimentEvent(kind: .error)
        event.errorCode = code
        event.note = message
        logger.log(event)
    }

    static func batteryLevel() -> Double? {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let level = Double(device.batteryLevel)
        guard level >= 0 else { return nil }   // 未知状态为 -1.0
        return level
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension AlarmCoordinator: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // 身份守卫：旧会话的迟到回调（重预约/取消后仍可能到达）不得碰当前状态
        guard extendedRuntimeSession === session else { return }
        logger.log(ExperimentEvent(kind: .alarmSessionStarted)
            .withBattery(start: Self.batteryLevel(), end: nil))
        beginWindowIfNeeded()
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        guard extendedRuntimeSession === session else { return }
        // 最后兜底：会话将过期但仍未提醒 → 立刻提醒（不能白占会话，F07/§5）
        if !phase.isFired {
            fire(trigger: .sessionExpiring, rationale: "会话即将过期，最后兜底提醒")
        }
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        guard extendedRuntimeSession === session else { return }
        let errorCode = (error as? NSError)?.code.description ?? error.map { "\($0)" }
        var event = ExperimentEvent(kind: .alarmInvalidated)
        event.invalidationReason = "\(reason)"
        event.errorCode = errorCode
        event.sessionDuration = sessionDuration()
        event.startBattery = startBattery
        event.endBattery = Self.batteryLevel()
        logger.log(event)
        // 只有"没响过"的失效才值得警告（F07）；用户主动 cancel/dismiss 的
        // 回调已被身份守卫拦下（那时 self.session 已清空），不会走到这里
        if !firedInCurrentSession {
            userNotice = Self.degradationHint(for: error)
        }
        firedInCurrentSession = false
        teardown(notice: nil)
    }

    /// F07：如实呈现原始错误 + 通用行动指引。
    /// 注意：WKExtendedRuntimeSessionErrorCode 的数字原始值未在文档公开，
    /// 不做数字→含义的臆测映射（SPEC §11：必须返回原始错误）。
    private static func degradationHint(for error: (any Error)?) -> String? {
        if let nsError = error as? NSError {
            return "闹钟会话失效[\(nsError.domain) #\(nsError.code)] \(nsError.localizedDescription)。请检查 设置>通用>后台应用刷新；今晚用系统闹钟保底。"
        }
        return "闹钟会话已结束。今晚请用系统闹钟保底。"
    }
}

// MARK: - Phase 便捷判断

extension AlarmCoordinator.Phase {
    var isWindowRunning: Bool {
        if case .windowRunning = self { return true }
        return false
    }

    var isFired: Bool {
        if case .fired = self { return true }
        return false
    }

    var triggerValue: ExperimentEvent.WakeTrigger? {
        if case .fired(let trigger, _) = self { return trigger }
        return nil
    }
}

extension ExperimentEvent {
    func withScheduled(start: Date, deadline: Date) -> ExperimentEvent {
        var copy = self
        copy.scheduledStart = start
        copy.deadline = deadline
        return copy
    }

    func withTrigger(_ trigger: WakeTrigger, rationale: String) -> ExperimentEvent {
        var copy = self
        copy.triggerReason = trigger
        copy.note = rationale
        return copy
    }

    func withBattery(start: Double?, end: Double?) -> ExperimentEvent {
        var copy = self
        copy.startBattery = start
        copy.endBattery = end
        return copy
    }
}
