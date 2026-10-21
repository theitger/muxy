import SwiftUI

/// Measures every card so offscreen labels also contribute to the board's
/// shared height. Scrolling cannot change which card determines the height.
struct TaskCardGrid: Layout {
    private let minimumWidth: CGFloat = 280
    private let spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? minimumWidth
        let columns = columns(for: width)
        let cellWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let height = subviews.map { $0.sizeThatFits(.init(width: cellWidth, height: nil)).height }.max() ?? 0
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(for: bounds.width)
        let width = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let height = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }.max() ?? 0
        for (index, view) in subviews.enumerated() {
            let point = CGPoint(x: bounds.minX + CGFloat(index % columns) * (width + spacing),
                                y: bounds.minY + CGFloat(index / columns) * (height + spacing))
            view.place(at: point, anchor: .topLeading, proposal: .init(width: width, height: height))
        }
    }

    private func columns(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumWidth + spacing)))
    }
}
