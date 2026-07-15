import Foundation
import os

@MainActor
final class GoogleCalendarClient: ObservableObject {
    let source: MeetingSource = .googleCalendar
    private let logger = Logger(subsystem: "com.meetingmonitor.app", category: "GoogleCalendar")
    private let session: URLSession
    private let baseURL = URL(string: "https://www.googleapis.com/calendar/v3")!
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    @Published private(set) var isConfigured = false
    @Published private(set) var email: String?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastAuthError: String?

    /// OAuth Desktop client ID (remembered between launches for the sign-in form).
    @Published var oauthClientID: String {
        didSet { UserDefaults.standard.set(oauthClientID, forKey: Keys.oauthClientID) }
    }

    /// Optional client secret — held in memory / CredentialStore only (never UserDefaults).
    @Published var oauthClientSecret: String = ""

    private var credentials: CalendarCredentials? {
        didSet { applyCredentialState() }
    }

    init(session: URLSession) {
        self.session = session
        oauthClientID = UserDefaults.standard.string(forKey: Keys.oauthClientID) ?? ""
        // Drop legacy secret key if present (was stored in UserDefaults in older builds).
        UserDefaults.standard.removeObject(forKey: Keys.legacyOAuthClientSecret)
        credentials = CredentialStore.load(provider: "google")
        // `didSet` does not run during init — apply loaded credentials explicitly.
        applyCredentialState()
        // Prefill OAuth form from stored credentials when available.
        if let creds = credentials {
            if oauthClientID.isEmpty, let id = creds.clientId { oauthClientID = id }
            if let secret = creds.clientSecret, !secret.isEmpty { oauthClientSecret = secret }
        }
    }

    private func applyCredentialState() {
        isConfigured = credentials?.refreshToken?.isEmpty == false
        email = credentials?.username
    }

    /// True when Google needs the user to sign in again (token/refresh failure).
    var needsReauth: Bool {
        lastAuthError != nil && isConfigured
    }

    /// Interactive browser OAuth (PKCE + loopback). Spacemail stays password-based.
    func signInWithGoogle() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        lastAuthError = nil
        defer { isAuthenticating = false }

        do {
            let tokens = try await GoogleOAuthFlow.signIn(
                clientID: oauthClientID,
                clientSecret: oauthClientSecret.isEmpty ? nil : oauthClientSecret,
                session: session
            )
            let secret = oauthClientSecret.isEmpty ? nil : oauthClientSecret
            let creds = CalendarCredentials(
                provider: "google",
                username: tokens.email,
                password: nil,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                tokenExpiry: Date().addingTimeInterval(tokens.expiresIn - 60),
                clientId: oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: secret
            )
            credentials = creds
            CredentialStore.save(credential: creds)
            logger.info("Google OAuth sign-in succeeded for \(tokens.email ?? "unknown", privacy: .public)")
        } catch {
            lastAuthError = error.localizedDescription
            logger.error("Google OAuth failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearCredentials() {
        credentials = nil
        lastAuthError = nil
        oauthClientSecret = ""
        CredentialStore.delete(provider: "google")
    }

    func fetchMeetings(from startDate: Date, to endDate: Date) async throws -> [Meeting] {
        guard isConfigured else {
            throw CalendarProviderError.notConfigured
        }

        let token = try await getAccessToken()

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("calendars/primary/events"),
            resolvingAgainstBaseURL: false
        ) else {
            throw CalendarProviderError.networkError("Invalid URL")
        }
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: Self.isoString(from: startDate)),
            URLQueryItem(name: "timeMax", value: Self.isoString(from: endDate)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]

        guard let url = components.url else {
            throw CalendarProviderError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MeetingMonitor/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarProviderError.networkError("Invalid response")
        }
        if http.statusCode == 401 {
            markAuthFailure("Token expired. Sign in again in Preferences.")
            throw CalendarProviderError.authFailed("Token expired. Sign in again in Preferences.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CalendarProviderError.httpStatus(http.statusCode)
        }

        lastAuthError = nil
        return try Self.parseEvents(data: data)
    }

    // MARK: - Token

