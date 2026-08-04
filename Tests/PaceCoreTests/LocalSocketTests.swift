import Foundation
import XCTest
@testable import PaceCore

final class LocalSocketTests: XCTestCase {
    func testRoundTripOverPrivateLocalSocket() async throws {
        let path = "/private/tmp/pace-\(UUID().uuidString.prefix(8)).sock"
        let server = LocalSocketServer(path: path) { request in
            IPCResponse(id: request.id, success: true, message: "connected")
        }
        try server.start()
        defer { server.stop() }

        let request = IPCRequest(command: .status)
        let response = try LocalSocketClient.send(request, path: path)

        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.message, "connected")
        XCTAssertTrue(response.success)
    }

    func testSnippetPayloadRoundTripsOverLocalSocket() async throws {
        let path = "/private/tmp/pace-\(UUID().uuidString.prefix(8)).sock"
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let snippet = Snippet(
            name: "Email",
            template: "person@example.com {cursor}",
            keyword: ";em",
            tags: ["personal"],
            isPinned: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let server = LocalSocketServer(path: path) { request in
            XCTAssertEqual(request.command, .snippetList)
            return IPCResponse(
                id: request.id,
                success: true,
                snippets: [snippet],
                snippet: snippet,
                renderedSnippet: RenderedSnippet(
                    text: "person@example.com ",
                    cursorOffset: 19
                )
            )
        }
        try server.start()
        defer { server.stop() }

        let request = IPCRequest(command: .snippetList)
        let response = try LocalSocketClient.send(request, path: path)

        XCTAssertEqual(response.snippets, [snippet])
        XCTAssertEqual(response.snippet, snippet)
        XCTAssertEqual(
            response.renderedSnippet,
            RenderedSnippet(text: "person@example.com ", cursorOffset: 19)
        )
    }
}
