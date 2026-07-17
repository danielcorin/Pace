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
}
