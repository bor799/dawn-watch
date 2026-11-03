import Foundation
import Combine

/// 呼吸训练状态机（纯逻辑，不含任何 WatchKit 调用）。
/// 时间线在 start 时一次性展开为相位段落；视图层用 Timer 推进 advance(by:)，
/// 并在 currentPhase 变化时自行播放触觉。屏幕熄灭/离开前台 → 视图调 pause()，
/// 不承诺后台继续。
final class BreathEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case breathing
        case paused
        case finished
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentSegment: PhaseSegment?
    @Published private(set) var completed: Bool = false

    private(set) var pattern: BreathPattern = .fourSix
    private(set) var plannedDuration: TimeInterval = 0
    private(set) var segments: [PhaseSegment] = []

    var currentPhase: BreathPattern.Phase? { currentSegment?.phase }

    /// 当前相位内的进度 0..1（驱动圆环/文字）。
    var phaseProgress: Double { currentSegment?.progress(at: elapsed) ?? 0 }

    /// 当前相位剩余秒。
    var phaseRemaining: TimeInterval {
        guard let segment = currentSegment else { return 0 }
        return max(0, segment.end - elapsed)
    }

    var remaining: TimeInterval { max(0, plannedDuration - elapsed) }

    var cyclesCompleted: Int {
        Int(elapsed / max(pattern.cycleDuration, 1))
    }

    var isRunning: Bool { state == .breathing || state == .paused }

    // MARK: - 控制

    func start(pattern: BreathPattern, requestedSeconds: TimeInterval) {
        self.pattern = pattern
        self.plannedDuration = pattern.effectiveDuration(requestedSeconds: requestedSeconds)
        self.segments = pattern.timeline(forDuration: plannedDuration)
        self.elapsed = 0
        self.completed = false
        self.currentSegment = segments.first
        self.state = .breathing
    }

    /// 由视图层 Timer 驱动（前台时）。
    func advance(by dt: TimeInterval) {
        guard state == .breathing else { return }
        elapsed = min(elapsed + max(0, dt), plannedDuration)
        currentSegment = segment(at: elapsed)
        if elapsed >= plannedDuration {
            finish(completed: true)
        }
    }

    func pause() {
        guard state == .breathing else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        state = .breathing
    }

    /// 用户主动结束（未完成）。
    func stop() {
        guard state == .breathing || state == .paused else { return }
        finish(completed: false)
    }

    func reset() {
        state = .idle
        elapsed = 0
        currentSegment = nil
        completed = false
    }

    private func finish(completed flag: Bool) {
        completed = flag
        if flag { elapsed = plannedDuration }
        state = .finished
    }

    private func segment(at time: TimeInterval) -> PhaseSegment? {
        guard !segments.isEmpty else { return nil }
        // 越界收尾
        if time >= segments[segments.count - 1].end { return segments[segments.count - 1] }
        var low = 0, high = segments.count - 1
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].end <= time { low = mid + 1 } else { high = mid }
        }
        return segments[low]
    }
}
