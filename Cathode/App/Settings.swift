import Foundation
import SwiftUI

/// User preferences, persisted in `UserDefaults`.
///
/// Deliberately small: anything that can be derived from telemetry is derived,
/// not stored. What lives here is the handful of choices the app genuinely
/// cannot infer — where the dish is, how often to poll, what counts as a problem.
@Observable
final class Settings {
    enum Source: String, CaseIterable, Codable, Sendable {
        /// Talk to real hardware on the local network.
        case dish
        /// Run against the built-in simulator.
        case demo

        var label: String {
            switch self {
            case .dish: "My Starlink"
            case .demo: "Demo mode"
            }
        }
        var detail: String {
            switch self {
            case .dish: "Connect to the dish on this network"
            case .demo: "Explore Cathode with simulated telemetry"
            }
        }
    }

    enum Appearance: String, CaseIterable, Codable, Sendable {
        case system, dark, light
        var label: String {
            switch self {
            case .system: "System"
            case .dark: "Dark"
            case .light: "Light"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .dark: .dark
            case .light: .light
            }
        }
    }

    var source: Source { didSet { store(source.rawValue, .source) } }
    var dishHost: String { didSet { store(dishHost, .dishHost) } }
    var pollIntervalSeconds: Double { didSet { store(pollIntervalSeconds, .pollInterval) } }
    var appearance: Appearance { didSet { store(appearance.rawValue, .appearance) } }
    var notificationsEnabled: Bool { didSet { store(notificationsEnabled, .notifications) } }
    /// Minimum severity that raises a local notification.
    var notifyMinimumSeverity: Int { didSet { store(notifyMinimumSeverity, .notifySeverity) } }
    var keepScreenAwake: Bool { didSet { store(keepScreenAwake, .keepAwake) } }
    var hapticsEnabled: Bool { didSet { store(hapticsEnabled, .haptics) } }
    /// Monthly data allowance in GB; 0 means unmetered.
    var monthlyAllowanceGB: Double { didSet { store(monthlyAllowanceGB, .allowance) } }
    /// Day of month the billing cycle restarts.
    var billingCycleDay: Int { didSet { store(billingCycleDay, .billingDay) } }
    var thresholds: AlertEngine.Thresholds { didSet { storeCodable(thresholds, .thresholds) } }

    private enum Key: String {
        case source, dishHost, pollInterval, appearance, notifications, notifySeverity
        case keepAwake, haptics, allowance, billingDay, thresholds
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Demo mode is the first-run default: it makes the app immediately
        // explorable, and someone without a dish on this network gets a working
        // product rather than a connection error.
        self.source = defaults.string(forKey: Key.source.rawValue)
            .flatMap(Source.init) ?? .demo
        self.dishHost = defaults.string(forKey: Key.dishHost.rawValue) ?? DishEndpoint.dishHost
        let interval = defaults.double(forKey: Key.pollInterval.rawValue)
        self.pollIntervalSeconds = interval > 0 ? interval : 1
        self.appearance = defaults.string(forKey: Key.appearance.rawValue)
            .flatMap(Appearance.init) ?? .system
        self.notificationsEnabled = defaults.object(forKey: Key.notifications.rawValue) as? Bool ?? false
        self.notifyMinimumSeverity = defaults.object(forKey: Key.notifySeverity.rawValue) as? Int
            ?? Alert.Severity.critical.rawValue
        self.keepScreenAwake = defaults.bool(forKey: Key.keepAwake.rawValue)
        self.hapticsEnabled = defaults.object(forKey: Key.haptics.rawValue) as? Bool ?? true
        self.monthlyAllowanceGB = defaults.double(forKey: Key.allowance.rawValue)
        let day = defaults.integer(forKey: Key.billingDay.rawValue)
        self.billingCycleDay = day > 0 ? day : 1
        self.thresholds = (defaults.data(forKey: Key.thresholds.rawValue)
            .flatMap { try? JSONDecoder().decode(AlertEngine.Thresholds.self, from: $0) })
            ?? .default
    }

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private func storeCodable(_ value: some Codable, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }

    /// Start of the current billing month, respecting `billingCycleDay`.
    func billingPeriodStart(now: Date = .now, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = min(billingCycleDay, 28)
        let candidate = calendar.date(from: components) ?? now
        if candidate > now {
            return calendar.date(byAdding: .month, value: -1, to: candidate) ?? candidate
        }
        return candidate
    }
}
