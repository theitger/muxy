import XCTest
@testable import muxy

/// Which servers belong to which session (Open app).
final class PortsTests: XCTestCase {
    func testParsesLsofFieldOutput() {
        let output = "p632\nf17\nn*:50397\nf20\nn[::1]:3000\np81551\nf3\nn127.0.0.1:49552\n"
        let parsed = Ports.parseListening(output)
        XCTAssertEqual(parsed[50397], [632])
        XCTAssertEqual(parsed[3000], [632])
        XCTAssertEqual(parsed[49552], [81551])
    }

    func testReadsTheSessionFromAProcessEnvironment() {
        let id = "abcdef12-3456-7890-abcd-ef1234567890"
        let output = """
          123 node server.js PATH=/usr/bin MUXY_SESSION=\(id) HOME=/Users/x
          456 python3 -m http.server NOT_MUXY_SESSION=\(id)
        """
        let parsed = Ports.parseSessionIDs(output)
        XCTAssertEqual(parsed[123], id.uppercased())
        XCTAssertNil(parsed[456], "only the variable itself counts")
    }

    func testFoldersInsideACheckout() {
        XCTAssertTrue(Ports.inside("/repo/wt/web", "/repo/wt"))
        XCTAssertTrue(Ports.inside("/repo/wt", "/repo/wt"))
        XCTAssertFalse(Ports.inside("/repo/wt-other", "/repo/wt"))
        XCTAssertTrue(Ports.inside("/private/tmp/x/app", "/tmp/x"))
    }

    func testOnlyBrowsableHTTPResponsesCountAsWebPreviews() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:3000/"))
        let html = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"]))
        let smtpGreeting = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Date": "today"]))
        let api = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
        XCTAssertTrue(Probe.isBrowsable(html))
        XCTAssertFalse(Probe.isBrowsable(smtpGreeting))
        XCTAssertFalse(Probe.isBrowsable(api))
    }

    /// A real server started with a session's id is found, and found to
    /// speak HTTP; another session gets nothing.
    func testFindsARealServerOfASession() throws {
        let id = UUID().uuidString
        let folder = try temporaryFolder()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "0", "--bind", "127.0.0.1"]
        server.currentDirectoryURL = folder
        server.environment = ["MUXY_SESSION": id, "PATH": "/usr/bin:/bin"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }

        var found: [String: [AppPort]] = [:]
        for _ in 0 ..< 40 where found[id] == nil {
            Thread.sleep(forTimeInterval: 0.25)
            found = Ports.scan([
                Ports.Session(id: id, checkout: nil, leased: []),
                Ports.Session(id: UUID().uuidString, checkout: nil, leased: []),
            ])
        }
        let ports = try XCTUnwrap(found[id], "the server should belong to its session")
        XCTAssertEqual(ports.count, 1)
        XCTAssertTrue(ports[0].isWeb)
        XCTAssertEqual(found.count, 1, "the other session runs nothing")
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muxy-ports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
