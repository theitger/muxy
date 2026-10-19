import Foundation

/// A server a session runs: what "Open app" opens.
struct AppPort: Equatable, Hashable {
    var port: Int
    /// It answered HTTP: a web app, not a database.
    var isWeb: Bool

    var url: URL { URL(string: "http://localhost:\(port)")! }
}

/// Which listening ports belong to which session. A port belongs to a
/// session when the process listening on it
/// - carries the session's MUXY_SESSION (anything started in its terminal
///   does, even after it detached from the shell),
/// - or works inside the session's checkout,
/// - or is one of the ports muxy leased for its worktree (.wtconfig), which
///   catches servers in containers that sit outside both.
/// One `lsof` for the whole machine per look, so it stays cheap with many
/// sessions. Blocking; call off the main thread.
enum Ports {
    struct Session: Sendable {
        var id: String
        var checkout: String?
        var leased: [Int]
    }

    static func scan(_ sessions: [Session]) -> [String: [AppPort]] {
        guard !sessions.isEmpty else { return [:] }
        let listening = listeningPorts()
        guard !listening.isEmpty else { return [:] }
        let pids = Set(listening.values.flatMap { $0 })
        let owners = sessionIDs(of: pids)
        let folders = workingDirectories(of: pids.filter { owners[$0] == nil })
        var found: [String: Set<Int>] = [:]
        for (port, holders) in listening {
            for pid in holders {
                if let owner = owners[pid], sessions.contains(where: { $0.id == owner }) {
                    found[owner, default: []].insert(port)
                } else if let folder = folders[pid],
                          let session = sessions.first(where: { $0.checkout.map { inside(folder, $0) } == true }) {
                    found[session.id, default: []].insert(port)
                }
            }
            for session in sessions where session.leased.contains(port) {
                found[session.id, default: []].insert(port)
            }
        }
        return found.mapValues { ports in
            ports.map { AppPort(port: $0, isWeb: Probe.isWeb($0)) }
                // Web first, then lowest: the dev server before its helpers.
                .sorted { ($0.isWeb ? 0 : 1, $0.port) < ($1.isWeb ? 0 : 1, $1.port) }
        }
    }

    /// Port → pids listening on it (TCP, any address).
    static func listeningPorts() -> [Int: Set<Int32>] {
        guard let output = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"], in: "/") else {
            return [:]
        }
        return parseListening(output)
    }

    /// lsof's field output: "p<pid>" starts a process, "n<address>:<port>"
    /// lines follow.
    static func parseListening(_ output: String) -> [Int: Set<Int32>] {
        var result: [Int: Set<Int32>] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid,
                      let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) {
                result[port, default: []].insert(pid)
            }
        }
        return result
    }

    /// The MUXY_SESSION each process was started with, where it has one.
    static func sessionIDs(of pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let output = Shell.run("/bin/ps", ["-E", "-ww", "-o", "pid=,command=", "-p", list], in: "/") else {
            return [:]
        }
        return parseSessionIDs(output)
    }

    static func parseSessionIDs(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let pid = Int32(trimmed.prefix { $0.isNumber }),
                  let range = trimmed.range(of: #"(^|\s)MUXY_SESSION=[0-9A-Fa-f-]{36}"#, options: .regularExpression)
            else { continue }
            result[pid] = String(trimmed[range].suffix(36)).uppercased()
        }
        return result
    }

    private static func workingDirectories(of pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty,
              let output = Shell.run(
                  "/usr/sbin/lsof", ["-a", "-d", "cwd", "-F", "pn", "-p", pids.map(String.init).joined(separator: ",")], in: "/"
              )
        else { return [:] }
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("n"), let pid { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    static func inside(_ folder: String, _ checkout: String) -> Bool {
        let base = checkout.hasSuffix("/") ? checkout : checkout + "/"
        // /private/tmp and /tmp are the same place.
        let normalized = folder.hasPrefix("/private/") ? String(folder.dropFirst("/private".count)) : folder
        return [folder, normalized].contains { $0 == checkout || $0.hasPrefix(base) }
    }

    /// The ports muxy leased for a worktree: their variables' values in the
    /// env file and in .wt.env.
    static func leased(in checkout: String, root: String) -> [Int] {
        guard let recipe = WorktreeRecipe.load(root: root), !recipe.ports.isEmpty else { return [] }
        let names = Set(recipe.ports.map(\.name))
        var ports: [Int] = []
        for file in [recipe.env, WorktreeRecipe.portsFile].compactMap({ $0 }) {
            guard let text = try? String(contentsOfFile: (checkout as NSString).appendingPathComponent(file), encoding: .utf8)
            else { continue }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, names.contains(parts[0].replacingOccurrences(of: "export ", with: "")),
                      let port = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
                else { continue }
                ports.append(port)
            }
        }
        return ports
    }
}

/// Does a port speak HTTP? Remembered per port for a while: a server
/// doesn't change what it is between two looks.
enum Probe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [Int: (web: Bool, at: Date)] = [:]

    static func isWeb(_ port: Int) -> Bool {
        if let hit = lock.withLock({ known[port] }), Date().timeIntervalSince(hit.at) < 60 { return hit.web }
        let web = ask(port)
        lock.withLock { known[port] = (web, Date()) }
        return web
    }

    private static func ask(_ port: Int) -> Bool {
        var request = URLRequest(url: URL(string: "http://localhost:\(port)/")!, timeoutInterval: 1.5)
        request.httpMethod = "HEAD"
        let done = DispatchSemaphore(value: 0)
        var web = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            web = response is HTTPURLResponse
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 2) == .timedOut { task.cancel() }
        return web
    }
}