    private func getAccessToken() async throws -> String {
        guard let creds = credentials,
              let refreshToken = creds.refreshToken,
              let clientId = creds.clientId, !clientId.isEmpty else {
            throw CalendarProviderError.notConfigured
        }

        if let accessToken = creds.accessToken, let expiry = creds.tokenExpiry, Date() < expiry {
            return accessToken
        }

        var fields: [String: String] = [
            "client_id": clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = creds.clientSecret, !secret.isEmpty {
            fields["client_secret"] = secret
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuthFlow.formURLEncodedBody(fields)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            markAuthFailure("Token refresh failed. Sign in again in Preferences.")
            throw CalendarProviderError.authFailed("Token refresh failed. Sign in again in Preferences.")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            markAuthFailure("Token refresh returned no access token.")
            throw CalendarProviderError.authFailed("Token refresh returned no access token.")
        }

        let expiresIn = json["expires_in"] as? Double ?? 3600
        let expiry = Date().addingTimeInterval(expiresIn - 60)

        let updated = CalendarCredentials(
            provider: "google",
            username: creds.username,
            password: nil,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenExpiry: expiry,
            clientId: clientId,
            clientSecret: creds.clientSecret
        )
        credentials = updated
        CredentialStore.save(credential: updated)
        lastAuthError = nil

        return accessToken
    }

    /// Surface re-auth UI without wiping the refresh token (user can Sign in again).
    private func markAuthFailure(_ message: String) {
        lastAuthError = message
        guard let creds = credentials else { return }
        // Drop only the short-lived access token so the next attempt forces refresh/sign-in.
        let cleared = CalendarCredentials(
            provider: creds.provider,
            username: creds.username,
            password: nil,
            accessToken: nil,
            refreshToken: creds.refreshToken,
            tokenExpiry: nil,
            clientId: creds.clientId,
            clientSecret: creds.clientSecret
        )
        credentials = cleared
        CredentialStore.save(credential: cleared)
        logger.error("Google auth failure: \(message, privacy: .public)")
    }

    // MARK: - Parsing (testable)

    nonisolated static func parseEvents(data: Data) throws -> [Meeting] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let items = json?["items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let summary = item["summary"] as? String else {
                return nil
            }

            let startInfo = item["start"] as? [String: Any]
            let endInfo = item["end"] as? [String: Any]
            let isAllDay = startInfo?["date"] != nil

            guard let startDate = parseGoogleDate(startInfo) else { return nil }
            let endDate = parseGoogleDate(endInfo) ?? startDate

            let location = item["location"] as? String
            let meetingLink = extractMeetLink(from: item)
            let attendees = (item["attendees"] as? [[String: Any]])?.compactMap { $0["email"] as? String } ?? []
            let isRecurring = item["recurringEventId"] as? String != nil

            return Meeting(
                id: "google_\(id)",
                title: summary,
                startDate: startDate,
                endDate: endDate,
                location: location,
                meetingLink: meetingLink,
                isAllDay: isAllDay,
                source: .googleCalendar,
                attendees: attendees,
                isRecurring: isRecurring,
                calendarName: "Google Calendar"
            )
        }
    }

    nonisolated static func parseGoogleDate(_ info: [String: Any]?) -> Date? {
        guard let info else { return nil }
        if let dateTimeStr = info["dateTime"] as? String {
            return parseISO8601(dateTimeStr)
        }
        if let dateStr = info["date"] as? String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            return df.date(from: dateStr)
        }
        return nil
    }

    nonisolated private static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }

        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }

    nonisolated private static func extractMeetLink(from item: [String: Any]) -> String? {
        if let conferenceData = item["conferenceData"] as? [String: Any],
           let entryPoints = conferenceData["entryPoints"] as? [[String: Any]] {
            for entry in entryPoints where (entry["entryPointType"] as? String) == "video" {
                return entry["uri"] as? String
            }
        }
        if let location = item["location"] as? String,
           location.contains("meet.google.com") || location.contains("zoom.us") ||
           location.contains("teams.microsoft.com") {
            return location
        }
        return nil
    }

    private static func isoString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private enum Keys {
        static let oauthClientID = "googleOAuthClientID"
        /// Removed: secrets must not live in UserDefaults.
        static let legacyOAuthClientSecret = "googleOAuthClientSecret"
    }
}
