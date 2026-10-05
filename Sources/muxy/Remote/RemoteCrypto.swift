import CryptoKit
import Foundation

/// The remote channel's crypto. Pairing hands the phone a 32-byte secret
/// (the QR code's URL fragment — it never travels over the network).
/// Every connection then runs a fresh X25519 exchange; both sides derive
/// their keys from secret + exchange, so
///
/// - nobody without the secret can talk to muxy or read along,
/// - a leaked secret doesn't open recorded past connections.
///
/// Frames are ChaCha20-Poly1305 with a per-direction counter as the nonce;
/// a frame that is replayed, reordered or altered fails to open and ends
/// the connection. Same construction on the phone (Prototypes/remote,
/// src/lib/channel.ts) — change both together.
enum RemoteCrypto {
    static let info = Data("muxy-remote v1".utf8)

    struct Keys {
        let send: SymmetricKey
        let receive: SymmetricKey
    }

    /// Server side: the phone's ephemeral public key in, both directions'
    /// keys out. `serverPublic`/`clientPublic` bind the exchange (salt).
    static func deriveServerKeys(
        secret: Data,
        serverPrivate: Curve25519.KeyAgreement.PrivateKey,
        clientPublic: Data
    ) throws -> Keys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublic)
        let shared = try serverPrivate.sharedSecretFromKeyAgreement(with: peer)
        let dh = shared.withUnsafeBytes { Data($0) }
        let salt = serverPrivate.publicKey.rawRepresentation + clientPublic
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret + dh),
            salt: salt,
            info: info,
            outputByteCount: 64
        )
        let bytes = okm.withUnsafeBytes { Data($0) }
        // First half: phone → muxy, second half: muxy → phone.
        return Keys(
            send: SymmetricKey(data: bytes.suffix(32)),
            receive: SymmetricKey(data: bytes.prefix(32))
        )
    }

    /// 12-byte nonce: 4 zero bytes + 64-bit big-endian counter.
    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var data = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { data.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: data)
    }

    static func seal(_ plain: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce(counter))
        return box.ciphertext + box.tag
    }

    static func open(_ frame: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        guard frame.count >= 16 else { throw CryptoKitError.authenticationFailure }
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce(counter),
            ciphertext: frame.dropLast(16),
            tag: frame.suffix(16)
        )
        return try ChaChaPoly.open(box, using: key)
    }

    // MARK: - The pairing secret

    /// ~/Library/Application Support/Muxy/remote-secret, readable only by
    /// you. Replaced on "pair again", which locks out every paired phone.
    static var secretURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muxy/remote-secret")
    }

    /// Identifies this Mac to a relay. Unlike the secret it never reaches
    /// a phone; "pair again" leaves it alone.
    static var relayTokenURL: URL {
        secretURL.deletingLastPathComponent().appendingPathComponent("remote-relay-token")
    }

    static func loadSecret() -> Data? { load(secretURL) }

    @discardableResult
    static func newSecret() -> Data { create(secretURL) }

    static var relayToken: Data { load(relayTokenURL) ?? create(relayTokenURL) }

    private static func load(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count == 32 else { return nil }
        return data
    }

    private static func create(_ url: URL) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no randomness")
        let data = Data(bytes)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return data
    }
}

extension Data {
    /// URL-safe base64 without padding — fits a URL fragment.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
