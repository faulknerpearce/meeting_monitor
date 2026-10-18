import Darwin
@testable import MeetingMonitor
import XCTest

final class GoogleOAuthFlowTests: XCTestCase {
    func testFormEncodingEscapesReservedCharacters() {
        let body = GoogleOAuthFlow.formURLEncodedBody(["refresh_token": "1//0a+b=c&d e", "a": "x"])
        XCTAssertEqual(String(bytes: body, encoding: .utf8), "a=x&refresh_token=1%2F%2F0a%2Bb%3Dc%26d%20e")
    }

    func testParseQueryDecodesPlusAndPercent() {
        let query = LoopbackCallbackServer.parseQuery(
            fromHTTPRequest: "GET /?error=access_denied&error_description=User+said%20no HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        XCTAssertEqual(query["error"], "access_denied")
        XCTAssertEqual(query["error_description"], "User said no")
    }

    // MARK: - Loopback server

    /// Opens a TCP connection to the loopback server and optionally sends a request.
    private func connect(to port: UInt16, sending request: String?) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if let request {
            _ = request.withCString { write(fd, $0, strlen($0)) }
        }
        return fd
    }

    func testStrayRequestDoesNotCompleteSignIn() async throws {
        let server = try LoopbackCallbackServer.start()
        defer { server.cancel() }
        let waiter = Task { try await server.waitForCallback() }

        close(connect(to: server.port, sending: "GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n"))
        close(connect(to: server.port, sending: "GET /?code=abc&state=xyz HTTP/1.1\r\nHost: x\r\n\r\n"))

        let query = try await waiter.value
        XCTAssertEqual(query["code"], "abc")
        XCTAssertEqual(query["state"], "xyz")
    }

    func testIdleConnectionDoesNotBlockRedirect() async throws {
        let server = try LoopbackCallbackServer.start()
        defer { server.cancel() }
        let waiter = Task { try await server.waitForCallback() }

        let idle = connect(to: server.port, sending: nil)
        defer { close(idle) }
        close(connect(to: server.port, sending: "GET /?code=late&state=s HTTP/1.1\r\nHost: x\r\n\r\n"))

        let started = Date()
        let query = try await waiter.value
        XCTAssertEqual(query["code"], "late")
        XCTAssertLessThan(Date().timeIntervalSince(started), LoopbackCallbackServer.clientReadTimeout + 3)
    }

    func testCancellingTheWaitingTaskThrowsPromptly() async throws {
        let server = try LoopbackCallbackServer.start()
        let waiter = Task { try await server.waitForCallback() }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? GoogleOAuthFlow.OAuthError, .userCancelled)
        }
    }

    func testWaitForRedirectTimesOut() async throws {
        let server = try LoopbackCallbackServer.start()
        defer { server.cancel() }
        let started = Date()
        do {
            _ = try await GoogleOAuthFlow.waitForRedirect(from: server, timeout: 0.3)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? GoogleOAuthFlow.OAuthError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
