import Foundation

/// 闹钟偏好（持久化在 UserDefaults，JSON 编码）。
/// 只存"用户想要的"，不存系统会话状态——会话事实由 AlarmCoordinator 记录在实验日志里。
struct AlarmSettings: Equatable, Codable {
    enum ScheduleKind: String, Codable {
        case morning   // 明晨正式唤醒
        case test      // F04 短间隔试响
    }

    var enabled: Bool
    /// 截止时刻（本地时区的当日钟点）。跨时区/夏令时由 Calendar 重算，不存绝对 Date。
    var hour: Int
    var minute: Int
    /// 智能唤醒窗口长度，秒。WakePolicy 硬钳制为 30min − 2×安全余量 = 27min，
    /// 默认值直接存 27min，避免"设了 28 实际跑 27"的隐性偏差。
    var windowSeconds: TimeInterval
    /// P1 提前唤醒开关。默认关：没有可靠证据时不提前。
    var allowsEarlyWake: Bool
    var createdAt: Date?

    /// 最近一次成功预约的事实（用于 App 重启后恢复显示；不作为会话真值）。
    var lastScheduleKind: ScheduleKind?
    var lastScheduledStart: Date?
    var lastScheduledDeadline: Date?

    static let `default` = AlarmSettings(
        enabled: false,
        hour: 7, minute: 30,
        windowSeconds: 27 * 60,
        allowsEarlyWake: false,
        createdAt: nil,
        lastScheduleKind: nil,
        lastScheduledStart: nil,
        lastScheduledDeadline: nil)

    // MARK: - 持久化

    static var storageKey: String { "dawn.alarm.settings" }

    static func load(from defaults: UserDefaults = .standard) -> AlarmSettings {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(AlarmSettings.self, from: data)
        else { return .default }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

extension AlarmSettings {
    /// 下一次截止时刻：今天该钟点还没到就用今天，否则用明天。
    /// 用 Calendar 而不是秒数加减，保证夏令时/时区正确。
    func nextDeadline(after now: Date, calendar: Calendar = .current) -> Date {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = calendar.nextDate(
            after: now, matching: comps, matchingPolicy: .nextTime,
            repeatedTimePolicy: .first, direction: .forward)
        if let today, today > now {
            return today
        }
        // nextDate(after:) 严格大于 now，通常不会走到这里；兜底 +1 天
        return calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
    }

    /// 供 UI 显示的 "07:30"。
    var timeLabel: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
