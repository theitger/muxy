import Foundation

/// The repositories a new session can start in: main checkouts only (a
/// worktree's `.git` is a file), the ones with open sessions first, then
/// the rest by when they were last worked in.
enum Repos {
    struct Repo: Identifiable, Hashable {
        let path: String
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Blocking (a shallow scan of the home folder); call off the main thread.
    static func load(open: [String]) -> [Repo] {
        var seen = Set<String>()
        var result: [Repo] = []
        for path in open where seen.insert(path).inserted {
            result.append(Repo(path: path))
        }
        let scanned = scan().sorted { $0.1 > $1.1 }
        for (path, _) in scanned where seen.insert(path).inserted {
            result.append(Repo(path: path))
        }
        return result
    }

    /// Main checkouts one or two levels under home, with the time git last
    /// touched them (HEAD's log moves on commit and checkout).
    private static func scan() -> [(String, Date)] {
        let fm = FileManager.default
        let skip: Set = ["Library", "Applications", "Pictures", "Music", "Movies", "Public", "Downloads"]
        var found: [(String, Date)] = []
        func check(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            let git = path + "/.git"
            guard fm.fileExists(atPath: git, isDirectory: &isDir), isDir.boolValue else { return false }
            let stamps = [git + "/logs/HEAD", git + "/index", git + "/HEAD"].compactMap {
                (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
            }
            found.append((path, stamps.max() ?? .distantPast))
            return true
        }
        let home = Paths.home
        for name in (try? fm.contentsOfDirectory(atPath: home)) ?? [] where !name.hasPrefix(".") && !skip.contains(name) {
            let path = home + "/" + name
            if check(path) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            for child in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where !child.hasPrefix(".") {
                _ = check(path + "/" + child)
            }
        }
        return found
    }
}
