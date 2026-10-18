import Foundation
import os
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    static let activePollRange = 15...300
    static let idlePollRange = 30...3600
    static let lookaheadHoursRange = 1...72
    static let defaultLookaheadHours = 72

    private let defaults: UserDefaults
    private let logger = Logger(category: "Settings")

    @Published var activePollSeconds: Int {
        didSet {
            guard activePollSeconds != oldValue else { return }
            defaults.set(activePollSeconds, forKey: Keys.activePoll)
        }
    }

    @Published var idlePollSeconds: Int {
        didSet {
            guard idlePollSeconds != oldValue else { return }
            defaults.set(idlePollSeconds, forKey: Keys.idlePoll)
        }
    }

    @Published var lookaheadHours: Int {
        didSet {
            guard lookaheadHours != oldValue else { return }
            defaults.set(lookaheadHours, forKey: Keys.lookaheadHours)
        }
    }

    @Published var showSourceInMenuBar: Bool {
        didSet {
            guard showSourceInMenuBar != oldValue else { return }
            defaults.set(showSourceInMenuBar, forKey: Keys.showSource)
        }
    }

    @Published var showGoogleCalendar: Bool {
        didSet {
            guard showGoogleCalendar != oldValue else { return }
            defaults.set(showGoogleCalendar, forKey: Keys.showGoogleCalendar)
        }
    }

    @Published var showSpacemailCalendar: Bool {
        didSet {
            guard showSpacemailCalendar != oldValue else { return }
            defaults.set(showSpacemailCalendar, forKey: Keys.showSpacemailCalendar)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isRevertingLaunchAtLogin, launchAtLogin != oldValue else { return }
            updateLaunchAtLogin()
        }
    }

    /// Why the last Launch at Login change did not take effect.
    @Published private(set) var launchAtLoginError: String?

    private var isRevertingLaunchAtLogin = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activePollSeconds = Self.clamp(defaults.object(forKey: Keys.activePoll) as? Int ?? 60, to: Self.activePollRange)
        idlePollSeconds = Self.clamp(defaults.object(forKey: Keys.idlePoll) as? Int ?? 300, to: Self.idlePollRange)
        lookaheadHours = Self.clamp(
            defaults.object(forKey: Keys.lookaheadHours) as? Int ?? Self.defaultLookaheadHours,
            to: Self.lookaheadHoursRange
        )
        showSourceInMenuBar = defaults.object(forKey: Keys.showSource) as? Bool ?? true
        showGoogleCalendar = defaults.object(forKey: Keys.showGoogleCalendar) as? Bool ?? true
        showSpacemailCalendar = defaults.object(forKey: Keys.showSpacemailCalendar) as? Bool ?? true
        // Property observers do not run during init, so this does not re-register the service.
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    func filteredMeetings(_ meetings: [Meeting]) -> [Meeting] {
        meetings.filter { meeting in
            switch meeting.source {
            case .googleCalendar: return showGoogleCalendar
            case .spacemail: return showSpacemailCalendar
            }
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            logger.error("Launch at Login change failed: \(error.localizedDescription, privacy: .public)")
            let actual = SMAppService.mainApp.status == .enabled
            guard launchAtLogin != actual else { return }
            isRevertingLaunchAtLogin = true
            launchAtLogin = actual
            isRevertingLaunchAtLogin = false
        }
    }

    private enum Keys {
        static let activePoll = "activePollSeconds"
        static let idlePoll = "idlePollSeconds"
        static let lookaheadHours = "lookaheadHours"
        static let showSource = "showSourceInMenuBar"
        static let showGoogleCalendar = "showGoogleCalendar"
        static let showSpacemailCalendar = "showSpacemailCalendar"
    }
}
