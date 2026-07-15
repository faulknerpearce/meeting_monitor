import SwiftUI
import AppKit

struct MenuBarLabelView: View {
    let meetings: [Meeting]
    let showSource: Bool

    private var labelID: String {
        let next = MeetingFormat.nextMeeting(from: meetings)
        let timeLabel = next.map { MeetingFormat.menuBarTime(for: $0) } ?? "none"
        let stamp = next.map { Int($0.startDate.timeIntervalSince1970) } ?? 0
        let count = meetings.count
        return "\(timeLabel)-\(stamp)-\(count)-\(showSource)"
    }

    var body: some View {
        Image(nsImage: MenuBarStatusRenderer.image(
            meetings: meetings,
            showSource: showSource
        ))
        .renderingMode(.original)
        .id(labelID)
    }
}
