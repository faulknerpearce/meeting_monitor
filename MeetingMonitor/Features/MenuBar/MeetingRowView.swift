import AppKit
import SwiftUI

/// One meeting in the day list, laid out like a network row in the Wi-Fi menu.
/// Rows with a join link highlight on hover and open the link when clicked.
struct MeetingRowView: View {
    let meeting: Meeting
    let now: Date

    private var isPast: Bool { !meeting.isAllDay && meeting.endDate <= now }
    private var isNow: Bool { !meeting.isAllDay && meeting.startDate <= now && meeting.endDate > now }

    var body: some View {
        if let link = meeting.meetingLink {
            Button {
                NSWorkspace.shared.open(link)
            } label: {
                content
            }
            .buttonStyle(MenuRowButtonStyle())
            .help("Join \(meeting.title)")
            .accessibilityHint("Opens the meeting link")
        } else {
            content
                .menuRowLayout()
                .help(meeting.title)
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            MenuRowIcon(
                systemName: meeting.meetingLink == nil ? "calendar" : "video.fill",
                tint: meeting.source.tint,
                isActive: isNow
            )
            .opacity(isPast ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(MenuMetrics.itemFont)
                    .foregroundStyle(isPast ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(MeetingFormat.timeRange(meeting)) · \(meeting.source.shortName)")
                    .font(MenuMetrics.detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            trailingStatus
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isNow {
            Text("Now")
                .font(MenuMetrics.detailFont.weight(.semibold))
                .foregroundStyle(meeting.source.tint)
        } else if !meeting.isAllDay, !isPast {
            Text(MeetingFormat.relativeTime(for: meeting, now: now))
                .font(MenuMetrics.detailFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
