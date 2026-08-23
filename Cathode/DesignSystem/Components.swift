import SwiftUI

/// The card every panel sits in. One shape, one border, one shadow — repeated
/// everywhere so the eye can stop parsing chrome and read the numbers.
struct Panel<Content: View>: View {
    var title: String?
    var subtitle: String?
    var accessory: AnyView?
    var padding: CGFloat = Metrics.cardPadding
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil, padding: CGFloat = Metrics.cardPadding,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.padding = padding
        self.accessory = nil
        self.content = content()
    }

    init<Accessory: View>(_ title: String? = nil, subtitle: String? = nil,
                          padding: CGFloat = Metrics.cardPadding,
                          @ViewBuilder accessory: () -> Accessory,
                          @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.padding = padding
        self.accessory = AnyView(accessory())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title.uppercased())
                                .font(.label)
                                .tracking(0.8)
                                .foregroundStyle(Color.inkTertiary)
                            if let subtitle {
                                Text(subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(Color.inkSecondary)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: .rect(cornerRadius: Metrics.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(Color.hairline, lineWidth: 1)
        }
    }
}

/// A labelled readout: big monospaced value, small unit, optional trend.
struct StatTile: View {
    var label: String
    var value: Format.Measured
    var tone: Tone = .idle
    var icon: String?
    var trend: [Double]?
    var trendTint: Color?
    var caption: String?
    var emphasise = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(trendTint ?? Color.tone(tone))
                }
                Text(label.uppercased())
                    .font(.label)
                    .tracking(0.7)
                    .foregroundStyle(Color.inkTertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.value)
                    .font(emphasise ? .readoutLarge : .readout)
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
                Text(value.unit)
                    .font(.unit)
                    .foregroundStyle(Color.inkTertiary)
                    .padding(.bottom, 1)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            if let trend, trend.count > 1 {
                Sparkline(values: trend, tint: trendTint ?? Color.tone(tone))
                    .frame(height: 22)
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Color.inkTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A filled mini-chart. Deliberately axis-free: it shows shape, not values.
struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var filled = true

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let span = max(hi - lo, .ulpOfOne)
            let stepX = size.width / CGFloat(values.count - 1)

            func point(_ index: Int) -> CGPoint {
                let normalized = (values[index] - lo) / span
                return CGPoint(x: CGFloat(index) * stepX,
                               y: size.height - CGFloat(normalized) * size.height)
            }

            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }

            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.28), tint.opacity(0.01)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            context.stroke(line, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .drawingGroup()
    }
}

/// State badge: a coloured dot and a word. Used in the nav bar and on rows.
struct StatusPill: View {
    var text: String
    var tone: Tone
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.tone(tone))
                .frame(width: 7, height: 7)
                .overlay {
                    if pulsing {
                        Circle()
                            .stroke(Color.tone(tone), lineWidth: 1.5)
                            .scaleEffect(pulse ? 2.6 : 1)
                            .opacity(pulse ? 0 : 0.8)
                    }
                }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.tone(tone).opacity(0.13), in: .capsule)
        .overlay { Capsule().strokeBorder(Color.tone(tone).opacity(0.28), lineWidth: 1) }
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// A key/value line for detail lists.
struct MetricRow: View {
    var label: String
    var value: String
    var tone: Tone?
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.inkSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .technical : .system(size: 13, weight: .medium))
                .foregroundStyle(tone.map { Color.tone($0) } ?? Color.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Section heading used between panels on a scroll view.
struct SectionHeader: View {
    var title: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.ink)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown wherever a panel has nothing to draw yet, instead of an empty box.
struct EmptyPanel: View {
    var icon: String
    var message: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.inkTertiary)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.inkSecondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.inkTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

/// A horizontal segmented control styled for the instrument panel.
struct SegmentPicker<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == option.value ? Color.ink : Color.inkTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selection == option.value {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.surfaceRaised)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.surfaceSunken, in: .rect(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.hairline, lineWidth: 1) }
    }
}

/// A progress arc, used for health and obstruction summaries.
struct GaugeArc: View {
    /// 0–1.
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 9
    /// Fraction of the full circle the arc spans.
    var sweep: Double = 0.75

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.surfaceSunken, style: .init(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: sweep * max(0, min(1, progress)))
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.55), tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * sweep)),
                    style: .init(lineWidth: lineWidth, lineCap: .round))
        }
        // Rotate so the gap sits at the bottom, centred.
        .rotationEffect(.degrees(90 + 360 * (1 - sweep) / 2))
        .animation(.smooth(duration: 0.5), value: progress)
    }
}
