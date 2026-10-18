import AppKit
import SwiftUI

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
        dayMeetings.filter(\.isAllDay)
    }

    private var timedMeetings: [Meeting] {
        dayMeetings.filter { !$0.isAllDay }
    }

    private var isAnySourceConfigured: Bool {
        MeetingSource.allCases.contains(where: poller.isConfigured)
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
            selectedDate = Date()
            poller.menuIsOpen = true
        }
        .onDisappear {
            poller.menuIsOpen = false
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Meeting Monitor")
                    .font(PanelTypography.title)
                Spacer()
                PanelPill(text: "\(poller.upcomingCount) upcoming")
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        if let error = poller.lastError {
            Text(error)
                .font(PanelTypography.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else if let last = poller.lastRefreshedAt {
            Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                .font(PanelTypography.caption)
                .foregroundStyle(.secondary)
        } else if poller.isRefreshing {
            Text("Refreshing…")
                .font(PanelTypography.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Waiting for meetings…")
                .font(PanelTypography.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Day list (calendar navigation)

    private var meetingCalendar: some View {
        VStack(spacing: 0) {
            dateNavigation

            if !isAnySourceConfigured {
                configurationEmptyState
            } else if poller.isRefreshing, filtered.isEmpty {
                loadingState
            } else {
                meetingList
            }
        }
        .frame(maxHeight: 560)
    }

    private var dateNavigation: some View {
        HStack(spacing: 12) {
            dayNavButton(systemName: "chevron.left", label: "Previous day") { shiftDay(by: -1) }

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

            dayNavButton(systemName: "chevron.right", label: "Next day") { shiftDay(by: 1) }
        }
        .padding(.bottom, 8)
    }

    /// Full square is tappable (not just the chevron glyph).
    private func dayNavButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
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
        .accessibilityLabel(label)
    }

    private var dateTitle: String {
        let cal = Calendar.current
        let date = selectedDate.formatted(date: .abbreviated, time: .omitted)
        if cal.isDateInToday(selectedDate) { return "Today, \(date)" }
        if cal.isDateInTomorrow(selectedDate) { return "Tomorrow, \(date)" }
        if cal.isDateInYesterday(selectedDate) { return "Yesterday, \(date)" }
        return selectedDate.formatted(date: .long, time: .omitted)
    }

    private var dayMeetingCountLabel: String {
        switch dayMeetings.count {
        case 0: return "No meetings"
        case 1: return "1 meeting"
        case let count: return "\(count) meetings"
        }
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
                            meetingSection(title: "All day", meetings: allDayMeetings)
                        }
                        if !timedMeetings.isEmpty {
                            meetingSection(title: "Schedule", meetings: timedMeetings)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(minHeight: 200, maxHeight: 480, alignment: .top)
            }
        }
    }

    private func meetingSection(title: String, meetings: [Meeting]) -> some View {
        PanelCard {
            PanelSectionHeader(title: title)
            ForEach(meetings) { meeting in
                MeetingRowView(meeting: meeting, now: Date())
            }
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
                Text("Connect Google Calendar or Spacemail to see meetings.")
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
                Text("Nothing scheduled for this day.")
                    .font(PanelTypography.body)
                    .foregroundStyle(.secondary)
                if !Calendar.current.isDateInToday(selectedDate) {
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

    // MARK: - Navigation

    private func shiftDay(by days: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
        }
    }
}

// MARK: - Menu Actions

extension MenuBarPanelView {
    private var menuActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            panelButton("Refresh", shortcut: "⌘R") {
                Task { await poller.refreshNow() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(poller.isRefreshing)

            if let url = poller.nextMeeting?.meetingLink {
                panelButton("Join Next Meeting", shortcut: "⌘J") {
                    NSWorkspace.shared.open(url)
                }
                .keyboardShortcut("j", modifiers: [.command])
            }

            Divider().padding(.vertical, 4)

            sourceToggle(.googleCalendar, isOn: $settings.showGoogleCalendar)
            sourceToggle(.spacemail, isOn: $settings.showSpacemailCalendar)

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

    private func sourceToggle(_ source: MeetingSource, isOn: Binding<Bool>) -> some View {
        let configured = poller.isConfigured(source)
        return Toggle(isOn: isOn) {
            statusLabel(source.displayName, enabled: configured)
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .font(PanelTypography.body)
        .disabled(!configured)
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
}
