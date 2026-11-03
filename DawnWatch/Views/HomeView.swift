import SwiftUI

/// 首页：呼吸 / 智能闹钟 / 健康数据 / 反馈 + 实验日志速览。
struct HomeView: View {
    @EnvironmentObject private var alarm: AlarmCoordinator
    @EnvironmentObject private var logger: ExperimentLogger

    var body: some View {
        List {
            Section {
                alarmStatus
                    .font(.footnote)
            }
            Section {
                NavigationLink(destination: BreathSessionView()) {
                    Label("呼吸训练", systemImage: "leaf")
                }
                NavigationLink(destination: AlarmSetupView()) {
                    Label("智能闹钟", systemImage: "alarm")
                }
                NavigationLink(destination: HealthSummaryView()) {
                    Label("健康数据", systemImage: "heart.text.square")
                }
                NavigationLink(destination: MorningFeedbackView()) {
                    Label("晨间反馈", systemImage: "checklist")
                }
            }
            Section("实验日志") {
                if logger.recentEvents.isEmpty {
                    Text("暂无记录").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(logger.recentEvents.prefix(8).enumerated()), id: \.offset) { _, event in
                        Text(event.summaryLine)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("Dawn")
    }

    @ViewBuilder
    private var alarmStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch alarm.phase {
            case .idle:
                Text("闹钟：未预约")
            case .scheduled(let start, let deadline, let kind):
                Text(kind == .test ? "试响已预约" : "唤醒已预约")
                Text("窗口 \(ExperimentEvent.timeLabel(start)) · 截止 \(ExperimentEvent.timeLabel(deadline))")
                    .foregroundStyle(.secondary)
            case .windowRunning(let start, let deadline, _):
                Text("唤醒窗口运行中")
                Text("起点 \(ExperimentEvent.timeLabel(start)) · 截止 \(ExperimentEvent.timeLabel(deadline))")
                    .foregroundStyle(.secondary)
            case .fired(let trigger, let at):
                Text("已提醒 · \(trigger.rawValue)")
                Text("于 \(ExperimentEvent.timeLabel(at))").foregroundStyle(.secondary)
                Text("到 MorningFeedback 记录状态").foregroundStyle(.secondary)
            case .invalidated(let reason, let code):
                Text("会话已失效")
                Text(code.map { "\($0)" } ?? reason).foregroundStyle(.secondary)
            }
            if let notice = alarm.userNotice {
                Text(notice).foregroundStyle(.tertiary)
            }
        }
    }
}
