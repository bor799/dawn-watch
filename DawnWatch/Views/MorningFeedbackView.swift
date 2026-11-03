import SwiftUI

/// 晨间反馈（F08）：困倦 0–10 / 离床状态 / 训练舒适度 0–10，本地记录。
struct MorningFeedbackView: View {
    @EnvironmentObject private var logger: ExperimentLogger
    @EnvironmentObject private var alarm: AlarmCoordinator

    @State private var sleepiness = 5
    @State private var comfort = 5
    @State private var outOfBed = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionCard("现在的困倦感（0 清醒 – 10 极困）") {
                    Stepper(value: $sleepiness, in: 0...10) {
                        Text("\(sleepiness)").font(.title3).monospacedDigit()
                    }
                }

                SectionCard("呼吸训练舒适度（0–10）") {
                    Stepper(value: $comfort, in: 0...10) {
                        Text("\(comfort)").font(.title3).monospacedDigit()
                    }
                }

                SectionCard("状态") {
                    Picker("离床", selection: $outOfBed) {
                        Text("已离床").tag(true)
                        Text("又睡着了").tag(false)
                    }
                    .labelsHidden()
                }

                Button("保存反馈") {
                    var event = ExperimentEvent(kind: .feedback)
                    event.sleepiness = sleepiness
                    event.comfort = comfort
                    event.outOfBed = outOfBed
                    logger.log(event)
                    if alarm.phase.isFired { alarm.dismiss() }
                }
                .tint(.green)

                recentSection
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("晨间反馈")
    }

    private var recentSection: some View {
        SectionCard("最近反馈") {
            let feedback = logger.recentEvents.filter { $0.kind == .feedback }
            if feedback.isEmpty {
                Text("暂无记录").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(Array(feedback.prefix(7).enumerated()), id: \.offset) { _, event in
                    Text("困倦 \(event.sleepiness ?? -1) · 舒适 \(event.comfort ?? -1) · \(event.outOfBed == true ? "离床" : "又睡") · \(ExperimentEvent.timeLabel(event.time))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
