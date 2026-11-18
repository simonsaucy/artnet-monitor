//
//  UniverseCard.swift
//  Art-Net Monitor
//
//  One card per source+universe, matching the `.uni` block in the viewer's
//  Art-Net drawer: header, then either the 32 x 16 cell grid or the text list.
//

import SwiftUI

enum UniverseViewMode: String, CaseIterable {
    case grid
    case text

    var title: String { self == .grid ? "Grid" : "Text" }
}

struct UniverseCard: View {
    let universe: UniverseSnapshot
    let viewMode: UniverseViewMode
    let fadeTick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch viewMode {
            case .grid: UniverseGrid(values: universe.values)
            case .text: UniverseText(universe: universe, fadeTick: fadeTick)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Cue.bgTertiary, in: RoundedRectangle(cornerRadius: Cue.radiusLarge,
                                                         style: .continuous))
    }

    private var header: some View {
        // Wraps instead of overflowing when the window is narrow.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                Spacer(minLength: 8)
                meta
            }
            VStack(alignment: .leading, spacing: 3) {
                title
                meta
            }
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Universe \(universe.universe)")
                .font(Cue.ui(13, .semibold))
                .foregroundStyle(Cue.textPrimary)
                .fixedSize()
            Text("\(universe.sourceIP) · \(universe.triple)")
                .font(Cue.mono(11))
                .foregroundStyle(Cue.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var meta: some View {
        Text("seq \(String(format: "%03d", universe.sequence)) · \(universe.activeCount) active")
            .font(Cue.mono(10.5))
            .foregroundStyle(Cue.textTertiary)
            .fixedSize()
    }
}

// MARK: - Grid

/// 512 channels as 32 columns x 16 rows, drawn in a single Canvas pass. Hover a
/// cell to read its channel number and value.
struct UniverseGrid: View {
    let values: [UInt8]

    private static let columns = 32
    private static let rows = 16
    private static let gap: CGFloat = 2

    @State private var size: CGSize = .zero
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            canvas
            readout
        }
    }

    private var canvas: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let cellWidth = cellWidth(for: size)
            let cellHeight = cellHeight(for: size)
            guard cellWidth > 0, cellHeight > 0 else { return }

            for index in 0..<512 {
                let column = index % Self.columns
                let row = index / Self.columns
                let rect = CGRect(x: CGFloat(column) * (cellWidth + Self.gap),
                                  y: CGFloat(row) * (cellHeight + Self.gap),
                                  width: cellWidth,
                                  height: cellHeight)
                let value = index < values.count ? values[index] : 0
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(Cue.cell(for: value)))
                if index == hovered {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: -0.75, dy: -0.75),
                                        cornerRadius: 2.5),
                                   with: .color(Cue.textPrimary),
                                   lineWidth: 1)
                }
            }
        }
        .aspectRatio(2, contentMode: .fit)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hovered = index(at: point)
            case .ended: hovered = nil
            }
        }
    }

    private var readout: some View {
        // Fixed-height row so hovering never changes the layout.
        Text(readoutText)
            .font(Cue.mono(10.5))
            .foregroundStyle(hovered == nil ? Cue.textQuaternary : Cue.green)
            .lineLimit(1)
            .frame(height: 13, alignment: .leading)
    }

    private var readoutText: String {
        guard let hovered, hovered < values.count else {
            return "ch 1–512 · hover a cell"
        }
        let value = Int(values[hovered])
        return "ch \(String(format: "%03d", hovered + 1))   \(value)   \(dmxPercent(value))%"
    }

    private func cellWidth(for size: CGSize) -> CGFloat {
        (size.width - CGFloat(Self.columns - 1) * Self.gap) / CGFloat(Self.columns)
    }

    private func cellHeight(for size: CGSize) -> CGFloat {
        (size.height - CGFloat(Self.rows - 1) * Self.gap) / CGFloat(Self.rows)
    }

    private func index(at point: CGPoint) -> Int? {
        let cellWidth = cellWidth(for: size)
        let cellHeight = cellHeight(for: size)
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let column = Int(point.x / (cellWidth + Self.gap))
        let row = Int(point.y / (cellHeight + Self.gap))
        guard column >= 0, column < Self.columns, row >= 0, row < Self.rows else { return nil }
        return row * Self.columns + column
    }
}

// MARK: - Text

struct UniverseText: View {
    let universe: UniverseSnapshot
    let fadeTick: Int

    /// How long a changed row keeps its green outline.
    private static let highlight: Double = 1.2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if universe.activeCount == 0 {
                Text("Nothing above zero.")
                    .font(Cue.ui(12.5))
                    .foregroundStyle(Cue.textTertiary)
            } else {
                rows
            }
        }
    }

    private var summary: some View {
        // e.g. "5 channels up. Last change: ch 10  172 → 157 (62%)"
        Text(summaryString)
            .font(Cue.ui(12.5))
            .foregroundStyle(Cue.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryString: AttributedString {
        var out = AttributedString()
        if universe.activeCount == 0 {
            var head = AttributedString("All 512 channels at 0.")
            head.foregroundColor = Cue.textSecondary
            out += head
        } else {
            var head = AttributedString(
                "\(universe.activeCount) channel\(universe.activeCount == 1 ? "" : "s") up.")
            head.foregroundColor = Cue.textPrimary
            head.font = Cue.ui(12.5, .semibold)
            out += head
        }
        if let change = universe.lastChange {
            var label = AttributedString(" Last change: ")
            label.foregroundColor = Cue.textSecondary
            out += label

            var detail = AttributedString(
                "ch \(change.channel)  \(change.from) → \(change.to) (\(dmxPercent(change.to))%)")
            detail.font = Cue.mono(12)
            detail.foregroundColor = Cue.green
            out += detail
        }
        return out
    }

    private var rows: some View {
        let now = monotonicNow()
        let active: [Int] = (0..<512).filter { universe.values[$0] > 0 }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 4)],
                         spacing: 4) {
            ForEach(active, id: \.self) { index in
                ChannelRow(channel: index + 1,
                           value: Int(universe.values[index]),
                           changed: now - universe.changedAt[index] < Self.highlight)
            }
        }
    }
}

struct ChannelRow: View {
    let channel: Int
    let value: Int
    let changed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("CH \(String(format: "%03d", channel))")
                .foregroundStyle(changed ? Cue.green : Cue.textSecondary)
            Spacer(minLength: 4)
            Text("\(value)")
                .foregroundStyle(Cue.textPrimary)
            Text("\(dmxPercent(value))%")
                .foregroundStyle(Cue.textSecondary)
                .frame(width: 34, alignment: .trailing)
        }
        .font(Cue.mono(11.5, .medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(alignment: .bottomLeading) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: Cue.radiusSmall, style: .continuous)
                    .fill(Cue.bgSecondary)
                // Thin green level bar along the bottom, 2 pt, as wide as the level.
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Cue.green)
                        .frame(width: geometry.size.width * Double(value) / 255, height: 2)
                        .position(x: geometry.size.width * Double(value) / 510,
                                  y: geometry.size.height - 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Cue.radiusSmall, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Cue.radiusSmall, style: .continuous)
                .strokeBorder(changed ? Cue.green : .clear, lineWidth: 1)
        }
    }
}
