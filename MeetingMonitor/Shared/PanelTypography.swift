import SwiftUI

/// Shared type scale for menu-panel surfaces — mirrored from token_monitor.
enum PanelTypography {
    /// Panel and major section titles.
    static let title = Font.system(size: 13, weight: .semibold)
    /// Primary body copy and list rows.
    static let body = Font.system(size: 12)
    static let bodySemibold = Font.system(size: 12, weight: .semibold)
    /// Secondary captions, tags and source labels.
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let captionSemibold = Font.system(size: 11, weight: .semibold)
    /// Dense tertiary marks.
    static let micro = Font.system(size: 10)
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
