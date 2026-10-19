import XCTest
@testable import muxy

/// The numbered answers an agent's permission prompt offers (Inbox,
/// notification buttons). Wording as the agents' current versions draw it.
final class ChoicesTests: XCTestCase {
    func testClaudePermissionPrompt() {
        let screen = """
        ⏺ Bash(npm test)
          ⎿  Running…

         Bash command
           npm test
           Run the test suite

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for npm test commands in ~/repo
           3. No, and tell Claude what to do differently (esc)

        """
        let choices = Choices.parse(screen)
        XCTAssertEqual(choices.map(\.number), [1, 2, 3])
        XCTAssertEqual(choices.first?.label, "Yes")
        XCTAssertEqual(choices.last?.label, "No, and tell Claude what to do differently")
        XCTAssertEqual(choices.map(\.selected), [true, false, false])
    }

    func testKeysMoveTheCursorThenConfirm() {
        let choices = [
            Choice(number: 1, label: "Yes"),
            Choice(number: 2, label: "Always", selected: true),
            Choice(number: 3, label: "No"),
        ]
        XCTAssertEqual(Choices.keys(to: choices[2], in: choices), ["down", "enter"])
        XCTAssertEqual(Choices.keys(to: choices[0], in: choices), ["up", "enter"])
        XCTAssertEqual(Choices.keys(to: choices[1], in: choices), ["enter"])
        XCTAssertEqual(Choices.keys(to: choices[2], in: []), ["down", "down", "enter"])
    }

    func testCodexApproval() {
        let screen = """
        Would you like to run the following command?

          $ cargo test

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `cargo test` (a)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm or esc to cancel
        """
        let choices = Choices.parse(screen)
        XCTAssertEqual(choices.map(\.label), [
            "Yes, proceed",
            "Yes, and don't ask again for commands that start with `cargo test`",
            "No, and tell Codex what to do differently",
        ])
    }

    func testOrdinaryOutputHasNoChoices() {
        let screen = """
        Plan:
        1. Add the endpoint
        then later
        2023. A year, not an option
        $ ls
        """
        XCTAssertEqual(Choices.parse(screen), [])
    }

    func testTheLastMenuOnScreenWins() {
        let screen = """
        1. Old
        2. Menu
        some output
         ❯ 1. Yes
           2. No
        """
        XCTAssertEqual(Choices.parse(screen).map(\.label), ["Yes", "No"])
    }
}
