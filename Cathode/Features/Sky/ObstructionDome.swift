import SwiftUI
import UIKit

/// Renders the dish's 123×123 SNR grid as a sky dome.
///
/// The grid is a top-down fisheye: centre is zenith, the inscribed circle's edge
/// is the horizon, north is up. Rather than drawing 15 129 cells through
/// `Canvas` on every frame, the grid is rasterised once into a small bitmap and
/// scaled up — the data only changes every couple of minutes, and smooth
/// interpolation reads better than visible cell boundaries.
enum ObstructionRenderer {

    /// Supersampling factor. Rasterising at grid resolution and letting the
    /// image view scale it up left visible 5-pixel stair steps along the edge of
    /// the observed region, because that edge is a hard jump in the data and
    /// image interpolation only softens it after the fact. Sampling the grid
    /// bilinearly at a higher resolution smooths the boundary itself.
    private static let scale = 4

    static func image(for map: ObstructionMap, isDark: Bool) -> UIImage? {
        let rows = map.rows, cols = map.cols
        guard rows > 0, cols > 0 else { return nil }

        let width = cols * scale
        let height = rows * scale
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let clearNear = isDark ? (0.15, 0.62, 0.64) : (0.32, 0.69, 0.84)
        let clearFar = isDark ? (0.09, 0.30, 0.42) : (0.62, 0.83, 0.90)
        let unseen = isDark ? (0.10, 0.14, 0.16) : (0.88, 0.90, 0.90)

        for y in 0..<height {
            // Map the output pixel back to a continuous grid coordinate.
            let gy = (Double(y) + 0.5) / Double(scale) - 0.5
            for x in 0..<width {
                let gx = (Double(x) + 0.5) / Double(scale) - 0.5
                let index = (y * width + x) * 4

                let sky = gridToSky(row: gy, col: gx, rows: rows, cols: cols)
                guard sky.radius <= 1 else { continue } // outside the dome

                // Bilinear sample of the SNR grid. Unobserved cells (-1) are
                // sampled as a separate channel so the blend can fade between
                // "clear" and "not yet seen" instead of averaging -1 into the
                // obstruction value and inventing a reading.
                let (value, seen) = sampleBilinear(map, row: gy, col: gx)

                let (cr, cg, cb): (Double, Double, Double)
                if value < 0.5 {
                    // t is 1 at fully clear and 0 at the edge of "partly
                    // obstructed", so the brighter tone belongs to clear sky.
                    let t = 1 - value * 2
                    cr = clearFar.0 + (clearNear.0 - clearFar.0) * t
                    cg = clearFar.1 + (clearNear.1 - clearFar.1) * t
                    cb = clearFar.2 + (clearNear.2 - clearFar.2) * t
                } else {
                    let t = (value - 0.5) * 2
                    (cr, cg, cb) = (1.0, 0.48 - 0.20 * t, 0.33 - 0.18 * t)
                }

                // Cross-fade toward the neutral wash by how much of the
                // neighbourhood has actually been observed.
                let r = unseen.0 + (cr - unseen.0) * seen
                let g = unseen.1 + (cg - unseen.1) * seen
                let b = unseen.2 + (cb - unseen.2) * seen
                let a = 0.55 + 0.40 * seen

                // Feather the last pixel of the rim so the dome edge is not
                // aliased against the card behind it.
                let edge = min(1, (1 - sky.radius) * Double(scale) * 14)

                pixels[index] = UInt8(min(255, max(0, r * 255)))
                pixels[index + 1] = UInt8(min(255, max(0, g * 255)))
                pixels[index + 2] = UInt8(min(255, max(0, b * 255)))
                pixels[index + 3] = UInt8(min(255, max(0, a * edge * 255)))
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Samples the SNR grid at a continuous coordinate.
    ///
    /// Returns two things separately: the blended obstruction value, and how
    /// much of the neighbourhood has been observed at all. Keeping them apart
    /// matters — averaging the -1 sentinel into the obstruction value would
    /// invent readings along the edge of the observed region.
    private static func sampleBilinear(
        _ map: ObstructionMap, row: Double, col: Double
    ) -> (value: Double, seen: Double) {
        let r0 = Int(row.rounded(.down)), c0 = Int(col.rounded(.down))
        let fr = row - Double(r0), fc = col - Double(c0)

        var weightedValue = 0.0
        var observedWeight = 0.0

        for (dr, dc, weight) in [
            (0, 0, (1 - fr) * (1 - fc)), (0, 1, (1 - fr) * fc),
            (1, 0, fr * (1 - fc)), (1, 1, fr * fc),
        ] {
            guard weight > 0 else { continue }
            let cell = map.value(row: r0 + dr, col: c0 + dc)
            guard cell >= 0 else { continue }
            observedWeight += weight
            weightedValue += Double(cell) * weight
        }

        // The observed/unobserved boundary is a hard step in the data, and a
        // 2x2 sample only feathers it across a single cell — still visibly
        // stepped once a 123-cell grid is blown up to a full-width dome. A
        // wider tent over the seen mask alone softens the rim without blurring
        // the obstruction values themselves.
        var seenWeight = 0.0
        var seenTotal = 0.0
        for dr in -1...1 {
            for dc in -1...1 {
                let weight = (1 - Double(abs(dr)) / 2) * (1 - Double(abs(dc)) / 2)
                guard weight > 0 else { continue }
                seenTotal += weight
                if map.value(row: r0 + dr, col: c0 + dc) >= 0 { seenWeight += weight }
            }
        }

        let value = observedWeight > 0 ? weightedValue / observedWeight : 0
        return (value, seenTotal > 0 ? seenWeight / seenTotal : 0)
    }
}

/// The full sky view: the dome, elevation rings, compass, a live scan sweep,
/// the recent satellite track, and the current boresight.
struct ObstructionDome: View {
    var map: ObstructionMap?
    var boresight: SkyPoint?
    var desired: SkyPoint?
    /// Recent boresight history, oldest first.
    var track: [SkyPoint] = []
    /// Highlighted wedge from the advisor, drawn as a call-out.
    var highlightAzimuth: Double?
    var showsLabels = true
    var animated = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rendered: UIImage?
    /// When the current scan burst began, or nil when the dome is at rest.
    @State private var sweepStart: Date?

    /// One revolution of the scan sweep.
    private let sweepPeriod: Double = 7
    /// How long a burst runs: two revolutions, then it stops.
    private var sweepDuration: Double { sweepPeriod * 2 }

    /// The sweep is a *refresh* indicator, not decoration. It runs for two
    /// revolutions when the view appears or a new obstruction map arrives, then
    /// stops — which is both more meaningful (it says "this was just re-scanned")
    /// and stops a 20 fps redraw loop from running for as long as the tab is
    /// open. Liveness is already carried by the marker and the track, which
    /// update once a second from real telemetry.
    private var isSweeping: Bool {
        sweepStart != nil && animated && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = side / 2

            ZStack {
                Circle()
                    .fill(Color.surfaceSunken)
                    .frame(width: side, height: side)

                if let rendered {
                    Image(uiImage: rendered)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: side, height: side)
                        .clipShape(.circle)
                        .transition(.opacity)
                } else {
                    Circle()
                        .strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: side, height: side)
                }

                // Everything that moves or overlays lives in one Canvas: it
                // redraws as a unit, so the sweep, the track and the grid lines
                // can never disagree about where a given angle sits.
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !isSweeping)) { timeline in
                    Canvas { context, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        drawGrid(&context, center: c, radius: radius)
                        if isSweeping, let sweepStart {
                            drawSweep(&context, center: c, radius: radius,
                                      elapsed: timeline.date.timeIntervalSince(sweepStart))
                        }
                        if let highlightAzimuth {
                            drawWedge(&context, center: c, radius: radius,
                                      azimuth: highlightAzimuth)
                        }
                        // Age-fading uses the wall clock rather than the timeline
                        // date, so the track still fades correctly on the
                        // once-a-second redraws that happen while the sweep is
                        // stopped and the timeline is paused.
                        drawTrack(&context, center: c, radius: radius, now: .now)
                    }
                }
                .frame(width: side, height: side)
                .allowsHitTesting(false)

                // The markers are SwiftUI views rather than Canvas drawing so a
                // handoff eases to the new position instead of teleporting.
                if let desired {
                    DesiredMarker()
                        .position(position(desired, center: center, radius: radius))
                        .animation(.smooth(duration: 0.9), value: desired)
                }
                if let boresight {
                    BoresightMarker(animating: animated && !reduceMotion && scenePhase == .active)
                        .position(position(boresight, center: center, radius: radius))
                        .animation(.smooth(duration: 0.9), value: boresight)
                }

                if showsLabels {
                    ForEach([("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)], id: \.0) { label, angle in
                        let rad = (angle - 90) * .pi / 180
                        Text(label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.inkTertiary)
                            .position(x: center.x + cos(rad) * (radius + 12),
                                      y: center.y + sin(rad) * (radius + 12))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(14)
        .task(id: renderKey) {
            await rerender()
            await runSweepBurst()
        }
    }

    // MARK: - Geometry

    /// Projects an azimuth/elevation onto the fisheye: zenith at the centre,
    /// horizon at the rim, north up.
    private func position(_ point: SkyPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        let r = radius * (1 - max(0, min(90, point.elevation)) / 90)
        let rad = (point.azimuth - 90) * .pi / 180
        return CGPoint(x: center.x + cos(rad) * r, y: center.y + sin(rad) * r)
    }

    // MARK: - Canvas layers

    private func drawGrid(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        // Elevation rings at 30° and 60°.
        for elevation in [30.0, 60.0] {
            let r = radius * (1 - elevation / 90)
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .color(.ink.opacity(0.12)), lineWidth: 1)
        }
        // Cardinal spokes.
        var spokes = Path()
        for angle in stride(from: 0.0, to: 360.0, by: 90.0) {
            let rad = (angle - 90) * .pi / 180
            spokes.move(to: center)
            spokes.addLine(to: CGPoint(x: center.x + cos(rad) * radius,
                                       y: center.y + sin(rad) * radius))
        }
        context.stroke(spokes, with: .color(.ink.opacity(0.08)), lineWidth: 1)
        // Horizon.
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .color(.hairlineStrong), lineWidth: 1.5)
    }

    /// A slow radar sweep. Canvas has no angular gradient, so the trailing fade
    /// is built from a fan of thin wedges with falling opacity.
    ///
    /// `elapsed` is time since the burst began, which also drives the dim-out
    /// over the final revolution so the sweep ends rather than cutting off.
    private func drawSweep(_ context: inout GraphicsContext, center: CGPoint,
                           radius: CGFloat, elapsed: Double) {
        guard elapsed >= 0, elapsed < sweepDuration else { return }
        // Ease out across the second revolution.
        let remaining = sweepDuration - elapsed
        let dim = min(1, remaining / sweepPeriod)
        let phase = (elapsed / sweepPeriod).truncatingRemainder(dividingBy: 1)
        let head = phase * 360 - 90
        let tailDegrees = 70.0
        let steps = 14

        for step in 0..<steps {
            let t = Double(step) / Double(steps)
            let start = head - tailDegrees * (t + 1 / Double(steps))
            let end = head - tailDegrees * t
            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(center: center, radius: radius,
                         startAngle: .degrees(start), endAngle: .degrees(end),
                         clockwise: false)
            wedge.closeSubpath()
            // Brightest at the leading edge, fading back along the tail.
            context.fill(wedge, with: .color(.good.opacity(0.085 * dim * (1 - t) * (1 - t))))
        }

        // The leading edge itself, as a crisp line.
        let rad = head * .pi / 180
        var edge = Path()
        edge.move(to: center)
        edge.addLine(to: CGPoint(x: center.x + cos(rad) * radius,
                                 y: center.y + sin(rad) * radius))
        context.stroke(edge, with: .color(.good.opacity(0.28 * dim)), lineWidth: 1)
    }

    private func drawWedge(_ context: inout GraphicsContext, center: CGPoint,
                           radius: CGFloat, azimuth: Double) {
        var wedge = Path()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: radius,
                     startAngle: .degrees(azimuth - 90 - 12),
                     endAngle: .degrees(azimuth - 90 + 12),
                     clockwise: false)
        wedge.closeSubpath()
        context.fill(wedge, with: .color(.obstruction.opacity(0.16)))
    }

    /// The recent satellite track. Consecutive samples from the same pass are
    /// joined; a handoff jump is left as a gap, because drawing a line across it
    /// would imply the dish swept through sky it never looked at.
    private func drawTrack(_ context: inout GraphicsContext, center: CGPoint,
                           radius: CGFloat, now: Date) {
        guard track.count > 1 else { return }
        let window = Double(AppModel.trackSeconds)

        for index in 1..<track.count {
            let previous = track[index - 1]
            let current = track[index]
            let age = now.timeIntervalSince(current.t)
            guard age <= window else { continue }
            // Fade with age so the newest arc reads as the live one.
            let freshness = max(0, 1 - age / window)
            guard separation(previous, current) < 12 else { continue }

            var segment = Path()
            segment.move(to: position(previous, center: center, radius: radius))
            segment.addLine(to: position(current, center: center, radius: radius))
            context.stroke(segment, with: .color(.downlink.opacity(0.10 + 0.5 * freshness)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }

        // A dot at the start of each pass marks where a handoff put the dish.
        for index in track.indices {
            let point = track[index]
            let age = now.timeIntervalSince(point.t)
            guard age <= window else { continue }
            let isHandoff = index == 0 || separation(track[index - 1], point) >= 12
            guard isHandoff else { continue }
            let freshness = max(0, 1 - age / window)
            let p = position(point, center: center, radius: radius)
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                with: .color(.downlink.opacity(0.15 + 0.45 * freshness)))
        }
    }

    /// Great-circle angle between two sky points, in degrees.
    private func separation(_ a: SkyPoint, _ b: SkyPoint) -> Double {
        let e1 = a.elevation * .pi / 180, e2 = b.elevation * .pi / 180
        let deltaAz = (a.azimuth - b.azimuth) * .pi / 180
        let cosine = sin(e1) * sin(e2) + cos(e1) * cos(e2) * cos(deltaAz)
        return acos(max(-1, min(1, cosine))) * 180 / .pi
    }

    // MARK: - Rasterising

    /// Re-rasterise only when the data or the colour scheme actually changes.
    private var renderKey: String {
        "\(map?.timestamp.timeIntervalSince1970 ?? 0)-\(colorScheme == .dark)"
    }

    /// Runs one scan burst, then releases the timeline. Cancellation — the tab
    /// being switched away, or a newer map arriving — clears the state via the
    /// `defer`, so the dome never gets stuck animating.
    private func runSweepBurst() async {
        guard animated, !reduceMotion else { return }
        sweepStart = .now
        defer { sweepStart = nil }
        try? await Task.sleep(for: .seconds(sweepDuration))
    }

    private func rerender() async {
        guard let map else {
            rendered = nil
            return
        }
        let isDark = colorScheme == .dark
        let image = await Task.detached(priority: .userInitiated) {
            ObstructionRenderer.image(for: map, isDark: isDark)
        }.value
        withAnimation(.easeInOut(duration: 0.45)) { rendered = image }
    }
}

/// The live boresight: a pulsing ring around a solid core.
struct BoresightMarker: View {
    var animating: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.downlink.opacity(0.22))
                .frame(width: 26, height: 26)
                .scaleEffect(pulse ? 1.35 : 0.85)
                .opacity(pulse ? 0 : 0.9)
            Circle()
                .strokeBorder(Color.downlink, lineWidth: 1.5)
                .frame(width: 13, height: 13)
            Circle()
                .fill(Color.downlink)
                .frame(width: 6, height: 6)
        }
        // A `repeatForever` animation keeps the render server working until it
        // is explicitly cancelled, so it has to follow the same gate as the
        // sweep rather than being started once and left running.
        .onChange(of: animating, initial: true) { _, isOn in
            if isOn {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            } else {
                withAnimation(.linear(duration: 0)) { pulse = false }
            }
        }
    }
}

/// Where the dish *wants* to point, when that differs from where it is.
struct DesiredMarker: View {
    var body: some View {
        Circle()
            .strokeBorder(Color.inkTertiary,
                          style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2.5]))
            .frame(width: 15, height: 15)
    }
}

/// The dome's colour key. Without it, "is orange bad or just unmeasured?" is a
/// real question a first-time viewer has.
struct DomeLegend: View {
    var showsTrack: Bool = true

    var body: some View {
        HStack(spacing: 13) {
            item(.downlink.opacity(0.75), "Clear")
            item(.obstruction, "Blocked")
            item(.surfaceRaised, "Not yet seen")
            if showsTrack {
                HStack(spacing: 5) {
                    Capsule().fill(Color.downlink).frame(width: 12, height: 2.5)
                    Text("Track")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.inkTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.inkTertiary)
        }
    }
}
