import Foundation
import BackgroundTasks

/// Periodic checks while the app is not open.
///
/// An honest caveat, surfaced in Settings rather than buried: Cathode reads the
/// dish over the local network, so a background check only succeeds while the
/// device is actually on that network. Off it — on cellular, or at work — the
/// check fails quietly and nothing is reported. This is a monitor for the
/// place the dish is, not a remote monitoring service, and there is no cloud
/// relay that would make it one.
///
/// iOS also decides when these run. `earliestBeginDate` is a floor, not a
/// schedule; the system may run it far less often than requested.
enum BackgroundRefresh {
    static let taskIdentifier = "dev.cathode.refresh"
    /// Ask for a check roughly every 20 minutes; iOS will do as it pleases.
    static let interval: TimeInterval = 20 * 60

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        // Throws when the app is not entitled or too many requests are queued;
        // neither is worth interrupting the user over.
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Always queue the next one first: if this check crashes or is killed,
        // the chain still continues.
        schedule()

        // `BGAppRefreshTask` is not `Sendable`, but BackgroundTasks guarantees
        // the launch handler and the expiration handler are serialised against
        // each other, and nothing else touches this reference. The unchecked
        // capture is accurate rather than a way around the checker.
        nonisolated(unsafe) let task = task

        let work = Task.detached(priority: .background) {
            await performCheck()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// One poll, evaluated against the user's thresholds, notifying anything
    /// that clears the bar. Deliberately independent of the live `AppModel` —
    /// in the background there is no running poll loop to borrow from.
    static func performCheck() async {
        let settings = Settings()
        guard settings.notificationsEnabled else { return }
        guard settings.source == .dish else { return } // never notify on demo data

        let host = settings.dishHost
        let thresholds = settings.thresholds
        let minimum = Alert.Severity(rawValue: settings.notifyMinimumSeverity) ?? .critical

        let client = DishClient(transport: GrpcWebTransport(host: host))
        guard let status = try? await client.status() else { return }

        var engine = AlertEngine()
        engine.thresholds = thresholds
        let alerts = engine.evaluate(status: status, recent: [], previous: [])

        for alert in alerts where alert.severity >= minimum {
            await NotificationService.postDetached(alert)
        }
    }
}
