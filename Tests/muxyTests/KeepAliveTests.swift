import XCTest
@testable import muxy

/// The line muxy hands Ghostty for a kept session, run the way Ghostty
/// runs it (/bin/sh -c, in a terminal): the program outlives its tab and
/// the same line finds it again.
final class KeepAliveTests: XCTestCase {
    func testTheTabsLineKeepsTheProgramAcrossTabs() throws {
        guard let muxyd = KeepAlive.binary else { throw XCTSkip("muxyd isn't built (cd Daemon && cargo build --release)") }
        let dir = NSTemporaryDirectory() + "muxy-keep-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ticks = dir + "/ticks"
        let id = UUID()
        let program = "i=0; while [ $i -lt 30 ]; do i=$((i+1)); echo $i > '\(ticks)'; echo tick-$i; sleep 1; done"
        let line = try XCTUnwrap(KeepAlive.wrap(program, id: id, directory: dir))
        XCTAssertTrue(line.contains(KeepAlive.socket.replacingOccurrences(of: " ", with: "\\ ")) || line.contains(KeepAlive.socket))

        func tab() throws -> Process {
            // `script` gives it a terminal, as Ghostty does.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", line]
            process.standardInput = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        func tick() -> Int { Int(((try? String(contentsOfFile: ticks, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        func listed() -> Bool {
            Shell.execute(muxyd, ["list", "--socket", KeepAlive.socket], in: dir).output.contains(id.uuidString)
        }

        let first = try tab()
        let start = Date()
        while tick() < 2, Date().timeIntervalSince(start) < 10 { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThanOrEqual(tick(), 2, "it runs")

        // muxy quits: the terminal and the client in it go.
        first.terminate()
        first.waitUntilExit()
        let before = tick()
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertGreaterThan(tick(), before, "the program went on without its tab")
        XCTAssertTrue(listed())

        // The next launch: the same line attaches, nothing new starts.
        let reached = tick()
        let second = try tab()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(listed())
        XCTAssertGreaterThan(tick(), reached, "the same program counts on: not started again from 1")

        // A closed tab ends it.
        KeepAlive.kill(id)
        let killed = Date()
        while listed(), Date().timeIntervalSince(killed) < 8 { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(listed())
        second.terminate()
    }
}
