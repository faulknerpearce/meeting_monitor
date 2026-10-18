import Foundation
import os

@MainActor
final class GoogleCalendarClient: ObservableObject, MeetingProvider {
    let source: MeetingSource = .googleCalendar
    private let logger = Logger(category: "GoogleCalendar")
    private let session: URLSession
    private let eventsURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
    /// Pages fetched per refresh; 250 events per page.
    private let maxPages = 8

    // ISO8601DateFormatter is thread-safe; parsing runs off the main actor.
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    @Published private(set) var isConfigured = false
    @Published private(set) var email: String?
    @Published private(set) var isAuthenticating = false
    /// Stored credentials stopped working; the user has to sign in again.
    @Published private(set) var lastAuthError: String?
    /// The most recent interactive sign-in failed or was cancelled.
    @Published private(set) var signInError: String?

    /// OAuth Desktop client ID (remembered between launches for the sign-in form).
    @Published var oauthClientID: String {
        didSet { UserDefaults.standard.set(oauthClientID, forKey: Keys.oauthClientID) }
    }

    /// Optional client secret — held in memory and in CredentialStore only, never UserDefaults.
    @Published var oauthClientSecret: String = ""

    private var signInTask: Task<GoogleOAuthFlow.Tokens, Error>?

    private var credentials: CalendarCredentials? {
        didSet { applyCredentialState() }
    }

    init(session: URLSession) {
        self.session = session
        oauthClientID = UserDefaults.standard.string(forKey: Keys.oauthClientID) ?? ""
        // The client secret must not live in UserDefaults; remove any stored copy.
        UserDefaults.standard.removeObject(forKey: Keys.legacyOAuthClientSecret)
        credentials = CredentialStore.load(provider: MeetingSource.googleCalendar.credentialKey)
        // `didSet` does not run during init — apply loaded credentials explicitly.
        applyCredentialState()
        if let creds = credentials {
            if oauthClientID.isEmpty, let id = creds.clientId { oauthClientID = id }
            if let secret = creds.clientSecret, !secret.isEmpty { oauthClientSecret = secret }
        }
    }

    private func applyCredentialState() {
        isConfigured = credentials?.refreshToken?.isEmpty == false
        email = credentials?.username
    }

    /// True when stored Google credentials were refused and the user must sign in again.
    var needsReauth: Bool {
        lastAuthError != nil && isConfigured
    }

