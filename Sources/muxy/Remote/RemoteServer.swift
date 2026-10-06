import CryptoKit
import Foundation
import IOKit.pwr_mgt
import Network

/// Muxy on the phone. Through a relay (any network: Muxy connects out, the
/// relay serves the web app) or, without one, over the local network (one
/// port serves the web app, the next carries the channel). Either way the
/// channel is end-to-end encrypted (see RemoteCrypto); nothing is accepted
/// before a phone has proven it holds the pairing secret. Off until
/// switched on in Settings.
@MainActor
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()

    static let httpPort: UInt16 = 47_820
    static var socketPort: UInt16 { httpPort + 1 }
    static let enabledKey = "remoteEnabled"
    static let relayKey = "remoteRelay"

    @Published private(set) var isRunning = false
    @Published private(set) var relayState: RemoteRelay.State?
    @Published private(set) var phones = 0
    @Published private(set) var problem: String?

    private var relay: RemoteRelay?
    private var httpListener: NWListener?
    private var socketListener: NWListener?
    private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0

    var secret: Data {
        RemoteCrypto.loadSecret() ?? RemoteCrypto.newSecret()
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? start() : stop()
    }

    /// The relay's host name, e.g. "muxy.example.com"; empty: local network.
    var relayHost: String {
        (UserDefaults.standard.string(forKey: Self.relayKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func setRelayHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: Self.relayKey)
        if isRunning {
            stop()
            start()
        }
    }

    func start() {
        guard !isRunning else { return }
        problem = nil
        if !relayHost.isEmpty {
            let relay = RemoteRelay(
                host: relayHost, token: RemoteCrypto.relayToken, secret: secret,
                onState: { [weak self] state in self?.relayState = state },
                attach: { [weak self] connection in self?.track(connection) }
            )
            self.relay = relay
            relay.start()
            startTicking()
            return
        }
        do {
            let http = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.httpPort)!)
            http.newConnectionHandler = { connection in
                MainActor.assumeIsolated { Self.serveApp(on: connection) }
            }
            http.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            http.start(queue: .main)
            httpListener = http

            let parameters = NWParameters.tcp
            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            websocket.maximumMessageSize = 1 << 20
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
            let socket = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.socketPort)!)
            socket.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            socket.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            socket.start(queue: .main)
            socketListener = socket
        } catch {
            problem = error.localizedDescription
            stop()
            return
        }
        startTicking()
    }

    private func startTicking() {
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        relay?.stop()
        relay = nil
        relayState = nil
        httpListener?.cancel()
        socketListener?.cancel()
        httpListener = nil
        socketListener = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
        isRunning = false
        updatePhones()
    }

    /// New secret: every paired phone is locked out, open connections end.
    func pairAgain() {
        RemoteCrypto.newSecret()
        if isRunning {
            stop()
            start()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        if case let .failed(error) = state {
            problem = error.localizedDescription
            stop()
        }
    }

    // MARK: - Pairing

    /// What the QR code holds: this Mac's address plus the secret in the
    /// fragment — browsers never send a fragment over the network.
    var pairingURL: String? {
        if !relayHost.isEmpty {
            let room = RemoteRelay.room(for: RemoteCrypto.relayToken)
            return "https://\(relayHost)/#r=\(room)&k=\(secret.base64URL)"
        }
        guard let host = Self.localAddress() else { return nil }
        return "http://\(host):\(Self.httpPort)/#k=\(secret.base64URL)"
    }

    /// The Mac's IPv4 address on the local network (Wi-Fi or Ethernet).
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((String(cString: entry.ifa_name), String(cString: host)))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }

    // MARK: - The web app

    /// Built by Prototypes/remote (`pnpm build`) — bundled into Muxy.app by
    /// make-app.sh; development builds read it straight from the repo.
    static var appURL: URL? {
        if let bundled = Bundle.main.url(forResource: "remote", withExtension: "html") { return bundled }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dev = repo.appendingPathComponent("Prototypes/remote/dist/index.html")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private static func serveApp(on connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = request.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? parts[1].split(separator: "?").first.map(String.init) ?? "/" : "/"
            let body: Data
            let status: String
            if parts.first == "GET", path == "/" || path == "/index.html",
               let url = appURL, let file = try? Data(contentsOf: url) {
                status = "200 OK"
                body = file
            } else {
                status = "404 Not Found"
                body = Data("Not found".utf8)
            }
            let head = [
                "HTTP/1.1 \(status)",
                "Content-Type: \(status.hasPrefix("200") ? "text/html; charset=utf-8" : "text/plain")",
                "Content-Length: \(body.count)",
                "Cache-Control: no-store",
                "X-Content-Type-Options: nosniff",
                "Referrer-Policy: no-referrer",
                "X-Frame-Options: DENY",
                "Connection: close",
                "", "",
            ].joined(separator: "\r\n")
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let remote = RemoteConnection(
            secret: secret,
            send: { data in
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
                connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                    if error != nil { connection.cancel() }
                })
            },
            close: { connection.cancel() }
        )
        track(remote)
        connection.stateUpdateHandler = { [weak remote] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: remote?.start()
                case .failed, .cancelled: remote?.close()
                default: break
                }
            }
        }
        func receive() {
            connection.receiveMessage { [weak remote] data, _, _, error in
                MainActor.assumeIsolated {
                    guard let remote else { return }
                    if error != nil { return remote.close() }
                    if let data { remote.receive(data) }
                    receive()
                }
            }
        }
        receive()
        connection.start(queue: .main)
    }

    /// Every phone, however it came in, counts for the badge and the push.
    func track(_ remote: RemoteConnection) {
        let key = ObjectIdentifier(remote)
        remote.onAuthenticated = { [weak self] in self?.updatePhones() }
        remote.onClose = { [weak self] in
            self?.connections[key] = nil
            self?.updatePhones()
        }
        connections[key] = remote
    }

    private func tick() {
        for connection in connections.values where connection.isAuthenticated {
            connection.push()
        }
    }

    /// A paired phone keeps the Mac awake — otherwise it would fall asleep
    /// under your thumb.
    private func updatePhones() {
        phones = connections.values.filter(\.isAuthenticated).count
        if phones > 0, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "A phone is connected to Muxy" as CFString,
                &sleepAssertion
            )
        } else if phones == 0, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}

