import CBlake3
import CryptoKit
import Darwin
import Foundation

let benchBlockBytes = 1 << 20
let benchQuickBytes: Int64 = 256 * 1024 * 1024
let benchFullBytes: Int64 = 1024 * 1024 * 1024
let benchTargetBytes: Int64 = 10_000_000_000

enum BenchMode: String, CaseIterable, Codable {
    case writeOnly = "write_only"
    case blake3Block = "blake3_block"
    case blake3BlockReadback = "blake3_block_readback"
    case blake3WholeEnd = "blake3_whole_end"
    case sha256Block = "sha256_block"

    var english: String {
        switch self {
        case .writeOnly: "1. Write only"
        case .blake3Block: "2. Write + BLAKE3 per 1 MiB block"
        case .blake3BlockReadback: "3. Mode 2 + read back and hash again"
        case .blake3WholeEnd: "4. Write, then one BLAKE3 of the whole file"
        case .sha256Block: "5. Write + SHA-256 per 1 MiB block (comparison)"
        }
    }

    var title: String {
        switch self {
        case .writeOnly: L10n.text("perf.mode.write_only", fallback: english)
        case .blake3Block: L10n.text("perf.mode.blake3_block", fallback: english)
        case .blake3BlockReadback: L10n.text("perf.mode.blake3_readback", fallback: english)
        case .blake3WholeEnd: L10n.text("perf.mode.blake3_whole", fallback: english)
        case .sha256Block: L10n.text("perf.mode.sha256_block", fallback: english)
        }
    }
}

/// Free space the test needs: two copies of the file plus 1 GiB of headroom.
func benchRequiredFreeBytes(_ fileBytes: Int64) -> Int64 { 2 * fileBytes + 1024 * 1024 * 1024 }
func benchHasEnoughSpace(free: Int64, fileBytes: Int64) -> Bool { free >= benchRequiredFreeBytes(fileBytes) }

struct BenchModeResult: Equatable {
    let mode: BenchMode
    let bytes: Int64
    let wallSeconds: Double
    let cpuSeconds: Double
    var verifyMismatches = 0

    /// Decimal megabytes per second.
    var mbPerSecond: Double { wallSeconds > 0 ? Double(bytes) / 1e6 / wallSeconds : 0 }
}

/// A mode scaled to 10 GB, and its cost on top of the write-only baseline.
struct BenchExtrapolation: Equatable {
    let mode: BenchMode
    let wallSeconds: Double
    let cpuSeconds: Double
    let extraWallSeconds: Double
    let extraCpuSeconds: Double
}

func benchExtrapolate(baseline: BenchModeResult, result: BenchModeResult, target: Int64 = benchTargetBytes) -> BenchExtrapolation {
    func scale(_ v: Double, _ bytes: Int64) -> Double { v * Double(target) / Double(bytes) }
    let wall = scale(result.wallSeconds, result.bytes)
    let cpu = scale(result.cpuSeconds, result.bytes)
    return BenchExtrapolation(
        mode: result.mode, wallSeconds: wall, cpuSeconds: cpu,
        extraWallSeconds: wall - scale(baseline.wallSeconds, baseline.bytes),
        extraCpuSeconds: cpu - scale(baseline.cpuSeconds, baseline.bytes))
}

struct BenchReport {
    let sizeBytes: Int64
    let startedAt: Date
    let device: String
    let appVersion: String
    let vectorsPassed: Bool
    let readNote: String
    let results: [BenchModeResult]

    static let implementation = "Native BLAKE3 1.8.7 (official C, NEON on arm64) via SwiftPM; SHA-256 via CryptoKit"

    var extrapolations: [BenchExtrapolation] {
        guard let base = results.first(where: { $0.mode == .writeOnly }) else { return [] }
        return results.filter { $0.mode != .writeOnly }.map { benchExtrapolate(baseline: base, result: $0) }
    }

