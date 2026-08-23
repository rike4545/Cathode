import SwiftUI

/// The live throughput chart: download above the axis, upload mirrored below.
///
/// Drawn with `Canvas` rather than Swift Charts. At 1 Hz over a 15-minute window
/// this redraws ~900 points every second, and a mirrored dual-axis area with a
/// moving "now" edge is not something the chart framework expresses cleanly.
/// Canvas also lets the outage bands sit *under* the series, which is what makes
/// a gap read as "no data" instead of "zero throughput".
struct ThroughputRibbon: View {
    var samples: [HistorySample]
    /// Seconds of history to show.
    var window: Int = 900
    var showsAxis = true
    /// Highlighted sample from a drag, if any.
    @Binding var selection: HistorySample?

    @State private var dragX: CGFloat?

    private var visible: [HistorySample] {
        guard let last = samples.last else { return [] }
        let cutoff = last.t.addingTimeInterval(-Double(window))
        return samples.filter { $0.t >= cutoff }
    }

    /// A shared scale for both halves keeps the visual weight of up and down
    /// honest — uplink is genuinely a tenth of downlink and should look it.
    private var peak: Double {
        let maxDown = visible.map(\.downlinkBps).max() ?? 0
        return max(maxDown, 10_000_000) * 1.12
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragX = value.location.x
                            selection = sample(atX: value.location.x, width: geo.size.width)
                        }
                        .onEnded { _ in
                            dragX = nil
                            selection = nil
                        })
            }
            if showsAxis {
                HStack {
                    Text("\(window / 60) min ago")
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.inkTertiary)
            }
        }
    }

    private func sample(atX x: CGFloat, width: CGFloat) -> HistorySample? {
        let points = visible
        guard !points.isEmpty, width > 0 else { return nil }
        let fraction = max(0, min(1, x / width))
        return points[min(points.count - 1, Int(fraction * CGFloat(points.count - 1)))]
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let points = visible
        guard points.count > 1 else {
            drawPlaceholder(&context, size: size)
            return
        }

        let midY = size.height * 0.62 // downlink gets the larger share
        let downHeight = midY
        let upHeight = size.height - midY
        let stepX = size.width / CGFloat(points.count - 1)
        let scale = peak

        // Outage bands first, so the series draws over them.
        var bandStart: Int?
        for (i, sample) in points.enumerated() {
            let isDown = sample.isOutage || sample.noSchedule
            if isDown, bandStart == nil { bandStart = i }
            if !isDown, let start = bandStart {
                fillBand(&context, from: start, to: i, stepX: stepX, size: size)
                bandStart = nil
            }
        }
        if let start = bandStart {
            fillBand(&context, from: start, to: points.count, stepX: stepX, size: size)
        }

        // Zero line.
        context.stroke(
            Path { $0.move(to: CGPoint(x: 0, y: midY)); $0.addLine(to: CGPoint(x: size.width, y: midY)) },
            with: .color(.hairlineStrong.opacity(0.7)), lineWidth: 1)

        func series(_ value: (HistorySample) -> Double, height: CGFloat, upward: Bool) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY))
            for (i, sample) in points.enumerated() {
                let normalized = min(1, value(sample) / scale)
                let offset = CGFloat(normalized) * height
                path.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: upward ? midY - offset : midY + offset))
            }
            path.addLine(to: CGPoint(x: CGFloat(points.count - 1) * stepX, y: midY))
            path.closeSubpath()
            return path
        }

        let downPath = series({ $0.downlinkBps }, height: downHeight, upward: true)
        let upPath = series({ $0.uplinkBps * 6 }, height: upHeight, upward: false)

        context.fill(downPath, with: .linearGradient(
            Gradient(colors: [.downlink.opacity(0.55), .downlink.opacity(0.05)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: midY)))
        context.fill(upPath, with: .linearGradient(
            Gradient(colors: [.uplink.opacity(0.05), .uplink.opacity(0.45)]),
            startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: 0, y: size.height)))

        context.stroke(downPath, with: .color(.downlink), lineWidth: 1.4)
        context.stroke(upPath, with: .color(.uplink), lineWidth: 1.2)

        // The leading edge: a bright marker at "now", which makes a live chart
        // read as live even when the line is flat.
        if let last = points.last {
            let x = CGFloat(points.count - 1) * stepX
            let y = midY - CGFloat(min(1, last.downlinkBps / scale)) * downHeight
            context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                         with: .color(.downlink))
            context.fill(Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12)),
                         with: .color(.downlink.opacity(0.22)))
        }

        // Drag readout line.
        if let dragX {
            let clamped = max(0, min(size.width, dragX))
            context.stroke(
                Path { $0.move(to: CGPoint(x: clamped, y: 0)); $0.addLine(to: CGPoint(x: clamped, y: size.height)) },
                with: .color(.ink.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func fillBand(_ context: inout GraphicsContext, from: Int, to: Int,
                          stepX: CGFloat, size: CGSize) {
        let x = CGFloat(from) * stepX
        let width = max(1.5, CGFloat(to - from) * stepX)
        context.fill(
            Path(CGRect(x: x, y: 0, width: width, height: size.height)),
            with: .color(.bad.opacity(0.16)))
    }

    private func drawPlaceholder(_ context: inout GraphicsContext, size: CGSize) {
        let midY = size.height * 0.62
        context.stroke(
            Path { $0.move(to: CGPoint(x: 0, y: midY)); $0.addLine(to: CGPoint(x: size.width, y: midY)) },
            with: .color(.hairline),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}

/// The readout that floats above the ribbon while dragging.
struct RibbonReadout: View {
    var sample: HistorySample?
    var fallbackDown: Double?
    var fallbackUp: Double?

    var body: some View {
        HStack(spacing: 18) {
            legend("Down", Format.bitrate(sample?.downlinkBps ?? fallbackDown), .downlink)
            legend("Up", Format.bitrate(sample?.uplinkBps ?? fallbackUp), .uplink)
            Spacer()
            if let sample {
                Text(Format.clock(sample.t, seconds: true))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkSecondary)
                    .monospacedDigit()
            }
        }
    }

    private func legend(_ title: String, _ value: Format.Measured, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 9, height: 3)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.inkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(value.unit)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.inkTertiary)
            }
            .foregroundStyle(Color.ink)
        }
    }
}
