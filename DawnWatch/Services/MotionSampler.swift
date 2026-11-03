import Foundation
import CoreMotion
import Combine

/// 唤醒窗口内的运动采样探针（F06）。
/// 只做间歇突发采样：每分钟取一个 10 秒窗口、窗口内 5Hz 加速度。
/// 不承诺系统级采样保证——实际间隔/缺口写入日志，供 G3 判定。
final class MotionSampler: ObservableObject {
    /// 每完成一个观察窗口回调一次（主线程）。
    var onWindow: ((MotionAnalysis.WindowReport) -> Void)?
    /// 采集不可用/出错时回调（主线程）——上层记录并安全降级。
    var onError: ((String) -> Void)?

    @Published private(set) var isRunning = false
    @Published private(set) var completedWindows = 0

    private let manager = CMMotionManager()
    private var config = MotionAnalysis.BurstConfig()
    private var burstTimer: Timer?
    private var buffer: [MotionAnalysis.Sample] = []
    private var burstStartWallClock: Date?
    /// 首个样本的传感器时间戳（开机相对，单调），后续偏移都相对它，
    /// 这样 P50/P95 间隔统计不受主线程调度抖动污染。
    private var firstSensorTimestamp: Double?

    func start(config: MotionAnalysis.BurstConfig = .init()) {
        stop()
        self.config = config
        guard manager.isAccelerometerAvailable else {
            onError?("加速度计不可用（模拟器或硬件限制）——按截止时刻唤醒")
            return
        }
        firstSensorTimestamp = nil
        isRunning = true
        // 立即采第一个窗口，之后按周期轮转
        beginBurst()
        let timer = Timer.scheduledTimer(
            withTimeInterval: config.periodSeconds, repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
        burstTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 周期心跳：先做看门狗（上一窗口卡死时复位），再开新窗口。
    /// 否则 CoreMotion 一旦停止回调，isAccelerometerActive 永远为 true，
    /// 整个会话再也产不出任何窗口报告，G3 的数据可用性结论会被污染。
    private func tick() {
        guard isRunning else { return }
        if manager.isAccelerometerActive,
           let start = burstStartWallClock,
           Date().timeIntervalSince(start) > config.burstSeconds + 5 {
            manager.stopAccelerometerUpdates()
            onError?("窗口超时未收口（传感器疑似停更），已复位；截获样本 \(buffer.count)")
            buffer.removeAll()
            burstStartWallClock = nil
        }
        beginBurst()
    }

    func stop() {
        burstTimer?.invalidate()
        burstTimer = nil
        if manager.isAccelerometerActive {
            manager.stopAccelerometerUpdates()
        }
        buffer.removeAll()
        isRunning = false
    }

    // MARK: - 突发窗口

    private func beginBurst() {
        guard isRunning, !manager.isAccelerometerActive else { return }
        buffer.removeAll()
        burstStartWallClock = Date()
        manager.accelerometerUpdateInterval = 1.0 / config.sampleHz
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.manager.stopAccelerometerUpdates()
                self.onError?("加速度采样错误: \(error.localizedDescription)")
                return
            }
            guard let data else { return }
            if self.firstSensorTimestamp == nil {
                self.firstSensorTimestamp = data.timestamp
            }
            let base = self.firstSensorTimestamp ?? data.timestamp
            let sample = MotionAnalysis.Sample(
                offsetSeconds: data.timestamp - base,
                x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z)
            self.buffer.append(sample)
            // 窗口时长达标 → 收口并停止，等下一个周期
            if Date().timeIntervalSince(self.burstStartWallClock ?? Date()) >= self.config.burstSeconds {
                self.manager.stopAccelerometerUpdates()
                self.finishBurst()
            }
        }
    }

    private func finishBurst() {
        defer {
            windowIndexValue += 1
            buffer.removeAll()
        }
        guard let report = MotionAnalysis.analyze(
            samples: buffer, windowIndex: windowIndexValue, config: config)
        else {
            onError?("窗口 \(windowIndexValue) 样本不足(\(buffer.count))")
            return
        }
        completedWindows += 1
        onWindow?(report)
    }

    private var windowIndexValue = 0
}
