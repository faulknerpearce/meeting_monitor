import SwiftUI

/// Shared type scale for menu-panel surfaces — mirrored from token_monitor.
enum PanelTypography {
    /// Panel and major section titles.
    static let title = Font.system(size: 13, weight: .semibold)
    /// Primary body copy and list rows.
    static let body = Font.system(size: 12)
    static let bodySemibold = Font.system(size: 12, weight: .semibold)
    static let bodyDigit = Font.system(size: 12, weight: .semibold).monospacedDigit()
    /// Secondary captions, tags, resets, source labels.
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let captionSemibold = Font.system(size: 11, weight: .semibold)
    /// Chart axis / dense tertiary marks.
    static let micro = Font.system(size: 10)
    /// Stats-sheet label and value.
    static let metricLabel = Font.system(size: 14)
    static let metricValue = Font.system(size: 26, weight: .semibold)
}

/// Tracked uppercase section label used on panel blocks.
struct PanelSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(PanelTypography.micro)
            .fontWeight(.semibold)
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
    }
}
