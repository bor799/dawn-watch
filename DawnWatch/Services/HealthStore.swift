import Foundation
import HealthKit
import Combine

/// HealthKit 只读访问层。只读取系统已有记录，不写入、不订阅实时流。
/// 数据缺失/授权拒绝都必须能正常返回（F03/F07：不崩溃、不推断）。
@MainActor
final class HealthStore: ObservableObject {
    enum AuthorizationOutcome: String {
        case authorized
        case denied
        case notAvailableOnDevice
    }

    @Published private(set) var lastAuthOutcome: AuthorizationOutcome?
    @Published private(set) var nights: [SleepInsight.Night] = []
    @Published private(set) var heartRateSummary: ScalarSampleSummary?
    @Published private(set) var respiratorySummary: ScalarSampleSummary?
    @Published private(set) var lastError: String?

    private let store = HKHealthStore()
    private let logger: ExperimentLogger?

    init(logger: ExperimentLogger? = nil) {
        self.logger = logger
    }

    static var readTypes: Set<HKObjectType> {
        // categoryType(for:)/quantityType(for:) 返回 Optional（静态标识符必有效）
        Set([
            HKObjectType.categoryType(for: .sleepAnalysis),
            HKObjectType.quantityType(for: .heartRate),
            HKObjectType.quantityType(for: .respiratoryRate),
        ].compactMap { $0 })
    }

    func requestAuthorization() async -> AuthorizationOutcome {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastAuthOutcome = .notAvailableOnDevice
            logger?.log(ExperimentEvent(kind: .healthAuth).with(authStatus: "notAvailable"))
            return .notAvailableOnDevice
        }
        let outcome: AuthorizationOutcome = await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: Self.readTypes) { [weak self] granted, _ in
                // 拒绝时 HealthKit 不会报错，只是返回空数据——这里如实记录。
                let result: AuthorizationOutcome = granted ? .authorized : .denied
                continuation.resume(returning: result)
                Task { @MainActor [weak self] in
                    self?.lastAuthOutcome = result
                    self?.logger?.log(ExperimentEvent(kind: .healthAuth).with(authStatus: result.rawValue))
                }
            }
        }
        return outcome
    }

    /// 拉取最近 7 晚睡眠 + 心率/呼吸频率历史。
    func refresh(days: Int = 7) async {
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let intervals = await fetchSleepIntervals(since: since)
        let heart = await fetchQuantity(type: .heartRate, since: since)
        let resp = await fetchQuantity(type: .respiratoryRate, since: since)
        nights = SleepInsight.nights(from: intervals)
        heartRateSummary = ScalarSampleSummary(
            typeName: "心率", samples: heart.map { ($0.value, $0.date) }, unitLabel: "次/分")
        respiratorySummary = ScalarSampleSummary(
            typeName: "呼吸频率", samples: resp.map { ($0.value, $0.date) }, unitLabel: "次/分")
        let event = ExperimentEvent(kind: .healthSampleSummary)
            .with(sampleCount: intervals.count + heart.count + resp.count,
                  latestSampleTime: SleepInsight.latestSampleTime(intervals))
        logger?.log(event)
    }

    /// 供 WakePolicy：最近睡眠是否充分（缺失 → false → 不提前唤醒）。
    func sleepSufficientForEarlyWake() async -> Bool {
        let since = Date().addingTimeInterval(-36 * 3600)
        let intervals = await fetchSleepIntervals(since: since)
        return SleepInsight.latestNightSleepSufficient(intervals, now: Date())
    }

    // MARK: - 查询

    private func fetchSleepIntervals(since: Date) async -> [SleepInsight.Interval] {
        guard let type = HKObjectType.categoryType(for: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(
            withStart: since, end: nil, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: 500,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    Task { @MainActor [weak self] in
                        self?.lastError = "睡眠查询失败: \(error.localizedDescription)"
                    }
                }
                let intervals = (samples as? [HKCategorySample])?.compactMap { sample in
                    Self.interval(from: sample)
                } ?? []
                continuation.resume(returning: intervals)
            }
            store.execute(query)
        }
    }

    private func fetchQuantity(
        type identifier: HKQuantityTypeIdentifier, since: Date
    ) async -> [(value: Double, date: Date)] {
        guard let type = HKObjectType.quantityType(for: identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(
            withStart: since, end: nil, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: 200,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                let unit: HKUnit = identifier == .heartRate
                    ? HKUnit.count().unitDivided(by: .minute())
                    : HKUnit.count().unitDivided(by: .minute())
                let values = (samples as? [HKQuantitySample])?.map { sample in
                    (value: sample.quantity.doubleValue(for: unit), date: sample.endDate)
                } ?? []
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    /// HKCategoryValueSleepAnalysis → 平台无关的 SleepInsight.Stage。
    nonisolated static func interval(from sample: HKCategorySample) -> SleepInsight.Interval? {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
        let stage: SleepInsight.Stage
        switch value {
        case .inBed: stage = .inBed
        case .awake: stage = .awake
        case .asleepUnspecified: stage = .asleepUnspecified
        case .asleepCore: stage = .asleepCore
        case .asleepDeep: stage = .asleepDeep
        case .asleepREM: stage = .asleepREM
        default: return nil   // .asleepCDSV / hypnapnea 等罕见值，忽略
        }
        return SleepInsight.Interval(start: sample.startDate, end: sample.endDate, stage: stage)
    }
}

// MARK: - 事件便捷填充

extension ExperimentEvent {
    func with(authStatus: String) -> ExperimentEvent {
        var copy = self
        copy.authStatus = authStatus
        return copy
    }

    func with(sampleCount: Int, latestSampleTime: Date? = nil) -> ExperimentEvent {
        var copy = self
        copy.sampleCount = sampleCount
        copy.latestSampleTime = latestSampleTime
        return copy
    }
}
