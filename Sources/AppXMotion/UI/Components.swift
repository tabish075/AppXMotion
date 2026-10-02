import SwiftUI

extension RGBAColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// A titled inspector section.
struct InspectorSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                }
                Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.6)
                Spacer()
                trailing
            }
            .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

/// Small preview tile of a background.
struct BackgroundSwatch: View {
    let settings: BackgroundSettings
    var selected = false
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fill)
            .overlay {
                if settings.style == .blurredApp {
                    Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
                    .padding(-3.5)
            )
            .frame(width: size, height: size)
    }

    private var fill: AnyShapeStyle {
        switch settings.style {
        case .solid:
            return AnyShapeStyle(settings.color1.color)
        case .gradient:
            let theta = settings.angle * .pi / 180
            let dx = sin(theta) / 2, dy = -cos(theta) / 2
            return AnyShapeStyle(LinearGradient(colors: [settings.color1.color, settings.color2.color],
                                                startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                                                endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)))
        case .radial:
            return AnyShapeStyle(RadialGradient(colors: [settings.color1.color, settings.color2.color],
                                                center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: size * 0.8))
        case .blurredApp:
            return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.55), Color(red: 0.35, green: 0.35, blue: 0.85)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

/// Big primary capture/action button used in the sidebar and empty state.
struct ActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
    }
}

struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045))
            )
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
