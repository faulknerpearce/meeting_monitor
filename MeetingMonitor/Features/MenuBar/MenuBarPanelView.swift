import AppKit
import SwiftUI

/// The menu bar dropdown, styled like macOS Control Center–style menus (Wi-Fi, Bluetooth).
struct MenuBarPanelView: View {
    @ObservedObject var poller: MeetingPoller
    @ObservedObject var settings: AppSettings

    var openPreferences: () -> Void

    @State private var selectedDate = Date()

    /// Days with more meetings than this scroll instead of growing the menu.
    private static let maxVisibleRows = 8
    private static let rowHeight: CGFloat = 38

    private var filtered: [Meeting] { poller.filteredMeetings }

    private var dayMeetings: [Meeting] {
        let dayStart = Calendar.current.startOfDay(for: selectedDate)
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        // Overlap the day (not start-only) so multi-day / all-day events still appear.
        return filtered
            .filter { MeetingFormat.overlapsDay($0, dayStart: dayStart, dayEnd: dayEnd) }
            .sorted { $0.startDate < $1.startDate }
    }

    private var isAnySourceConfigured: Bool {
        MeetingSource.allCases.contains(where: poller.isConfigured)
    }

    private var isShowingToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuSeparator()
            if isAnySourceConfigured {
                dayNavigator
            }
            meetings
            MenuSeparator()
            meetingActions
            MenuSeparator()
            calendars
            MenuSeparator()
            MenuActionRow(title: "Preferences…", shortcut: ",", action: openPreferences)
            MenuActionRow(title: "Quit Meeting Monitor", shortcut: "q") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 6)
        .frame(width: MenuMetrics.width)
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
            HStack(alignment: .firstTextBaseline) {
                Text("Meeting Monitor")
                    .font(MenuMetrics.titleFont)
                Spacer()
                Text(statusText)
                    .font(MenuMetrics.detailFont)
                    .foregroundStyle(.secondary)
            }
            if let error = poller.lastError {
                Label {
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(MenuMetrics.detailFont)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, MenuMetrics.contentInset)
        .padding(.top, 4)
    }

    private var statusText: String {
        guard isAnySourceConfigured else { return "" }
        if poller.isRefreshing { return "Refreshing…" }
        if let last = poller.lastRefreshedAt {
            return "Updated \(last.formatted(date: .omitted, time: .shortened))"
        }
        return ""
    }

    // MARK: - Day navigator

    private var dayNavigator: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(dateTitle)
                    .font(MenuMetrics.titleFont)
                Text(dayMeetingCountLabel)
                    .font(MenuMetrics.detailFont)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            navigatorButton("chevron.left", label: "Previous day") { shiftDay(by: -1) }
            Button("Today") {
                selectedDate = Date()
            }
            .buttonStyle(.borderless)
            .font(MenuMetrics.detailFont.weight(.medium))
            .disabled(isShowingToday)
            navigatorButton("chevron.right", label: "Next day") { shiftDay(by: 1) }
        }
        .padding(.horizontal, MenuMetrics.contentInset)
        .padding(.bottom, 4)
    }

    private func navigatorButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private var dateTitle: String {
        let cal = Calendar.current
        let date = selectedDate.formatted(.dateTime.month(.abbreviated).day())
        if cal.isDateInToday(selectedDate) { return "Today, \(date)" }
        if cal.isDateInTomorrow(selectedDate) { return "Tomorrow, \(date)" }
        if cal.isDateInYesterday(selectedDate) { return "Yesterday, \(date)" }
        return selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var dayMeetingCountLabel: String {
        switch dayMeetings.count {
        case 0: return "No meetings"
        case 1: return "1 meeting"
        case let count: return "\(count) meetings"
        }
    }

    private func shiftDay(by days: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    }

    // MARK: - Meetings

    @ViewBuilder
    private var meetings: some View {
        if !isAnySourceConfigured {
            placeholder("No calendars connected")
            MenuActionRow(title: "Connect a Calendar…", action: openPreferences)
        } else if poller.isRefreshing, filtered.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(MenuMetrics.itemFont)
                    .foregroundStyle(.secondary)
            }
            .menuRowLayout()
        } else if dayMeetings.isEmpty {
            placeholder("Nothing scheduled")
        } else if dayMeetings.count > Self.maxVisibleRows {
            ScrollView {
                meetingRows
            }
            .frame(height: CGFloat(Self.maxVisibleRows) * Self.rowHeight)
        } else {
            meetingRows
        }
    }

    private var meetingRows: some View {
        let now = Date()
        let allDay = dayMeetings.filter(\.isAllDay)
        let timed = dayMeetings.filter { !$0.isAllDay }
        return VStack(alignment: .leading, spacing: 0) {
            if !allDay.isEmpty {
                MenuSectionHeader(title: "All Day")
                ForEach(allDay) { MeetingRowView(meeting: $0, now: now) }
            }
            if !timed.isEmpty {
                if !allDay.isEmpty {
                    MenuSectionHeader(title: "Meetings")
                }
                ForEach(timed) { MeetingRowView(meeting: $0, now: now) }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(MenuMetrics.itemFont)
            .foregroundStyle(.secondary)
            .menuRowLayout()
    }

    // MARK: - Actions

    @ViewBuilder
    private var meetingActions: some View {
        if let url = poller.nextMeeting?.meetingLink {
            MenuActionRow(title: "Join Next Meeting", shortcut: "j") {
                NSWorkspace.shared.open(url)
            }
        }
        MenuActionRow(title: poller.isRefreshing ? "Refreshing…" : "Refresh", shortcut: "r") {
            Task { await poller.refreshNow() }
        }
        .disabled(poller.isRefreshing)
    }

    // MARK: - Calendars

    private var calendars: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuSectionHeader(title: "Calendars")
            calendarRow(.googleCalendar, isOn: $settings.showGoogleCalendar)
            calendarRow(.spacemail, isOn: $settings.showSpacemailCalendar)
        }
    }

    /// Source row with a show/hide switch, like device rows in the Bluetooth menu.
    private func calendarRow(_ source: MeetingSource, isOn: Binding<Bool>) -> some View {
        let configured = poller.isConfigured(source)
        return HStack(spacing: 8) {
            MenuRowIcon(systemName: "calendar", tint: source.tint, isActive: configured && isOn.wrappedValue)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                    .font(MenuMetrics.itemFont)
                if !configured {
                    Text("Not connected")
                        .font(MenuMetrics.detailFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if configured {
                Toggle("Show \(source.displayName)", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
        .menuRowLayout()
    }
}
