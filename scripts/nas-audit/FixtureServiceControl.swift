import Foundation
import XCTest

/// Only controls the generated loopback fixture process owned by service_control.py.
@MainActor
struct FixtureServiceControl {
    private struct Session: Decodable { let nonce: String }
    struct Reply: Decodable {
        let id: String
        let nonce: String
        let running: Bool
        let generation: Int
    }
    private let directory: URL
    private let nonce: String

    init() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
        directory = root.appending(path: ".service-control")
        guard FileManager.default.fileExists(atPath: directory.appending(path: "session.json").path) else {
            throw XCTSkip("Start service_control.py for real SMB service-loss tests")
        }
        nonce = try JSONDecoder().decode(Session.self, from: Data(contentsOf: directory.appending(path: "session.json"))).nonce
    }

    @discardableResult
    func setRunning(_ running: Bool) async throws -> Reply {
        let id = UUID().uuidString
        let request = ["id": id, "nonce": nonce, "action": running ? "start" : "stop"]
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appending(path: "request.json"), options: .atomic)
        for _ in 0..<1000 {
            if let data = try? Data(contentsOf: directory.appending(path: "response.json")),
               let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.id == id, reply.nonce == nonce {
                XCTAssertEqual(reply.running, running)
                return reply
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Owned fixture service did not acknowledge \(request["action"] ?? "")")
        throw CocoaError(.fileReadUnknown)
    }
}
