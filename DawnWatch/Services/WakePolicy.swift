import Foundation

/// 唤醒决策层（纯函数，可离线测试）。
/// 原则（SPEC §5）：没有可靠证据时一律等到截止时刻；
/// 运动候选只是"运动候选"，绝不表述为"已识别浅睡眠"。
enum WakePolicy {
    struct Config: Equatable, Codable {
        /// 系统硬限制：alarm 会话最长 30 分钟。
        var maxSessionDuration: TimeInterval = 30 * 60
        /// 到期安全余量：必须在 expirationDate 前发出 notifyUser，
        /// 留出余量做最后兜底触发。
        var safetyMargin: TimeInterval = 90
        /// 预约最早可以提前多少秒安排（start(at:) 不接受过去时间）。
        var minimumLead: TimeInterval = 60

        // 运动候选判据（实验参数，非系统保证；全部满足才允许提前唤醒）
        var baselineWindowCount = 2                 // 前几个窗口算个体基线
        var consecutiveCandidateWindows = 2         // 需连续几个窗口超判据
        var variabilityFactorOverBaseline: Double = 2.0
        /// 基线为零（完全静止）时的绝对门槛：否则 ×2.0 判据退化为 ≥0，
        /// 噪声级波动也会被当作"超基线"。
        var minimumAbsoluteVariability: Double = 0.02
        var sustainedMotionRatioThreshold: Double = 0.35
        var minimumSleepMinutes: Double = 6 * 60    // 睡眠不足则绝不提前

        static let `default` = Config()
    }

    struct SchedulePlan: Equatable, Codable {
        var kind: AlarmSettings.ScheduleKind
        var start: Date
        var deadline: Date
        /// 预计过期时间 = start + 30min（运行时以 session.expirationDate 为准）。
        var expectedExpiration: Date
    }

    struct Decision: Equatable {
        var shouldFire: Bool
        var trigger: ExperimentEvent.WakeTrigger
        var rationale: String
    }

    // MARK: - 排程

    /// 明晨唤醒排程：deadline - 窗口 = 会话开始。
    /// 窗口被钳制到 (30min - 2×安全余量)，确保截止时刻后仍有余量。
    static func morningPlan(
        deadline: Date, windowSeconds: TimeInterval, now: Date,
        config: Config = .default
    ) -> SchedulePlan? {
        let window = min(windowSeconds, config.maxSessionDuration - 2 * config.safetyMargin)
        let start = deadline.addingTimeInterval(-window)
        guard start >= now.addingTimeInterval(config.minimumLead) else { return nil }
        return SchedulePlan(
            kind: .morning,
            start: start,
            deadline: deadline,
            expectedExpiration: start.addingTimeInterval(config.maxSessionDuration))
    }

    /// F04 试响排程：delay 分钟后开始会话，会话开始 45 秒后即触发提醒。
    static func testPlan(now: Date, delaySeconds: TimeInterval, config: Config = .default) -> SchedulePlan {
        let start = now.addingTimeInterval(max(delaySeconds, 30))
        return SchedulePlan(
            kind: .test,
            start: start,
            deadline: start.addingTimeInterval(45),
            expectedExpiration: start.addingTimeInterval(config.maxSessionDuration))
    }

    /// 最后安全触发门槛：再不响就来不及了。
    static func latestSafeTrigger(expiration: Date, config: Config = .default) -> Date {
        expiration.addingTimeInterval(-config.safetyMargin)
    }

    // MARK: - 触发决策

    /// now 时刻该不该响。
    /// 优先级：会话将过期兜底 > 截止时刻 > 运动候选 > 继续等待。
    static func decide(
        now: Date,
        deadline: Date,
        sessionExpiration: Date?,
        reports: [MotionAnalysis.WindowReport],
        sleepSufficient: Bool,
        allowsEarlyWake: Bool,
        config: Config = .default
    ) -> Decision {
        if let expiration = sessionExpiration,
           now >= latestSafeTrigger(expiration: expiration, config: config) {
            return Decision(
                shouldFire: true, trigger: .sessionExpiring,
                rationale: "会话将过期，安全余量兜底触发")
        }
        if now >= deadline {
            return Decision(shouldFire: true, trigger: .deadline, rationale: "到达用户设定的截止时刻")
        }
        if !allowsEarlyWake {
            return Decision(shouldFire: false, trigger: .deadline, rationale: "未开启提前唤醒，等待截止时刻")
        }
        if !sleepSufficient {
            return Decision(shouldFire: false, trigger: .deadline, rationale: "睡眠数据缺失或不足，不提前唤醒")
        }
        if let candidate = motionCandidate(in: reports, config: config) {
            return Decision(
                shouldFire: true, trigger: .motionCandidate,
                rationale: candidate)
        }
        return Decision(shouldFire: false, trigger: .deadline, rationale: "继续观察（运动信号未达标或窗口不足）")
    }

    /// 运动候选判据（SPEC §5）：
    /// 1. 前 baselineWindowCount 个窗口建立当晚个体基线；
    /// 2. 之后需连续 consecutiveCandidateWindows 个窗口：
    ///    variability ≥ 基线中位数 × factor 且 sustainedMotionRatio ≥ 阈值；
    /// 3. 任何说明文字只能写"运动候选"。
    static func motionCandidate(
        in reports: [MotionAnalysis.WindowReport], config: Config = .default
    ) -> String? {
        let ordered = reports.sorted { $0.windowIndex < $1.windowIndex }
        guard ordered.count > config.baselineWindowCount else { return nil }
        let baseline = Array(ordered.prefix(config.baselineWindowCount))
        let baselineMed = MotionAnalysis.median(baseline.map(\.variability))
        let variabilityGate = max(
            baselineMed * config.variabilityFactorOverBaseline,
            config.minimumAbsoluteVariability)
        let observations = ordered.dropFirst(config.baselineWindowCount)
        var streak = 0
        for window in observations {
            let overVariability = window.variability >= variabilityGate
            let overRatio = window.sustainedMotionRatio >= config.sustainedMotionRatioThreshold
            if overVariability && overRatio {
                streak += 1
                if streak >= config.consecutiveCandidateWindows {
                    return "连续\(streak)个窗口运动量≥基线×\(config.variabilityFactorOverBaseline)且持续运动比例≥\(config.sustainedMotionRatioThreshold)（运动候选，非睡眠分期）"
                }
            } else {
                streak = 0
            }
        }
        return nil
    }
}
