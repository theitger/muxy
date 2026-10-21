import XCTest
@testable import muxy

final class TerminalEnvironmentTests: XCTestCase {
    func testNewTerminalDoesNotInheritAgentCaptureColorPolicyOrNestedSessionMarkers() {
        let environment = ["NO_COLOR": "1", "FORCE_COLOR": "0", "CLICOLOR": "0", "CLICOLOR_FORCE": "1",
                           "CLAUDECODE": "1", "CLAUDE_PID": "123", "CLAUDE_CODE_ENTRYPOINT": "cli",
                           "PATH": "/usr/bin", "HOME": "/Users/test", "COLORTERM": "truecolor",
                           "MUXY_STATE_DIR": "/tmp/muxy-dev", "MY_SETTING": "yes"]
        let removed = Set(TerminalEnvironment.inheritedKeysToRemove(environment))
        XCTAssertEqual(removed, ["NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE",
                                 "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertEqual(environment.filter { !removed.contains($0.key) },
                       ["PATH": "/usr/bin", "HOME": "/Users/test", "COLORTERM": "truecolor",
                        "MUXY_STATE_DIR": "/tmp/muxy-dev", "MY_SETTING": "yes"])
    }
}
