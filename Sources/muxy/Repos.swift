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

    /// The folders your repositories live in, chosen on first launch;
    /// home until then.
    static let foldersKey = "repoFolders"

    static var folders: [String] {
        get {
            let saved = UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
            return saved.isEmpty ? [Paths.home] : saved
        }
        set { UserDefaults.standard.set(newValue, forKey: foldersKey) }
    }

    /// Main checkouts one or two levels under each folder, with the time
    /// git last touched them (HEAD's log moves on commit and checkout).
    static func scan(in folders: [String] = folders) -> [(String, Date)] {
        let fm = FileManager.default
        let skip: Set = ["Library", "Applications", "Pictures", "Music", "Movies", "Public", "Downloads"]
        var found: [(String, Date)] = []
        var seen = Set<String>()
        func check(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            let git = path + "/.git"
            guard fm.fileExists(atPath: git, isDirectory: &isDir), isDir.boolValue else { return false }
            let stamps = [git + "/logs/HEAD", git + "/index", git + "/HEAD"].compactMap {
                (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
            }
            if seen.insert(path).inserted { found.append((path, stamps.max() ?? .distantPast)) }
            return true
        }
        for folder in folders {
            if check(folder) { continue }
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where !name.hasPrefix(".") && !skip.contains(name) {
                let path = folder + "/" + name
                if check(path) { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                for child in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where !child.hasPrefix(".") {
                    _ = check(path + "/" + child)
                }
            }
        }
        return found
    }
}
