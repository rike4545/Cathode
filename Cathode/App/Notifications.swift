import Foundation
import UserNotifications

/// Delivers alerts as local notifications.
///
/// The alert engine already decides what matters and how badly; this only
/// decides what is worth interrupting someone for, and makes sure the same
/// problem does not notify twice. A dish that drops out for ten seconds every
/// few minutes would otherwise produce a notification storm — which is exactly
/// the situation where a monitoring app becomes something you mute.
@MainActor
@Observable
final class NotificationService {
    static let shared = NotificationService()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Alert IDs that currently have a delivered or pending notification.
    private var outstanding: Set<String> = []

    private let center = UNUserNotificationCenter.current()

    private init() {}

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .provisional
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks for permission. Returns whether notifications can now be delivered.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            await refreshAuthorization()
            return false
        }
    }

    /// Reconciles delivered notifications against the current alert set.
    ///
    /// New alerts at or above `minimum` are posted; alerts that have cleared
    /// have their notifications withdrawn, so the lock screen reflects what is
    /// wrong *now* rather than a history of everything that ever went wrong.
    func sync(alerts: [Alert], minimum: Alert.Severity, enabled: Bool) async {
        guard enabled, isAuthorized else {
            if !outstanding.isEmpty { await clearAll() }
            return
        }

        let notifiable = alerts.filter { $0.severity >= minimum }
        let current = Set(notifiable.map(\.id))

        // Withdraw anything that has resolved.
        let resolved = outstanding.subtracting(current)
        if !resolved.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: Array(resolved))
            center.removePendingNotificationRequests(withIdentifiers: Array(resolved))
            outstanding.subtract(resolved)
        }

        // Post anything new. Reusing the alert ID as the request identifier
        // means a repeat of the same condition replaces rather than stacks.
        for alert in notifiable where !outstanding.contains(alert.id) {
            await post(alert)
            outstanding.insert(alert.id)
        }

        await updateBadge(count: notifiable.count)
    }

    private func post(_ alert: Alert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.remedy.map { "\(alert.detail) \($0)" } ?? alert.detail
        content.sound = alert.severity == .critical ? .defaultCritical : .default
        content.interruptionLevel = alert.severity == .critical ? .timeSensitive : .active
        content.threadIdentifier = "cathode.alerts"
        content.categoryIdentifier = "cathode.alert"
        content.userInfo = ["alertID": alert.id, "severity": alert.severity.rawValue]

        // No trigger: deliver immediately.
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        try? await center.add(request)
    }

    func clearAll() async {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        outstanding.removeAll()
        await updateBadge(count: 0)
    }

    private func updateBadge(count: Int) async {
        try? await center.setBadgeCount(count)
    }

    /// Used by the background task, which has no live `AppModel` to reconcile
    /// against and simply reports what it found.
    nonisolated static func postDetached(_ alert: Alert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        content.sound = .default
        content.interruptionLevel = alert.severity == .critical ? .timeSensitive : .active
        content.threadIdentifier = "cathode.alerts"
        content.userInfo = ["alertID": alert.id]
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension Alert.Severity {
    /// Options offered in Settings for "notify me about…".
    static var notificationChoices: [Alert.Severity] { [.info, .warning, .critical] }

    var notifyLabel: String {
        switch self {
        case .info: "Everything"
        case .warning: "Warnings"
        case .critical: "Critical"
        }
    }
}
