import SwiftUI

/// The screen for when something is wrong with Cathode rather than the dish.
///
/// Starlink's Device API is undocumented, so being transparent about what the
/// app is guessing — and letting someone check it against their own hardware —
/// is part of the product, not a debug leftover.
struct DiagnosticsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var probe: [Operation: Bool] = [:]
    @State private var probing = false
    @State private var rawOperation: Operation = .getStatus
    @State private var rawResult: String?
    @State private var rawRunning = false

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.gutter) {
                connectionPanel
                capabilityPanel
                schemaPanel
                consolePanel
                storagePanel
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 28)
        }
        .background(Color.ground)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectionPanel: some View {
        Panel("Connection") {
            MetricRow(label: "Transport", value: model.transportKind, mono: true)
            MetricRow(label: "Endpoint", value: model.transportTarget, mono: true)
            MetricRow(label: "State", value: model.connection.label, tone: model.connection.tone)
            if let last = model.lastUpdate {
                MetricRow(label: "Last successful poll", value: Format.relative(last))
            }
            if case .failed(let message, let hint) = model.connection {
                Divider().overlay(Color.hairline)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.bad)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(Color.hairline)
            MetricRow(label: "Dish ID", value: model.status?.deviceInfo.id ?? "—", mono: true)
            MetricRow(label: "Hardware",
                      value: model.status?.deviceInfo.hardwareVersion ?? "—", mono: true)
            MetricRow(label: "Firmware",
                      value: model.status?.deviceInfo.softwareVersion ?? "—", mono: true)
            MetricRow(label: "Boot count",
                      value: model.status?.deviceInfo.bootcount.map(String.init) ?? "—")
        }
    }

    private var capabilityPanel: some View {
        Panel("Supported operations",
              subtitle: "What this endpoint actually answers") {
            Button {
                runProbe()
            } label: {
                HStack(spacing: 6) {
                    if probing { ProgressView().controlSize(.small) }
                    Text(probing ? "Probing…" : "Probe")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .disabled(probing)
        } content: {
            if probe.isEmpty {
                Text("Sends one read-only request per operation and records which ones the "
                     + "hardware implements. Nothing is modified.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Operation.allCases.filter { probe[$0] != nil }, id: \.self) { op in
                        HStack {
                            Image(systemName: probe[op] == true
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(probe[op] == true ? Color.good : Color.inkTertiary)
                            Text(op.label)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ink)
                            Spacer()
                            Text("field \(op.field)")
                                .font(.technical)
                                .foregroundStyle(Color.inkTertiary)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    private var schemaPanel: some View {
        Panel("Protocol") {
            Text("Starlink's Device API is not publicly documented. Cathode decodes responses "
                 + "structurally — by field number and wire type — instead of compiling a "
                 + "checked-in schema, so a firmware update that adds fields does not break "
                 + "the app, and a field it cannot find reads as unknown rather than as a "
                 + "wrong number.")
                .font(.system(size: 12))
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Color.hairline)
            MetricRow(label: "Service", value: "SpaceX.API.Device.Device", mono: true)
            MetricRow(label: "Method", value: "Handle", mono: true)
            MetricRow(label: "Wire format", value: "gRPC-web (proto)", mono: true)
            MetricRow(label: "Field map", value: "built-in", mono: true)
        }
    }

    private var consolePanel: some View {
        Panel("Request console", subtitle: "Read-only operations") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Operation", selection: $rawOperation) {
                    ForEach(Operation.allCases.filter { !$0.isMutating }, id: \.self) { op in
                        Text(op.label).tag(op)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 13))

                Button {
                    runRaw()
                } label: {
                    HStack(spacing: 6) {
                        if rawRunning { ProgressView().controlSize(.small) }
                        Text("Send")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.surfaceRaised, in: .rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink)
                .disabled(rawRunning)

                if let rawResult {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(rawResult)
                            .font(.technical)
                            .foregroundStyle(Color.inkSecondary)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxHeight: 260)
                    .background(Color.surfaceSunken, in: .rect(cornerRadius: Metrics.innerRadius))
                }
            }
        }
    }

    private var storagePanel: some View {
        Panel("Local storage") {
            if let stats = model.storeStatistics {
                MetricRow(label: "Second-resolution rows", value: stats.sampleRows.formatted())
                MetricRow(label: "Minute rollups", value: stats.rollupRows.formatted())
                MetricRow(label: "Outages", value: stats.outageRows.formatted())
                MetricRow(label: "Speed tests", value: stats.speedTestRows.formatted())
                if let oldest = stats.oldestRecord {
                    MetricRow(label: "Recording since", value: Format.dayAndTime(oldest))
                }
                MetricRow(label: "Database size",
                          value: Format.bytes(Double(stats.fileSizeBytes)).combined)
            } else if let error = model.storeErrorMessage {
                Text("History is unavailable: \(error)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                EmptyPanel(icon: "internaldrive", message: "No statistics yet")
            }
        }
    }

    private func runProbe() {
        probing = true
        Task {
            probe = await model.probeCapabilities()
            probing = false
        }
    }

    private func runRaw() {
        rawRunning = true
        rawResult = nil
        Task {
            rawResult = await model.rawRequestDump(rawOperation)
            rawRunning = false
        }
    }
}
