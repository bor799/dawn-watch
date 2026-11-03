import SwiftUI

/// 智能闹钟设置（F04 试响 / F05 明晨预约 / P1 开关）。
struct AlarmSetupView: View {
    @EnvironmentObject private var alarm: AlarmCoordinator

    @State private var settings = AlarmSettings.load()
    @State private var deadlineDate = Date()
    @State private var testDelayMinutes = 2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                statusHeader

                SectionCard("截止时刻") {
                    DatePicker(
                        "最晚起床",
                        selection: $deadlineDate,
                        displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Toggle("预约明晨唤醒", isOn: $settings.enabled)
                }

                Button("预约明晨唤醒") { alarm.scheduleMorning() }
                    .tint(.green)

                SectionCard("试响（F04）") {
                    Picker("延迟", selection: $testDelayMinutes) {
                        Text("2 分钟").tag(2)
                        Text("3 分钟").tag(3)
                        Text("5 分钟").tag(5)
                    }
                    .labelsHidden()
                    Button("预约试响") {
                        alarm.scheduleTest(delaySeconds: TimeInterval(testDelayMinutes * 60))
                    }
                }

                if alarm.canCancel {
                    Button("取消预约", role: .destructive) {
                        alarm.cancel(notice: "已取消预约。今晚请用系统闹钟保底。")
                    }
                }

                SectionCard("实验选项") {
                    Toggle("允许提前唤醒（P1）", isOn: $settings.allowsEarlyWake)
                    Text("默认关闭：没有可靠睡眠数据时绝不提前，只在截止时刻提醒。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Text("测试期请始终保留一个系统原生闹钟保底（F07）。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("智能闹钟")
        .onAppear {
            // 用已存的钟点初始化 DatePicker
            if let date = Calendar.current.date(bySettingHour: settings.hour,
                                                minute: settings.minute,
                                                second: 0, of: Date()) {
                deadlineDate = date
            }
        }
        .onChange(of: deadlineDate) { newValue in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            settings.hour = comps.hour ?? 7
            settings.minute = comps.minute ?? 30
            settings.save()
        }
        .onChange(of: settings.allowsEarlyWake) { _ in settings.save() }
        .onChange(of: settings.enabled) { _ in settings.save() }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch alarm.phase {
            case .idle:
                Text("当前：未预约").font(.footnote)
            case .scheduled(let start, let deadline, _):
                Text("已预约 \(ExperimentEvent.timeLabel(start))–\(ExperimentEvent.timeLabel(deadline))").font(.footnote)
            case .windowRunning:
                Text("唤醒窗口运行中…").font(.footnote)
            case .fired(let trigger, _):
                Text("已提醒（\(trigger.rawValue)）— 去反馈页记录状态").font(.footnote)
            case .invalidated:
                Text("上次会话已失效").font(.footnote)
            }
            if let notice = alarm.userNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// 小节卡片容器。
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(.vertical, 4)
    }
}

extension AlarmCoordinator {
    /// 预约/运行中允许取消。
    var canCancel: Bool {
        switch phase {
        case .idle: return false
        default: return true
        }
    }
}
