import AppKit
import SwiftUI

/// One meeting in the day list; clicking opens its join link when it has one.
struct MeetingRowView: View {
    let meeting: Meeting
    let now: Date

    private var color: Color {
        switch meeting.source {
        case .googleCalendar: return Color(red: 0.15, green: 0.55, blue: 0.85)
        case .spacemail: return Color(red: 0.95, green: 0.45, blue: 0.15)
        }
    }

    private var isPast: Bool { !meeting.isAllDay && meeting.endDate <= now }
    private var isNow: Bool { !meeting.isAllDay && meeting.startDate <= now && meeting.endDate > now }

    var body: some View {
        Button {
            if let url = meeting.meetingLink {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    detailLine
                    if let location = meeting.location {
                        Text(location)
                            .font(PanelTypography.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isPast ? 0.6 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color.opacity(isNow ? 0.45 : 0.18), lineWidth: 1)
            )
            .opacity(isPast ? 0.72 : 1)
        }
        .buttonStyle(.plain)
        .help(meeting.meetingLink == nil ? meeting.title : "Click to join")
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(meeting.title)
                .font(PanelTypography.bodySemibold)
                .foregroundStyle(isPast ? Color.secondary : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 4)

            if isNow {
                Text("Now")
                    .font(PanelTypography.micro.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color))
            } else if !meeting.isAllDay, meeting.endDate > now {
                Text(MeetingFormat.relativeTime(for: meeting, now: now))
                    .font(PanelTypography.captionMedium)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailLine: some View {
        HStack(spacing: 6) {
            Text(MeetingFormat.timeRange(meeting))
                .font(PanelTypography.caption)
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(meeting.source.shortName)
                .font(PanelTypography.micro.weight(.medium))
                .foregroundStyle(color)

            if meeting.meetingLink != nil {
                Text("·")
                    .foregroundStyle(.tertiary)
                Label("Join", systemImage: "video.fill")
                    .font(PanelTypography.micro.weight(.medium))
                    .foregroundStyle(color)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}
