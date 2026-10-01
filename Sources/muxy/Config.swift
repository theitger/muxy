import Foundation

enum Config {
    /// Points libghostty at Ghostty's resources (shell integration,
    /// terminfo) — bundled copy first, then an installed Ghostty.app.
    /// Must run before the first surface spawns a shell.
    static func prepareGhosttyResources() {
        guard ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] == nil else { return }
        let candidates = [
            Bundle.main.resourcePath.map { $0 + "/ghostty" },
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
            Paths.home + "/Applications/Ghostty.app/Contents/Resources/ghostty",
        ].compactMap { $0 }
        if let dir = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0 + "/shell-integration")
        }) {
            setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
        }
    }
}
