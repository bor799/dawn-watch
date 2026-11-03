import Foundation

// Dawn 纯逻辑层验证 harness。
// 编译进来的文件：Models×4 + BreathEngine/WakePolicy/MotionAnalysis/ExperimentLogger。
// 用法：logic-check/run.sh

@main
struct TestsMain {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0

    static func expect(_ label: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failed += 1
            print("  ✗ \(label) \(detail)")
        }
    }

    static func eq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
        expect(label, actual == expected, "→ \(actual) (期望 \(expected))")
    }

    static func main() {
        print("== 1. BreathPattern 节律与时间线 ==")
        testBreathPattern()
        print("== 2. BreathEngine 状态机 ==")
        testBreathEngine()
        print("== 3. MotionAnalysis 聚合统计 ==")
        testMotionAnalysis()
        print("== 4. WakePolicy 排程与决策 ==")
        testWakePolicy()
        print("== 5. SleepInsight 睡眠聚合 ==")
        testSleepInsight()
        print("== 6. ExperimentEvent/Logger JSONL ==")
        testExperimentLogger()
        print("== 7. AlarmSettings 持久化与日期 ==")
        testAlarmSettings()

        print("")
        print("RESULT: passed=\(passed) failed=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - 测试组

    static func testBreathPattern() {
        let fourSix = BreathPattern.fourSix
        eq("4-6 周期=10s", fourSix.cycleDuration, 10)
        eq("4-6 相位序列=[吸,呼]", fourSix.phasesPerCycle, [.inhale, .exhale])
        eq("4-6 3分钟实际=180s", fourSix.effectiveDuration(requestedSeconds: 180), 180)
        eq("4-6 5分钟实际=300s", fourSix.effectiveDuration(requestedSeconds: 300), 300)

        let sw = BreathPattern.fourSevenEight
        eq("4-7-8 周期=19s", sw.cycleDuration, 19)
        eq("4-7-8 初学上限=4周期", sw.cycleLimit ?? -1, 4)
        eq("4-7-8 上限时≈76s", sw.effectiveDuration(requestedSeconds: .infinity), 76)

        let timeline = fourSix.timeline(forDuration: 180)
        eq("180s 时间线段数=36", timeline.count, 36)
        eq("首段=吸气[0,4)", timeline.first!, PhaseSegment(phase: .inhale, start: 0, end: 4))
        eq("次段=呼气[4,10)", timeline[1], PhaseSegment(phase: .exhale, start: 4, end: 10))
        var continuous = true
        for i in 1..<timeline.count where timeline[i].start != timeline[i - 1].end {
            continuous = false
        }
        expect("时间线无缝连续", continuous)
        eq("时间线总长=180", timeline.last!.end, 180)

        let swTimeline = sw.timeline(forDuration: 76)
        eq("4-7-8 时间线段数=12", swTimeline.count, 12)
        let phases = swTimeline.map(\.phase)
        eq("4-7-8 相位循环", Array(phases.prefix(3)), [.inhale, .hold, .exhale])
        eq("4-7-8 屏息段[4,11)", swTimeline[1], PhaseSegment(phase: .hold, start: 4, end: 11))

        // 时长对齐整周期（timeline 覆盖长度 == effectiveDuration 的不变式）
        eq("4-7-8 请求60s→对齐3周期57s", sw.effectiveDuration(requestedSeconds: 60), 57)
        eq("4-7-8 57s 时间线段数=9", sw.timeline(forDuration: 57).count, 9)
        eq("4-6 请求95s→对齐9周期90s", fourSix.effectiveDuration(requestedSeconds: 95), 90)
    }

    static func testBreathEngine() {
        let engine = BreathEngine()
        eq("初始=IDLE", engine.state, .idle)

        engine.start(pattern: .fourSix, requestedSeconds: 180)
        eq("开始后=BREATHING", engine.state, .breathing)
        eq("计划时长=180", engine.plannedDuration, 180)
        eq("起始相位=吸气", engine.currentPhase, .inhale)

        engine.advance(by: 3.9)
        eq("3.9s 仍在吸气", engine.currentPhase, .inhale)
        engine.advance(by: 0.2)
        eq("4.1s 进入呼气", engine.currentPhase, .exhale)
        engine.advance(by: 5.9)
        eq("10s 进入第2周期吸气", engine.currentPhase, .inhale)
        eq("周期计数=1", engine.cyclesCompleted, 1)

        engine.pause()
        eq("暂停状态", engine.state, .paused)
        engine.advance(by: 50)
        expect("暂停时 advance 不生效", engine.elapsed < 20)

        engine.resume()
        engine.advance(by: 169.9)
        eq("暂停恢复后可推进至收尾", engine.state, .breathing)
        engine.advance(by: 0.2)
        eq("到点完成 FINISHED", engine.state, .finished)
        eq("completed=true", engine.completed, true)

        let sw = BreathEngine()
        sw.start(pattern: .fourSevenEight, requestedSeconds: 999)
        eq("4-7-8 请求999 实际76", sw.plannedDuration, 76)
        sw.advance(by: 75.9)
        sw.advance(by: 0.2)
        eq("4-7-8 到点完成", sw.state == .finished && sw.completed, true)

        let stop = BreathEngine()
        stop.start(pattern: .fourSix, requestedSeconds: 180)
        stop.advance(by: 30)
        stop.stop()
        eq("中途结束 completed=false", stop.completed, false)
        eq("中途结束实际=30s", stop.elapsed, 30)
    }

    static func makeReport(index: Int, variability: Double, ratio: Double) -> MotionAnalysis.WindowReport {
        MotionAnalysis.WindowReport(
            windowIndex: index, startedAtOffset: Double(index) * 60, samplesCount: 50,
            variability: variability, sustainedMotionRatio: ratio,
            p50Interval: 0.2, p95Interval: 0.3, expectedSamples: 50)
    }

    static func testMotionAnalysis() {
        func makeSamples(magnitudes: [Double], interval: Double = 0.2) -> [MotionAnalysis.Sample] {
            magnitudes.enumerated().map { i, m in
                MotionAnalysis.Sample(offsetSeconds: Double(i) * interval, x: 0, y: 0, z: m)
            }
        }

        // 静息：全在 1g 附近
        let still = makeSamples(magnitudes: Array(repeating: 1.0, count: 50).map { $0 + Double.random(in: -0.005...0.005) })
        let stillReport = MotionAnalysis.analyze(samples: still, windowIndex: 0, config: .init())!
        expect("静息 variability<0.01", stillReport.variability < 0.01)
        expect("静息 持续运动比例=0", stillReport.sustainedMotionRatio == 0)
        eq("静息 样本数=50", stillReport.samplesCount, 50)

        // 活跃：幅度在 0.5–1.5 摆动
        let active = makeSamples(magnitudes: (0..<50).map { i in i.isMultiple(of: 2) ? 1.5 : 0.5 })
        let activeReport = MotionAnalysis.analyze(samples: active, windowIndex: 1, config: .init())!
        expect("活跃 variability>0.4", activeReport.variability > 0.4)
        expect("活跃 持续比例=1", activeReport.sustainedMotionRatio == 1.0)

        // 采样间隔统计
        expect("5Hz P50≈0.2", abs(stillReport.p50Interval - 0.2) < 0.01)
        // 造 3 个真实的 5 秒缺口（3/49≈6% 的间隔是长间隔，P95 才会落在缺口上）
        let withGap: [MotionAnalysis.Sample] = (0..<50).map { i in
            var offset = Double(i) * 0.2
            if i >= 40 { offset += 15 }
            else if i >= 25 { offset += 10 }
            else if i >= 10 { offset += 5 }
            return MotionAnalysis.Sample(offsetSeconds: offset, x: 0, y: 0, z: 1.0)
        }
        let gapReport = MotionAnalysis.analyze(samples: withGap, windowIndex: 2, config: .init())!
        expect("缺口后 P95 抬升", gapReport.p95Interval > 1.0)
        expect("P50 仍≈0.2", abs(gapReport.p50Interval - 0.2) < 0.01)

        let intervals = Array(repeating: 0.2, count: 49)
        eq("gapRatio 无缺口=0", MotionAnalysis.gapRatio(intervals: intervals, config: .init()), 0)

        eq("percentile([1..5],0.5)=3", MotionAnalysis.percentile([1, 2, 3, 4, 5], 0.5), 3)
        expect("percentile([1..5],0.95)=4.8", abs(MotionAnalysis.percentile([1, 2, 3, 4, 5], 0.95) - 4.8) < 1e-9)
        eq("median 空数组=0", MotionAnalysis.median([]), 0)
    }

    static func testWakePolicy() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)   // 固定锚点
        let deadline = base.addingTimeInterval(3600)

        // 排程：默认 27 分钟窗口（30min − 2×90s 安全余量，WakePolicy 硬钳制）
        let plan = WakePolicy.morningPlan(deadline: deadline, windowSeconds: 1620, now: base)!
        eq("窗口起点=截止-27min", plan.start, deadline.addingTimeInterval(-1620))
        eq("预计过期=起点+30min", plan.expectedExpiration, plan.start.addingTimeInterval(1800))
        eq("截止早于最后安全触发", plan.deadline < WakePolicy.latestSafeTrigger(expiration: plan.expectedExpiration), true)

        // 窗口钳制（请求 28/30 分钟 → 都被钳到 27 分钟）
        let wide = WakePolicy.morningPlan(deadline: deadline, windowSeconds: 1800, now: base)!
        eq("宽窗口被钳到27min", deadline.timeIntervalSince(wide.start), 1620)
        let w28 = WakePolicy.morningPlan(deadline: deadline, windowSeconds: 1680, now: base)!
        eq("28min请求也被钳到27min", deadline.timeIntervalSince(w28.start), 1620)

        // 窗口起点过近 → nil
        expect("距截止10min无法排27min窗口",
               WakePolicy.morningPlan(deadline: base.addingTimeInterval(600), windowSeconds: 1620, now: base) == nil)

        // 试响
        let test = WakePolicy.testPlan(now: base, delaySeconds: 120)
        eq("试响起点=+120s", test.start, base.addingTimeInterval(120))
        eq("试响截止=起点+45s", test.deadline, test.start.addingTimeInterval(45))

        // 决策优先级（windowIndex 递增，因为 motionCandidate 按它排序）
        let quiet1 = makeReport(index: 0, variability: 0.005, ratio: 0.0)
        let quiet2 = makeReport(index: 1, variability: 0.006, ratio: 0.0)
        let moving1 = makeReport(index: 2, variability: 0.5, ratio: 0.8)
        let moving2 = makeReport(index: 3, variability: 0.6, ratio: 0.9)

        // a) 会话将过期兜底优先
        let a = WakePolicy.decide(
            now: deadline, deadline: deadline.addingTimeInterval(60),
            sessionExpiration: deadline.addingTimeInterval(30),
            reports: [], sleepSufficient: false, allowsEarlyWake: false)
        eq("过期兜底触发", a.trigger, .sessionExpiring)
        expect("过期兜底 shouldFire", a.shouldFire)

        // b) 到达截止
        let b = WakePolicy.decide(
            now: deadline, deadline: deadline,
            sessionExpiration: deadline.addingTimeInterval(120),
            reports: [], sleepSufficient: false, allowsEarlyWake: false)
        eq("截止触发", b.trigger, .deadline)
        expect("截止 shouldFire", b.shouldFire)

        // c) 未开提前唤醒 → 等
        let c = WakePolicy.decide(
            now: deadline.addingTimeInterval(-600), deadline: deadline,
            sessionExpiration: deadline.addingTimeInterval(120),
            reports: [quiet1, quiet2, moving1, moving2], sleepSufficient: true, allowsEarlyWake: false)
        expect("未开提前唤醒→等待", !c.shouldFire)

        // d) 睡眠不充分 → 等
        let d = WakePolicy.decide(
            now: deadline.addingTimeInterval(-600), deadline: deadline,
            sessionExpiration: deadline.addingTimeInterval(120),
            reports: [quiet1, quiet2, moving1, moving2], sleepSufficient: false, allowsEarlyWake: true)
        expect("睡眠不充分→等待", !d.shouldFire)

        // e) 全条件满足 → 运动候选
        let e = WakePolicy.decide(
            now: deadline.addingTimeInterval(-600), deadline: deadline,
            sessionExpiration: deadline.addingTimeInterval(120),
            reports: [quiet1, quiet2, moving1, moving2], sleepSufficient: true, allowsEarlyWake: true)
        eq("运动候选触发", e.trigger, .motionCandidate)
        expect("理由标注非睡眠分期", e.rationale.contains("运动候选"))

        // e2) 乱序传入也按 windowIndex 归位（sorted 非稳定，靠索引不靠顺序）
        let e2 = WakePolicy.decide(
            now: deadline.addingTimeInterval(-600), deadline: deadline,
            sessionExpiration: deadline.addingTimeInterval(120),
            reports: [moving2, quiet2, moving1, quiet1], sleepSufficient: true, allowsEarlyWake: true)
        eq("乱序输入仍运动候选", e2.trigger, .motionCandidate)

        // f) 只有基线窗口 → 等
        let f = WakePolicy.decide(
            now: deadline.addingTimeInterval(-600), deadline: deadline,
            sessionExpiration: deadline.addingTimeInterval(120),
            reports: [quiet1, quiet2], sleepSufficient: true, allowsEarlyWake: true)
        expect("窗口不足→等待", !f.shouldFire)

        // g) 连续性被打断 → 等（索引互异，确保排序后仍是 q,q,m,q,m）
        let quiet3 = makeReport(index: 3, variability: 0.004, ratio: 0.02)
        let moving3 = makeReport(index: 4, variability: 0.55, ratio: 0.7)
        let g = WakePolicy.decide(
            now: deadline.addingTimeInterval(-600), deadline: deadline,
            sessionExpiration: deadline.addingTimeInterval(120),
            reports: [quiet1, quiet2, moving1, quiet3, moving3], sleepSufficient: true, allowsEarlyWake: true)
        expect("连击打断→等待", !g.shouldFire)

        // h) 零基线退化保护：基线完全静止时 ×2.0 判据退化为 ≥0，
        //    必须靠绝对门槛拦住噪声级波动（哪怕持续运动比例很高）
        let zero1 = makeReport(index: 0, variability: 0.0, ratio: 0.0)
        let zero2 = makeReport(index: 1, variability: 0.0, ratio: 0.0)
        let noise1 = makeReport(index: 2, variability: 0.01, ratio: 0.9)
        let noise2 = makeReport(index: 3, variability: 0.012, ratio: 0.85)
        let h = WakePolicy.decide(
            now: deadline.addingTimeInterval(-600), deadline: deadline,
            sessionExpiration: deadline.addingTimeInterval(120),
            reports: [zero1, zero2, noise1, noise2], sleepSufficient: true, allowsEarlyWake: true)
        expect("零基线+噪声不触发", !h.shouldFire)
    }

    static func testSleepInsight() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // 固定时区：分组/充分性判定不随宿主机时区漂移（UTC+9 以上会跨午夜）
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        func stage(_ start: TimeInterval, _ minutes: Double, _ s: SleepInsight.Stage) -> SleepInsight.Interval {
            SleepInsight.Interval(
                start: base.addingTimeInterval(start),
                end: base.addingTimeInterval(start + minutes * 60), stage: s)
        }

        // 第一晚：核心300 深睡60 REM90 清醒30（时间轴连续 0–480min）
        let night1: [SleepInsight.Interval] = [
            stage(0, 300, .asleepCore), stage(300, 60, .asleepDeep),
            stage(360, 90, .asleepREM), stage(450, 30, .awake),
        ]
        // 与第一晚重叠 5 分钟的重复源 → 时间轴任何瞬间只计一次
        var withOverlap = night1
        withOverlap.append(stage(295, 10, .asleepCore))
        let nights = SleepInsight.nights(from: withOverlap, calendar: calendar)
        eq("重叠去重后仍1晚", nights.count, 1)
        // 重叠的 295–305 被截为 300–305 并归给核心：核心=305 深睡=55 REM=90
        expect("核心=305min(重叠归核心)", abs((nights[0].stageMinutes[.asleepCore] ?? 0) - 305) < 0.01)
        expect("深睡=55min", abs((nights[0].stageMinutes[.asleepDeep] ?? 0) - 55) < 0.01)
        expect("REM=90min", abs((nights[0].stageMinutes[.asleepREM] ?? 0) - 90) < 0.01)
        expect("总睡眠=450min(时间轴守恒)", abs(nights[0].totalAsleepMinutes - 450) < 0.01)
        expect("清醒=30min", abs((nights[0].stageMinutes[.awake] ?? 0) - 30) < 0.01)

        // 睡眠充分性（固定时区日历）
        expect("450min ≥ 360min 充分",
               SleepInsight.latestNightSleepSufficient(withOverlap, minimumMinutes: 360, now: base.addingTimeInterval(8 * 3600), calendar: calendar))
        expect("450min < 480min 不充分",
               !SleepInsight.latestNightSleepSufficient(withOverlap, minimumMinutes: 480, now: base.addingTimeInterval(8 * 3600), calendar: calendar))
        expect("无数据→不充分", !SleepInsight.latestNightSleepSufficient([], now: base, calendar: calendar))

        // 标量摘要取时间最新
        let summary = ScalarSampleSummary(
            typeName: "心率",
            samples: [(62, base), (58, base.addingTimeInterval(600))],
            unitLabel: "次/分")
        eq("最新值=58(按时间非顺序)", summary.latestValue ?? -1, 58)
        expect("ageLabel=10分钟前", summary.ageLabel(now: base.addingTimeInterval(1200)) == "10 分钟前")
    }

    static func testExperimentLogger() {
        // 事件编解码
        var event = ExperimentEvent(kind: .alarmFired)
        event.triggerReason = .motionCandidate
        event.startBattery = 0.9
        event.endBattery = 0.85
        event.note = "测试理由"
        let line = event.encodedLine()
        let decoded = ExperimentEvent.decode(line: line)
        eq("JSONL 往返 trigger=motion_candidate", decoded?.triggerReason, .motionCandidate)
        eq("JSONL 往返 电量保留", decoded?.endBattery ?? -1, 0.85)

        // 日志器
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawn-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("experiment.jsonl")
        let logger = ExperimentLogger(fileURL: file)

        var e1 = ExperimentEvent(kind: .alarmScheduled)
        e1.scheduledStart = Date(timeIntervalSince1970: 1)
        logger.log(e1)
        logger.log(ExperimentEvent(kind: .alarmSessionStarted))
        var e3 = ExperimentEvent(kind: .feedback)
        e3.sleepiness = 4
        logger.log(e3)

        let all = ExperimentLogger.readAll(from: file)
        eq("JSONL 行数=3", all.count, 3)
        eq("顺序保持", all.map(\.kind), [.alarmScheduled, .alarmSessionStarted, .feedback])
        eq("字段保留 sleepiness=4", all.last?.sleepiness ?? -1, 4)

        // 主线程 recentEvents（CLI 需要转一下 runloop）
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        eq("内存镜像最新在前", logger.recentEvents.first?.kind, .feedback)

        // 清空
        logger.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        eq("清空后文件为空", ExperimentLogger.readAll(from: file).count, 0)
        try? FileManager.default.removeItem(at: dir)

        // summaryLine 全类型不崩溃
        for kind in [ExperimentEvent.Kind.appLaunch, .breathStart, .breathEnd, .healthAuth,
                     .healthSampleSummary, .alarmScheduled, .alarmSessionStarted, .alarmFired,
                     .alarmDismissed, .alarmInvalidated, .motionWindow, .feedback, .error] {
            _ = ExperimentEvent(kind: kind).summaryLine
        }
        expect("summaryLine 全类型可生成", true)
    }

    static func testAlarmSettings() {
        // 固定时区日历，避免机器本地时区影响
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let suiteName = "dawn-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 默认值
        let loaded = AlarmSettings.load(from: defaults)
        eq("缺省未启用", loaded.enabled, false)
        eq("缺省窗口=27min", loaded.windowSeconds, 1620)
        eq("缺省提前唤醒=关", loaded.allowsEarlyWake, false)

        // 往返
        var settings = loaded
        settings.enabled = true
        settings.hour = 7
        settings.minute = 30
        settings.allowsEarlyWake = true
        settings.save(to: defaults)
        let reloaded = AlarmSettings.load(from: defaults)
        eq("持久化往返 时点", "\(reloaded.hour):\(reloaded.minute)", "7:30")
        eq("持久化往返 提前唤醒", reloaded.allowsEarlyWake, true)

        // nextDeadline：06:00 → 当天 07:30；08:00 → 次日 07:30
        // 期望值用同一固定时区格式化器生成，与机器本地时区无关
        func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        let shLabel = DateFormatter()
        shLabel.dateFormat = "MM-dd HH:mm"
        shLabel.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        shLabel.locale = Locale(identifier: "en_US_POSIX")
        let morning = reloaded.nextDeadline(after: date(2026, 11, 3, 6, 0), calendar: calendar)
        eq("06:00 预约→当天07:30", shLabel.string(from: morning), shLabel.string(from: date(2026, 11, 3, 7, 30)))
        let afterAlarm = reloaded.nextDeadline(after: date(2026, 11, 3, 8, 0), calendar: calendar)
        eq("08:00 预约→次日07:30", shLabel.string(from: afterAlarm), shLabel.string(from: date(2026, 11, 4, 7, 30)))
        let exactly = reloaded.nextDeadline(after: date(2026, 11, 3, 7, 30), calendar: calendar)
        eq("07:30 整点预约→次日", shLabel.string(from: exactly), shLabel.string(from: date(2026, 11, 4, 7, 30)))
        // 跨月
        let monthEnd = reloaded.nextDeadline(after: date(2026, 11, 30, 23, 0), calendar: calendar)
        eq("跨月→12-01", shLabel.string(from: monthEnd), shLabel.string(from: date(2026, 12, 1, 7, 30)))
    }
}
