import SwiftUI

/// The `muxy` command (Scripts/muxy), linked into ~/.local/bin from Settings.
/// Only there and only when your shell looks there: muxy never edits your
/// shell's config to make it so.
enum CommandLineTool {
    /// The script this muxy ships: in the app bundle, or in the checkout a
    /// development build was built from.
    static var source: String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/muxy").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        var folder = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0 ..< 5 {
            guard let current = folder else { break }
            let script = current.appendingPathComponent("Scripts/muxy").path
            if FileManager.default.isExecutableFile(atPath: script) { return script }
            folder = current.deletingLastPathComponent()
        }
        return nil
    }

    static let folder = Paths.home + "/.local/bin"
    static var link: String { folder + "/muxy" }

    enum State: Equatable {
        case missing
        /// A link to this muxy's script.
        case installed
        /// A link somewhere else (another checkout, an older app).
        case elsewhere(String)
        /// Something that isn't a link: not ours to replace.
        case occupied
    }

    static func state(source: String?) -> State {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: link) {
            return target == source ? .installed : .elsewhere(target)
        }
        return fm.fileExists(atPath: link) ? .occupied : .missing
    }

    /// Whether your login shell searches `folder`. GUI apps don't share
    /// your shell's PATH, so the shell itself is asked, starting from the
    /// bare PATH a login gets (muxy's own already has the folder). Blocking.
    static func folderOnPath() -> Bool {
        let result = Shell.execute(
            Paths.userShell, ["-l", "-i", "-c", "printenv PATH"], in: Paths.home, timeout: 5,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        // Interactive shells may print a greeting first: PATH is the last line.
        let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
        return path.split(separator: ":").contains { ($0 as NSString).standardizingPath == folder }
    }

    /// Links `source` as `<folder>/muxy`, replacing only an older link.
    static func install(_ source: String, into folder: String = folder) throws {
        let fm = FileManager.default
        let link = folder + "/muxy"
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
            try fm.removeItem(atPath: link)
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: source)
    }
}

/// Settings → install the `muxy` command.
struct CommandLineSettings: View {
    @State private var source = CommandLineTool.source
    @State private var state: CommandLineTool.State = .missing
    @State private var onPath: Bool?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Command line tool"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                    Text(L("The muxy command in any terminal: start sessions, report into them, list them. For scripts and agents."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if source != nil, onPath == true, state != .installed, state != .occupied {
                    Button(L("Install"), action: install)
                }
            }
            detail
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var detail: some View {
        if let problem {
            Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.red)
        } else if let source {
            switch (state, onPath) {
            case (.installed, _):
                Text(L("Installed as %@.", Paths.abbreviate(CommandLineTool.link)))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.green)
            case (.occupied, _):
                Text(L("%@ exists and is not a link. Remove it to install.", Paths.abbreviate(CommandLineTool.link)))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
            case (_, false?):
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Your shell doesn't look in %@. Add it to your PATH, or link the tool into a folder it does look in:",
                           Paths.abbreviate(CommandLineTool.folder)))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("ln -s '\(source)' /usr/local/bin/muxy")
                        .font(Theme.mono(size: 11)).foregroundStyle(Theme.textBody)
                        .textSelection(.enabled)
                }
            case let (.elsewhere(target), _):
                Text(L("%@ points to %@. Install replaces the link.", Paths.abbreviate(CommandLineTool.link),
                       Paths.abbreviate(target)))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        } else {
            Text(L("This build doesn't include the tool."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
        }
    }

    private func refresh() async {
        state = CommandLineTool.state(source: source)
        onPath = await Task.detached { CommandLineTool.folderOnPath() }.value
    }

    private func install() {
        guard let source else { return }
        do {
            try CommandLineTool.install(source)
            problem = nil
        } catch {
            problem = L("Couldn't install: %@", error.localizedDescription)
        }
        state = CommandLineTool.state(source: source)
    }
}
