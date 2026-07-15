import Foundation

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
            return "Invalid email or password (HTTP 401). Re-enter your Spacemail password in Preferences."
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
}
