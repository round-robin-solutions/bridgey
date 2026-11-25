import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

/// protocol/test-vectors/files-resume-v1.json (draft files_resume_draft1), checked with this app's own code: the
/// prefix hashes and the running hash's block checkpoints, both payloads, the receiver's and the sender's decisions,
/// retention, and the designed folder rules. rust/client and Android check the same vectors.
final class FileResumeVectorTests: XCTestCase {
    private static let vector: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/files-resume-v1.json").standardizedFileURL
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }()

    private var v: [String: Any] { Self.vector }

    private func cases(_ key: String) throws -> [[String: Any]] { try XCTUnwrap(v[key] as? [[String: Any]], key) }

    private func source() throws -> Data {
        let source = try XCTUnwrap(v["source"] as? [String: Any])
        XCTAssertEqual(source["pattern"] as? String, "byte i is (i * 31) mod 251")
        return pattern(try XCTUnwrap(source["size"] as? Int))
    }

    private func pattern(_ count: Int) -> Data { Data((0..<count).map { UInt8(($0 * 31) % 251) }) }

    private func sha(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }

    private func temporaryDirectory(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-resume-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A plaintext as each case gives it: `plaintextString` byte for byte, else `plaintext` through this platform's encoder.
    private func plaintext(_ c: [String: Any]) throws -> Data {
        if let string = c["plaintextString"] as? String { return Data(string.utf8) }
        return try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["plaintext"]))
    }

    private func jsonEqual(_ a: Data, _ b: Any) throws -> Bool {
        let left = try XCTUnwrap(JSONSerialization.jsonObject(with: a) as? NSDictionary)
        return left.isEqual(try XCTUnwrap(b as? NSDictionary))
    }

    func testLimitsMatchThisApp() throws {
        let limits = try XCTUnwrap(v["limits"] as? [String: Any])
        XCTAssertEqual(limits["blockBytes"] as? Int64, FileResume.block)
        XCTAssertEqual(limits["lifetimeMs"] as? Int64, FileResume.lifetimeMilliseconds)
        XCTAssertEqual(limits["perDevice"] as? Int, FileResume.perDevice)
        XCTAssertEqual(limits["total"] as? Int, FileResume.total)
        XCTAssertEqual(limits["maxKeptBytes"] as? Int64, FileResume.maximumKeptBytes)
        XCTAssertEqual(limits["maxPlaintextBytes"] as? Int, FileResume.maximumMessage)
        XCTAssertEqual(limits["checkpointEveryBytes"] as? Int64, FileResume.checkpointEvery)
        XCTAssertEqual(limits["resumableAbove"] as? Int64, FileResume.block)
        XCTAssertEqual(limits["answerWithinSeconds"] as? Double, FileResume.answerWindow)
        XCTAssertFalse(FileResume.isResumable(size: FileResume.block))
        XCTAssertTrue(FileResume.isResumable(size: FileResume.block + 1))
    }

    func testPrefixHashesAndBlockCheckpointsMatch() throws {
        let data = try source()
        let whole = try XCTUnwrap((v["source"] as? [String: Any])?["sha256"] as? String)
        XCTAssertEqual(sha(data), whole)
        let directory = try temporaryDirectory("prefix")
        let file = directory.appendingPathComponent("source.bin")
        try data.write(to: file)
        for p in try cases("prefixes") {
            let offset = try XCTUnwrap(p["offset"] as? Int64)
            let expected = try XCTUnwrap(p["prefixSha256"] as? String)
            let (hasher, digest) = try FileResume.hashPrefix(of: file, length: offset)
            XCTAssertEqual(digest.base64EncodedString(), expected, "prefix \(offset)")
            // The hasher read again continues to the whole file's SHA-256.
            var running = ResumeHasher(resumed: hasher, length: offset, digest: digest)
            running.update(data.subdata(in: Int(offset)..<data.count))
            XCTAssertEqual(running.finalize().base64EncodedString(), whole, "continued from \(offset)")
        }
        XCTAssertThrowsError(try FileResume.hashPrefix(of: file, length: Int64(data.count) + 1), "a file shorter than the record fails")
        // The sender's pass keeps every block; the receiver's running hash checkpoints at them, piece by odd piece.
        var sender = ResumeHasher(keepBlocks: true)
        sender.update(data)
        let blocks = try XCTUnwrap(sender.blocks)
        XCTAssertEqual(Int64(blocks.count), Int64(data.count) / FileResume.block)
        for p in try cases("prefixes") {
            let offset = try XCTUnwrap(p["offset"] as? Int64)
            let kept = offset == Int64(data.count) ? sender.finalize() : FileResume.blockPrefix(blocks, offset: offset)
            XCTAssertEqual(kept?.base64EncodedString(), p["prefixSha256"] as? String, "block hash at \(offset)")
        }
        XCTAssertNil(FileResume.blockPrefix(blocks, offset: FileResume.block + 1))
        XCTAssertNil(FileResume.blockPrefix(blocks, offset: 0))
        XCTAssertNil(FileResume.blockPrefix(blocks, offset: 4 * FileResume.block))
        var receiver = ResumeHasher(keepBlocks: false)
        var start = 0
        while start < data.count {
            let end = min(data.count, start + 24 * 1024 + 7)
            receiver.update(data.subdata(in: start..<end))
            start = end
            let (at, digest) = receiver.checkpoint(size: Int64(data.count))
            XCTAssertTrue(at == Int64(data.count) || at % FileResume.block == 0)
            XCTAssertEqual(digest, Data(SHA256.hash(data: data.prefix(Int(at)))))
        }
    }

    func testResumePayloadsDecodeAsTheVectorsSay() throws {
        var checked = 0
        for c in try cases("resumePayload") {
            let name = try XCTUnwrap(c["name"] as? String)
            let transferID = try XCTUnwrap(c["transferId"] as? String)
            let size = try XCTUnwrap(c["size"] as? Int64)
            let decoded = FileResume.parseResume(try plaintext(c), transferID: transferID, size: size)
            if c["expect"] as? String == "invalid" {
                XCTAssertNil(decoded, name)
            } else {
                let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
                let got = try XCTUnwrap(decoded, name)
                XCTAssertEqual(got.offset, expect["offset"] as? Int64, name)
                XCTAssertEqual(got.prefix.base64EncodedString(), expect["prefixSha256"] as? String, name)
                if c["write"] as? Bool == true {
                    let written = FileResume.resumePayload(transferID: transferID, offset: got.offset, prefix: got.prefix)
                    XCTAssertTrue(try jsonEqual(written, try XCTUnwrap(c["plaintext"])), "\(name) writes the same fields")
                }
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 10)
    }

    func testAcksDecodeAsTheVectorsSay() throws {
        for c in try cases("ackPayload") {
            let name = try XCTUnwrap(c["name"] as? String)
            let transferID = try XCTUnwrap(c["transferId"] as? String)
            let proposed = try XCTUnwrap(c["proposed"] as? Int64)
            let got = FileResume.parseAck(try plaintext(c), transferID: transferID, proposed: proposed)
            switch try XCTUnwrap(c["expect"] as? String) {
            case "invalid": XCTAssertNil(got, name)
            case "resume": XCTAssertEqual(got, proposed, name)
            case "restart": XCTAssertEqual(got, 0, name)
            case let other: XCTFail("\(name): \(other)")
            }
            if c["write"] as? Bool == true {
                let p = try XCTUnwrap(c["plaintext"] as? [String: Any])
                let written = FileResume.ackPayload(transferID: try XCTUnwrap(p["transferId"] as? String), offset: try XCTUnwrap(p["offset"] as? Int64),
                                                    reason: p["reason"] as? String)
                XCTAssertTrue(try jsonEqual(written, p), "\(name) writes the same fields")
            }
        }
    }

    /// The receiver's decision for an offer from its record and what is on disk, the way the app makes it: the
    /// store's claim (after a reload and sweep when the vector says so), then the kept partial reopened and read again.
    func testReceiverDecisionsFollowTheVectors() throws {
        let data = try source()
        for c in try cases("receiverDecision") {
            let name = try XCTUnwrap(c["name"] as? String)
            let directory = try temporaryDirectory("decide")
            let r = try XCTUnwrap(c["record"] as? [String: Any])
            let o = try XCTUnwrap(c["offer"] as? [String: Any])
            let part = "photo.jpg\(FileResume.partSuffix)"
            var onDisk = data.prefix(try XCTUnwrap(r["partLength"] as? Int))
            if let flip = r["flipByte"] as? Int { onDisk[flip] ^= 0xFF }
            if r["partExists"] as? Bool != false { try Data(onDisk).write(to: directory.appendingPathComponent(part)) }
            let record = ResumeRecord(peer: try XCTUnwrap(r["peer"] as? String), size: try XCTUnwrap(r["size"] as? Int64),
                                      sha256: try XCTUnwrap(r["sha256"] as? String), length: try XCTUnwrap(r["length"] as? Int64),
                                      prefix: try XCTUnwrap(r["prefixSha256"] as? String), dir: directory.path, part: part,
                                      name: try XCTUnwrap(r["name"] as? String), updated: 0)
            var now = try XCTUnwrap(r["updatedMs"] as? Int64)
            let recordsURL = directory.appendingPathComponent("records/file-resume.json")
            var partials = ResumePartials(fileURL: recordsURL, now: { now })
            partials.save(record)
            partials.release(record.partURL, keep: true)
            now = try XCTUnwrap(c["nowMs"] as? Int64)
            if c["afterRestart"] as? Bool == true {
                partials = ResumePartials(fileURL: recordsURL, now: { now })
                partials.load()
            }
            let offer = FileOfferPayload(transferId: UUID().uuidString.lowercased(), name: try XCTUnwrap(o["name"] as? String), mimeType: "image/jpeg",
                                         size: try XCTUnwrap(o["size"] as? Int64), sha256: try XCTUnwrap(o["sha256"] as? String), resumable: LenientFlag(true))
            let access = ReceiveDirectoryAccess(url: directory, scoped: false)
            let transfer = try XCTUnwrap(partials.openIncoming(offer, from: try XCTUnwrap(o["peer"] as? String), access: access, resumable: true), name)
            var resumeAt: Int64?
            if case let .checking(length, _) = transfer.phase {
                let result = try? FileResume.hashPrefix(of: transfer.partialURL, length: length)
                if case let .propose(offset, _) = transfer.applyCheck(result) { resumeAt = offset }
            }
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            XCTAssertEqual(resumeAt, expect["resumeAt"] as? Int64, "\(name): resume offset")
            if let dropped = expect["dropsRecord"] as? Bool {
                // The kept record, not one a fresh part of the same name starts with (nothing verified, or other content).
                let kept = partials.store.records.contains { $0.part == part && $0.sha256 == record.sha256 && $0.length == record.length }
                XCTAssertEqual(!kept, dropped, "\(name): the record is dropped")
            }
            partials.drop(transfer)
        }
    }

    /// The sender's answer to a files.resume, from the hashes kept while hashing for the offer and by reading again.
    func testSenderDecisionsFollowTheVectors() throws {
        let data = try source()
        let directory = try temporaryDirectory("sender")
        for c in try cases("senderDecision") {
            let name = try XCTUnwrap(c["name"] as? String)
            var file = data
            if let flip = c["senderFlipByte"] as? Int { file[flip] ^= 0xFF }
            if let length = c["senderLength"] as? Int { file = file.prefix(length) }
            let url = directory.appendingPathComponent("source-\(UUID().uuidString).bin")
            try file.write(to: url)
            let transferID = try XCTUnwrap(c["transferId"] as? String)
            let plain = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["resume"]))
            // The app's own sender: hashed once for the offer, block hashes kept, the answer checks the file can seek.
            let outgoing = try OutgoingFileTransfer(url: url, transferID: transferID, cancellation: FileCancellationToken())
            let (offset, reason) = outgoing.resumeAnswer(plain)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            XCTAssertEqual(offset, expect["offset"] as? Int64, name)
            XCTAssertEqual(reason, expect["reason"] as? String, name)
            // Reading the prefix again gives the same answer.
            let reread: (Int64, String?)
            if let (n, prefix) = FileResume.parseResume(plain, transferID: transferID, size: Int64(file.count)) {
                let digest = try? FileResume.hashPrefix(of: url, length: n).digest
                reread = digest.map { FileResume.equalInConstantTime($0, prefix) } == true ? (n, nil) : (0, "mismatch")
            } else {
                reread = (0, "invalid")
            }
            XCTAssertEqual(reread.0, offset, "\(name): read again")
            XCTAssertEqual(reread.1, reason, "\(name): read again")
        }
    }

    func testRetentionFollowsTheVectors() throws {
        for c in try cases("retention") {
            let name = try XCTUnwrap(c["name"] as? String)
            var store = ResumeStore()
            var labels: [String: String] = [:]
            func record(_ peer: String, _ n: Int, length: Int64?) -> ResumeRecord {
                let len = length ?? 10
                return ResumeRecord(peer: peer, size: max(1000 + Int64(n), len), sha256: Data(SHA256.hash(data: Data("\(n)".utf8))).base64EncodedString(),
                                    length: len, prefix: Data(SHA256.hash(data: Data("x".utf8))).base64EncodedString(), dir: "/nonexistent",
                                    part: "\(UUID().uuidString)\(FileResume.partSuffix)", name: "file\(n).bin", updated: 0)
            }
            for k in try XCTUnwrap(c["kept"] as? [[String: Any]]) {
                let r = record(try XCTUnwrap(k["peer"] as? String), try XCTUnwrap(k["n"] as? Int), length: k["length"] as? Int64)
                labels[r.key] = try XCTUnwrap(k["label"] as? String)
                _ = store.save(r, now: try XCTUnwrap(k["updatedMs"] as? Int64))
                if k["inUse"] as? Bool != true { store.release(r.partURL, keep: true) }
            }
            let n = try XCTUnwrap(c["new"] as? [String: Any])
            let added = record(try XCTUnwrap(n["peer"] as? String), 9999, length: n["length"] as? Int64)
            let gone = store.save(added, now: try XCTUnwrap(n["updatedMs"] as? Int64)).map { labels[$0.standardizedFileURL.path] ?? "?" }
            XCTAssertEqual(gone, try XCTUnwrap(c["evicted"] as? [String]), name)
        }
    }

    /// Folders are designed, not built: these restate docs/protocol.md, as rust/client's test does.
    func testFolderVectorsFollowTheDesignedRules() throws {
        for c in try cases("folderAccept") {
            let name = try XCTUnwrap(c["name"] as? String)
            let sizes = try XCTUnwrap(c["entrySizes"] as? [String: Int64])
            let decoded: [String: Any]??
            if c["partial"] is NSNull || c["partial"] == nil {
                decoded = .some(nil)
            } else {
                let p = try XCTUnwrap(c["partial"] as? [String: Any])
                if let entry = jsonInteger(p["entry"]), entry >= 0, let size = sizes[String(entry)], let offset = jsonInteger(p["offset"]).map(Int64.init),
                   offset >= 1, offset <= size, offset % FileResume.block == 0 || offset == size,
                   let prefix = (p["prefixSha256"] as? String).flatMap({ Data(base64Encoded: $0) }), prefix.count == 32 {
                    decoded = .some(["entry": entry, "offset": offset, "prefixSha256": prefix.base64EncodedString()])
                } else {
                    decoded = nil
                }
            }
            switch (c["expect"], decoded) {
            case let (expect as String, .some(nil)) where expect == "none": break
            case let (expect as String, nil) where expect == "invalid": break
            case let (expect as [String: Any], .some(.some(got))):
                XCTAssertEqual(got["entry"] as? Int, expect["entry"] as? Int, name)
                XCTAssertEqual(got["offset"] as? Int64, expect["offset"] as? Int64, name)
                XCTAssertEqual(got["prefixSha256"] as? String, expect["prefixSha256"] as? String, name)
            default: XCTFail("\(name): expected \(String(describing: c["expect"])), got \(String(describing: decoded))")
            }
        }
        for c in try cases("entryOffer") {
            let name = try XCTUnwrap(c["name"] as? String)
            let partial = c["receiverPartial"] as? [String: Any]
            let offer = try XCTUnwrap(c["entryOffer"] as? [String: Any])
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let sameEntry = partial != nil && jsonInteger(partial?["entry"]) == jsonInteger(offer["entry"])
            if let offset = jsonInteger(offer["offset"]) {
                if sameEntry, jsonInteger(partial?["offset"]) == offset, let size = jsonInteger(offer["size"]), offset <= size {
                    XCTAssertEqual(jsonInteger(expect["startAt"]), offset, name)
                } else {
                    XCTAssertEqual(expect["entryFailed"] as? String, "invalid_message", name)
                }
            } else {
                XCTAssertEqual(jsonInteger(expect["startAt"]), 0, name)
                XCTAssertEqual(expect["discardsPartial"] as? Bool ?? false, sameEntry, name)
            }
        }
    }

    func testRecordsSurviveEncodingAndBadOnesAreDropped() throws {
        let good = ResumeRecord(peer: "7e57d00d-0000-4000-8000-0000000000aa", size: 2000, sha256: sha(Data("a".utf8)), length: 10,
                                prefix: sha(Data("b".utf8)), dir: "/tmp/received", part: "photo.jpg.bridgey-part", name: "photo.jpg", updated: 5)
        var store = ResumeStore()
        _ = store.save(good, now: 5)
        XCTAssertEqual(ResumeStore.decode(store.encode()).records, store.records)
        func encoded(_ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
            change(&object)
            return object
        }
        let records: [[String: Any]] = [
            try encoded { $0["part"] = "../../etc/passwd" },
            try encoded { $0["part"] = "photo.jpg" },
            try encoded { $0["prefix"] = "AAAA" },
            try encoded { $0["length"] = 2001 },
            try encoded { $0["peer"] = "not a device" },
            try encoded { $0["dir"] = "relative/dir" },
            try encoded { $0["size"] = "2000" },
            try encoded { _ in },
        ]
        let document = try JSONSerialization.data(withJSONObject: ["version": 1, "records": records])
        XCTAssertEqual(ResumeStore.decode(document).records.count, 1, "only the valid record is kept")
        XCTAssertTrue(ResumeStore.decode(Data(#"{"version":2,"records":[]}"#.utf8)).records.isEmpty)
        XCTAssertTrue(ResumeStore.decode(Data("not json".utf8)).records.isEmpty)
        XCTAssertTrue(ResumeStore.decode(nil).records.isEmpty)
    }

    func testClaimsArePerDeviceInTheReceiveFolderAndOneAtATime() throws {
        let peer = "7e57d00d-0000-4000-8000-0000000000aa", other = "7e57d00d-0000-4000-8000-0000000000bb"
        let record = ResumeRecord(peer: peer, size: 2000, sha256: sha(Data("a".utf8)), length: 10, prefix: sha(Data("b".utf8)),
                                  dir: "/tmp/received", part: "photo.jpg.bridgey-part", name: "photo.jpg", updated: 0)
        var store = ResumeStore()
        _ = store.save(record, now: 100)
        store.release(record.partURL, keep: true)
        let dir = URL(fileURLWithPath: "/tmp/received", isDirectory: true)
        XCTAssertNil(store.claim(peer: other, size: 2000, sha256: record.sha256, name: "photo.jpg", dir: dir, now: 200).0, "another device never gets it")
        XCTAssertEqual(store.records.count, 1, "nor does it disturb it")
        XCTAssertEqual(store.claim(peer: peer.uppercased(), size: 2000, sha256: record.sha256, name: "photo.jpg", dir: dir, now: 200).0?.part, record.part)
        let again = store.claim(peer: peer, size: 2000, sha256: record.sha256, name: "photo.jpg", dir: dir, now: 200)
        XCTAssertTrue(again.0 == nil && again.1.isEmpty, "a partial in use serves one transfer")
        store.release(record.partURL, keep: true)
        XCTAssertNil(store.claim(peer: peer, size: 2000, sha256: record.sha256, name: "photo.jpg", dir: URL(fileURLWithPath: "/elsewhere"), now: 200).0,
                     "only in the folder files land in now")
        XCTAssertTrue(store.records.isEmpty, "the same content arriving elsewhere lets the old partial go, as in rust/client")
        // Forgetting a device takes only its partials.
        var theirs = record
        theirs.peer = other
        theirs.part = "theirs.jpg.bridgey-part"
        for r in [record, theirs] {
            _ = store.save(r, now: 300)
            store.release(r.partURL, keep: true)
        }
        XCTAssertEqual(store.forget(peer: peer).map(\.lastPathComponent), ["photo.jpg.bridgey-part"])
        XCTAssertEqual(store.records.map(\.peer), [other])
    }
}
