import Foundation
import Combine
import os
import AppKit

/// Periodically refreshes upcoming meetings and publishes the latest list.
@MainActor
final class MeetingPoller: ObservableObject {
    @Published private(set) var upcomingMeetings: [Meeting] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published var menuIsOpen = false

    private let settings: AppSettings
    private let googleClient: GoogleCalendarClient
    private let spacemailClient: SpacemailCalDAVClient
    private let logger = Logger(subsystem: "com.meetingmonitor.app", category: "Poller")

    private var timerTask: Task<Void, Never>?
    private var backoffSeconds: TimeInterval = 0
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pausedForSleep = false

    var isGoogleConfigured: Bool { googleClient.isConfigured }
    var isSpacemailConfigured: Bool { spacemailClient.isConfigured }
    var googleEmail: String? { googleClient.email }
    var spacemailEmail: String? { spacemailClient.email }

    var filteredMeetings: [Meeting] {
        settings.filteredMeetings(upcomingMeetings)
    }

    /// Next not-yet-ended meeting (same policy as the menu bar label).
    var nextMeeting: Meeting? { MeetingFormat.nextMeeting(from: filteredMeetings) }

    /// Count of filtered meetings that have not fully ended.
    var upcomingCount: Int {
        filteredMeetings.filter { MeetingFormat.isRelevant($0) }.count
    }

    init(
        settings: AppSettings,
        googleClient: GoogleCalendarClient,
        spacemailClient: SpacemailCalDAVClient
    ) {
        self.settings = settings
        self.googleClient = googleClient
        self.spacemailClient = spacemailClient
        observeSleep()
    }

    deinit {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()
            while !Task.isCancelled {
                let interval = self.currentInterval() + self.backoffSeconds
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                if self.pausedForSleep { continue }
                await self.refreshNow()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let lookahead = cal.date(byAdding: .hour, value: settings.lookaheadHours, to: todayStart)
            ?? todayStart.addingTimeInterval(86400)

        var allMeetings: [Meeting] = []
        var errors: [String] = []
        var anySourceSucceeded = false
        let anyConfigured = googleClient.isConfigured || spacemailClient.isConfigured

        if googleClient.isConfigured {
            do {
                let meetings = try await googleClient.fetchMeetings(from: todayStart, to: lookahead)
                allMeetings.append(contentsOf: meetings)
                anySourceSucceeded = true
            } catch {
                errors.append("Google: \(error.localizedDescription)")
                logger.error("Google fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if spacemailClient.isConfigured {
            do {
                let meetings = try await spacemailClient.fetchMeetings(from: todayStart, to: lookahead)
                allMeetings.append(contentsOf: meetings)
                anySourceSucceeded = true
            } catch {
                errors.append("Spacemail: \(error.localizedDescription)")
                logger.error("Spacemail fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        lastError = errors.isEmpty ? nil : errors.joined(separator: " · ")

        // Keep last good list when every configured source fails (do not blank the UI).
        if anySourceSucceeded || !anyConfigured {
            // Keep events for the day list (including ended-today); next/join use MeetingFormat.
            upcomingMeetings = allMeetings
                .filter { $0.endDate > now || $0.startDate >= todayStart }
                .sorted { $0.startDate < $1.startDate }
            lastRefreshedAt = Date()
            backoffSeconds = 0
            if allMeetings.isEmpty {
                logger.info("No upcoming meetings found")
            } else {
                logger.info("Refreshed: \(allMeetings.count) meetings (\(errors.count) source error(s))")
            }
        } else {
            applyBackoff()
            logger.error("All sources failed; keeping previous meeting list")
        }
    }

    private func currentInterval() -> TimeInterval {
        if menuIsOpen {
            return TimeInterval(settings.activePollSeconds)
        }
        return TimeInterval(settings.idlePollSeconds)
    }

    private func applyBackoff() {
        if backoffSeconds == 0 {
            backoffSeconds = 30
        } else {
            backoffSeconds = min(backoffSeconds * 2, 600)
        }
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pausedForSleep = true }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pausedForSleep = false
                await self?.refreshNow()
            }
        }
    }
}
