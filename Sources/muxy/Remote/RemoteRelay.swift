import AppKit
import CryptoKit
import Foundation

/// Muxy's line to a relay (Relay/main.go): one outgoing connection that
/// phones on any network reach through. Phones arrive as channels; each
/// gets its own RemoteConnection, so the relay only ever moves sealed
/// frames. Reconnects by itself — after sleep, a network change, a relay
/// restart.
@MainActor
final class RemoteRelay: NSObject, URLSessionWebSocketDelegate {
    enum State: Equatable { case connecting, connected, failed(String) }

    let host: String
    private let token: Data
    private let secret: Data
    private let onState: (State) -> Void
    private let attach: (RemoteConnection) -> Void

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var channels: [UInt32: RemoteConnection] = [:]
    private var retry = 0
    private var stopped = false
    private var pingTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(host: String, token: Data, secret: Data, onState: @escaping (State) -> Void, attach: @escaping (RemoteConnection) -> Void) {
        self.host = host
        self.token = token
        self.secret = secret
        self.onState = onState
        self.attach = attach
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectNow() }
        }
    }

    /// What the relay knows this Mac by — derived from the token, which
    /// never leaves the Mac except to the relay itself.
    static func room(for token: Data) -> String {
        let digest = SHA256.hash(data: Data("muxy-room".utf8) + token)
        return Data(digest).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        dropChannels()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        session.invalidateAndCancel()
    }

    private func connect() {
        guard !stopped, let url = URL(string: "wss://\(host)/relay/mac") else { return }
        onState(.connecting)
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 2 << 20
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func reconnectNow() {
        guard !stopped else { return }
        retry = 0
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func scheduleReconnect(_ reason: String) {
        guard !stopped else { return }
        task = nil
        pingTimer?.invalidate()
        dropChannels()
        onState(.failed(reason))
        let delay = min(30, pow(2, Double(retry)))
        retry += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.task == nil else { return }
                self.connect()
            }
        }
    }

    private func dropChannels() {
        let open = channels.values
        channels.removeAll()
        for connection in open { connection.close() }
    }

    // MARK: - Frames

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.task === task else { return }
                switch result {
                case let .success(.data(frame)):
                    self.handle(frame)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case let .failure(error):
                    self.scheduleReconnect(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ frame: Data) {
        guard frame.count >= 5 else { return }
        let ch = frame.subdata(in: 1 ..< 5).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        switch frame[frame.startIndex] {
        case 0x01:
            let connection = RemoteConnection(
                secret: secret,
                send: { [weak self] data in self?.send(op: 0x03, ch, data) },
                close: { [weak self] in
                    guard let self, self.channels.removeValue(forKey: ch) != nil else { return }
                    self.send(op: 0x02, ch, Data())
                }
            )
            channels[ch] = connection
            attach(connection)
            connection.start()
        case 0x02:
            channels.removeValue(forKey: ch)?.close()
        case 0x03:
            channels[ch]?.receive(frame.subdata(in: 5 ..< frame.count))
        default:
            break
        }
    }

    private func send(op: UInt8, _ ch: UInt32, _ payload: Data) {
        guard let task else { return }
        var frame = Data([op])
        withUnsafeBytes(of: ch.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        task.send(.data(frame)) { [weak self] error in
            if error != nil {
                MainActor.assumeIsolated { self?.task?.cancel(with: .goingAway, reason: nil) }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        MainActor.assumeIsolated {
            retry = 0
            onState(.connected)
            // Notice a dead line (sleep, network switch) within half a minute.
            pingTimer?.invalidate()
            pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.task?.sendPing { error in
                        if error != nil {
                            MainActor.assumeIsolated { self?.task?.cancel(with: .goingAway, reason: nil) }
                        }
                    }
                }
            }
        }
    }

    nonisolated func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        MainActor.assumeIsolated {
            guard self.task === task else { return }
            let reason = status == 403 ? "Relay kennt diesen Mac nicht"
                : status == 401 ? "Relay lehnt das Token ab"
                : error?.localizedDescription ?? "Verbindung beendet"
            scheduleReconnect(reason)
        }
    }
}
