import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

final class ProtocolCryptoIntegrationTests: XCTestCase {
    private lazy var vector: [String: String] = loadVector()

    func testMacMatchesSharedPairingVectorInBothDirections() throws {
        let a = try P256.KeyAgreement.PrivateKey(rawRepresentation: data("privateKeyA"))
        let b = try P256.KeyAgreement.PrivateKey(rawRepresentation: data("privateKeyB"))
        let fromA = try pairingMaterial(
            privateKey: a,
            remoteKey: required("publicKeyB"),
            sessionID: required("sessionId")
        )
        let fromB = try pairingMaterial(
            privateKey: b,
            remoteKey: required("publicKeyA"),
            sessionID: required("sessionId")
        )

        XCTAssertEqual(fromA.code, required("expectedCode"))
        XCTAssertEqual(fromA.code, fromB.code)
        XCTAssertEqual(fromA.key, data("expectedKey"))
        XCTAssertEqual(fromA.key, fromB.key)
    }

    func testMacMatchesSharedProtocol2CommitmentCodeAndEnvelopeVectors() throws {
        let a = try P256.KeyAgreement.PrivateKey(rawRepresentation: data("privateKeyA"))
        let b = try P256.KeyAgreement.PrivateKey(rawRepresentation: data("privateKeyB"))
        let sessionID = required("sessionId")
        let publicA = required("publicKeyA")
        let publicB = required("publicKeyB")

        let commitment = SessionSecurity.commitment(sessionID: sessionID, publicKey: publicA)
        XCTAssertEqual(commitment, required("expectedCommitmentA"))
        XCTAssertTrue(SessionSecurity.commitmentMatches(commitment, sessionID: sessionID, publicKey: publicA))
        XCTAssertFalse(SessionSecurity.commitmentMatches(commitment, sessionID: sessionID, publicKey: publicB))
        XCTAssertFalse(SessionSecurity.commitmentMatches(commitment, sessionID: sessionID + "x", publicKey: publicA))

        // A is the initiator: both ends name A's key first.
        let fromA = try pairingMaterial(privateKey: a, remoteKey: publicB, sessionID: sessionID, sasKeys: (publicA, publicB))
        let fromB = try pairingMaterial(privateKey: b, remoteKey: publicA, sessionID: sessionID, sasKeys: (publicA, publicB))
        XCTAssertEqual(fromA.code, required("expectedSasCodeV2"))
        XCTAssertEqual(fromA.code, fromB.code)
        XCTAssertEqual(fromA.key, data("expectedKey"))
        XCTAssertNotEqual(fromA.code, required("expectedCode"))

        let envelopeKey = SessionSecurity.envelopeKey(sessionKey: fromA.key)
        XCTAssertEqual(envelopeKey, data("expectedEnvelopeKey"))
        var message = PairingMessage(
            kind: "clipboard.update",
            sessionId: sessionID,
            messageId: required("envelopeMessageId"),
            nonce: required("aesNonce"),
            ciphertext: required("aesCiphertext"),
            sequence: Int64(required("envelopeSequence"))
        )
        let sender = required("deviceId")
        let tag = SessionSecurity.tag(envelopeKey: envelopeKey, senderDeviceID: sender, message: message)
        XCTAssertEqual(tag, required("expectedEnvelopeTag"))
        XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: envelopeKey, senderDeviceID: sender, message: message))
        message.tag = tag
        XCTAssertTrue(SessionSecurity.tagMatches(envelopeKey: envelopeKey, senderDeviceID: sender, message: message))
        // Replay under a new messageId, a relabelled kind, a reflection to its sender: all fail.
        var replayed = message
        replayed.messageId = "0d9c8b7a-6f5e-4d3c-2b1a-0f9e8d7c6b5b"
        XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: envelopeKey, senderDeviceID: sender, message: replayed))
        let relabelled = PairingMessage(
            kind: "clipboard.rich", sessionId: sessionID, messageId: message.messageId, nonce: message.nonce,
            ciphertext: message.ciphertext, sequence: message.sequence, tag: tag
        )
        XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: envelopeKey, senderDeviceID: sender, message: relabelled))
        XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: envelopeKey, senderDeviceID: "mac-fixture-device", message: message))
        // The tag survives the wire: encode, strict decode, verify.
        let decoded = try decodeProtocolMessage(JSONEncoder().encode(message))
        XCTAssertTrue(SessionSecurity.tagMatches(envelopeKey: envelopeKey, senderDeviceID: sender, message: decoded))
    }

    func testMacMatchesSharedProofAndAesGCMVector() throws {
        let key = data("expectedKey")
        let proof = confirmationProof(
            key: key,
            sessionID: required("sessionId"),
            deviceID: required("deviceId"),
            identityKey: required("identityKey")
        )
        XCTAssertEqual(proof, required("expectedConfirmationProof"))
        XCTAssertTrue(verifyConfirmationProof(
            proof,
            key: key,
            sessionID: required("sessionId"),
            deviceID: required("deviceId"),
            identityKey: required("identityKey")
        ))
        XCTAssertFalse(verifyConfirmationProof(
            proof,
            key: key,
            sessionID: required("sessionId") + "-tampered",
            deviceID: required("deviceId"),
            identityKey: required("identityKey")
        ))

        let plaintext = try decrypt(
            nonce: required("aesNonce"),
            ciphertext: required("aesCiphertext"),
            key: key
        )
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), required("aesPlaintext"))
        var tampered = data("aesCiphertext")
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        XCTAssertThrowsError(try decrypt(
            nonce: required("aesNonce"),
            ciphertext: tampered.base64EncodedString(),
            key: key
        ))
    }

    private func loadVector() -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/crypto-v1.properties")
            .standardizedFileURL
        let content = try! String(contentsOf: url, encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: content.split(whereSeparator: { $0.isNewline }).map { line in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]), String(pair[1]))
        })
    }

    private func required(_ key: String) -> String {
        guard let value = vector[key] else { XCTFail("Missing test vector property: \(key)"); return "" }
        return value
    }

    private func data(_ key: String) -> Data {
        guard let value = Data(base64Encoded: required(key)) else {
            XCTFail("Invalid base64 test vector property: \(key)")
            return Data()
        }
        return value
    }
}
