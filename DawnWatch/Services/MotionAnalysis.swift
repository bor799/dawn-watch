import Foundation

/// 运动信号的纯计算层（平台无关，可离线测试）。
/// MotionSampler 只负责采集；这里负责聚合与统计。
enum MotionAnalysis {
    /// 采样方案（实验参数）：每 periodSeconds 观察一个 burstSeconds 窗口，
    /// 窗口内以 sampleHz 采加速度。非连续常开。
    struct BurstConfig: Equatable, Codable {
        var sampleHz: Double = 5
        var burstSeconds: Double = 10
        var periodSeconds: Double = 60

        var samplesPerBurst: Int { Int(sampleHz * burstSeconds) }
    }

    struct Sample: Equatable {
        var offsetSeconds: TimeInterval   // 相对会话开始
        var x: Double
        var y: Double
        var z: Double

        var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
    }

    /// 一个观察窗口的聚合报告（进入实验日志与 WakePolicy）。
    struct WindowReport: Equatable, Codable {
        var windowIndex: Int
        var startedAtOffset: TimeInterval
        var samplesCount: Int
        /// 幅度标准差：腕动幅度越大越高。
        var variability: Double
        /// 幅度偏离静息参考(≈1g)超过阈值的样本占比。
        var sustainedMotionRatio: Double
        /// 实际采样间隔统计（缺口检测）。
        var p50Interval: Double
        var p95Interval: Double
        var expectedSamples: Int
    }

    /// 无运动参考：地球重力 1g。
    static let restMagnitude: Double = 1.0
    /// 超过此幅度视为"在动"。粗糙阈值，供窗口聚合用。
    static let motionMagnitudeDelta: Double = 0.12

    static func analyze(
        samples: [Sample], windowIndex: Int, config: BurstConfig
    ) -> WindowReport? {
        guard samples.count >= 2 else { return nil }
        let magnitudes = samples.map(\.magnitude)
        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        let variance = magnitudes.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(magnitudes.count)
        let std = variance.squareRoot()
        let moving = magnitudes.filter { abs($0 - restMagnitude) > motionMagnitudeDelta }.count
        let sortedOffsets = samples.map(\.offsetSeconds).sorted()
        var intervals: [Double] = []
        for i in 1..<sortedOffsets.count {
            intervals.append(sortedOffsets[i] - sortedOffsets[i - 1])
        }
        return WindowReport(
            windowIndex: windowIndex,
            startedAtOffset: samples.first?.offsetSeconds ?? 0,
            samplesCount: samples.count,
            variability: std,
            sustainedMotionRatio: Double(moving) / Double(magnitudes.count),
            p50Interval: intervals.isEmpty ? 0 : percentile(intervals, 0.5),
            p95Interval: intervals.isEmpty ? 0 : percentile(intervals, 0.95),
            expectedSamples: config.samplesPerBurst)
    }

    // MARK: - 统计工具

    static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    /// 线性插值百分位（P50/P95 采样间隔统计用）。
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = Int(rank.rounded(.up))
        if low == high { return sorted[low] }
        let fraction = rank - Double(low)
        return sorted[low] + (sorted[high] - sorted[low]) * fraction
    }

    /// 样本缺口率：interval 远大于期望间隔(1/sampleHz × 3)的比例。
    static func gapRatio(intervals: [Double], config: BurstConfig) -> Double {
        guard !intervals.isEmpty else { return 1 }
        let expected = 1.0 / config.sampleHz
        let gaps = intervals.filter { $0 > expected * 3 }.count
        return Double(gaps) / Double(intervals.count)
    }
}
