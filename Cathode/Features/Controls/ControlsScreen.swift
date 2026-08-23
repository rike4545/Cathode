import SwiftUI

struct ControlsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pending: AppModel.ControlAction?
    @State private var busy: AppModel.ControlAction?
    @State private var errorMessage: String?

    private var isStowed: Bool { model.status?.state == .stowed }

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.gutter) {
                if let errorMessage {
                    Panel {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.bad)
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }
                }

                Panel("Dish", subtitle: "These change hardware state") {
                    VStack(spacing: 0) {
                        ForEach(actions) { action in
                            ControlRow(
                                action: action,
                                isBusy: busy == action,
                                onTap: { pending = action })
                            if action != actions.last { Divider().overlay(Color.hairline) }
                        }
                    }
                }

                Panel("Sleep schedule") {
                    Text("Power the dish down for a fixed window each day. Cathode reads and "
                         + "writes this through the dish's own configuration, the same setting "
                         + "the official app exposes.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SleepScheduleEditor()
                }

                Panel("Snow melt") {
                    SnowMeltEditor()
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 28)
        }
        .background(Color.ground)
        .navigationTitle("Controls")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(pending.title, role: pending.isDestructive ? .destructive : nil) {
                    run(pending)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let pending { Text(pending.detail) }
        }
    }

    private var actions: [AppModel.ControlAction] {
        [.reboot, isStowed ? .unstow : .stow, .clearObstructionMap]
    }

    private func run(_ action: AppModel.ControlAction) {
        pending = nil
        busy = action
        errorMessage = nil
        Task {
            do {
                try await model.perform(action)
            } catch {
                errorMessage = (error as? GrpcError)?.message ?? error.localizedDescription
            }
            busy = nil
        }
    }
}

struct ControlRow: View {
    var action: AppModel.ControlAction
    var isBusy: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(action.isDestructive ? Color.warn : Color.inkSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.ink)
                    Text(action.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.inkTertiary)
                }
            }
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var icon: String {
        switch action {
        case .reboot: "arrow.clockwise.circle"
        case .stow: "arrow.down.to.line.compact"
        case .unstow: "arrow.up.to.line.compact"
        case .clearObstructionMap: "eraser"
        }
    }
}

/// Sleep-schedule editor. Writes through `dish_set_config`, which the dish
/// applies immediately.
struct SleepScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = false
    @State private var start = Calendar.current.date(from: DateComponents(hour: 1)) ?? .now
    @State private var duration: Double = 6
    @State private var saving = false

    var body: some View {
        VStack(spacing: 12) {
            Toggle("Sleep on a schedule", isOn: $enabled)
                .font(.system(size: 13, weight: .medium))
            if enabled {
                DatePicker("Sleep from", selection: $start, displayedComponents: .hourAndMinute)
                    .font(.system(size: 13))
                HStack {
                    Text("For")
                        .font(.system(size: 13))
                    Slider(value: $duration, in: 1...12, step: 0.5)
                    Text("\(Format.decimal(duration, places: 1)) h")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Button {
                save()
            } label: {
                HStack {
                    if saving { ProgressView().controlSize(.small) }
                    Text("Apply to dish")
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.surfaceRaised, in: .rect(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink)
            .disabled(saving)
        }
    }

    private func save() {
        saving = true
        let minutes = Calendar.current.component(.hour, from: start) * 60
            + Calendar.current.component(.minute, from: start)
        Task {
            // Writing config is a mutation, so it goes through the same client
            // path as the other controls rather than a side channel.
            try? await model.setDishConfig(DishConfig(
                sleepEnabled: enabled,
                sleepStartMinute: minutes,
                sleepDurationMinutes: Int(duration * 60)))
            saving = false
        }
    }
}

struct SnowMeltEditor: View {
    @Environment(AppModel.self) private var model
    @State private var mode: DishConfig.SnowMeltMode = .auto
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The dish can heat itself to shed snow and ice. Automatic is right for "
                 + "almost everyone; always-on costs a lot of power.")
                .font(.system(size: 12))
                .foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Snow melt", selection: $mode) {
                ForEach(DishConfig.SnowMeltMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, newValue in
                saving = true
                Task {
                    try? await model.setDishConfig(DishConfig(snowMeltMode: newValue))
                    saving = false
                }
            }
        }
    }
}
