import SwiftUI

struct SkyScreen: View {
    @Environment(AppModel.self) private var model

    private var advice: Insights.ObstructionAdvice? { model.obstructionAdvice }
    private var alignment: AlignmentStats? { model.status?.alignment }

    private var boresightPoint: SkyPoint? {
        guard let azimuth = alignment?.boresightAzimuthDeg,
              let elevation = alignment?.boresightElevationDeg else { return nil }
        return SkyPoint(azimuth: azimuth, elevation: elevation,
                        t: model.status?.timestamp ?? .now)
    }

    private var desiredPoint: SkyPoint? {
        guard let azimuth = alignment?.desiredBoresightAzimuthDeg,
              let elevation = alignment?.desiredBoresightElevationDeg else { return nil }
        return SkyPoint(azimuth: azimuth, elevation: elevation,
                        t: model.status?.timestamp ?? .now)
    }

    /// A handoff is a discontinuity in the track — the dish jumping to a
    /// different satellite rather than following one across the sky.
    private var handoffCount: Int {
        let track = model.boresightTrack
        guard track.count > 1 else { return 0 }
        return (1..<track.count).count { index in
            let a = track[index - 1], b = track[index]
            let e1 = a.elevation * .pi / 180, e2 = b.elevation * .pi / 180
            let deltaAz = (a.azimuth - b.azimuth) * .pi / 180
            let cosine = sin(e1) * sin(e2) + cos(e1) * cos(e2) * cos(deltaAz)
            return acos(max(-1, min(1, cosine))) * 180 / .pi >= 12
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Metrics.gutter) {
                    domePanel
                    advicePanel
                    if let advice, !advice.wedges.isEmpty { wedgePanel(advice) }
                    alignmentPanel
                    obstructionStatsPanel
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 28)
            }
            .background(Color.ground)
            .navigationTitle("Sky")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Dome

