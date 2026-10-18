import Foundation

/// A calendar backend the poller can refresh.
@MainActor
protocol MeetingProvider: AnyObject, Sendable {
    var source: MeetingSource { get }
    var isConfigured: Bool { get }
    func fetchMeetings(from startDate: Date, to endDate: Date) async throws -> [Meeting]
}

enum CalendarProviderError: LocalizedError, Equatable {
    case notConfigured
    case invalidCredentials
    case authFailed(String)
    case httpStatus(Int)
    case decodeFailed
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Not configured. Add credentials in Preferences."
        case .invalidCredentials:
            return "The server rejected the email or password. Re-enter your Spacemail password in Preferences."
        case .authFailed(let reason):
            return "Authentication failed: \(reason)"
        case .httpStatus(let code):
            return "Server returned HTTP \(code)."
        case .decodeFailed:
            return "Could not parse calendar response."
        case .networkError(let msg):
            return msg
        }
    }

    /// Maps a failed HTTP status to an error; 401 and 403 mean the credentials were refused.
    static func forStatus(_ status: Int) -> CalendarProviderError {
        status == 401 || status == 403 ? .invalidCredentials : .httpStatus(status)
    }
}
