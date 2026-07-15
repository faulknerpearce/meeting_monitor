import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

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

    private var isRevertingLaunchAtLogin = false

    /// Matches Preferences stepper range (`1...72`).
    static let lookaheadHoursRange = 1...72
    static let defaultLookaheadHours = 72

    init() {
        activePollSeconds = defaults.object(forKey: Keys.activePoll) as? Int ?? 60
        idlePollSeconds = defaults.object(forKey: Keys.idlePoll) as? Int ?? 300
        let storedLookahead = defaults.object(forKey: Keys.lookaheadHours) as? Int
            ?? Self.defaultLookaheadHours
        lookaheadHours = min(max(storedLookahead, Self.lookaheadHoursRange.lowerBound),
                             Self.lookaheadHoursRange.upperBound)
        showSourceInMenuBar = defaults.object(forKey: Keys.showSource) as? Bool ?? true
        showGoogleCalendar = defaults.object(forKey: Keys.showGoogleCalendar) as? Bool ?? true
        showSpacemailCalendar = defaults.object(forKey: Keys.showSpacemailCalendar) as? Bool ?? true
        launchAtLogin = false
        Task {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
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
        } catch {
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
