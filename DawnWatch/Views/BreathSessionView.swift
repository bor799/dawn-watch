import SwiftUI
import WatchKit

/// 前台呼吸训练（F02）：4-6 默认 / 4-7-8 初学限 4 周期。
/// 触觉只在视图可见时播放；离开视图自动暂停（后台不承诺持续触觉）。
struct BreathSessionView: View {
    @EnvironmentObject private var logger: ExperimentLogger
    @StateObject private var engine = BreathEngine()

    @State private var patternKind: BreathPattern.Kind = .fourSix
    @State private var durationMinutes = 3

    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var pattern: BreathPattern {
        patternKind == .fourSix ? .fourSix : .fourSevenEight
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                switch engine.state {
                case .idle, .finished: controls
                case .breathing, .paused: sessionView
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("呼吸")
        .onReceive(tick) { _ in
            guard engine.state == .breathing else { return }
            engine.advance(by: 0.25)
        }
        .onChange(of: engine.currentPhase) { _ in haptic() }
        .onDisappear {
            // 离开本页 = 放弃本次训练（本页无更深的 NavigationLink）：
            // 补写 breathEnd，不留悬挂的 breathStart
            if engine.isRunning { endSession(completed: false) }
        }
    }

    // MARK: - 配置区（未开始时）

    private var controls: some View {
        VStack(spacing: 8) {
            if engine.state == .finished {
                Text(engine.completed ? "完成 ✓ 共 \(Int(engine.plannedDuration)) 秒" : "已结束 · \(Int(engine.elapsed)) 秒")
                    .font(.footnote)
            }
            Picker("节律", selection: $patternKind) {
                Text("4-6").tag(BreathPattern.Kind.fourSix)
                Text("4-7-8").tag(BreathPattern.Kind.fourSevenEight)
            }
            .labelsHidden()
            if patternKind == .fourSix {
                Picker("时长", selection: $durationMinutes) {
                    Text("3 分钟").tag(3)
                    Text("5 分钟").tag(5)
                }
                .labelsHidden()
            } else {
                Text("初学模式：4 个周期，约 76 秒")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("开始") {
                engine.start(pattern: pattern, requestedSeconds: TimeInterval(durationMinutes * 60))
                var event = ExperimentEvent(kind: .breathStart)
                event.pattern = pattern.kind.rawValue
                event.plannedSeconds = engine.plannedDuration
                logger.log(event)
            }
            .tint(.green)
        }
    }

    // MARK: - 训练区

    private var sessionView: some View {
        VStack(spacing: 10) {
            breathCircle
            Text(phaseLabel)
                .font(.title3.weight(.semibold))
            Text("\(Int(engine.phaseRemaining.rounded(.up))) 秒")
                .font(.title2).monospacedDigit()
            Text("周期 \(engine.cyclesCompleted + 1) · 剩 \(Int(engine.remaining.rounded(.up))) 秒")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button(engine.state == .paused ? "继续" : "暂停") {
                    engine.state == .paused ? engine.resume() : engine.pause()
                }
                Button("结束") { endSession(completed: false) }
                    .tint(.orange)
            }
        }
    }

    private var breathCircle: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.25))
            .frame(width: 74, height: 74)
            .scaleEffect(circleScale)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).scaleEffect(circleScale))
            .animation(.easeInOut(duration: 0.25), value: circleScale)
    }

    private var circleScale: Double {
        guard let segment = engine.currentSegment else { return 0.8 }
        let p = engine.phaseProgress
        switch segment.phase {
        case .inhale: return 0.7 + 0.5 * p
        case .hold: return 1.2
        case .exhale: return 1.2 - 0.5 * p
        }
    }

    private var phaseLabel: String {
        switch engine.currentPhase {
        case .inhale: return "吸气"
        case .hold: return "屏息"
        case .exhale: return "呼气"
        case nil: return engine.state == .paused ? "已暂停" : ""
        }
    }

    // MARK: - 事件

    /// 相位变化 → 前台触觉（视图可见才生效，符合 WKInterfaceDevice 限制）。
    private func haptic() {
        let device = WKInterfaceDevice.current()
        switch engine.currentPhase {
        case .inhale: device.play(.directionUp)
        case .hold: device.play(.click)
        case .exhale: device.play(.directionDown)
        case nil: break
        }
    }

    private func endSession(completed: Bool) {
        var event = ExperimentEvent(kind: .breathEnd)
        event.pattern = pattern.kind.rawValue
        event.actualSeconds = engine.elapsed
        event.completed = completed || engine.state == .finished
        logger.log(event)
        engine.reset()
    }
}

/// 观察 currentPhase 变化播放触觉的辅助包装（保留给需要显式挂载的场合）。
struct PhaseHapticObserver: ViewModifier {
    let phase: BreathPattern.Phase?
    let handler: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: phase) { _ in handler() }
    }
}
