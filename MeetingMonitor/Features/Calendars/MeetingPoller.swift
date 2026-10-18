import AppKit
import Combine
import Foundation
import os

/// Periodically refreshes upcoming meetings and publishes the latest list.
@MainActor
final class MeetingPoller: ObservableObject {
    @Published private(set) var upcomingMeetings: [Meeting] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var sourceErrors: [MeetingSource: Error] = [:]
    @Published private(set) var lastRefreshedAt: Date?
    /// Advances at each minute boundary so time-relative labels re-render between polls.
    @Published private(set) var clock = Date()
    @Published var menuIsOpen = false {
        didSet {
            guard menuIsOpen != oldValue, menuIsOpen else { return }
            menuOpened()
        }
    }

    private let settings: AppSettings
    private let providers: [any MeetingProvider]
    private let logger = Logger(category: "Poller")

    /// Last successful result per source; a failing source keeps showing its previous meetings.
    private var meetingsBySource: [MeetingSource: [Meeting]] = [:]
    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var isWaitingForNextPoll = false
    private(set) var backoffSeconds: TimeInterval = 0
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pausedForSleep = false

    var filteredMeetings: [Meeting] {
        settings.filteredMeetings(upcomingMeetings)
    }

    /// Next meeting for the menu bar label and "Join Next Meeting".
    var nextMeeting: Meeting? { MeetingFormat.nextMeeting(from: filteredMeetings, now: clock) }

    /// Per-source errors joined for display, e.g. `Google: … · Spacemail: …`.
    var lastError: String? {
        let messages = MeetingSource.allCases.compactMap { source in
            sourceErrors[source].map { "\(source.shortName): \($0.localizedDescription)" }
        }
        return messages.isEmpty ? nil : messages.joined(separator: " · ")
    }

    init(settings: AppSettings, providers: [any MeetingProvider]) {
        self.settings = settings
        self.providers = providers
        observeSleep()
    }

    deinit {
        pollTask?.cancel()
        clockTask?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func isConfigured(_ source: MeetingSource) -> Bool {
        providers.contains { $0.source == source && $0.isConfigured }
    }

    func error(for source: MeetingSource) -> Error? {
        sourceErrors[source]
    }

    func start() {
        guard pollTask == nil else { return }
        startClock()
        schedulePolling(refreshFirst: true)
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        clockTask?.cancel()
        clockTask = nil
    }

    // MARK: - Scheduling

    private func schedulePolling(refreshFirst: Bool) {
        pollTask?.cancel()
        isWaitingForNextPoll = false
        pollTask = Task { [weak self] in
            if refreshFirst { await self?.refreshNow() }
            while !Task.isCancelled {
                guard let delay = self?.nextDelay() else { return }
                self?.isWaitingForNextPoll = true
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // A cancelled loop has been replaced; leave the flag to its successor.
                guard !Task.isCancelled, let self else { return }
                isWaitingForNextPoll = false
                if !pausedForSleep {
                    await refreshNow()
                }
            }
        }
    }

    /// Switches to the active interval right away instead of after the current idle sleep.
    private func menuOpened() {
        let isStale = lastRefreshedAt.map {
            Date().timeIntervalSince($0) >= TimeInterval(settings.activePollSeconds)
        } ?? true
        // A refresh in flight keeps going; the loop picks the active interval when it finishes.
        guard pollTask == nil || isWaitingForNextPoll else { return }
        schedulePolling(refreshFirst: isStale)
    }

    private func nextDelay() -> TimeInterval {
        let base = menuIsOpen ? settings.activePollSeconds : settings.idlePollSeconds
        return TimeInterval(base) + backoffSeconds
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date().timeIntervalSinceReferenceDate
                let nextMinute = (now / 60).rounded(.down) * 60 + 60
                try? await Task.sleep(nanoseconds: UInt64((nextMinute - now) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                clock = Date()
            }
        }
    }

    // MARK: - Refresh

    /// Fetch window: from the start of today until `lookaheadHours` from now, and at least
    /// through the end of today so the day list is complete.
    static func fetchWindow(now: Date, lookaheadHours: Int, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        let lookahead = now.addingTimeInterval(TimeInterval(lookaheadHours) * 3600)
        return (start, max(lookahead, endOfToday))
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        let window = Self.fetchWindow(now: now, lookaheadHours: settings.lookaheadHours)
        let configured = providers.filter(\.isConfigured)
        let configuredSources = Set(configured.map(\.source))

        let results = await fetchAll(configured, window: window)

        meetingsBySource = meetingsBySource.filter { configuredSources.contains($0.key) }
        var errors: [MeetingSource: Error] = [:]
        var succeeded = 0
        for (source, result) in results {
            switch result {
            case .success(let meetings):
                meetingsBySource[source] = meetings
                succeeded += 1
            case .failure(let error) where Self.isCancellation(error):
                errors[source] = sourceErrors[source]
            case .failure(let error):
                errors[source] = error
                logger.error("\(source.shortName, privacy: .public) fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        sourceErrors = errors

        upcomingMeetings = meetingsBySource.values
            .joined()
            .filter { $0.endDate > window.start }
            .sorted { $0.startDate < $1.startDate }

        if succeeded > 0 || configured.isEmpty {
            lastRefreshedAt = now
            backoffSeconds = 0
            let meetingCount = upcomingMeetings.count
            logger.info("Refreshed: \(meetingCount) meetings (\(errors.count) source error(s))")
        } else if !errors.isEmpty {
            applyBackoff()
            logger.error("All sources failed; keeping previous meeting lists")
        }
    }

    /// Fetches every provider concurrently; each result is independent.
    private func fetchAll(
        _ providers: [any MeetingProvider],
        window: (start: Date, end: Date)
    ) async -> [(MeetingSource, Result<[Meeting], Error>)] {
        await withTaskGroup(of: (MeetingSource, Result<[Meeting], Error>).self) { group in
            for provider in providers {
                group.addTask { @MainActor in
                    do {
                        let meetings = try await provider.fetchMeetings(from: window.start, to: window.end)
                        return (provider.source, .success(meetings))
                    } catch {
                        return (provider.source, .failure(error))
                    }
                }
            }
            var collected: [(MeetingSource, Result<[Meeting], Error>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func applyBackoff() {
        backoffSeconds = backoffSeconds == 0 ? 30 : min(backoffSeconds * 2, 600)
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
                self?.clock = Date()
                await self?.refreshNow()
            }
        }
    }
}
