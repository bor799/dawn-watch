import Foundation

/// 呼吸节律预设。V0.1 仅两种：4-6（默认）与 4-7-8（初学限 4 周期）。
struct BreathPattern: Equatable, Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case fourSix = "4-6"
        case fourSevenEight = "4-7-8"
    }

    enum Phase: String, Codable, Equatable {
        case inhale
        case hold
        case exhale
    }

    var id: String { kind.rawValue }
    var kind: Kind
    /// 秒。零值相位（如 4-6 的屏息）不进入时间线。
    var inhaleSeconds: TimeInterval
    var holdSeconds: TimeInterval
    var exhaleSeconds: TimeInterval
    /// 初学周期上限（4-7-8 = 4）；nil 表示不限，由时长控制。
    var cycleLimit: Int?

    static let fourSix = BreathPattern(
        kind: .fourSix, inhaleSeconds: 4, holdSeconds: 0, exhaleSeconds: 6, cycleLimit: nil)

    static let fourSevenEight = BreathPattern(
        kind: .fourSevenEight, inhaleSeconds: 4, holdSeconds: 7, exhaleSeconds: 8, cycleLimit: 4)

    var cycleDuration: TimeInterval { inhaleSeconds + holdSeconds + exhaleSeconds }

    /// 一个呼吸周期内实际会经历的相位序列（跳过 0 秒相位）。
    var phasesPerCycle: [Phase] {
        var phases: [Phase] = []
        if inhaleSeconds > 0 { phases.append(.inhale) }
        if holdSeconds > 0 { phases.append(.hold) }
        if exhaleSeconds > 0 { phases.append(.exhale) }
        return phases
    }

    /// 指定选择时长下，训练的实际总时长。
    /// 始终对齐到完整周期（至少 1 个）；有周期上限的模式再按上限截断。
    /// 这保证 timeline(forDuration:) 的覆盖长度恰好等于该时长。
    func effectiveDuration(requestedSeconds: TimeInterval) -> TimeInterval {
        let floorToCycle = max(
            cycleDuration,
            (requestedSeconds / cycleDuration).rounded(.down) * cycleDuration)
        if let limit = cycleLimit {
            return min(floorToCycle, Double(limit) * cycleDuration)
        }
        return min(floorToCycle, max(cycleDuration, requestedSeconds))
    }

    /// 完整训练的相位段落时间线（相对开始时刻的秒偏移）。
    /// 不含结束后空闲段；总时长等于 effectiveDuration。
    func timeline(forDuration duration: TimeInterval) -> [PhaseSegment] {
        var segments: [PhaseSegment] = []
        var offset: TimeInterval = 0
        let cycleCount = Int((duration / cycleDuration).rounded(.down))
        for cycle in 0..<max(1, cycleCount) {
            if let limit = cycleLimit, cycle >= limit { break }
            for phase in phasesPerCycle {
                let length = length(of: phase)
                guard length > 0 else { continue }
                // 尾周期可能被请求时长截断
                let clippedEnd = min(offset + length, duration)
                if clippedEnd <= offset { break }
                segments.append(PhaseSegment(phase: phase, start: offset, end: clippedEnd))
                offset = clippedEnd
            }
        }
        return segments
    }

    func length(of phase: Phase) -> TimeInterval {
        switch phase {
        case .inhale: return inhaleSeconds
        case .hold: return holdSeconds
        case .exhale: return exhaleSeconds
        }
    }

    /// 面向 UI 的时长选项：4-6 用 3/5 分钟；4-7-8 固定 4 周期（约 76 秒）。
    var offeredDurations: [TimeInterval] {
        switch kind {
        case .fourSix: return [180, 300]
        case .fourSevenEight: return [effectiveDuration(requestedSeconds: .infinity)]
        }
    }
}

/// 时间线上的一段相位。start/end 为相对训练开始的秒数。
struct PhaseSegment: Equatable, Codable {
    var phase: BreathPattern.Phase
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { end - start }

    /// elapsed 秒时所处的相位进度（0..<1）；越界返回最近边界。
    func progress(at elapsed: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, (elapsed - start) / duration))
    }
}