    private var domePanel: some View {
        Panel("Sky obstruction map",
              subtitle: model.obstructionMap == nil
                ? "Waiting for the dish's first map"
                : "What the dish can and cannot see") {
            VStack(spacing: 12) {
                ObstructionDome(
                    map: model.obstructionMap,
                    boresight: boresightPoint,
                    desired: desiredPoint,
                    track: model.boresightTrack,
                    highlightAzimuth: advice?.worst?.azimuthDeg)
                    .frame(maxHeight: 320)
                DomeLegend(showsTrack: model.boresightTrack.count > 1)
                if let boresight = boresightPoint {
                    Text("Tracking \(Format.compass(boresight.azimuth)) at "
                         + "\(Int(boresight.elevation))° elevation"
                         + (model.boresightTrack.count > 1
                            ? " · \(handoffCount) handoffs in the last "
                              + "\(AppModel.trackSeconds / 60) min" : ""))
                        .font(.caption2)
                        .foregroundStyle(Color.inkTertiary)
                        .monospacedDigit()
                }
                if model.obstructionMap == nil {
                    Text("The dish builds this map over about 12 hours of observation. "
                         + "Cathode reads it every couple of minutes.")
                        .font(.caption)
                        .foregroundStyle(Color.inkTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    // MARK: - Advisor
    //
    // The part that goes past what the dish itself will tell you: not just how
    // much sky is blocked, but which way to move to fix it.

    private var advicePanel: some View {
        Panel("Placement advisor") {
            if let advice, !advice.isClear, let recommendation = advice.recommendation {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.obstruction.opacity(0.15))
                                .frame(width: 42, height: 42)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Color.obstruction)
                                .rotationEffect(.degrees(advice.worst?.azimuthDeg ?? 0))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recommendation)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if let improvement = advice.estimatedImprovement, improvement > 0.15 {
                                Text("That single direction accounts for about "
                                     + "\(Int(improvement * 100))% of all the blockage.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Divider().overlay(Color.hairline)
                    Text("Cathode derives this from the SNR grid, not from the dish — "
                         + "Starlink reports how much sky is blocked, never where.")
                        .font(.caption2)
                        .foregroundStyle(Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if advice?.isClear == true {
                HStack(spacing: 11) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(Color.good)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear view of the sky")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ink)
                        Text("Nothing is blocking the dish's field of view.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
            } else {
                EmptyPanel(icon: "hourglass", message: "No map yet",
                           detail: "The advisor needs the dish's obstruction map.")
            }
        }
    }

    private func wedgePanel(_ advice: Insights.ObstructionAdvice) -> some View {
        Panel("Blockage by direction", subtitle: "Worst first") {
            VStack(spacing: 9) {
                ForEach(advice.wedges.prefix(6)) { wedge in
                    HStack(spacing: 10) {
                        Text(wedge.compass)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink)
                            .frame(width: 34, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.surfaceSunken)
                                Capsule()
                                    .fill(Color.obstruction)
                                    .frame(width: max(4, geo.size.width
                                        * min(1, wedge.blockedFraction / max(0.01, advice.wedges[0].blockedFraction))))
                            }
                        }
                        .frame(height: 7)
                        Text("to \(Int(wedge.peakElevationDeg))°")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.inkSecondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Text("Bar length is blockage relative to the worst direction. "
                     + "The angle is how high the obstruction reaches.")
                    .font(.caption2)
                    .foregroundStyle(Color.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Alignment

    private var alignmentPanel: some View {
        Panel("Alignment", subtitle: "Where the dish is pointing") {
            HStack(spacing: 14) {
                AlignmentDial(
                    title: "Azimuth",
                    actual: alignment?.boresightAzimuthDeg,
                    desired: alignment?.desiredBoresightAzimuthDeg,
                    range: 0...360,
                    formatter: { "\(Int($0))° \(Format.compass($0))" })
                AlignmentDial(
                    title: "Elevation",
                    actual: alignment?.boresightElevationDeg,
                    desired: alignment?.desiredBoresightElevationDeg,
                    range: 0...90,
                    formatter: { "\(Format.decimal($0, places: 1))°" })
            }
            if let error = alignment?.pointingErrorDeg {
                Divider().overlay(Color.hairline)
                MetricRow(label: "Pointing error", value: Format.degrees(error, places: 2).combined,
                          tone: error < 1 ? .good : error < 3 ? .warn : .bad)
            }
            if let tilt = alignment?.tiltAngleDeg {
                MetricRow(label: "Mast tilt", value: Format.degrees(tilt).combined)
            }
            if let uncertainty = alignment?.attitudeUncertaintyDeg {
                MetricRow(label: "Attitude uncertainty",
                          value: Format.degrees(uncertainty, places: 2).combined)
            }
        }
    }

    // MARK: - Stats

    private var obstructionStatsPanel: some View {
        let obstruction = model.status?.obstruction
        return Panel("Obstruction statistics") {
            MetricRow(label: "Fraction of sky blocked",
                      value: Format.percent(obstruction?.fractionObstructed, places: 3).combined,
                      tone: (obstruction?.fractionObstructed ?? 0) < 0.001 ? .good : .warn)
            MetricRow(label: "Currently obstructed",
                      value: (obstruction?.currentlyObstructed ?? false) ? "Yes" : "No",
                      tone: (obstruction?.currentlyObstructed ?? false) ? .bad : .good)
            if let valid = obstruction?.validS {
                MetricRow(label: "Observation window", value: Format.duration(valid))
            }
            if let time = obstruction?.timeObstructed {
                MetricRow(label: "Time obstructed", value: Format.duration(time))
            }
            if let interval = obstruction?.avgProlongedObstructionIntervalS {
                MetricRow(label: "Average gap between prolonged blockages",
                          value: Format.duration(interval))
            }
            Divider().overlay(Color.hairline)
            NavigationLink {
                ControlsScreen()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset the obstruction map")
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}

/// A linear dial comparing where the dish points against where it wants to.
struct AlignmentDial: View {
    var title: String
    var actual: Double?
    var desired: Double?
    var range: ClosedRange<Double>
    var formatter: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.label)
                .tracking(0.7)
                .foregroundStyle(Color.inkTertiary)
            Text(actual.map(formatter) ?? "—")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surfaceSunken).frame(height: 6)
                    if let desired {
                        Rectangle()
                            .fill(Color.inkTertiary)
                            .frame(width: 1.5, height: 12)
                            .offset(x: position(desired, in: geo.size.width))
                    }
                    if let actual {
                        Circle()
                            .fill(Color.downlink)
                            .frame(width: 9, height: 9)
                            .offset(x: position(actual, in: geo.size.width) - 4.5)
                    }
                }
                .frame(height: 12)
            }
            .frame(height: 12)
            if let desired {
                Text("target \(formatter(desired))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.inkTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func position(_ value: Double, in width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return CGFloat((clamped - range.lowerBound) / span) * width
    }
}
