import Foundation
import XCTest
@testable import muxy

/// Real git in a throwaway folder: a main checkout with one commit, and
/// optionally a local bare "origin". No network, no user git config.
final class TempRepo {
    let base: String
    let root: String
    private(set) var origin: String?

    init(name: String = "repo") throws {
        Self.isolateGit()
        // Resolved: git reports real paths (/private/var/…), muxy compares them.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muxy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        // (URL.resolvingSymlinksInPath keeps /var, so realpath.)
        base = try XCTUnwrap(realpath(temp.path, nil).map { String(cString: $0) })
        root = (base as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git("init", "--quiet", "--initial-branch=main")
        try write("README.md", "hello\n")
        try commit("Initial")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: base)
    }

    /// A bare origin with main pushed, and origin/HEAD set as clone would.
    func addOrigin() throws {
        let path = (base as NSString).appendingPathComponent("origin.git")
        try Self.run(["init", "--quiet", "--bare", "--initial-branch=main", path], in: base)
        try git("remote", "add", "origin", path)
        try git("push", "--quiet", "origin", "main")
        try git("remote", "set-head", "origin", "main")
        origin = path
    }

    func path(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    func write(_ relative: String, _ text: String, in directory: String? = nil) throws {
        let file = ((directory ?? root) as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    func read(_ relative: String, in directory: String? = nil) -> String? {
        try? String(contentsOfFile: ((directory ?? root) as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    func commit(_ message: String, in directory: String? = nil) throws {
        try git("add", "-A", in: directory)
        try git("commit", "--quiet", "--allow-empty", "-m", message, in: directory)
    }

    @discardableResult
    func git(_ args: String..., in directory: String? = nil) throws -> String {
        try Self.run(args, in: directory ?? root)
    }

    /// A worktree in `<root>/.worktrees/<name>`, as muxy makes them.
    func addWorktree(_ name: String, branch: String? = nil, detach: Bool = false) throws -> String {
        let path = Launcher.freeFolder(in: root, named: name)
        var args = ["worktree", "add", "--quiet"]
        if detach { args.append("--detach") }
        if let branch { args += ["-b", branch] }
        args += [path, "HEAD"]
        try Self.run(args, in: root)
        return path
    }

    func head(in directory: String? = nil) throws -> String {
        try git("rev-parse", "HEAD", in: directory)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    @discardableResult
    static func run(_ args: [String], in directory: String) throws -> String {
        let result = Shell.execute("/usr/bin/git", args, in: directory)
        guard result.status == 0 else {
            throw Failure(description: "git \(args.joined(separator: " ")) failed: \(result.error)")
        }
        return result.output
    }

    /// Shell.execute and Shell.run pass the environment on: keep the user's
    /// git config, hooks and signing out of it.
    static func isolateGit() {
        let empty = (NSTemporaryDirectory() as NSString).appendingPathComponent("muxy-tests-gitconfig")
        FileManager.default.createFile(atPath: empty, contents: Data())
        setenv("GIT_CONFIG_GLOBAL", empty, 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        for key in ["GIT_AUTHOR", "GIT_COMMITTER"] {
            setenv("\(key)_NAME", "Muxy Tests", 1)
            setenv("\(key)_EMAIL", "tests@example.invalid", 1)
        }
    }
}

/// A TCP socket listening on `port`, closed by `close()`.
final class Listener {
    let fd: Int32

    init?(port: Int, address: in_addr_t = INADDR_LOOPBACK) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = address.bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            return nil
        }
    }

    /// `[::]:port`, dual stack, the way Node and many dev servers listen.
    init?(ipv6Port port: Int) {
        fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port)).bigEndian
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
        guard bound, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            return nil
        }
    }

    func close() {
        Darwin.close(fd)
    }
}

/// A run of `count` consecutive ports nothing listens on right now, so
/// leasing tests don't collide with whatever runs on this Mac.
func freePortRange(_ count: Int) -> Int {
    var start = 41000 + Int.random(in: 0 ..< 2000) * 4
    while true {
        let listeners = (0 ..< count).map { Listener(port: start + $0, address: INADDR_ANY) }
        listeners.forEach { $0?.close() }
        if listeners.allSatisfy({ $0 != nil }) { return start }
        start += count
    }
}
