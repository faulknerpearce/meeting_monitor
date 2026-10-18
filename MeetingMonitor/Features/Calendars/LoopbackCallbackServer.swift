import Darwin
import Foundation

/// Minimal HTTP server on a free loopback port that captures a single OAuth redirect query.
/// Uses POSIX sockets directly to avoid NWListener sandbox issues on macOS 15+.
/// All mutable state is confined to `queue`.
final class LoopbackCallbackServer: @unchecked Sendable {
    /// How long a connected client may take to send its request line.
    static let clientReadTimeout: TimeInterval = 2

    let port: UInt16
    private let listenFd: Int32
    private let queue = DispatchQueue(label: "com.meetingmonitor.oauth.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pendingQuery: [String: String]?
    private var finished = false
    private var listenerClosed = false
    private var acceptSource: DispatchSourceRead?

    private init(listenFd: Int32, port: UInt16) {
        self.listenFd = listenFd
        self.port = port
    }

    deinit {
        if !listenerClosed, acceptSource == nil {
            close(listenFd)
        }
    }

    static func start() throws -> LoopbackCallbackServer {
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
        guard getResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw GoogleOAuthFlow.OAuthError.serverStartFailed
        }

        return LoopbackCallbackServer(listenFd: fd, port: UInt16(bigEndian: actualAddr.sin_port))
    }

    /// Waits for a request carrying `code`, `error` or `state`. Throws `.userCancelled` when the
    /// task is cancelled or `cancel()` is called.
    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    if let pending = self.pendingQuery {
                        cont.resume(returning: pending)
                    } else if self.finished {
                        cont.resume(throwing: GoogleOAuthFlow.OAuthError.userCancelled)
                    } else {
                        self.continuation = cont
                        self.startAccepting()
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Stops listening and fails any pending wait. Safe to call repeatedly and from any thread.
    func cancel() {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.continuation?.resume(throwing: GoogleOAuthFlow.OAuthError.userCancelled)
            self.continuation = nil
            self.closeListener()
        }
    }

    private func startAccepting() {
        guard acceptSource == nil, !listenerClosed else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        acceptSource = source
        source.setEventHandler { [weak self] in
            self?.handleAccept()
        }
        source.setCancelHandler { [listenFd] in
            close(listenFd)
        }
        source.resume()
    }

    /// Runs on `queue`.
    private func closeListener() {
        guard !listenerClosed else { return }
        listenerClosed = true
        if let acceptSource {
            acceptSource.cancel()
            self.acceptSource = nil
        } else {
            close(listenFd)
        }
    }

    /// Runs on `queue`.
    private func handleAccept() {
        var clientAddr = sockaddr()
        var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFd = accept(listenFd, &clientAddr, &addrLen)
        guard clientFd >= 0 else { return }
        defer { close(clientFd) }

        var noSigPipe: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // An idle connection must not block the real redirect queued behind it.
        var readTimeout = timeval(tv_sec: Int(Self.clientReadTimeout), tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(clientFd, &buffer, buffer.count)
        guard count > 0 else { return }

        let request = String(bytes: buffer[0..<count], encoding: .utf8) ?? ""
        let query = Self.parseQuery(fromHTTPRequest: request)

        // Ignore unrelated requests (favicon, probes) and keep listening.
        guard query["code"] != nil || query["error"] != nil || query["state"] != nil else {
            Self.respond(to: clientFd, status: "404 Not Found", html: "")
            return
        }

        Self.respond(
            to: clientFd,
            status: "200 OK",
            html: query["error"] != nil ? Self.failureHTML(query: query) : Self.successHTML
        )
        complete(with: query)
    }

    /// Runs on `queue`.
    private func complete(with query: [String: String]) {
        guard !finished else { return }
        finished = true
        closeListener()
        if let continuation {
            continuation.resume(returning: query)
            self.continuation = nil
        } else {
            pendingQuery = query
        }
    }

    private static func respond(to fd: Int32, status: String, html: String) {
        let response = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + html
        let bytes = Array(response.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }

    static func parseQuery(fromHTTPRequest request: String) -> [String: String] {
        let firstLine = request.components(separatedBy: "\r\n").first ?? request
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return [:] }
        let path = String(parts[1])
        guard let qIndex = path.firstIndex(of: "?") else { return [:] }
        let query = path[path.index(after: qIndex)...]
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.replacingOccurrences(of: "+", with: " ")
            }
            guard parts.count == 2 else { continue }
            result[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }

    private static let pageStyle = """
    <style>
      body { font-family: -apple-system, system-ui, sans-serif; display:flex; align-items:center;
             justify-content:center; height:100vh; margin:0; background:#f5f5f7; color:#1d1d1f; }
      .card { background:white; padding:2rem 2.5rem; border-radius:12px;
              box-shadow:0 4px 24px rgba(0,0,0,.08); text-align:center; max-width:28rem; }
      h1 { font-size:1.25rem; margin:0 0 .5rem; }
      p { color:#6e6e73; margin:0; line-height:1.4; }
    </style>
    """

    private static func page(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Meeting Monitor</title>
        \(pageStyle)</head>
        <body><div class="card">
          <h1>\(title)</h1>
          \(body)
        </div></body></html>
        """
    }

    private static let successHTML = page(
        title: "Connected to Google Calendar",
        body: "<p>You can close this window and return to Meeting Monitor.</p>"
    )

    private static func failureHTML(query: [String: String]) -> String {
        let detail = query["error_description"] ?? query["error"] ?? "Sign-in was not completed."
        let escaped = detail
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return page(
            title: "Google sign-in did not complete",
            body: """
            <p>\(escaped)</p>
              <p style="margin-top:0.75rem">Close this window and try again in Meeting Monitor.</p>
            """
        )
    }
}
