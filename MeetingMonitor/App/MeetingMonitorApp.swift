import AppKit
import Combine
import SwiftUI

@main
struct MeetingMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRoot(model: model)
        } label: {
            MenuBarLabelContainer(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Meeting Monitor", id: "preferences") {
            PreferencesRoot(model: model)
                .background(PreferencesWindowLifecycle())
        }
        .defaultSize(width: 500, height: 560)
    }
}

/// Shared app services owned for the process lifetime.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let googleClient: GoogleCalendarClient
    let spacemailClient: SpacemailCalDAVClient
    let poller: MeetingPoller

    private var cancellables = Set<AnyCancellable>()

    /// True when the process is hosting unit tests; the app then stays idle.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        let session: URLSession = {
            // Ephemeral: no on-disk cache or persistent cookies for calendar traffic.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            config.httpAdditionalHeaders = ["User-Agent": "MeetingMonitor/\(version)"]
            return URLSession(configuration: config)
        }()
        googleClient = GoogleCalendarClient(session: session)
        spacemailClient = SpacemailCalDAVClient(session: session)
        poller = MeetingPoller(settings: settings, providers: [googleClient, spacemailClient])
        forwardChanges(from: settings)
        forwardChanges(from: poller)
        forwardChanges(from: googleClient)
        forwardChanges(from: spacemailClient)
        if !Self.isRunningTests {
            poller.start()
        }
    }

    /// MenuBarExtra label only observes `AppModel`; forward child updates.
    private func forwardChanges(from object: some ObservableObject) {
        object.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

private struct MenuBarRoot: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanelView(
            poller: model.poller,
            settings: model.settings,
            openPreferences: {
                AppDelegate.revealWindow()
                openWindow(id: "preferences")
            }
        )
    }
}

private struct PreferencesRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PreferencesView(
            settings: model.settings,
            poller: model.poller,
            googleClient: model.googleClient,
            spacemailClient: model.spacemailClient
        )
    }
}

private struct PreferencesWindowLifecycle: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onDisappear {
                AppDelegate.hideDockIfNoWindows()
            }
    }
}

private struct MenuBarLabelContainer: View {
    @ObservedObject var model: AppModel

    var body: some View {
        MenuBarLabelView(
            meetings: model.poller.filteredMeetings,
            showSource: model.settings.showSourceInMenuBar,
            now: model.poller.clock
        )
    }
}