    func jsonString() -> String {
        var root: [String: Any] = [
            "schema": 1, "app": "Bridgey by Round Robin", "appVersion": appVersion, "device": device,
            "startedAtEpochMillis": Int64(startedAt.timeIntervalSince1970 * 1000), "fileBytes": sizeBytes,
            "blockBytes": benchBlockBytes, "hashImplementation": Self.implementation, "nativeBlake3": true,
            "blake3VectorsPassed": vectorsPassed, "readNote": readNote,
            "energyNote": "Mac power metrics need root, so only CPU time is reported.",
        ]
        root["modes"] = results.map { r -> [String: Any] in
            ["mode": r.mode.rawValue, "bytes": r.bytes, "wallSeconds": r.wallSeconds, "mbPerSecond": r.mbPerSecond,
             "cpuSeconds": r.cpuSeconds, "verifyMismatches": r.verifyMismatches]
        }
        root["per10GbExtraOverWriteOnly"] = extrapolations.map { e -> [String: Any] in
            ["mode": e.mode.rawValue, "per10GbWallSeconds": e.wallSeconds, "per10GbCpuSeconds": e.cpuSeconds,
             "extraWallSeconds": e.extraWallSeconds, "extraCpuSeconds": e.extraCpuSeconds]
        }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func text() -> String {
        var s = "Bridgey performance test, \(device), \(appVersion)\n"
        s += "\(Self.implementation); test vectors \(vectorsPassed ? "pass" : "FAIL"); file \(sizeBytes / (1024 * 1024)) MiB, block 1 MiB\n\n"
        for r in results {
            s += String(format: "%@: %.2f s, %.0f MB/s, CPU %.2f s", r.mode.english, r.wallSeconds, r.mbPerSecond, r.cpuSeconds)
            if r.verifyMismatches > 0 { s += ", MISMATCHES \(r.verifyMismatches)" }
            s += "\n"
        }
        s += "\nExtra per 10 GB over write only\n"
        for e in extrapolations {
            s += String(format: "%@: %+.1f s, %+.1f CPU s\n", e.mode.english, e.extraWallSeconds, e.extraCpuSeconds)
        }
        return s + "\n" + readNote + "\nEnergy: Mac power metrics need root, so only CPU time is reported.\n"
    }
}

// MARK: - Hashers

protocol BlockHasher: AnyObject {
    func reset()
    func update(_ pointer: UnsafeRawPointer, _ count: Int)
    func digest() -> [UInt8]
}

final class Blake3BlockHasher: BlockHasher {
    private var state = blake3_hasher()
    init() { blake3_hasher_init(&state) }
    func reset() { blake3_hasher_reset(&state) }
    func update(_ pointer: UnsafeRawPointer, _ count: Int) { blake3_hasher_update(&state, pointer, count) }
    func digest() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(BLAKE3_OUT_LEN))
        blake3_hasher_finalize(&state, &out, out.count)
        return out
    }
}

final class Sha256BlockHasher: BlockHasher {
    private var state = SHA256()
    func reset() { state = SHA256() }
    func update(_ pointer: UnsafeRawPointer, _ count: Int) { state.update(bufferPointer: UnsafeRawBufferPointer(start: pointer, count: count)) }
    func digest() -> [UInt8] { Array(state.finalize()) }
}

