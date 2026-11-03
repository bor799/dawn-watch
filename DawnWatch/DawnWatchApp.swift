import SwiftUI
import WatchKit

@main
struct DawnWatchApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var logger: ExperimentLogger
    @StateObject private var health: HealthStore
    @StateObject private var alarm: AlarmCoordinator

    init() {
        let logger = ExperimentLogger()
        let health = HealthStore(logger: logger)
        let alarm = AlarmCoordinator(logger: logger)
        alarm.sleepSufficientProvider = { [weak health] in
            await health?.sleepSufficientForEarlyWake() ?? false
        }
        _logger = StateObject(wrappedValue: logger)
        _health = StateObject(wrappedValue: health)
        _alarm = StateObject(wrappedValue: alarm)
        logger.log(ExperimentEvent(kind: .appLaunch))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(logger)
                .environmentObject(health)
                .environmentObject(alarm)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // 电量计量需要显式开启（G4 功耗对照用）
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }
}
