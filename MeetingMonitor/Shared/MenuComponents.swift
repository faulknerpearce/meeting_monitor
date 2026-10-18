import SwiftUI

/// Metrics and type scale matching macOS Control Center–style menus (Wi-Fi, Bluetooth, Sound).
enum MenuMetrics {
    static let width: CGFloat = 320
    /// Gap between the window edge and a row's hover highlight.
    static let outerInset: CGFloat = 5
    /// Gap between a row's highlight edge and its content.
    static let innerInset: CGFloat = 9
    /// Content inset from the window edge (outer + inner), used by headers and separators.
    static let contentInset: CGFloat = outerInset + innerInset
    static let highlightRadius: CGFloat = 5
    static let iconSize: CGFloat = 26

    /// Menu titles and section headers.
    static let titleFont = Font.system(size: 13, weight: .semibold)
    /// Menu items.
    static let itemFont = Font.system(size: 13)
    /// Secondary line under an item, status text, shortcut hints.
    static let detailFont = Font.system(size: 11)
}

/// Bold secondary header that opens a group of rows ("All Day", "Calendars").
struct MenuSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(MenuMetrics.titleFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MenuMetrics.contentInset)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Thin separator inset like the ones between menu groups.
struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuMetrics.contentInset)
            .padding(.vertical, 5)
    }
}

/// Full-width menu row: rounded highlight on hover, slightly stronger while pressed.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }

    private struct MenuRowBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .menuRowContent()
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: MenuMetrics.highlightRadius, style: .continuous)
                        .fill(Color.primary.opacity(highlightOpacity))
                )
                .padding(.horizontal, MenuMetrics.outerInset)
                .onHover { isHovered = $0 }
        }

        private var highlightOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.16 }
            return isHovered ? 0.1 : 0
        }
    }
}

extension View {
    /// Insets a row's content inside its highlight area.
    fileprivate func menuRowContent() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MenuMetrics.innerInset)
            .padding(.vertical, 4)
    }

    /// Lays out a non-interactive row so it lines up with `MenuRowButtonStyle` rows.
    func menuRowLayout() -> some View {
        menuRowContent()
            .padding(.horizontal, MenuMetrics.outerInset)
    }
}

/// Text-only menu item with a ⌘ shortcut shown right-aligned ("Refresh   ⌘R").
struct MenuActionRow: View {
    let title: String
    var shortcut: KeyEquivalent?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(MenuMetrics.itemFont)
                Spacer()
                if let shortcut {
                    Text("⌘\(String(shortcut.character).uppercased())")
                        .font(MenuMetrics.itemFont)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: .command) })
    }
}

/// Circular glyph used at the start of rows, like network and device icons in Wi-Fi and
/// Bluetooth menus. `isActive` fills it with `tint`.
struct MenuRowIcon: View {
    let systemName: String
    let tint: Color
    var isActive = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? tint : Color.primary.opacity(0.1))
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : tint)
        }
        .frame(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
        .accessibilityHidden(true)
    }
}

extension MeetingSource {
    /// Accent used for this source's icons.
    var tint: Color {
        switch self {
        case .googleCalendar: return Color(red: 0.15, green: 0.55, blue: 0.85)
        case .spacemail: return Color(red: 0.95, green: 0.45, blue: 0.15)
        }
    }
}
