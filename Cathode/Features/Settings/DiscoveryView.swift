import SwiftUI

/// Finding the dish, and saying plainly what was found.
///
/// The address used to be a text field pre-filled with `192.168.100.1`, which
/// asked the user to know something they have no reason to know. Cathode probes
/// for the hardware instead and only exposes the address when automatic
/// detection has failed, or when someone deliberately wants to override it.
struct DiscoveryView: View {
    @Environment(AppModel.self) private var model
    @Binding var hostDraft: String
    @Binding var showManual: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            statusRow

            if case .sweeping(let progress) = model.discovery {
                ProgressView(value: progress)
                    .tint(.good)
                Text("Checking every address on this network — \(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Color.inkTertiary)
            }

            if model.discovered.count > 1 {
                Divider().overlay(Color.hairline)
                ForEach(model.discovered) { device in
                    DiscoveredRow(device: device,
                                  isSelected: device.host == model.settings.dishHost) {
                        model.settings.dishHost = device.host
                        model.settings.dishHostIsPinned = true
                        Task { await model.reconnect() }
                    }
                }
            }

            actions

            if showManual {
                Divider().overlay(Color.hairline)
                manualEntry
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        switch model.discovery {
        case .idle:
            row(icon: "antenna.radiowaves.left.and.right", tone: .idle,
                title: "Not searched yet",
                detail: "Cathode will look for your dish when it connects.")
        case .searching:
            HStack(spacing: 11) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looking for your dish")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.ink)
                    Text("Checking the addresses Starlink hardware uses.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkTertiary)
                }
                Spacer()
            }
        case .sweeping:
            HStack(spacing: 11) {
                ProgressView().controlSize(.small)
                Text("Scanning the network")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink)
                Spacer()
            }
        case .found(let host, let name):
            row(icon: "checkmark.circle.fill", tone: .good,
                title: "Found \(name)",
                detail: "\(host) · \(model.settings.dishHostIsPinned ? "set by you" : "detected automatically")")
        case .notFound:
            row(icon: "exclamationmark.triangle.fill", tone: .warn,
                title: "No Starlink found on this network",
                detail: "Join your Starlink Wi-Fi and try again, or scan every "
                      + "address if your router uses an unusual subnet.")
        }
    }

    private func row(icon: String, tone: Tone, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.tone(tone))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                Task {
                    model.settings.dishHostIsPinned = false
                    await model.runDiscovery()
                    await model.reconnect()
                }
            } label: {
                Label("Search again", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .disabled(model.discovery.isBusy)

            Button {
                Task {
                    await model.sweepNetwork()
                    await model.reconnect()
                }
            } label: {
                Label("Scan network", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
            }
            .disabled(model.discovery.isBusy)

            Spacer()

            Button(showManual ? "Hide" : "Manual") {
                withAnimation(.snappy(duration: 0.2)) { showManual.toggle() }
                hostDraft = model.settings.dishHost
            }
            .font(.system(size: 12, weight: .semibold))
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 7) {
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
                    .frame(width: 150)
                    .onSubmit(applyManual)
            }
            Button("Use this address", action: applyManual)
                .font(.system(size: 12, weight: .semibold))
                .disabled(hostDraft.isEmpty || hostDraft == model.settings.dishHost)
            Text("Cathode talks to the dish on port \(DishEndpoint.dishPort). Setting an "
                 + "address by hand stops automatic detection from changing it.")
                .font(.caption2)
                .foregroundStyle(Color.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyManual() {
        let trimmed = hostDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.settings.dishHost = trimmed
        model.settings.dishHostIsPinned = true
        Task { await model.reconnect() }
    }
}

/// One responder from a scan, when more than one thing answered.
struct DiscoveredRow: View {
    var device: DishDiscovery.Found
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: device.kind == .dish ? "antenna.radiowaves.left.and.right" : "wifi.router")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.good : Color.inkSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.describedName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ink)
                    Text("\(device.host) · \(device.responseMilliseconds) ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.inkTertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.good)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
