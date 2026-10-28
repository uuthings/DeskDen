import Foundation
import UserNotifications
import LauncherCore

enum DeviceNotificationPermission: String, Sendable {
    case unknown, notDetermined, authorized, denied, unavailable
    var title: String { switch self { case .unknown: "正在检查"; case .notDetermined: "尚未授权"; case .authorized: "已允许通知"; case .denied: "通知未获允许"; case .unavailable: "通知服务不可用" } }
}
@MainActor protocol DeviceNotificationProviding {
    func permission() async -> DeviceNotificationPermission
    func requestPermission() async throws -> Bool
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws
}
/// Shares the app's existing notification delegate with calendar reminders; never replaces it.
@MainActor final class DeviceAlertService: DeviceNotificationProviding {
    private var center: UNUserNotificationCenter { .current() }
    func permission() async -> DeviceNotificationPermission {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .unavailable
        }
    }
    func requestPermission() async throws -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws {
        let content = UNMutableNotificationContent(); content.sound = .default; content.threadIdentifier = "deskden-device"
        switch event {
        case .budgetWarning(let percent):
            content.userInfo=["deskdenRoute":"network","detail":"budget"]
            content.title = "流量预算接近额度"
            content.body = "\(budget.scope.title)的\(budget.period.title)已记录流量达到预算的 \(percent)%。仅统计方寸运行期间采集到的流量。"
        case .budgetExceeded:
            content.userInfo=["deskdenRoute":"network","detail":"budget"]
            content.title = "流量预算已超出"
            content.body = "\(budget.scope.title)的\(budget.period.title)已记录流量达到或超过 \(budget.limitGB.formatted()) GB。此提醒不会限速或断网。"
        case .temperature(let sensor, let value):
            content.userInfo=["deskdenRoute":"device","detail":"thermal"]
            content.title = "\(sensor) 持续高温"
            content.body = "当前 \(Int(value.rounded()))°C，连续采样达到阈值已持续至少 \(rule.sustainedSeconds) 秒。可前往设备状态查看。"
        }
        let request = UNNotificationRequest(identifier: "deskden-device-\(UUID().uuidString)", content: content, trigger: nil)
        try await center.add(request)
    }
}
