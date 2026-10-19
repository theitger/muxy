import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// A terminal that slides down from the top of the screen on a global
/// hotkey and away again, like Ghostty's quick terminal. It is a plain
/// shell of its own, not a session in the wings, and keeps running while
/// hidden. The hotkey uses Carbon's RegisterEventHotKey, which needs no
/// accessibility permission.
@MainActor
final class QuickTerminal: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = QuickTerminal()

    /// The keys that can call it; stored by name.
    enum Hotkey: String, CaseIterable, Identifiable {
        case controlBacktick, optionSpace, commandBacktick

        var id: String { rawValue }

        var label: String {
            switch self {
            case .controlBacktick: "⌃`"
            case .optionSpace: "⌥Space"
            case .commandBacktick: "⌥⌘`"
            }
        }

        fileprivate var carbon: (key: UInt32, modifiers: UInt32) {
            switch self {
            case .controlBacktick: (UInt32(kVK_ANSI_Grave), UInt32(controlKey))
            case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
            case .commandBacktick: (UInt32(kVK_ANSI_Grave), UInt32(cmdKey | optionKey))
            }
        }
    }

    @AppStorage("quickTerminal") var enabled = false {
        didSet { register() }
    }
    @AppStorage("quickTerminalHotkey") var hotkeyName = Hotkey.controlBacktick.rawValue {
        didSet { register() }
    }
    /// Another app holds the key already.
    @Published private(set) var problem: String?

    var hotkey: Hotkey { Hotkey(rawValue: hotkeyName) ?? .controlBacktick }

    private var panel: QuickPanel?
    private var session: TerminalSession?
    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var exited: AnyCancellable?

    func start() {
        register()
    }

    // MARK: Hotkey

    private func register() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        problem = nil
        guard enabled else { return }
        installHandler()
        let (key, modifiers) = hotkey.carbon
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key, modifiers, EventHotKeyID(signature: OSType(0x6D757879), id: 1), // "muxy"
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            problem = L("%@ is taken by another app. Pick another key.", hotkey.label)
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in QuickTerminal.shared.toggle() }
            return noErr
        }, 1, &type, nil, &handler)
    }

    // MARK: Showing

    var isShown: Bool { panel?.isVisible == true }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        let terminal = currentSession()
        if terminal.terminalView.superview !== panel.contentView, let content = panel.contentView {
            terminal.terminalView.removeFromSuperview()
            terminal.terminalView.frame = content.bounds
            terminal.terminalView.autoresizingMask = [.width, .height]
            content.addSubview(terminal.terminalView)
        }
        let area = screen.visibleFrame
        let height = (area.height * 0.42).rounded()
        let shown = NSRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
        panel.setFrame(shown.offsetBy(dx: 0, dy: height), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        terminal.terminalView.setSurfaceVisible(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            panel.animator().setFrame(shown, display: true)
            panel.animator().alphaValue = 1
        }
        panel.makeFirstResponder(terminal.terminalView)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        let gone = panel.frame.offsetBy(dx: 0, dy: panel.frame.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(gone, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                self.session?.terminalView.setSurfaceVisible(false)
            }
        }
    }

    /// Clicking elsewhere puts it away, like Ghostty's.
    func windowDidResignKey(_: Notification) {
        hide()
    }

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(Theme.terminal).cgColor
        content.layer?.cornerRadius = 12
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        content.layer?.masksToBounds = true
        panel.contentView = content
        self.panel = panel
        return panel
    }

    /// Its shell, or a fresh one once the last was exited.
    private func currentSession() -> TerminalSession {
        if let session, session.status.isRunning { return session }
        session?.terminate()
        let fresh = TerminalSession(directory: Paths.home)
        exited = fresh.$status.sink { [weak self] status in
            guard !status.isRunning else { return }
            Task { @MainActor in self?.hide() }
        }
        session = fresh
        return fresh
    }
}

/// Takes the keyboard without bringing muxy's other windows forward.
private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickTerminalSettings: View {
    @ObservedObject private var quick = QuickTerminal.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Quick terminal"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                    Text(L("A shell that drops down from the top of the screen, from any app."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Toggle("", isOn: $quick.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(L("Quick terminal"))
            }
            if quick.enabled {
                Picker(L("Key"), selection: $quick.hotkeyName) {
                    ForEach(QuickTerminal.Hotkey.allCases) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            if let problem = quick.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.red)
            }
        }
    }
}
