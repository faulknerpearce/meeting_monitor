import SwiftUI
import AppKit

struct MenuBarPanelView: View {
    @ObservedObject var poller: MeetingPoller
    @ObservedObject var settings: AppSettings

    var openPreferences: () -> Void

    @State private var selectedDate = Date()

    private var filtered: [Meeting] { poller.filteredMeetings }

    private var dayMeetings: [Meeting] {
        let dayStart = Calendar.current.startOfDay(for: selectedDate)
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        // Overlap the day (not start-only) so multi-day / all-day events still appear.
        return filtered
            .filter { MeetingFormat.overlapsDay($0, dayStart: dayStart, dayEnd: dayEnd) }
            .sorted { $0.startDate < $1.startDate }
    }

    private var allDayMeetings: [Meeting] {
        dayMeetings.filter { $0.isAllDay }
    }

    private var timedMeetings: [Meeting] {
        dayMeetings.filter { !$0.isAllDay }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            meetingCalendar
            Divider().padding(.vertical, 6)
            menuActions
        }
        .padding(12)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            poller.menuIsOpen = true
            Task { await poller.refreshNow() }
        }
        .onDisappear {
            poller.menuIsOpen = false
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Meeting Monitor")
                .font(PanelTypography.title)

            HStack(spacing: 8) {
                if let last = poller.lastRefreshedAt {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                        .font(PanelTypography.caption)
                        .foregroundStyle(.secondary)
                } else if poller.isRefreshing {
                    Text("Refreshing…")
                        .font(PanelTypography.caption)
                        .foregroundStyle(.secondary)
                } else if let error = poller.lastError {
                    Text(error)
                        .font(PanelTypography.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Waiting for meetings…")
                        .font(PanelTypography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                PanelPill(text: "\(poller.upcomingCount) upcoming")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Day list (calendar navigation)

    private var meetingCalendar: some View {
        VStack(spacing: 0) {
            dateNavigation

            if !poller.isGoogleConfigured && !poller.isSpacemailConfigured {
                configurationEmptyState
            } else if poller.isRefreshing && filtered.isEmpty {
                loadingState
            } else {
                meetingList
            }
        }
        .frame(maxHeight: 560)
    }

    private var dateNavigation: some View {
        HStack(spacing: 12) {
            dayNavButton(systemName: "chevron.left", action: previousDay)

            Spacer()

            VStack(spacing: 1) {
                Text(dateTitle)
                    .font(PanelTypography.title)
                    .foregroundStyle(.primary)
                Text(dayMeetingCountLabel)
                    .font(PanelTypography.micro)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            dayNavButton(systemName: "chevron.right", action: nextDay)
        }
        .padding(.bottom, 8)
    }

    /// Full square is tappable (not just the chevron glyph).
    private func dayNavButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }

    private var dateTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(selectedDate) {
            return "Today, \(selectedDate.formatted(date: .abbreviated, time: .omitted))"
        } else if cal.isDateInTomorrow(selectedDate) {
            return "Tomorrow, \(selectedDate.formatted(date: .abbreviated, time: .omitted))"
        } else if cal.isDateInYesterday(selectedDate) {
            return "Yesterday, \(selectedDate.formatted(date: .abbreviated, time: .omitted))"
        }
        return selectedDate.formatted(date: .long, time: .omitted)
    }

    private var dayMeetingCountLabel: String {
        let count = dayMeetings.count
        if count == 0 { return "No meetings" }
        return count == 1 ? "1 meeting" : "\(count) meetings"
    }

    private var meetingList: some View {
        Group {
            if dayMeetings.isEmpty {
                dayEmptyState
            } else {
                // Fixed min height: bare ScrollView inside MenuBarExtra often collapses to 0.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !allDayMeetings.isEmpty {
                            PanelCard {
                                PanelSectionHeader(title: "All day")
                                ForEach(allDayMeetings) { meeting in
                                    meetingRow(meeting)
                                }
                            }
                        }
                        if !timedMeetings.isEmpty {
                            PanelCard {
                                if allDayMeetings.isEmpty {
                                    PanelSectionHeader(title: dayMeetings.count == timedMeetings.count ? "Schedule" : "Timed")
                                } else {
                                    PanelSectionHeader(title: "Schedule")
                                }
                                ForEach(timedMeetings) { meeting in
                                    meetingRow(meeting)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(minHeight: 200, maxHeight: 480, alignment: .top)
            }
        }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        let color = sourceColor(for: meeting)
        let isPast = !meeting.isAllDay && meeting.endDate < Date()
        let isNow = !meeting.isAllDay && meeting.startDate <= Date() && meeting.endDate >= Date()
        let hasJoin = meeting.meetingLink.flatMap(URL.init(string:)) != nil

        return Button {
            if let link = meeting.meetingLink, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 3) {
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
                        } else if !meeting.isAllDay, meeting.endDate > Date() {
                            Text(MeetingFormat.relativeTime(for: meeting))
                                .font(PanelTypography.captionMedium)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(MeetingFormat.timeRange(meeting))
                            .font(PanelTypography.caption)
                            .foregroundStyle(.secondary)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(meeting.source == .googleCalendar ? "Google" : "Spacemail")
                            .font(PanelTypography.micro.weight(.medium))
                            .foregroundStyle(color)

                        if hasJoin {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Label("Join", systemImage: "video.fill")
                                .font(PanelTypography.micro.weight(.medium))
                                .foregroundStyle(color)
                                .labelStyle(.titleAndIcon)
                        }
                    }

                    if let location = meeting.location, !location.isEmpty {
                        Text(location)
                            .font(PanelTypography.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
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
        .help(hasJoin ? "Click to join" : meeting.title)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private func sourceColor(for meeting: Meeting) -> Color {
        switch meeting.source {
        case .googleCalendar:
            return Color(red: 0.15, green: 0.55, blue: 0.85)
        case .spacemail:
            return Color(red: 0.95, green: 0.45, blue: 0.15)
        }
    }

    private var loadingState: some View {
        PanelCard {
            HStack {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Loading…")
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        }
    }

    private var configurationEmptyState: some View {
        PanelCard {
            VStack(spacing: 6) {
                PanelSectionHeader(title: "No calendars")
                Text("No calendars configured.")
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                Button("Configure in Preferences…") { openPreferences() }
                    .font(PanelTypography.body)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        }
    }

    private var dayEmptyState: some View {
        PanelCard {
            VStack(spacing: 6) {
                PanelSectionHeader(title: "No meetings")
                Text("No meetings on this day.")
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                if !isToday {
                    Button("Go to Today") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedDate = Date()
                        }
                    }
                    .font(PanelTypography.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Menu Actions

    private var menuActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            panelButton("Refresh", shortcut: "⌘R") {
                Task { await poller.refreshNow() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(poller.isRefreshing)

            if let next = poller.nextMeeting, let link = next.meetingLink, let url = URL(string: link) {
                panelButton("Join Next Meeting", shortcut: "⌘J") {
                    NSWorkspace.shared.open(url)
                }
                .keyboardShortcut("j", modifiers: [.command])
            }

            Divider().padding(.vertical, 4)

            Toggle(isOn: $settings.showGoogleCalendar) {
                statusLabel("Google Calendar", enabled: poller.isGoogleConfigured)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .font(PanelTypography.body)
            .disabled(!poller.isGoogleConfigured)

            Toggle(isOn: $settings.showSpacemailCalendar) {
                statusLabel("Spacemail", enabled: poller.isSpacemailConfigured)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .font(PanelTypography.body)
            .disabled(!poller.isSpacemailConfigured)

            Divider().padding(.vertical, 4)

            panelButton("Preferences…", shortcut: "⌘,", action: openPreferences)
                .keyboardShortcut(",", modifiers: [.command])

            Divider().padding(.vertical, 4)

            panelButton("Quit Meeting Monitor", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private func panelButton(_ title: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.secondary)
                        .font(PanelTypography.body)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .font(PanelTypography.body)
    }

    private func statusLabel(_ title: String, enabled: Bool) -> some View {
        HStack {
            Circle()
                .fill(enabled ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(title)
            Spacer()
            if !enabled {
                Text("Not configured")
                    .foregroundStyle(.tertiary)
                    .font(PanelTypography.caption)
            } else {
                Image(systemName: "checkmark")
                    .font(PanelTypography.captionSemibold)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    // MARK: - Navigation

    private func previousDay() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
        }
    }

    private func nextDay() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        }
    }
}
