import SwiftUI

/// A quiet press state for anything tappable that is not a filled button: a small scale plus a dim.
/// Honors Reduce Motion by dropping the scale.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressedScale: CGFloat = 0.96
    var pressedOpacity: Double = 0.6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? pressedScale : 1))
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The one filled button: accent background, white label, full width.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(17, weight: .semibold))
            .foregroundStyle(ChromeColor.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(ChromeColor.accent.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A restrained secondary button: surface fill, primary text.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(17, weight: .medium))
            .foregroundStyle(ChromeColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(configuration.isPressed ? ChromeColor.controlPressed : ChromeColor.control,
                        in: RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Section heading used on Settings, Hosts and Keys screens.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.body(13, weight: .semibold))
            .foregroundStyle(ChromeColor.textSecondary)
            .textCase(.uppercase)
            .kerning(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A grouped card with hairline border, used instead of system grouped lists so the chrome stays consistent.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(ChromeColor.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(ChromeColor.hairline, lineWidth: Metrics.hairline)
            )
    }
}

/// A row inside a Card: title, optional subtitle, and trailing content.
struct CardRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ChromeColor.textSecondary)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.body(16))
                    .foregroundStyle(ChromeColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.body(13))
                        .foregroundStyle(ChromeColor.textSecondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(ChromeColor.hairline)
            .frame(height: Metrics.hairline)
            .padding(.leading, 16)
    }
}

/// A single line of monospaced text styled like a terminal snippet, used in onboarding and help.
struct CodeLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.mono(14))
            .foregroundStyle(ChromeColor.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChromeColor.surfaceElevated, in: RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous))
    }
}

extension View {
    /// Standard horizontal screen padding.
    func screenPadding() -> some View {
        padding(.horizontal, Metrics.screenPadding)
    }
}
