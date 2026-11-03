import Foundation

/// 实验日志事件。扁平结构：一个 struct 覆盖所有事件类型，未用字段为 nil，
/// 直接一行 JSON 写入 JSONL。禁止把推测（如"识别浅睡眠"）写进事件语义。
struct ExperimentEvent: Equatable, Codable {
    enum Kind: String, Codable {
        case appLaunch
        case breathStart                       // pattern 选择与计划时长
        case breathEnd                         // 实际时长/完成与否
        case healthAuth                        // 授权结果
        case healthSampleSummary               // 读取到的样本概况（数量、最新时间）
        case alarmScheduled                    // start(at:) 成功
        case alarmSessionStarted               // extendedRuntimeSessionDidStart
        case alarmFired                        // notifyUser 已调用，triggerReason 必填
        case alarmDismissed                    // 用户点了 起床了/稍后
        case alarmInvalidated                  // 会话失效（原因 + 错误）
        case motionWindow                      // 一个观察窗口的聚合统计
        case feedback                          // 晨间反馈
        case error                             // 任何错误路径
    }

    enum WakeTrigger: String, Codable {
        case motionCandidate = "motion_candidate"   // 运动候选——严禁表述为"已识别浅睡眠"
        case deadline                                 // 到达截止时刻
        case sessionExpiring                          // 会话将过期，安全余量兜底
        case manualTest = "manual_test"               // 人工试响
    }

    var id: UUID
    var time: Date
    var kind: Kind

    // 呼吸
    var pattern: String?
    var plannedSeconds: Double?
    var actualSeconds: Double?
    var completed: Bool?

    // 健康
    var sampleCount: Int?
    var latestSampleTime: Date?
    var authStatus: String?

    // 闹钟
    var scheduledStart: Date?
    var deadline: Date?
    var triggerReason: WakeTrigger?
    var invalidationReason: String?
    var errorCode: String?

    // 运动窗口
    var samplesCount: Int?
    var p50Interval: Double?
    var p95Interval: Double?
    var motionVariability: Double?
    var sustainedMotionRatio: Double?

    // 功耗
    var startBattery: Double?   // 0–1
    var endBattery: Double?
    var sessionDuration: Double?

    // 晨间反馈
    var sleepiness: Int?        // 0–10
    var comfort: Int?           // 0–10
    var outOfBed: Bool?

    var note: String?

    init(id: UUID = UUID(), time: Date = Date(), kind: Kind) {
        self.id = id
        self.time = time
        self.kind = kind
    }
}

extension ExperimentEvent {
    /// 单行 JSONL（日期用 ISO8601，毫秒精度）。
    func encodedLine(encoder: JSONEncoder = ExperimentEvent.makeEncoder()) -> String {
        guard let data = try? encoder.encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(line: String, decoder: JSONDecoder = makeDecoder()) -> ExperimentEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(ExperimentEvent.self, from: data)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    /// 日志一行摘要（UI 展示用）。
    var summaryLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        var parts: [String] = []
        switch kind {
        case .appLaunch: parts = ["启动"]
        case .breathStart: parts = ["呼吸开始", pattern ?? ""]
        case .breathEnd: parts = ["呼吸结束", (completed ?? false) ? "完成" : "中断"]
        case .healthAuth: parts = ["健康授权", authStatus ?? ""]
        case .healthSampleSummary: parts = ["样本 \(sampleCount ?? 0) 条"]
        case .alarmScheduled: parts = ["已预约", scheduledStart.map { Self.timeLabel($0) } ?? ""]
        case .alarmSessionStarted: parts = ["会话开始"]
        case .alarmFired: parts = ["已提醒", triggerReason?.rawValue ?? ""]
        case .alarmDismissed: parts = ["已处理", triggerReason?.rawValue ?? ""]
        case .alarmInvalidated: parts = ["会话失效", invalidationReason ?? "", errorCode ?? ""]
        case .motionWindow: parts = ["运动窗口 n=\(samplesCount ?? 0)"]
        case .feedback: parts = ["反馈 困倦\(sleepiness ?? -1)"]
        case .error: parts = ["错误", errorCode ?? "", note ?? ""]
        }
        return "\(formatter.string(from: time)) \(parts.joined(separator: " "))"
    }

    static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
