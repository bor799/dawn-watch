import Foundation

/// 睡眠历史的纯计算层：把 HealthKit 已写入的 sleepAnalysis 样本
/// 聚合成"每晚摘要"。不做任何实时分期推断——只整理已有记录。
struct SleepInsight: Equatable, Codable {
    /// 与 HKCategoryValueSleepAnalysis 的 rawValue 字符串一一对应，
    /// 由 HealthStore 映射；这里不 import HealthKit，保持平台无关可测试。
    enum Stage: String, Codable, CaseIterable {
        case inBed = "inBed"
        case awake = "awake"
        case asleepCore = "asleepCore"
        case asleepDeep = "asleepDeep"
        case asleepREM = "asleepREM"
        case asleepUnspecified = "asleepUnspecified"

        var isAsleep: Bool {
            switch self {
            case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified: return true
            case .inBed, .awake: return false
            }
        }

        var label: String {
            switch self {
            case .inBed: return "在床"
            case .awake: return "清醒"
            case .asleepCore: return "核心"
            case .asleepDeep: return "深睡"
            case .asleepREM: return "REM"
            case .asleepUnspecified: return "睡眠(未分期)"
            }
        }
    }

    struct Interval: Equatable, Codable {
        var start: Date
        var end: Date
        var stage: Stage
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// 一晚（按"入睡日"归组）的摘要。
    struct Night: Equatable, Codable {
        var nightID: String            // 入睡日的 yyyy-MM-dd
        var bedtime: Date
        var wakeTime: Date
        var stageMinutes: [Stage: Double]
        var totalAsleepMinutes: Double

        var inBedMinutes: Double { stageMinutes[.inBed] ?? 0 }
        var awakeMinutes: Double { stageMinutes[.awake] ?? 0 }

        /// 供 WakePolicy 判断"睡眠是否充分"：总睡眠分钟。
        var asleepMinutes: Double { totalAsleepMinutes }
    }

    /// 单一样本时间轴里最新样本的时间（判断数据新鲜度）。
    static func latestSampleTime(_ intervals: [Interval]) -> Date? {
        intervals.map(\.end).max()
    }

    /// 聚合：按本地日历的"入睡当天"分组，组内按 stage 累计分钟。
    /// 重叠样本按先到优先截断，避免 Apple Watch + iPhone 双源重复计数。
    static func nights(from intervals: [Interval], calendar: Calendar = .current) -> [Night] {
        let sorted = intervals.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        // 去重叠
        var clipped: [Interval] = []
        for item in sorted {
            var current = item
            if let last = clipped.last, current.start < last.end {
                let overlap = last.end.timeIntervalSince(current.start)
                if overlap >= current.duration { continue }
                current.start = last.end
            }
            if current.duration > 0 { clipped.append(current) }
        }
        // 分组
        var groups: [String: [Interval]] = [:]
        for item in clipped {
            let key = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: item.start))
                .map { Self.dayFormatter.string(from: $0) } ?? "unknown"
            groups[key, default: []].append(item)
        }
        return groups.keys.sorted().reversed().compactMap { key in
            guard let items = groups[key], !items.isEmpty else { return nil }
            var minutes: [Stage: Double] = [:]
            for item in items {
                minutes[item.stage, default: 0] += item.duration / 60
            }
            let asleep = minutes.filter { $0.key.isAsleep }.reduce(0) { $0 + $1.value }
            return Night(
                nightID: key,
                bedtime: items.map(\.start).min()!,
                wakeTime: items.map(\.end).max()!,
                stageMinutes: minutes,
                totalAsleepMinutes: asleep)
        }
    }

    /// WakePolicy 用：最近一晚总睡眠是否 ≥ 阈值（默认 6 小时）。
    /// calendar 可注入（测试用固定时区，避免跨午夜分组随宿主时区漂移）。
    static func latestNightSleepSufficient(
        _ intervals: [Interval], minimumMinutes: Double = 6 * 60, now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let recent = intervals.filter { $0.end > now.addingTimeInterval(-36 * 3600) }
        guard let latest = latestSampleTime(recent), latest > now.addingTimeInterval(-36 * 3600) else {
            return false   // 数据缺失/过旧 → 一律视为"不充分"，回退截止唤醒
        }
        // nights 返回按日期降序（最新在前），取 first
        let latestNight = nights(from: recent, calendar: calendar).first
        guard let latestNight else { return false }
        return latestNight.totalAsleepMinutes >= minimumMinutes
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// 心率/呼吸频率等标量历史的最小摘要（只描述"已有记录"，不推断实时性）。
struct ScalarSampleSummary: Equatable, Codable {
    var typeName: String
    var count: Int
    var latestValue: Double?
    var latestUnitLabel: String
    var latestTime: Date?

    init(typeName: String, samples: [(value: Double, time: Date)], unitLabel: String) {
        self.typeName = typeName
        self.count = samples.count
        self.latestUnitLabel = unitLabel
        let latest = samples.max { $0.time < $1.time }
        self.latestValue = latest?.value
        self.latestTime = latest?.time
    }

    /// 距现在多久（人类可读），供 UI 强调"这是历史记录不是实时值"。
    func ageLabel(now: Date = Date()) -> String? {
        guard let latestTime else { return nil }
        let seconds = now.timeIntervalSince(latestTime)
        switch seconds {
        case ..<90: return "刚刚"
        case ..<3600: return "\(Int(seconds / 60)) 分钟前"
        case ..<86_400: return "\(Int(seconds / 3600)) 小时前"
        default: return "\(Int(seconds / 86_400)) 天前"
        }
    }
}
