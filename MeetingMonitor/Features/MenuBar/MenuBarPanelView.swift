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
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 400)
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
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                if let last = poller.lastRefreshedAt {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if poller.isRefreshing {
                    Text("Refreshing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let error = poller.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else {
                    Text("Waiting for meetings…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(poller.upcomingCount) upcoming")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
        .frame(maxHeight: 420)
    }

    private var dateNavigation: some View {
        HStack(spacing: 12) {
            dayNavButton(systemName: "chevron.left", action: previousDay)

            Spacer()

            VStack(spacing: 1) {
                Text(dateTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(dayMeetingCountLabel)
                    .font(.system(size: 10))
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
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !allDayMeetings.isEmpty {
                            sectionLabel("All day")
                            ForEach(allDayMeetings) { meeting in
                                meetingRow(meeting)
                            }
                        }
                        if !timedMeetings.isEmpty {
                            if !allDayMeetings.isEmpty {
                                sectionLabel("Schedule")
                            }
                            ForEach(timedMeetings) { meeting in
                                meetingRow(meeting)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(minHeight: 140, maxHeight: 320, alignment: .top)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.top, 2)
            .padding(.bottom, 2)
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
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isPast ? Color.secondary : Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 4)

                        if isNow {
                            Text("Now")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(color))
                        } else if !meeting.isAllDay, meeting.endDate > Date() {
                            Text(MeetingFormat.relativeTime(for: meeting))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(MeetingFormat.timeRange(meeting))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(meeting.source == .googleCalendar ? "Google" : "Spacemail")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(color)

                        if hasJoin {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Label("Join", systemImage: "video.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(color)
                                .labelStyle(.titleAndIcon)
                        }
                    }

                    if let location = meeting.location, !location.isEmpty {
                        Text(location)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isPast ? 0.03 : 0.06))
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
        HStack {
            ProgressView().controlSize(.small).scaleEffect(0.8)
            Text("Loading…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
    }

    private var configurationEmptyState: some View {
        VStack(spacing: 6) {
            Text("No calendars configured.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Configure in Preferences…") { openPreferences() }
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
    }

    private var dayEmptyState: some View {
        VStack(spacing: 6) {
            Text("No meetings on this day.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !isToday {
                Button("Go to Today") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedDate = Date()
                    }
                }
                .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
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
            .font(.system(size: 13))
            .disabled(!poller.isGoogleConfigured)

            Toggle(isOn: $settings.showSpacemailCalendar) {
                statusLabel("Spacemail", enabled: poller.isSpacemailConfigured)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .font(.system(size: 13))
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
                        .font(.system(size: 12))
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
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
                    .font(.system(size: 11))
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
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
