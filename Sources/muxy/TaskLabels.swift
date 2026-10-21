import SwiftUI

/// All GitHub labels, including those attached to the linked issue.
struct TaskLabels: View {
    let labels: [String]
    var status: SessionSummary?

    static func unique(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        let names = Self.unique(labels)
        if !names.isEmpty || status != nil {
            FlowRow(spacing: 5) {
                ForEach(names, id: \.self) { label in
                    Text(label)
                        .font(Theme.label(size: 11))
                        .foregroundStyle(tone(label).strong)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tone(label).soft))
                }
                if let status {
                    SessionSummaryLine(status: status)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.neutral.soft))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tone(_ label: String) -> Theme.Tone {
        if label == "ready-for-agent" { return Theme.greenTone }
        if label.contains("priority") { return Theme.orange }
        return Theme.neutral
    }
}
