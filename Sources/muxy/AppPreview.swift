import AppKit
import SwiftUI
import WebKit

/// "Open app": the servers each session runs (see Ports), and a preview of
/// one beside its terminal. You check what the agent built by using it,
/// not by reading its diff.
@MainActor
final class Previews: ObservableObject {
    static let shared = Previews()

    /// What each session runs, web servers first.
    @Published private(set) var ports: [Workspace.ID: [AppPort]] = [:]
    /// Sessions whose preview is open, and on which port. Kept per session:
    /// switching away and back brings it back.
    @Published private(set) var open: [Workspace.ID: Int] = [:]

    /// One web view per open preview, so its page and history survive a
    /// switch to another session.
    private var views: [Workspace.ID: WKWebView] = [:]
    private var scanning = false

    func ports(of workspace: Workspace) -> [AppPort] { ports[workspace.id] ?? [] }

    func port(open workspace: Workspace) -> Int? { open[workspace.id] }

    func show(_ port: Int, of workspace: Workspace) {
        withAnimation(Theme.ease) { open[workspace.id] = port }
        let view = webView(for: workspace)
        if view.url?.port != port || view.url == nil {
            view.load(URLRequest(url: URL(string: "http://localhost:\(port)/")!))
        }
    }

    func close(_ workspace: Workspace) {
        withAnimation(Theme.ease) { open[workspace.id] = nil }
    }

    func toggle(_ workspace: Workspace) {
        if open[workspace.id] != nil {
            close(workspace)
        } else if let first = ports(of: workspace).first {
            show(first.port, of: workspace)
        }
    }

    func openInBrowser(_ port: Int) {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(port)/")!)
    }

    func webView(for workspace: Workspace) -> WKWebView {
        if let view = views[workspace.id] { return view }
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsBackForwardNavigationGestures = true
        views[workspace.id] = view
        return view
    }

    /// Looks again which servers every session runs. Called by the Store
    /// every few seconds; one look at a time.
    func scan(_ workspaces: [Workspace]) {
        guard !scanning else { return }
        var owners: [String: Workspace.ID] = [:]
        var sessions: [Ports.Session] = []
        for workspace in workspaces {
            let context = workspace.context
            let leased = context.checkout.flatMap { checkout in
                context.root.map { Ports.leased(in: checkout, root: $0) }
            } ?? []
            for (index, tab) in workspace.sessions.enumerated() {
                let id = tab.id.uuidString
                owners[id] = workspace.id
                // The checkout and the leased ports count once per session.
                sessions.append(Ports.Session(
                    id: id, checkout: index == 0 ? context.checkout : nil, leased: index == 0 ? leased : []
                ))
            }
        }
        scanning = true
        Task.detached(priority: .utility) {
            let found = Ports.scan(sessions)
            await MainActor.run {
                self.scanning = false
                var merged: [Workspace.ID: [AppPort]] = [:]
                for (session, ports) in found {
                    guard let workspace = owners[session] else { continue }
                    merged[workspace, default: []].append(contentsOf: ports)
                }
                merged = merged.mapValues { ports in
                    Array(Set(ports)).sorted { ($0.isWeb ? 0 : 1, $0.port) < ($1.isWeb ? 0 : 1, $1.port) }
                }
                if merged != self.ports { self.ports = merged }
                // Sessions that are gone leave nothing behind.
                let alive = Set(workspaces.map(\.id))
                self.views = self.views.filter { alive.contains($0.key) }
                self.open = self.open.filter { alive.contains($0.key) }
            }
        }
    }
}

/// In the strip above the terminal: "App :3000". A click opens the preview
/// beside the terminal, ⌥-click the browser; several servers: a menu.
struct AppButton: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var previews = Previews.shared
    @State private var hovered = false

    var body: some View {
        let ports = previews.ports(of: workspace)
        let open = previews.port(open: workspace)
        if let first = ports.first {
            Group {
                if ports.count == 1 {
                    Button { activate(first.port) } label: { label(port: open ?? first.port, open: open != nil) }
                        .buttonStyle(.plain)
                } else {
                    Menu {
                        ForEach(ports, id: \.port) { port in
                            Button(port.isWeb ? L("Preview :%d", port.port) : L(":%d (not a web page)", port.port)) {
                                previews.show(port.port, of: workspace)
                            }
                        }
                        Divider()
                        ForEach(ports.filter(\.isWeb), id: \.port) { port in
                            Button(L("Open :%d in Browser", port.port)) { previews.openInBrowser(port.port) }
                        }
                        if open != nil {
                            Divider()
                            Button(L("Close Preview")) { previews.close(workspace) }
                        }
                    } label: {
                        label(port: open ?? first.port, open: open != nil)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .help(L("Open the app this session runs (⌥-click: in the browser)"))
            .accessibilityLabel(L("Open app on port %d", first.port))
            .onHover { hovered = $0 }
            .transition(.opacity)
        }
    }

    private func activate(_ port: Int) {
        if NSEvent.modifierFlags.contains(.option) {
            previews.openInBrowser(port)
        } else if previews.port(open: workspace) == port {
            previews.close(workspace)
        } else {
            previews.show(port, of: workspace)
        }
    }

    private func label(port: Int, open: Bool) -> some View {
        HStack(spacing: 5) {
            Icon("globe", size: 11)
            Text(L("App :%d", port))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(open || hovered ? Theme.textPrimary : Theme.textDim)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(open ? Theme.fillActive : (hovered ? Theme.fillHover : .clear))
        )
        .contentShape(Rectangle())
    }
}

/// The preview beside the terminal: the page, its address, back, reload,
/// the browser, close.
struct PreviewPane: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var previews = Previews.shared

    var body: some View {
        if let port = previews.port(open: workspace) {
            let view = previews.webView(for: workspace)
            VStack(spacing: 0) {
                PreviewBar(view: view, port: port, workspace: workspace)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                WebView(view: view)
            }
            .background(Theme.surface)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

private struct PreviewBar: View {
    let view: WKWebView
    let port: Int
    @ObservedObject var workspace: Workspace
    @State private var address = ""

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", help: L("Back")) { view.goBack() }
                .accessibilityLabel(L("Back"))
            IconButton(symbol: "arrow.clockwise", help: L("Reload")) { view.reload() }
                .accessibilityLabel(L("Reload"))
            Text(address.isEmpty ? "localhost:\(port)" : address)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .textSelection(.enabled)
            IconButton(symbol: "safari", help: L("Open in Browser")) {
                NSWorkspace.shared.open(view.url ?? URL(string: "http://localhost:\(port)/")!)
            }
            .accessibilityLabel(L("Open in Browser"))
            IconButton(symbol: "xmark", help: L("Close Preview")) { Previews.shared.close(workspace) }
                .accessibilityLabel(L("Close Preview"))
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // WKWebView's URL isn't observable from SwiftUI without KVO glue;
            // a cheap look twice a second is plenty for an address line.
            let shown = view.url.map(Self.address) ?? ""
            if shown != address { address = shown }
        }
    }
}

extension PreviewBar {
    /// "localhost:3000/login?next=1": the page without the scheme.
    static func address(_ url: URL) -> String {
        var text = url.host() ?? ""
        if let port = url.port { text += ":\(port)" }
        text += url.path()
        if let query = url.query() { text += "?" + query }
        return text
    }
}

private struct WebView: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context _: Context) -> WKWebView { view }
    func updateNSView(_: WKWebView, context _: Context) {}
}
