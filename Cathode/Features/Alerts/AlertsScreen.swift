import SwiftUI

struct AlertsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showAcknowledged = false

    private var visible: [Alert] {
        showAcknowledged ? model.alerts : model.unacknowledgedAlerts
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.gutter) {
                    if visible.isEmpty {
                        allClearPanel
                    } else {
                        ForEach(visible) { alert in
                            AlertCard(
                                alert: alert,
                                isAcknowledged: model.acknowledgedAlertIDs.contains(alert.id),
                                onAcknowledge: { model.acknowledge(alert) })
                        }
                    }
                    if !model.recentOutages.isEmpty { recentOutagesPanel }
                    thresholdsLink
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 28)
            }
            .background(Color.ground)
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show acknowledged", isOn: $showAcknowledged)
                        if !model.unacknowledgedAlerts.isEmpty {
                            Button("Acknowledge all") { model.acknowledgeAll() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var allClearPanel: some View {
        Panel {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.good)
                Text("Everything looks healthy")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("Cathode is watching latency, packet loss, obstruction, signal, "
                     + "stability and the dish's own hardware alerts.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
    }

    private var recentOutagesPanel: some View {
        Panel("Recent outages", subtitle: "Last 30 days") {
            VStack(spacing: 0) {
                ForEach(model.recentOutages.prefix(8)) { outage in
                    HStack(spacing: 10) {
                        Circle().fill(Color.bad).frame(width: 5, height: 5)
                        Text(outage.cause)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.ink)
                        Spacer()
                        Text(Format.preciseDuration(outage.duration))
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.inkSecondary)
                        Text(Format.relative(outage.start))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.inkTertiary)
                            .frame(width: 74, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var thresholdsLink: some View {
        NavigationLink {
            ThresholdsScreen()
        } label: {
            Panel {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color.inkSecondary)
                    Text("Alert thresholds")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.inkTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct AlertCard: View {
    var alert: Alert
    var isAcknowledged: Bool
    var onAcknowledge: () -> Void

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: alert.severity.icon)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.tone(alert.severity.tone))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ink)
                        Text(alert.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if let remedy = alert.remedy {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.latency)
                        Text(remedy)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surfaceSunken, in: .rect(cornerRadius: Metrics.innerRadius))
                }

                HStack(spacing: 8) {
                    Text(alert.severity.label.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.tone(alert.severity.tone))
                    if alert.isFromHardware {
                        Text("FROM DISH")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.inkTertiary)
                    }
                    Text("· active \(Format.duration(max(1, alert.age)))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.inkTertiary)
                    Spacer()
                    if isAcknowledged {
                        Label("Acknowledged", systemImage: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.inkTertiary)
                    } else {
                        Button("Acknowledge", action: onAcknowledge)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
        }
        .opacity(isAcknowledged ? 0.55 : 1)
    }
}