/// Official BLAKE3 test vectors: input byte i is (i mod 251); expected is the first 32 output bytes.
enum Blake3Vectors {
    static let cases: [(Int, String)] = [
        (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
        (1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"),
        (2, "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63"),
        (3, "e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f"),
        (4, "f30f5ab28fe047904037f77b6da4fea1e27241c5d132638d8bedce9d40494f32"),
        (5, "b40b44dfd97e7a84a996a91af8b85188c66c126940ba7aad2e7ae6b385402aa2"),
        (6, "06c4e8ffb6872fad96f9aaca5eee1553eb62aed0ad7198cef42e87f6a616c844"),
        (7, "3f8770f387faad08faa9d8414e9f449ac68e6ff0417f673f602a646a891419fe"),
        (8, "2351207d04fc16ade43ccab08600939c7c1fa70a5c0aaca76063d04c3228eaeb"),
        (63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b"),
        (64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"),
        (65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee"),
        (127, "d81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d"),
        (128, "f17e570564b26578c33bb7f44643f539624b05df1a76c81f30acd548c44b45ef"),
        (129, "683aaae9f3c5ba37eaaf072aed0f9e30bac0865137bae68b1fde4ca2aebdcb12"),
        (1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"),
        (1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
        (1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
        (2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"),
        (2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"),
        (3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"),
        (3073, "7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3"),
        (4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"),
        (4097, "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995"),
        (5120, "9cadc15fed8b5d854562b26a9536d9707cadeda9b143978f319ab34230535833"),
        (5121, "628bd2cb2004694adaab7bbd778a25df25c47b9d4155a55f8fbd79f2fe154cff"),
        (6144, "3e2e5b74e048f3add6d21faab3f83aa44d3b2278afb83b80b3c35164ebeca205"),
        (6145, "f1323a8631446cc50536a9f705ee5cb619424d46887f3c376c695b70e0f0507f"),
        (7168, "61da957ec2499a95d6b8023e2b0e604ec7f6b50e80a9678b89d2628e99ada77a"),
        (7169, "a003fc7a51754a9b3c7fae0367ab3d782dccf28855a03d435f8cfe74605e7817"),
        (8192, "aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63"),
        (8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"),
        (16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4"),
        (31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47"),
        (102400, "bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085"),
    ]

    static func input(_ length: Int) -> [UInt8] { (0..<length).map { UInt8($0 % 251) } }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Lengths that failed; empty when every vector passes, whole and in uneven pieces.
    static func failures(_ make: () -> BlockHasher = { Blake3BlockHasher() }) -> [Int] {
        let h = make()
        var failed: [Int] = []
        for (length, expected) in cases {
            let data = input(length)
            h.reset()
            data.withUnsafeBytes { raw in if length > 0 { h.update(raw.baseAddress!, length) } }
            var ok = hex(h.digest()) == expected
            h.reset()
            var at = 0, step = 1
            data.withUnsafeBytes { raw in
                while at < length {
                    let n = min(step, length - at)
                    h.update(raw.baseAddress! + at, n)
                    at += n
                    step = step * 3 + 1
                }
            }
            ok = ok && hex(h.digest()) == expected
            if !ok { failed.append(length) }
        }
        return failed
    }
}

// MARK: - Engine

struct BenchCancelled: Error {}
enum BenchError: Error { case io(String) }

func benchProcessCPUSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(u.ru_utime) + s(u.ru_stime)
}

func benchFreeBytes(at url: URL) -> Int64 {
    var fs = statfs()
    guard statfs(url.path, &fs) == 0 else { return 0 }
    return Int64(fs.f_bavail) * Int64(fs.f_bsize)
}

/// Writes a test file in 1 MiB blocks under each integrity mode. Hash work happens before each
/// block is written, as it would when the block arrives. Reads bypass the page cache (F_NOCACHE),
/// so read-back and the end-of-file hash pay for real disk reads.
final class HashBenchmark {
    private let dir: URL
    private let isCancelled: () -> Bool
    private let block: UnsafeMutableRawPointer
    private let readBuffer: UnsafeMutableRawPointer

    init(dir: URL, isCancelled: @escaping () -> Bool = { false }) {
        self.dir = dir
        self.isCancelled = isCancelled
        var a: UnsafeMutableRawPointer?
        var b: UnsafeMutableRawPointer?
        posix_memalign(&a, 16384, benchBlockBytes)
        posix_memalign(&b, 16384, benchBlockBytes)
        block = a!
        readBuffer = b!
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        let words = block.bindMemory(to: UInt64.self, capacity: benchBlockBytes / 8)
        for i in 0..<(benchBlockBytes / 8) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            words[i] = x
        }
    }

    deinit { free(block); free(readBuffer) }

    func runAll(fileBytes: Int64, modes: [BenchMode] = BenchMode.allCases, progress: (Double, BenchMode) -> Void = { _, _ in }) throws -> [BenchModeResult] {
        precondition(fileBytes > 0 && fileBytes % Int64(benchBlockBytes) == 0)
        var out: [BenchModeResult] = []
        for (index, mode) in modes.enumerated() {
            let file = dir.appendingPathComponent("bench-\(mode.rawValue).bin")
            defer { try? FileManager.default.removeItem(at: file) }
            out.append(try runMode(mode, file: file, fileBytes: fileBytes) { progress((Double(index) + $0) / Double(modes.count), mode) })
        }
        return out
    }

    func runMode(_ mode: BenchMode, file: URL, fileBytes: Int64, progress: (Double) -> Void = { _ in }) throws -> BenchModeResult {
        let blocks = Int(fileBytes / Int64(benchBlockBytes))
        let perBlock: BlockHasher? = switch mode {
        case .blake3Block, .blake3BlockReadback: Blake3BlockHasher()
        case .sha256Block: Sha256BlockHasher()
        default: nil
        }
        let whole: BlockHasher? = mode == .blake3WholeEnd ? Blake3BlockHasher() : nil
        var cvs = [UInt8](repeating: 0, count: perBlock == nil ? 0 : blocks * 32)
        var mismatches = 0
        try? FileManager.default.removeItem(at: file)
        let cpu0 = benchProcessCPUSeconds()
        let t0 = DispatchTime.now().uptimeNanoseconds

        let wfd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard wfd >= 0 else { throw BenchError.io("open failed: \(errno)") }
        defer { if wfd >= 0 { close(wfd) } }
        let share = (mode == .blake3BlockReadback || mode == .blake3WholeEnd) ? 0.5 : 1.0
        for i in 0..<blocks {
            if isCancelled() { throw BenchCancelled() }
            block.storeBytes(of: UInt64(i), as: UInt64.self)
            if let h = perBlock {
                h.reset()
                h.update(block, benchBlockBytes)
                cvs.replaceSubrange(i * 32 ..< i * 32 + 32, with: h.digest())
            }
            try writeFully(wfd, block, benchBlockBytes)
            progress(share * Double(i + 1) / Double(blocks))
        }
        // F_FULLFSYNC is what a durable receive would need on macOS.
        if fcntl(wfd, F_FULLFSYNC) != 0 { fsync(wfd) }

        if mode == .blake3BlockReadback, let h = perBlock {
            let rfd = try openUncached(file)
            defer { close(rfd) }
            for i in 0..<blocks {
                if isCancelled() { throw BenchCancelled() }
                try readFully(rfd, readBuffer, benchBlockBytes)
                h.reset()
                h.update(readBuffer, benchBlockBytes)
                if h.digest() != Array(cvs[i * 32 ..< i * 32 + 32]) { mismatches += 1 }
                progress(0.5 + 0.5 * Double(i + 1) / Double(blocks))
            }
        }
        if let h = whole {
            let rfd = try openUncached(file)
            defer { close(rfd) }
            for i in 0..<blocks {
                if isCancelled() { throw BenchCancelled() }
                try readFully(rfd, readBuffer, benchBlockBytes)
                h.update(readBuffer, benchBlockBytes)
                progress(0.5 + 0.5 * Double(i + 1) / Double(blocks))
            }
            _ = h.digest()
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let cpu = benchProcessCPUSeconds() - cpu0
        progress(1)
        return BenchModeResult(mode: mode, bytes: fileBytes, wallSeconds: wall, cpuSeconds: cpu, verifyMismatches: mismatches)
    }

    private func openUncached(_ file: URL) throws -> Int32 {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { throw BenchError.io("open for read failed: \(errno)") }
        _ = fcntl(fd, F_NOCACHE, 1)
        return fd
    }

    private func writeFully(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) throws {
        var done = 0
        while done < n {
            let w = write(fd, p + done, n - done)
            if w < 0 { if errno == EINTR { continue }; throw BenchError.io("write failed: \(errno)") }
            done += w
        }
    }

    private func readFully(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) throws {
        var done = 0
        while done < n {
            let r = read(fd, p + done, n - done)
            if r < 0 { if errno == EINTR { continue }; throw BenchError.io("read failed: \(errno)") }
            if r == 0 { throw BenchError.io("test file shorter than written") }
            done += r
        }
    }
}

// MARK: - Running it

enum HashBenchmarkRunner {
    static let readNote = "Reads bypass the page cache (F_NOCACHE), so read-back and the whole-file hash include real disk reads."

    static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "in.roundrobin.bridgey", isDirectory: true)
            .appendingPathComponent("perf-test", isDirectory: true)
    }

    enum Failure: Error, Equatable { case noSpace(free: Int64, needed: Int64), vectors, cancelled, io(String) }

    static func run(fileBytes: Int64, isCancelled: @escaping () -> Bool = { false }, progress: @escaping @Sendable (Double, BenchMode) -> Void = { _, _ in }) -> Result<BenchReport, Failure> {
        let dir = cacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let free = benchFreeBytes(at: dir)
        guard benchHasEnoughSpace(free: free, fileBytes: fileBytes) else { return .failure(.noSpace(free: free, needed: benchRequiredFreeBytes(fileBytes))) }
        guard Blake3Vectors.failures().isEmpty else { return .failure(.vectors) }
        do {
            let results = try HashBenchmark(dir: dir, isCancelled: isCancelled).runAll(fileBytes: fileBytes, progress: progress)
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            return .success(BenchReport(
                sizeBytes: fileBytes, startedAt: Date(), device: "\(hardwareModel()), macOS \(os)",
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
                vectorsPassed: true, readNote: readNote, results: results))
        } catch is BenchCancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.io("\(error)"))
        }
    }

    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

enum HashBenchmarkCLI {
    /// Headless run for measuring on a machine without opening the app. Prints JSON to stdout.
    static func run(full: Bool) -> Int32 {
        let bytes = full ? benchFullBytes : benchQuickBytes
        let result = HashBenchmarkRunner.run(fileBytes: bytes, progress: { fraction, mode in
            FileHandle.standardError.write(Data(String(format: "%3.0f%% %@\n", fraction * 100, mode.english).utf8))
        })
        switch result {
        case .success(let report):
            print(report.text())
            print(report.jsonString())
            return 0
        case .failure(let failure):
            FileHandle.standardError.write(Data("Benchmark failed: \(failure)\n".utf8))
            return 1
        }
    }
}