/// One phone. Speaks only after the handshake proved the secret; every
/// frame after that is sealed (see RemoteCrypto). The transport — a local
/// socket or a relay channel — only moves frames.
@MainActor
final class RemoteConnection {
    private let secret: Data
    private let transportSend: (Data) -> Void
    private let transportClose: () -> Void
    private let serverKey = Curve25519.KeyAgreement.PrivateKey()
    private var keys: RemoteCrypto.Keys?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var closed = false

    var onAuthenticated: (() -> Void)?
    var onClose: (() -> Void)?
    var isAuthenticated: Bool { keys != nil }

    // What this phone looks at, and what it has already been sent.
    private var watchedTab: String?
    private var wantsHistory = false
    private var lastSessions = ""
    private var lastScreen = ""
    private var lastChatStamp = ""
    private var lastParse = Date.distantPast
    private var lastHistoryRead = Date.distantPast
    private var parsing = false

    init(secret: Data, send: @escaping (Data) -> Void, close: @escaping () -> Void) {
        self.secret = secret
        transportSend = send
        transportClose = close
    }

    /// The transport is up: say hello, and drop a phone that hasn't proven
    /// itself within 10 s.
    func start() {
        sendFrame(Data([0x01]) + serverKey.publicKey.rawRepresentation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                if self?.isAuthenticated == false { self?.close() }
            }
        }
    }

    func receive(_ frame: Data) {
        guard !closed, !frame.isEmpty else { return }
        handle(frame)
    }

    func close() {
        guard !closed else { return }
        closed = true
        transportClose()
        onClose?()
    }

    private func handle(_ frame: Data) {
        do {
            if keys == nil {
                // [0x02][phone's ephemeral key][sealed hello]
                guard frame.first == 0x02, frame.count > 33 else { return close() }
                let clientPublic = frame.subdata(in: 1 ..< 33)
                let derived = try RemoteCrypto.deriveServerKeys(
                    secret: secret, serverPrivate: serverKey, clientPublic: clientPublic
                )
                let plain = try RemoteCrypto.open(frame.subdata(in: 33 ..< frame.count), key: derived.receive, counter: 0)
                guard let message = try JSONSerialization.jsonObject(with: plain) as? [String: Any],
                      message["t"] as? String == "auth" else { return close() }
                keys = derived
                receiveCounter = 1
                onAuthenticated?()
                push()
                return
            }
            guard let keys else { return close() }
            let plain = try RemoteCrypto.open(frame, key: keys.receive, counter: receiveCounter)
            receiveCounter += 1
            guard let message = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return }
            route(message)
        } catch {
            // Wrong secret, tampering or replay: nothing more from this one.
            close()
        }
    }

    // MARK: - Messages

    private func route(_ message: [String: Any]) {
        let tab = (message["tab"] as? String).flatMap(RemoteState.session)
        switch message["t"] as? String {
        case "watch":
            watchedTab = message["tab"] as? String
            wantsHistory = message["history"] as? Bool ?? false
            lastScreen = ""
            lastChatStamp = ""
            if let tab { RemoteState.markSeen(tab) }
            push()
        case "type":
            if let tab { RemoteState.type(message["text"] as? String ?? "", enter: message["enter"] as? Bool ?? false, into: tab) }
        case "key":
            if let tab, let key = message["key"] as? String { RemoteState.press(key, in: tab) }
        case "open":
            let id = (message["directory"] as? String).flatMap(RemoteState.open)
            send(["t": "opened", "session": id ?? NSNull()])
        default:
            break
        }
    }

    /// Sends whatever changed since the last time: the session list, the
    /// watched tab's screen, its chat.
    func push() {
        let sessions = RemoteState.sessions()
        let payload: [String: Any] = [
            "t": "sessions", "sessions": sessions, "recent": RemoteState.recentDirectories(),
            "history": ShellHistory.recent(),
        ]
        if let json = Self.encode(payload), json != lastSessions {
            lastSessions = json
            sendJSON(json)
        }
        guard let id = watchedTab, let session = RemoteState.session(id) else { return }
        // The whole scrollback is a big read — once a second is plenty.
        let now = Date()
        if wantsHistory, now.timeIntervalSince(lastHistoryRead) < 1 { return pushChat(id, session) }
        if wantsHistory { lastHistoryRead = now }
        if let screen = RemoteState.screen(of: session, history: wantsHistory) {
            var message = screen
            message["t"] = "screen"
            message["tab"] = id
            if let json = Self.encode(message), json != lastScreen {
                lastScreen = json
                sendJSON(json)
            }
        }
        pushChat(id, session)
    }

    /// The transcript is parsed off the main thread, at most once a second
    /// — a busy Claude rewrites it constantly.
    private func pushChat(_ id: String, _ session: TerminalSession) {
        guard let path = session.transcriptPath, !parsing,
              Date().timeIntervalSince(lastParse) >= 1 else { return }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let stamp = "\(path)|\(modified)|\(session.agent)"
        guard stamp != lastChatStamp else { return }
        parsing = true
        lastParse = Date()
        Task { [weak self] in
            let json = await Task.detached(priority: .utility) {
                Self.encode(["t": "chat", "tab": id, "items": Transcript.items(at: path)])
            }.value
            guard let self else { return }
            self.parsing = false
            // Still looking at the same tab?
            guard self.watchedTab == id else { return }
            self.lastChatStamp = stamp
            if let json { self.sendJSON(json) }
        }
    }

    nonisolated private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func send(_ object: [String: Any]) {
        if let json = Self.encode(object) { sendJSON(json) }
    }

    private func sendJSON(_ json: String) {
        guard let keys, !closed else { return }
        do {
            let sealed = try RemoteCrypto.seal(Data(json.utf8), key: keys.send, counter: sendCounter)
            sendCounter += 1
            sendFrame(sealed)
        } catch {
            close()
        }
    }

    private func sendFrame(_ data: Data) {
        guard !closed else { return }
        transportSend(data)
    }
}
