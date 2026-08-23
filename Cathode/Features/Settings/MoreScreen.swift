import SwiftUI

struct MoreScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showEraseConfirm = false
    @State private var hostDraft = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.gutter) {
                    sourcePanel
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
                    HStack {
                        Text("Dish address")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.inkSecondary)
                        Spacer()
                        TextField(DishEndpoint.dishHost, text: $hostDraft)
                            .font(.technical)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .frame(width: 140)
                            .onSubmit {
                                settings.dishHost = hostDraft
                                Task { await model.reconnect() }
                            }
                    }
                    Text("The dish serves gRPC-web on port \(DishEndpoint.dishPort). "
                         + "Change this only if your dish is behind a different address.")
                        .font(.caption2)
                        .foregroundStyle(Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
