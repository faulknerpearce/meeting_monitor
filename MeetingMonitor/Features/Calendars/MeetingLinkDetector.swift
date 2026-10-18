import Foundation

/// Finds video-conference join links in free-form event text.
enum MeetingLinkDetector {
    private static let conferenceHosts = [
        "meet.google.com",
        "zoom.us",
        "zoomgov.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
    ]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// True for http(s) URLs whose host is (a subdomain of) a known conferencing host.
    static func isConferenceURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return conferenceHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Parses a single URL string, accepting it only if it is a conferencing link.
    static func conferenceURL(from string: String?) -> URL? {
        guard let string, let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              isConferenceURL(url) else {
            return nil
        }
        return url
    }

    /// First conferencing link found anywhere in `text`.
    static func firstLink(in text: String?) -> URL? {
        guard let text, !text.isEmpty, let detector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .lazy
            .compactMap(\.url)
            .first(where: isConferenceURL)
    }
}
