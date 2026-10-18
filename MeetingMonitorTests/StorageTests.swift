@testable import MeetingMonitor
import XCTest

final class CredentialStoreTests: XCTestCase {
    private var originalDirectory: URL!
    private var tempDirectory: URL!
    private let provider = "test-\(UUID().uuidString)"

    override func setUpWithError() throws {
        originalDirectory = CredentialStore.directory
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialStoreTests-\(UUID().uuidString)", isDirectory: true)
        CredentialStore.directory = tempDirectory
    }

    override func tearDownWithError() throws {
        CredentialStore.directory = originalDirectory
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testRoundTripPermissionsAndDelete() throws {
        let creds = CalendarCredentials(
            provider: provider,
            username: "me@example.com",
            password: "p@ss word",
            accessToken: nil,
            refreshToken: nil,
            tokenExpiry: nil,
            clientId: nil,
            clientSecret: nil
        )
        CredentialStore.save(credential: creds)

        let loaded = try XCTUnwrap(CredentialStore.load(provider: provider))
        XCTAssertEqual(loaded.username, "me@example.com")
        XCTAssertEqual(loaded.password, "p@ss word")

        let fileMode = try FileManager.default
            .attributesOfItem(atPath: CredentialStore.fileURL(provider: provider).path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: tempDirectory.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)

        CredentialStore.delete(provider: provider)
        XCTAssertNil(CredentialStore.load(provider: provider))
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    func testStoredValuesAreClamped() throws {
        let suite = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: "activePollSeconds")
        defaults.set(99999, forKey: "idlePollSeconds")
        defaults.set(500, forKey: "lookaheadHours")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.activePollSeconds, AppSettings.activePollRange.lowerBound)
        XCTAssertEqual(settings.idlePollSeconds, AppSettings.idlePollRange.upperBound)
        XCTAssertEqual(settings.lookaheadHours, AppSettings.lookaheadHoursRange.upperBound)
    }
}
