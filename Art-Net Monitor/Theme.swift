//
//  Theme.swift
//  Art-Net Monitor
//
//  The Cueline / CrossingCue design language, lifted from the viewer's CSS
//  custom properties so the app and the web drawer look like one product.
//

import SwiftUI

nonisolated extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

nonisolated enum Cue {

    // Backgrounds
    static let bgPrimary = Color(hex: 0x000000)
    static let bgSecondary = Color(hex: 0x1C1C1E)
    static let bgTertiary = Color(hex: 0x2C2C2E)
    static let bgQuaternary = Color(hex: 0x3A3A3C)
    /// The off state of a DMX cell.
    static let cellOff = Color(hex: 0x1F1F21)

    // Text
    static let textPrimary = Color(hex: 0xF5F5F7)
    static let textSecondary = Color(hex: 0x8E8E93)
    static let textTertiary = Color(hex: 0x636366)
    static let textQuaternary = Color(hex: 0x48484A)

    // Accents
    static let green = Color(hex: 0x30D158)
    static let red = Color(hex: 0xFF453A)
    static let blue = Color(hex: 0x0A84FF)
    static let teal = Color(hex: 0x5AC8FA)
    static let yellow = Color(hex: 0xFFD60A)

    // Hairlines
    static let borderPrimary = Color.white.opacity(0.08)
    static let borderSecondary = Color.white.opacity(0.12)

    // Radii
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 12
    static let radiusXLarge: CGFloat = 16

    // Fonts — SF Pro for chrome, SF Mono for every number, IP and value.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Cell fill for a DMX value, matching the drawer's
    /// rgba(48,209,88, 0.14 + 0.86 * v/255).
    static func cell(for value: UInt8) -> Color {
        guard value > 0 else { return cellOff }
        return green.opacity(0.14 + 0.86 * Double(value) / 255)
    }
}

/// Percent, the way the drawer shows it: round(value / 2.55).
nonisolated func dmxPercent(_ value: Int) -> Int {
    Int((Double(value) / 2.55).rounded())
}

// MARK: - Shared chrome

/// The four pill bars with one green — the Cueline mark.
struct CueLogo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Cue.bgPrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Cue.borderSecondary, lineWidth: 0.5)
                }
            VStack(alignment: .leading, spacing: 1.9) {
                bar(width: 18, color: Cue.textQuaternary)
                bar(width: 18, color: Cue.green)
                bar(width: 18, color: Cue.textQuaternary)
                bar(width: 12, color: Cue.textQuaternary)
            }
            .frame(width: 18, alignment: .leading)
        }
        .frame(width: 30, height: 30)
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.3, style: .continuous)
            .fill(color)
            .frame(width: width, height: 2.6)
    }
}

/// Pill with a coloured dot, same as the viewer's `.status`.
struct StatusPill: View {
    let text: String
    let tint: MonitorStore.StatusTint

    private var dotColor: Color {
        switch tint {
        case .idle: return Cue.textTertiary
        case .live: return Cue.green
        case .waiting: return Cue.yellow
        case .error: return Cue.red
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle()
                        .stroke(dotColor.opacity(tint == .idle ? 0 : 0.18), lineWidth: 3)
                }
            Text(text)
                .font(Cue.ui(12, .medium))
                .foregroundStyle(Cue.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Cue.bgTertiary, in: Capsule())
        .layoutPriority(-1)
    }
}

/// One of the "pkts / s" tiles.
struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = Cue.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Cue.mono(15, .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(Cue.ui(10.5, .semibold))
                .kerning(0.7)
                .foregroundStyle(Cue.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Cue.bgTertiary, in: RoundedRectangle(cornerRadius: Cue.radiusMedium,
                                                         style: .continuous))
    }
}

/// The Grid | Text and Capture | Listen control, styled like `.seg` in the CSS
/// rather than AppKit's segmented control (which ignores the dark theme).
struct CueSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String, help: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(Cue.ui(11.5, .semibold))
                        .foregroundStyle(selection == option.value
                                         ? Cue.textPrimary : Cue.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selection == option.value
                                      ? Cue.bgQuaternary : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.help)
            }
        }
        .padding(2)
        .background(Cue.bgTertiary, in: RoundedRectangle(cornerRadius: Cue.radiusSmall,
                                                         style: .continuous))
    }
}

/// Blue primary / grey secondary buttons from the CSS.
struct CueButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        let background: Color = destructive ? Cue.red : (prominent ? Cue.blue : Cue.bgTertiary)
        let foreground: Color = (prominent || destructive) ? .white : Cue.textPrimary
        configuration.label
            .font(Cue.ui(13, prominent || destructive ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: Cue.radiusMedium,
                                             style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Section caption, `.art-h` in the CSS.
struct SectionCaption: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Cue.ui(11, .semibold))
            .kerning(0.75)
            .foregroundStyle(Cue.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
