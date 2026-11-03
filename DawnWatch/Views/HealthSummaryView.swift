import SwiftUI

/// 健康数据摘要（F03）：只读已有记录，突出"样本时间"与缺失状态。
struct HealthSummaryView: View {
    @EnvironmentObject private var health: HealthStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if health.lastAuthOutcome == nil {
                    Button("读取健康数据") {
                        Task {
                            await health.requestAuthorization()
                            await health.refresh()
                        }
                    }
                    .tint(.green)
                    Text("需要健康读取权限（只读，不写入）。拒绝授权不会影响其他功能。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let outcome = health.lastAuthOutcome {
                    authLine(outcome)
                }

                sleepSection
                scalarSection("心率", health.heartRateSummary)
                scalarSection("呼吸频率", health.respiratorySummary)

                Text("以上均为系统已有记录（含采样时间），不是实时值；缺失属正常。")
                    .font(.footnote).foregroundStyle(.secondary)

                if health.nights.isEmpty && health.lastAuthOutcome != nil {
                    Button("刷新") {
                        Task { await health.refresh() }
                    }
                }
                if let error = health.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("健康数据")
        .task {
            if health.lastAuthOutcome == .authorized, health.nights.isEmpty {
                await health.refresh()
            }
        }
    }

    private func authLine(_ outcome: HealthStore.AuthorizationOutcome) -> some View {
        Text(outcome == .authorized
             ? "已授权读取"
             : "未授权：可在手表 设置>健康>数据访问与设备 中修改")
            .font(.footnote)
            .foregroundStyle(outcome == .authorized ? Color.green : Color.orange)
    }

    private var sleepSection: some View {
        SectionCard("最近 7 晚睡眠（系统记录）") {
            if health.nights.isEmpty {
                Text("无睡眠记录。请确认手表佩戴就寝或手机睡眠监测已开启。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(health.nights.prefix(7), id: \.nightID) { night in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(nightTitle(night)).font(.footnote.weight(.medium))
                        Text(stageLine(night))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func nightTitle(_ night: SleepInsight.Night) -> String {
        let total = night.totalAsleepMinutes
        return "\(night.nightID.suffix(5)) 共睡 \(Int(total / 60))h\(Int(total.truncatingRemainder(dividingBy: 60)))m"
    }

    private func stageLine(_ night: SleepInsight.Night) -> String {
        func m(_ stage: SleepInsight.Stage) -> Int { Int(night.stageMinutes[stage] ?? 0) }
        return "深\(m(.asleepDeep)) 核\(m(.asleepCore)) R\(m(.asleepREM)) 清醒\(m(.awake)) 在床\(m(.inBed))"
    }

    @ViewBuilder
    private func scalarSection(_ title: String, _ summary: ScalarSampleSummary?) -> some View {
        SectionCard(title) {
            if let summary {
                if let value = summary.latestValue {
                    Text("\(String(format: "%.0f", value)) \(summary.latestUnitLabel)")
                        .font(.title3)
                    if let time = summary.latestTime {
                        Text("采样于 \(ExperimentEvent.timeLabel(time))（\(summary.ageLabel() ?? "未知")）")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("近 7 天无样本").font(.footnote).foregroundStyle(.secondary)
                }
                Text("样本数 \(summary.count)")
                    .font(.footnote2Fallback).foregroundStyle(.tertiary)
            } else {
                Text("尚未读取").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

extension Font {
    /// watchOS 低版本兜底的小字。
    static let footnote2Fallback: Font = .footnote
}