    /// Interactive browser OAuth (PKCE + loopback). Cancel with `cancelSignIn()`.
    func signInWithGoogle() async {
        guard signInTask == nil else { return }
        isAuthenticating = true
        signInError = nil

        let clientID = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = oauthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = trimmedSecret.isEmpty ? nil : trimmedSecret
        let session = session
        let task = Task {
            try await GoogleOAuthFlow.signIn(clientID: clientID, clientSecret: secret, session: session)
        }
        signInTask = task
        defer {
            signInTask = nil
            isAuthenticating = false
        }

        do {
            let tokens = try await task.value
            let creds = CalendarCredentials(
                provider: MeetingSource.googleCalendar.credentialKey,
                username: tokens.email,
                password: nil,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                tokenExpiry: Date().addingTimeInterval(tokens.expiresIn - 60),
                clientId: clientID,
                clientSecret: secret
            )
            credentials = creds
            CredentialStore.save(credential: creds)
            lastAuthError = nil
            logger.info("Google OAuth sign-in succeeded for \(tokens.email ?? "unknown", privacy: .private)")
        } catch {
            signInError = error.localizedDescription
            logger.error("Google OAuth failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func clearCredentials() {
        credentials = nil
        lastAuthError = nil
        signInError = nil
        oauthClientSecret = ""
        CredentialStore.delete(provider: MeetingSource.googleCalendar.credentialKey)
    }

    func fetchMeetings(from startDate: Date, to endDate: Date) async throws -> [Meeting] {
        guard isConfigured else {
            throw CalendarProviderError.notConfigured
        }

        let token = try await getAccessToken()
        var meetings: [Meeting] = []
        var pageToken: String?
        var pages = 0

        repeat {
            var components = URLComponents(url: eventsURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "timeMin", value: Self.isoFormatter.string(from: startDate)),
                URLQueryItem(name: "timeMax", value: Self.isoFormatter.string(from: endDate)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            guard let url = components.url else {
                throw CalendarProviderError.networkError("Invalid URL")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CalendarProviderError.networkError("Invalid response")
            }
            if http.statusCode == 401 {
                markAuthFailure("Google rejected the access token. Sign in again in Preferences.")
                throw CalendarProviderError.authFailed("Google rejected the access token.")
            }
            guard (200...299).contains(http.statusCode) else {
                throw CalendarProviderError.httpStatus(http.statusCode)
            }

            let page = try await Task.detached(priority: .utility) { try Self.parsePage(data: data) }.value
            meetings.append(contentsOf: page.meetings)
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < maxPages

        lastAuthError = nil
        return meetings
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

        var request = URLRequest(url: GoogleOAuthFlow.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuthFlow.formURLEncodedBody(fields)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard (200...299).contains(status) else {
            let oauthError = json?["error"] as? String
            if Self.isCredentialRejection(status: status, oauthError: oauthError) {
                markAuthFailure("Google refused the stored sign-in (\(oauthError ?? "HTTP \(status)")). Sign in again in Preferences.")
                throw CalendarProviderError.authFailed("Google refused the stored sign-in.")
            }
            throw CalendarProviderError.httpStatus(status)
        }

        guard let accessToken = json?["access_token"] as? String else {
            throw CalendarProviderError.decodeFailed
        }

        let expiresIn = json?["expires_in"] as? Double ?? 3600
        let updated = creds.replacingAccessToken(accessToken, expiry: Date().addingTimeInterval(expiresIn - 60))
        credentials = updated
        CredentialStore.save(credential: updated)
        lastAuthError = nil

        return accessToken
    }

    /// Token-endpoint responses meaning the refresh token or client is no longer valid
    /// (as opposed to transient server failures).
    nonisolated static func isCredentialRejection(status: Int, oauthError: String?) -> Bool {
        if let oauthError, ["invalid_grant", "invalid_client", "unauthorized_client"].contains(oauthError) {
            return true
        }
        return status == 401
    }

    /// Surfaces re-auth UI without wiping the refresh token (the user can sign in again).
    private func markAuthFailure(_ message: String) {
        lastAuthError = message
        guard let creds = credentials else { return }
        // Drop only the short-lived access token so the next attempt forces a refresh.
        let cleared = creds.replacingAccessToken(nil, expiry: nil)
        credentials = cleared
        CredentialStore.save(credential: cleared)
        logger.error("Google auth failure: \(message, privacy: .public)")
    }

    private enum Keys {
        static let oauthClientID = "googleOAuthClientID"
        /// Removed on launch: secrets must not live in UserDefaults.
        static let legacyOAuthClientSecret = "googleOAuthClientSecret"
    }
}

// MARK: - Parsing

extension GoogleCalendarClient {
    struct EventsPage {
        let meetings: [Meeting]
        let nextPageToken: String?
    }

    nonisolated static func parseEvents(data: Data) throws -> [Meeting] {
        try parsePage(data: data).meetings
    }

    nonisolated static func parsePage(data: Data) throws -> EventsPage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarProviderError.decodeFailed
        }
        let items = json["items"] as? [[String: Any]] ?? []

        let meetings = items.compactMap { item -> Meeting? in
            guard let id = item["id"] as? String,
                  (item["status"] as? String) != "cancelled" else {
                return nil
            }

            let startInfo = item["start"] as? [String: Any]
            let endInfo = item["end"] as? [String: Any]
            guard let startDate = parseGoogleDate(startInfo) else { return nil }
            let endDate = parseGoogleDate(endInfo) ?? startDate

            let summary = (item["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let location = (item["location"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            return Meeting(
                id: "google_\(id)",
                title: summary ?? Meeting.untitled,
                startDate: startDate,
                endDate: endDate,
                location: location,
                meetingLink: extractMeetingLink(from: item),
                isAllDay: startInfo?["date"] != nil,
                source: .googleCalendar
            )
        }
        return EventsPage(meetings: meetings, nextPageToken: json["nextPageToken"] as? String)
    }

    nonisolated static func parseGoogleDate(_ info: [String: Any]?) -> Date? {
        guard let info else { return nil }
        if let dateTime = info["dateTime"] as? String {
            return fractionalISOFormatter.date(from: dateTime) ?? isoFormatter.date(from: dateTime)
        }
        if let date = info["date"] as? String {
            // All-day dates are floating; resolve them in the local time zone.
            return ICalendarParser.parseDateTime(date.replacingOccurrences(of: "-", with: ""))?.date
        }
        return nil
    }

    private nonisolated static func extractMeetingLink(from item: [String: Any]) -> URL? {
        if let entryPoints = (item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] {
            for entry in entryPoints where (entry["entryPointType"] as? String) == "video" {
                if let uri = entry["uri"] as? String, let url = URL(string: uri), url.scheme?.hasPrefix("http") == true {
                    return url
                }
            }
        }
        return MeetingLinkDetector.conferenceURL(from: item["hangoutLink"] as? String)
            ?? MeetingLinkDetector.firstLink(in: item["location"] as? String)
            ?? MeetingLinkDetector.firstLink(in: item["description"] as? String)
    }
}
