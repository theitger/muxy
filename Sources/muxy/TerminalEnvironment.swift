import Foundation

/// Muxy launches independent interactive terminals, even when started by an agent.
enum TerminalEnvironment {
    static func inheritedKeysToRemove(_ environment: [String: String]) -> [String] {
        environment.keys.filter {
            $0 == "CLAUDECODE" || $0 == "CLAUDE_PID" || $0.hasPrefix("CLAUDE_CODE_")
                || ["NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE"].contains($0)
        }
    }
}
