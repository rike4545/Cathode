import SwiftUI

struct MoreScreen: View {
    @Environment(AppModel.self) private var model
    @State private var notifications = NotificationService.shared
    @State private var showEraseConfirm = false
    @State private var hostDraft = ""
    @State private var showManualHost = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.gutter) {
                    sourcePanel
                    notificationsPanel
                    linksPanel
                    appearancePanel
                    dataPanel
                    storagePanel
                    aboutPanel
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 28)
            }
            .background(Color.ground)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { hostDraft = model.settings.dishHost }
            .task { await notifications.refreshAuthorization() }
        }
    }

    // MARK: - Source

    private var sourcePanel: some View {
        @Bindable var settings = model.settings
        return Panel("Connection") {
            VStack(spacing: 10) {
                ForEach(Settings.Source.allCases, id: \.self) { source in
                    Button {
                        guard settings.source != source else { return }
                        settings.source = source
                        Task { await model.reconnect() }
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: settings.source == source
                                  ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(settings.source == source
                                                 ? Color.good : Color.inkTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.label)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.ink)
                                Text(source.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.inkTertiary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }

                if settings.source == .dish {
                    Divider().overlay(Color.hairline)
                    DiscoveryView(hostDraft: $hostDraft, showManual: $showManualHost)
                }

                Divider().overlay(Color.hairline)
                HStack {
                    Text("Poll every")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkSecondary)
                    Spacer()
                    Text("\(Format.decimal(settings.pollIntervalSeconds, places: 1)) s")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                }
                Slider(value: $settings.pollIntervalSeconds, in: 0.5...10, step: 0.5)
            }
        }
    }

    // MARK: - Navigation

    private var linksPanel: some View {
        Panel {
            VStack(spacing: 0) {
                link("Alerts", "bell",
                     alertSubtitle) { AlertsScreen() }
                Divider().overlay(Color.hairline)
                link("Controls", "slider.horizontal.below.square.filled.and.square",
                     "Reboot, stow, sleep schedule, snow melt") { ControlsScreen() }
                Divider().overlay(Color.hairline)
                link("Alert thresholds", "bell.badge",
                     "Tune what counts as a problem") { ThresholdsScreen() }
                Divider().overlay(Color.hairline)
                link("Diagnostics", "stethoscope",
                     "Protocol, capabilities, request console") { DiagnosticsScreen() }
                Divider().overlay(Color.hairline)
                link("Speed test", "speedometer",
                     "Measure the link and its bufferbloat") { SpeedTestScreen() }
            }
        }
    }

    private var alertSubtitle: String {
        let count = model.unacknowledgedAlerts.count
        return count == 0 ? "Nothing needs attention"
            : "\(count) unacknowledged \(count == 1 ? "alert" : "alerts")"
    }

    private func link<Destination: View>(
        _ title: String, _ icon: String, _ subtitle: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.ink)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.inkTertiary)
            }
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notifications

    private var notificationsPanel: some View {
        @Bindable var settings = model.settings
        return Panel("Notifications") {
            Toggle("Alert me about problems", isOn: $settings.notificationsEnabled)
                .font(.system(size: 13, weight: .medium))
                .onChange(of: settings.notificationsEnabled) { _, enabled in
                    Task {
                        if enabled {
                            let granted = await NotificationService.shared.requestAuthorization()
                            // A refused system prompt must not leave the toggle
                            // claiming something the app cannot do.
                            if !granted { settings.notificationsEnabled = false }
                            BackgroundRefresh.schedule()
                        } else {
                            await NotificationService.shared.clearAll()
                            BackgroundRefresh.cancel()
                        }
                    }
                }

            if settings.notificationsEnabled {
                Divider().overlay(Color.hairline)
                Picker("Notify me about", selection: $settings.notifyMinimumSeverity) {
                    ForEach(Alert.Severity.notificationChoices, id: \.rawValue) { severity in
                        Text(severity.notifyLabel).tag(severity.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if !notifications.isAuthorized {
                    Label("Notifications are turned off for Cathode in iOS Settings.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.warn)
                }

                Text("Cathode reads the dish over your local network, so background "
                     + "checks only succeed while this device is on that network. Away "
                     + "from home you will not be alerted — there is no cloud relay, "
                     + "which is also why there is no account.")
                    .font(.caption2)
                    .foregroundStyle(Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isDemo {
                    Text("Demo mode never sends notifications.")
                        .font(.caption2)
                        .foregroundStyle(Color.inkTertiary)
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearancePanel: some View {
        @Bindable var settings = model.settings
        return Panel("Appearance") {
            Picker("Theme", selection: $settings.appearance) {
                ForEach(Settings.Appearance.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)
                .font(.system(size: 13))
            Toggle("Keep the screen awake", isOn: $settings.keepScreenAwake)
                .font(.system(size: 13))
                .onChange(of: settings.keepScreenAwake) { _, on in
                    UIApplication.shared.isIdleTimerDisabled = on
                }
            Text("Useful while aiming a dish outdoors with the phone propped up.")
                .font(.caption2)
                .foregroundStyle(Color.inkTertiary)
        }
    }

    // MARK: - Data

    private var dataPanel: some View {
        @Bindable var settings = model.settings
        return Panel("Data plan") {
            HStack {
                Text("Monthly allowance")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkSecondary)
                Spacer()
                Text(settings.monthlyAllowanceGB > 0
                     ? "\(Int(settings.monthlyAllowanceGB)) GB" : "Unmetered")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
            }
            Slider(value: $settings.monthlyAllowanceGB, in: 0...3000, step: 50)
            Stepper(value: $settings.billingCycleDay, in: 1...28) {
                HStack {
                    Text("Billing cycle starts")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkSecondary)
                    Spacer()
                    Text("day \(settings.billingCycleDay)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.ink)
                }
            }
            Text("Cathode measures usage itself from the dish's throughput counters, so "
                 + "totals reflect what Cathode was running to observe.")
                .font(.caption2)
                .foregroundStyle(Color.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storagePanel: some View {
        Panel("Recorded history") {
            if let stats = model.storeStatistics {
                MetricRow(label: "Database size",
                          value: Format.bytes(Double(stats.fileSizeBytes)).combined)
                MetricRow(label: "Minute rollups kept", value: stats.rollupRows.formatted())
                if let oldest = stats.oldestRecord {
                    MetricRow(label: "Recording since", value: Format.dayAndTime(oldest))
                }
            }
            Text("Second-by-second detail is kept for 48 hours; minute rollups are kept "
                 + "indefinitely. Roughly 30 MB per year.")
                .font(.caption2)
                .foregroundStyle(Color.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Color.hairline)
            Button(role: .destructive) {
                showEraseConfirm = true
            } label: {
                Text("Erase recorded history")
                    .font(.system(size: 13, weight: .semibold))
            }
            .confirmationDialog("Erase all recorded history?",
                                isPresented: $showEraseConfirm, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { Task { await model.eraseHistory() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Charts and uptime figures start again from zero. This cannot be undone.")
            }
        }
    }

    private var aboutPanel: some View {
        Panel("About Cathode") {
            Text("A local-first instrument panel for Starlink. Cathode talks straight to the "
                 + "dish on your network over its own gRPC-web API. Nothing is sent anywhere "
                 + "else, there is no account, and there is no telemetry.")
                .font(.system(size: 12))
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Color.hairline)
            MetricRow(label: "Version",
                      value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            MetricRow(label: "Dish endpoint",
                      value: "\(model.settings.dishHost):\(DishEndpoint.dishPort)", mono: true)
            Text("Not affiliated with, endorsed by, or sponsored by SpaceX or Starlink.")
                .font(.caption2)
                .foregroundStyle(Color.inkTertiary)
                .padding(.top, 2)
        }
    }
}
