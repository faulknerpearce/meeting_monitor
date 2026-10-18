import AppKit
import CryptoKit
import Foundation
import os
import Security

/// Desktop OAuth 2.0 authorization-code flow with PKCE and a loopback redirect
/// (`http://127.0.0.1:<port>/`), matching Google's native-app guidance.
enum GoogleOAuthFlow {
    private static let logger = Logger(category: "GoogleOAuth")
    private static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!

    static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let emailScope = "https://www.googleapis.com/auth/userinfo.email"
    static let openIDScope = "openid"

    /// OAuth client registration (Desktop app type); the secret is optional for some clients.
    struct Client: Sendable {
        let id: String
        let secret: String?
    }

    struct Tokens: Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
        let email: String?
    }

    enum OAuthError: LocalizedError, Equatable {
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

    /// Runs the full browser-based sign-in. Fails with `.timedOut` after `timeout` and with
    /// `.userCancelled` when the calling task is cancelled.
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

        let callback = try LoopbackCallbackServer.start()
        defer { callback.cancel() }
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
            throw OAuthError.serverStartFailed
        }

        logger.info("Opening Google OAuth in browser (loopback port \(callback.port, privacy: .public))")
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }

        let query = try await waitForRedirect(from: callback, timeout: timeout)

        guard query["state"] == state else {
            throw OAuthError.authorizationFailed("Invalid state parameter (possible CSRF).")
        }
        if let err = query["error"] {
            throw OAuthError.authorizationFailed(query["error_description"] ?? err)
        }
        guard let code = query["code"], !code.isEmpty else {
            throw OAuthError.missingCode
        }

        return try await exchangeCode(
            code: code,
            redirectURI: redirectURI,
            client: Client(id: trimmedID, secret: clientSecret),
            codeVerifier: verifier,
            session: session
        )
    }

    /// Races the loopback redirect against `timeout`. The waiter is cancellation-aware, so the
    /// losing child finishes promptly and the group can return.
    static func waitForRedirect(
        from callback: LoopbackCallbackServer,
        timeout: TimeInterval
    ) async throws -> [String: String] {
        do {
            return try await withThrowingTaskGroup(of: [String: String].self) { group in
                group.addTask {
                    try await callback.waitForCallback()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw OAuthError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw OAuthError.userCancelled }
                return result
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw OAuthError.userCancelled }
            throw error
        }
    }

    // MARK: - Token exchange

    private static func exchangeCode(
        code: String,
        redirectURI: String,
        client: Client,
        codeVerifier: String,
        session: URLSession
    ) async throws -> Tokens {
        var fields: [String: String] = [
            "code": code,
            "client_id": client.id,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        if let secret = client.secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            fields["client_secret"] = secret
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody(fields)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            logger.error("Token exchange failed with HTTP \(status, privacy: .public)")
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
        if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
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

    /// `application/x-www-form-urlencoded` body; only RFC 3986 unreserved characters pass unescaped.
    static func formURLEncodedBody(_ fields: [String: String]) -> Data {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
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
