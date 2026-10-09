import Foundation

// Checks HookInstaller against scratch homes only (run.sh makes them).
// Usage: hook-installer-test <scratch dir> [<file to round-trip read-only> …]

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok {
        failures += 1
        print("     (main.swift:\(line))")
    }
}

let fm = FileManager.default
let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
try? fm.removeItem(at: scratch)
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
func stamp(_ url: URL) -> Date? {
    (try? fm.attributesOfItem(atPath: HookInstaller.resolved(url).path))?[.modificationDate] as? Date
}
func isLink(_ url: URL) -> Bool {
    (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
}
func object(_ url: URL) -> NSDictionary {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? NSDictionary ?? [:]
}
func claudeTarget(_ home: URL) -> HookInstaller.Target {
    .init(agent: "claude", file: home.appendingPathComponent(".claude/settings.json"), hooks: HookInstaller.claudeHooks)
}
func codexTarget(_ codexHome: URL) -> HookInstaller.Target {
    .init(agent: "codex", file: codexHome.appendingPathComponent("hooks.json"), hooks: HookInstaller.codexHooks)
}

// 1. Nothing there yet.
do {
    let home = scratch.appendingPathComponent("fresh")
    let target = claudeTarget(home)
    let script = HookInstaller.scriptURL(home: home)
    check(HookInstaller.status(of: target, script: script) == .notInstalled, "fresh: not installed")
    check((try? HookInstaller.install(target, script: script)) == true, "fresh: install writes")
    check(HookInstaller.status(of: target, script: script) == .installed, "fresh: installed afterwards")
    let first = text(target.file)
    let before = stamp(target.file)
    Thread.sleep(forTimeInterval: 1.1)
    check((try? HookInstaller.install(target, script: script)) == false, "fresh: second install is a no-op")
    check(text(target.file) == first && stamp(target.file) == before, "fresh: file untouched by the no-op")
    let hooks = object(target.file)["hooks"] as? NSDictionary ?? [:]
    check(hooks.count == 6, "fresh: six events (Notification twice)")
    check(first.hasSuffix("}\n") && first.contains("\"hooks\": {"), "fresh: two-space layout with newline")
}

// 2. A settings.json full of the user's own things plus stale muxy hooks.
let busy = """
{
  "model": "opus",
  "env": {
    "PATH_HINT": "/opt/homebrew/bin",
    "GREETING": "Grüße \\u00fcber \\/ slash"
  },
  "permissions": {
    "allow": [
      "Bash(git:*)"
    ],
    "deny": []
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -X POST http://localhost:8765/hook -d \\"$(cat)\\" > /dev/null 2>&1 &"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/no-ai-attribution.sh"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/x/muxy/Scripts/claude-hook.sh tool"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "say done"
          },
          {
            "type": "command",
            "command": "/Users/x/muxy/Scripts/claude-hook.sh stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/x/muxy/Scripts/agent-hook.sh idle claude"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  },
  "cleanupPeriodDays": 1e3
}

"""
do {
    let home = scratch.appendingPathComponent("busy")
    let target = claudeTarget(home)
    let script = HookInstaller.scriptURL(home: home)
    try fm.createDirectory(at: target.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try busy.write(to: target.file, atomically: true, encoding: .utf8)
    check(HookInstaller.status(of: target, script: script) == .outdated, "busy: stale muxy entries count as outdated")
    try HookInstaller.install(target, script: script)
    check(HookInstaller.status(of: target, script: script) == .installed, "busy: installed afterwards")
    let out = text(target.file)
    check(!out.contains("claude-hook.sh") && !out.contains("/Users/x/muxy"), "busy: stale entries gone")
    check(out.contains("\"say done\""), "busy: user's hook sharing an entry with muxy's stays")
    check(out.contains("no-ai-attribution.sh") && out.contains("localhost:8765"), "busy: user's hooks stay")
    check(out.contains("\"Grüße \\u00fcber \\/ slash\""), "busy: string escapes kept as written")
    check(out.contains("\"cleanupPeriodDays\": 1e3"), "busy: number kept as written")
    check(out.contains("\"deny\": []"), "busy: empty array kept")
    let keys = ["\"model\"", "\"env\"", "\"permissions\"", "\"hooks\"", "\"statusLine\"", "\"cleanupPeriodDays\""]
    let positions = keys.compactMap { out.range(of: $0)?.lowerBound }
    check(positions.count == keys.count && positions == positions.sorted(), "busy: top-level key order kept")
    // The same file through the shell installer must mean the same JSON.
    let reference = scratch.appendingPathComponent("busy-python.json")
    try busy.write(to: reference, atomically: true, encoding: .utf8)
    try out.write(to: scratch.appendingPathComponent("busy-swift.json"), atomically: true, encoding: .utf8)
}

// 3. CODEX_HOME is a symlink into a dotfiles repository; settings.json is
// a symlink to a file there.
do {
    let dotfiles = scratch.appendingPathComponent("dotfiles")
    let realCodex = dotfiles.appendingPathComponent("codex/.codex")
    try fm.createDirectory(at: realCodex, withIntermediateDirectories: true)
    try "model = \"gpt-5\"\n".write(to: realCodex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let home = scratch.appendingPathComponent("linked")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let codexHome = home.appendingPathComponent(".codex")
    try fm.createSymbolicLink(atPath: codexHome.path, withDestinationPath: "../dotfiles/codex/.codex")
    let script = HookInstaller.scriptURL(home: home)

    let codex = codexTarget(codexHome)
    try HookInstaller.install(codex, script: script)
    check(isLink(codexHome), "symlink: ~/.codex is still a link")
    check(fm.fileExists(atPath: realCodex.appendingPathComponent("hooks.json").path), "symlink: hooks.json landed in the dotfiles repo")
    check(HookInstaller.status(of: codex, script: script) == .installed, "symlink: codex installed")
    let codexText = text(codex.file)
    check(codexText.contains("\"timeout\": 10") && codexText.contains("agent-hook.sh tool codex"), "symlink: codex entries carry timeout and agent")
    let leftovers = (try? fm.contentsOfDirectory(atPath: realCodex.path))?.filter { $0.contains(".muxy-") } ?? []
    check(leftovers.isEmpty, "symlink: no temporary files left behind")

    let realClaude = dotfiles.appendingPathComponent("claude/.claude")
    try fm.createDirectory(at: realClaude, withIntermediateDirectories: true)
    try "{\n    \"model\": \"opus\"\n}".write(to: realClaude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    _ = chmod(realClaude.appendingPathComponent("settings.json").path, 0o600)
    try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    let link = home.appendingPathComponent(".claude/settings.json")
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../dotfiles/claude/.claude/settings.json")
    let claude = claudeTarget(home)
    try HookInstaller.install(claude, script: script)
    check(isLink(link), "symlink: settings.json is still a link")
    let real = text(realClaude.appendingPathComponent("settings.json"))
    check(real.contains("agent-hook.sh start claude"), "symlink: the link's target got the hooks")
    check(real.hasPrefix("{\n    \"model\": \"opus\",\n    \"hooks\": {"), "symlink: four-space indentation kept")
    check(!real.hasSuffix("\n"), "symlink: missing trailing newline stays missing")
    let mode = (try? fm.attributesOfItem(atPath: realClaude.appendingPathComponent("settings.json").path))?[.posixPermissions] as? Int
    check(mode == 0o600, "symlink: file permissions kept")
}

// 4. A script path that moved makes the install outdated; unreadable
// files are reported and left alone.
do {
    let home = scratch.appendingPathComponent("moved")
    let target = claudeTarget(home)
    try HookInstaller.install(target, script: URL(fileURLWithPath: "/old/place/agent-hook.sh"))
    check(HookInstaller.status(of: target, script: HookInstaller.scriptURL(home: home)) == .outdated, "moved: old path is outdated")
    try HookInstaller.install(target, script: HookInstaller.scriptURL(home: home))
    check(!text(target.file).contains("/old/place"), "moved: old path replaced")

    let broken = claudeTarget(scratch.appendingPathComponent("broken"))
    try fm.createDirectory(at: broken.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{ \"hooks\": ".write(to: broken.file, atomically: true, encoding: .utf8)
    if case .unreadable = HookInstaller.status(of: broken, script: HookInstaller.scriptURL(home: home)) {
        check(true, "broken: reported as unreadable")
    } else {
        check(false, "broken: reported as unreadable")
    }
    check((try? HookInstaller.install(broken, script: HookInstaller.scriptURL(home: home))) == nil, "broken: install refuses")
    check(text(broken.file) == "{ \"hooks\": ", "broken: file untouched")

    let spaced = scratch.appendingPathComponent("with space")
    let command = HookInstaller.command(for: HookInstaller.claudeHooks[0], agent: "claude", script: HookInstaller.scriptURL(home: spaced))
    check(command.hasPrefix("'") && command.hasSuffix("agent-hook.sh' start claude"), "spaced: path quoted for the shell")
}

// 5. The script copy.
do {
    let url = HookInstaller.scriptURL(home: scratch.appendingPathComponent("script"))
    let data = Data("#!/bin/sh\nexit 0\n".utf8)
    check((try? HookInstaller.installScript(data, at: url)) == true, "script: first copy writes")
    check(fm.isExecutableFile(atPath: url.path), "script: executable")
    check((try? HookInstaller.installScript(data, at: url)) == false, "script: same content is a no-op")
}

// 6. Files that must survive a parse and re-format unchanged (read only).
for path in CommandLine.arguments.dropFirst(2) {
    let original = text(URL(fileURLWithPath: path))
    guard let parsed = try? JSON.parse(original) else {
        check(false, "round trip: \(path) parses")
        continue
    }
    check(parsed.formatted(like: original) == original, "round trip: \(path) byte for byte")
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
