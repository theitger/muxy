import SwiftUI

/// The window has one visible destination. Selecting work never changes its
/// processes; it only changes which part of that work is shown.
enum WindowDestination: Equatable {
    case home, workspace, library
}

enum WorkSection: String, CaseIterable, Identifiable {
    case terminal, inspect, quorum, overview, result, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: L("Terminal")
        case .inspect: L("App & code")
        case .quorum: "Quorum"
        case .overview: L("Task details")
        case .result: L("Result")
        case .activity: L("Activity")
        }
    }
    var purpose: String {
        switch self {
        case .terminal: L("Run commands or talk to your coding agent here.")
        case .inspect: L("Try the app, inspect changes and send feedback to the agent.")
        case .quorum: L("Reviews, findings and fixes from the current quorum run.")
        case .overview: L("Keep the task's goal and acceptance criteria here.")
        case .result: L("See the agent's summary, test results and pull request checks.")
        case .activity: L("Look back at feedback, inspections and task history.")
        }
    }
    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .inspect: "eye"
        case .quorum: "checkmark.shield"
        case .overview: "checklist"
        case .result: "checkmark.circle"
        case .activity: "clock"
        }
    }
}

/// Shared sizes for the application shell and its primary content.
enum UI {
    static let pageTitle = Font.system(size: 28, weight: .semibold)
    static let title = Font.system(size: 19, weight: .semibold)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 14)
    static let metadata = Font.system(size: 12)
    static let control = Font.system(size: 13, weight: .medium)
    static let radius: CGFloat = 10
    static let pageInset: CGFloat = 28
}

struct ActionButton: View {
    let title: String
    var symbol: String = "arrow.right"
    var primary = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(symbol, size: 14)
                Text(title)
            }
            .font(UI.control)
            .foregroundStyle(primary ? Theme.bg : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Theme.textPrimary : Theme.fillHover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(UI.pageTitle).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(UI.body).foregroundStyle(Theme.textMuted)
        }
    }
}

/// Preview space is optional; the terminal's readable width is not.
enum WorkbenchLayout {
    static let previewMinimum: CGFloat = 360
    static func previewWidth(available: CGFloat, terminalMinimum: CGFloat = 800) -> CGFloat? {
        guard available >= terminalMinimum + previewMinimum + 1 else { return nil }
        return min(available * 0.45, available - terminalMinimum - 1)
    }
}
