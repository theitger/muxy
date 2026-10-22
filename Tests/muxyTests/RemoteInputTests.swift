import CryptoKit
import XCTest
@testable import muxy

@MainActor
final class RemoteInputTests: XCTestCase {
    func testEncryptedInputFailureIsAcknowledgedAndCorrelated() throws {
        let secret = Data(repeating: 0x35, count: 32)
        var frames: [Data] = []
        let connection = RemoteConnection(secret: secret, send: { frames.append($0) }, close: {})
        defer { connection.close() }
        connection.start()
        let hello = try XCTUnwrap(frames.first)
        XCTAssertEqual(hello.first, 1)
        let serverPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.dropFirst())
        let client = Curve25519.KeyAgreement.PrivateKey()
        let shared = try client.sharedSecretFromKeyAgreement(with: serverPublic)
        let dh = shared.withUnsafeBytes { Data($0) }
        let material = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret + dh),
            salt: serverPublic.rawRepresentation + client.publicKey.rawRepresentation,
            info: RemoteCrypto.info, outputByteCount: 64
        ).withUnsafeBytes { Data($0) }
        let sendKey = SymmetricKey(data: material.prefix(32))
        let receiveKey = SymmetricKey(data: material.suffix(32))
        let auth = try RemoteCrypto.seal(Data(#"{"t":"auth"}"#.utf8), key: sendKey, counter: 0)
        connection.receive(Data([2]) + client.publicKey.rawRepresentation + auth)
        XCTAssertTrue(connection.isAuthenticated)

        // A terminal which no longer exists must not look like a successful send.
        // The second request also exercises compatibility with older phone clients.
        for (index, request) in ["phone-input-1", ""].enumerated() {
            var input: [String: Any] = ["t": "type", "tab": "missing", "text": "continue", "enter": true]
            if !request.isEmpty { input["request"] = request }
            let responseCounter = UInt64(frames.count - 1) // hello is not encrypted
            let frameCount = frames.count
            connection.receive(try RemoteCrypto.seal(
                JSONSerialization.data(withJSONObject: input), key: sendKey, counter: UInt64(index + 1)
            ))
            XCTAssertEqual(frames.count, frameCount + 1)
            let response = try RemoteCrypto.open(try XCTUnwrap(frames.last), key: receiveKey, counter: responseCounter)
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            XCTAssertEqual(message["t"] as? String, "typed")
            XCTAssertEqual(message["ok"] as? Bool, false)
            XCTAssertEqual(message["request"] as? String, request.isEmpty ? nil : request)
        }
    }
}
