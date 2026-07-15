import Foundation
import CryptoKit
import AppKit
import os
import Darwin
import Security

/// Desktop OAuth 2.0 authorization-code flow with PKCE and a loopback redirect
/// (`http://127.0.0.1:<port>/`), matching Google's native-app guidance.
enum GoogleOAuthFlow {
    private static let logger = Logger(subsystem: "com.meetingmonitor.app", category: "GoogleOAuth")
    private static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!

    static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let emailScope = "https://www.googleapis.com/auth/userinfo.email"
    static let openIDScope = "openid"

    struct Tokens: Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
        let email: String?
    }

    enum OAuthError: LocalizedError {
        case missingClientID
        case serverStartFailed
        case userCancelled
        case authorizationFailed(String)
        case missingCode
        case tokenExchangeFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Enter a Google OAuth Client ID (Desktop app type)."
            case .serverStartFailed:
                return "Could not start the local sign-in callback server."
            case .userCancelled:
                return "Sign-in was cancelled."
            case .authorizationFailed(let reason):
                return "Google authorization failed: \(reason)"
            case .missingCode:
                return "No authorization code returned from Google."
            case .tokenExchangeFailed(let reason):
                return "Token exchange failed: \(reason)"
            case .timedOut:
                return "Sign-in timed out. Try again."
            }
        }
    }

    /// Runs the full browser-based sign-in. Cancels if `timeout` elapses.
    static func signIn(
        clientID: String,
        clientSecret: String?,
        session: URLSession,
        timeout: TimeInterval = 300
    ) async throws -> Tokens {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw OAuthError.missingClientID }

        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomURLSafe(byteCount: 24)

        let callback = try await LoopbackCallbackServer.start()
        let redirectURI = "http://127.0.0.1:\(callback.port)/"

        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: [openIDScope, emailScope, calendarScope].joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        guard let url = components.url else {
            await callback.cancel()
            throw OAuthError.serverStartFailed
        }

        logger.info("Opening Google OAuth in browser (loopback port \(callback.port, privacy: .public))")
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }

        let query: [String: String]
        do {
            query = try await withThrowingTaskGroup(of: [String: String].self) { group in
                group.addTask {
                    try await callback.waitForCallback()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw OAuthError.timedOut
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            await callback.cancel()
            throw error
        }

        if let err = query["error"] {
            throw OAuthError.authorizationFailed(query["error_description"] ?? err)
        }
        guard let returnedState = query["state"], returnedState == state else {
            throw OAuthError.authorizationFailed("Invalid state parameter (possible CSRF).")
        }
        guard let code = query["code"], !code.isEmpty else {
            throw OAuthError.missingCode
        }

        return try await exchangeCode(
            code: code,
            redirectURI: redirectURI,
            clientID: trimmedID,
            clientSecret: clientSecret,
            codeVerifier: verifier,
            session: session
        )
    }

    // MARK: - Token exchange

    private static func exchangeCode(
        code: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String?,
        codeVerifier: String,
        session: URLSession
    ) async throws -> Tokens {
        var fields: [String: String] = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        if let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            fields["client_secret"] = secret
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody(fields)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            logger.error("Token exchange failed: \(body, privacy: .public)")
            throw OAuthError.tokenExchangeFailed(summarizeTokenError(body))
        }

        guard let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw OAuthError.tokenExchangeFailed(
                "No refresh token returned. At myaccount.google.com/permissions, remove Meeting Monitor access, then sign in again."
            )
        }

        let expiresIn = json["expires_in"] as? Double ?? 3600
        let email = try? await fetchEmail(accessToken: accessToken, session: session)

        return Tokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            email: email
        )
    }

    private static func summarizeTokenError(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String {
            let desc = json["error_description"] as? String
            return desc.map { "\($0) (\(error))" } ?? error
        }
        return String(body.prefix(200))
    }

    private static func fetchEmail(accessToken: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    static func formURLEncodedBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
        let pairs = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return pairs.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

// MARK: - PKCE

private enum PKCE {
    static func makeVerifier() -> String {
        // RFC 7636: 43–128 characters from the unreserved set.
        randomURLSafe(byteCount: 32)
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback server (POSIX sockets)

/// Minimal HTTP server on a free port that captures a single OAuth redirect query.
/// Uses POSIX sockets directly to avoid NWListener sandbox issues on macOS 15+.
final class LoopbackCallbackServer: @unchecked Sendable {
    let port: UInt16
    private let listenFd: Int32
    private let queue = DispatchQueue(label: "com.meetingmonitor.oauth.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pendingQuery: [String: String]?
    private var finished = false
    private var acceptSource: DispatchSourceRead?

    private init(listenFd: Int32, port: UInt16) {
        self.listenFd = listenFd
        self.port = port
    }

    static func start() async throws -> LoopbackCallbackServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw GoogleOAuthFlow.OAuthError.serverStartFailed
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw GoogleOAuthFlow.OAuthError.serverStartFailed
        }

        var actualAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &actualAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addrLen)
            }
        }
        guard getResult == 0 else {
            close(fd)
            throw GoogleOAuthFlow.OAuthError.serverStartFailed
        }
        let port = UInt16(bigEndian: actualAddr.sin_port)

        guard listen(fd, 1) == 0 else {
            close(fd)
            throw GoogleOAuthFlow.OAuthError.serverStartFailed
        }

        return LoopbackCallbackServer(listenFd: fd, port: port)
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: GoogleOAuthFlow.OAuthError.userCancelled)
                    return
                }
                if let pending = self.pendingQuery {
                    cont.resume(returning: pending)
                    return
                }
                self.continuation = cont
                self.startAccepting()
            }
        }
    }

    private func startAccepting() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        self.acceptSource = source
        source.setEventHandler { [weak self] in
            self?.handleAccept()
        }
        source.setCancelHandler { [listenFd] in
            close(listenFd)
        }
        source.resume()
    }

    private func handleAccept() {
        var clientAddr = sockaddr()
        var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFd = accept(listenFd, &clientAddr, &addrLen)
        guard clientFd >= 0 else { return }

        // Read HTTP request
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(clientFd, &buffer, buffer.count)
        guard n > 0 else {
            close(clientFd)
            return
        }

        let request = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
        let query = Self.parseQuery(fromHTTPRequest: request)

        let html = query["error"] != nil ? Self.failureHTML(query: query) : Self.successHTML
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        _ = response.withCString { cstr in
            write(clientFd, cstr, strlen(cstr))
        }
        close(clientFd)

        finish(with: .success(query))
    }

    func cancel() async {
        queue.sync {
            guard !finished else { return }
            finished = true
            continuation?.resume(throwing: GoogleOAuthFlow.OAuthError.userCancelled)
            continuation = nil
            acceptSource?.cancel()
        }
    }

    private func finish(with result: Result<[String: String], Error>) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.acceptSource?.cancel()
            self.acceptSource = nil
            switch result {
            case .success(let query):
                if let cont = self.continuation {
                    cont.resume(returning: query)
                } else {
                    self.pendingQuery = query
                }
            case .failure(let error):
                self.continuation?.resume(throwing: error)
            }
            self.continuation = nil
        }
    }

    private static func parseQuery(fromHTTPRequest request: String) -> [String: String] {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? request
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return [:] }
        let path = String(parts[1])
        guard let qIndex = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: qIndex)...])
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].removingPercentEncoding ?? kv[0]
            let value = kv[1].removingPercentEncoding ?? kv[1]
            result[key] = value
        }
        return result
    }

    private static let successHTML = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>Meeting Monitor</title>
    <style>
      body { font-family: -apple-system, system-ui, sans-serif; display:flex; align-items:center; justify-content:center; height:100vh; margin:0; background:#f5f5f7; color:#1d1d1f; }
      .card { background:white; padding:2rem 2.5rem; border-radius:12px; box-shadow:0 4px 24px rgba(0,0,0,.08); text-align:center; max-width:28rem; }
      h1 { font-size:1.25rem; margin:0 0 .5rem; }
      p { color:#6e6e73; margin:0; line-height:1.4; }
    </style></head>
    <body><div class="card">
      <h1>Connected to Google Calendar</h1>
      <p>You can close this window and return to Meeting Monitor.</p>
    </div></body></html>
    """

    private static func failureHTML(query: [String: String]) -> String {
        let detail = query["error_description"] ?? query["error"] ?? "Sign-in was not completed."
        let escaped = detail
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Meeting Monitor</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif; display:flex; align-items:center; justify-content:center; height:100vh; margin:0; background:#f5f5f7; color:#1d1d1f; }
          .card { background:white; padding:2rem 2.5rem; border-radius:12px; box-shadow:0 4px 24px rgba(0,0,0,.08); text-align:center; max-width:28rem; }
          h1 { font-size:1.25rem; margin:0 0 .5rem; }
          p { color:#6e6e73; margin:0; line-height:1.4; }
        </style></head>
        <body><div class="card">
          <h1>Google sign-in did not complete</h1>
          <p>\(escaped)</p>
          <p style="margin-top:0.75rem">Close this window and try again in Meeting Monitor.</p>
        </div></body></html>
        """
    }
}
