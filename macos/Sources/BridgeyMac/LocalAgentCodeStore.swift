import Darwin
import Foundation

/// Mac-only preferences. Deliberately absent from SyncKey and the phone/agent wire protocol.
struct LocalAgentCodeOptions: Equatable {
    var enabled = false
    var minutes = 10
    var blockedSenders = Self.defaultBlockedSenders

    // Substrings of the sender, app name or package, ignoring punctuation and case. Include
    // common Indian DLT sender abbreviations as well as bank/payment app names.
    static let defaultBlockedSenders = [
        "bank", "payment", "upi", "card", "hdfc", "hdfcbk", "icici", "icicib", "sbi", "sbin",
        "axis", "axisbk", "kotak", "kbnk", "idfc", "idfcbk", "indusind", "indusb", "yesbnk",
        "pnb", "canara", "cnrb", "bob", "baroda", "union", "unionb", "aubank", "aubnkl",
        "federal", "fedbnk", "rbl", "rblbnk", "idbi", "indianb", "iob", "ucobank", "ucobnk",
        "bandhan", "bndbnk", "equitas", "equibn", "ujjivan", "ujjivn", "jupiter", "fi.money",
        "phonepe", "paytm", "googlepay", "gpay", "com.google.android.apps.nbu.paisa", "bhim",
        "amazonpay", "bharatpe", "cred", "mobikwik", "freecharge", "paypal", "razorpay",
        "cashfree", "cshfre", "payu", "slice", "simpl", "lazypay", "visa", "mastercard", "amex",
        "americanexpress", "citi", "hsbc", "standardchartered", "scbank", "chase", "wellsfargo"
    ]
    static let prefix = "localAgentCodes."

    init() {}
    init(defaults: UserDefaults) {
        enabled = defaults.bool(forKey: Self.prefix + "enabled")
        let saved = defaults.object(forKey: Self.prefix + "minutes") as? Int ?? 10
        minutes = (1...30).contains(saved) ? saved : 10
        blockedSenders = defaults.stringArray(forKey: Self.prefix + "blockedSenders") ?? Self.defaultBlockedSenders
    }

    func save(to defaults: UserDefaults) {
        // Only preferences, never codes, senders of received messages, or message text.
        defaults.set(enabled, forKey: Self.prefix + "enabled")
        defaults.set(minutes, forKey: Self.prefix + "minutes")
        defaults.set(blockedSenders, forKey: Self.prefix + "blockedSenders")
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    func blocks(_ identities: [String]) -> Bool {
        let identities = identities.map(Self.normalized)
        return blockedSenders.contains { rule in
            let rule = Self.normalized(rule)
            return !rule.isEmpty && identities.contains { $0.contains(rule) }
        }
    }
}

/// A locked allocation keeps retained code bytes out of swap. Fail closed if mlock fails.
/// Swift strings are made only for the immediate socket response; nothing here serializes to disk.
private final class LocalCodeBytes {
    let pointer: UnsafeMutableRawPointer
    let count: Int
    private let allocationSize = Int(getpagesize())
    init?(_ code: String) {
        count = code.utf8.count
        guard (1...32).contains(count) else { return nil }
        guard let allocation = mmap(nil, allocationSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              allocation != MAP_FAILED else { return nil }
        pointer = allocation
        guard mlock(pointer, allocationSize) == 0 else { munmap(pointer, allocationSize); return nil }
        for (index, byte) in code.utf8.enumerated() { pointer.storeBytes(of: byte, toByteOffset: index, as: UInt8.self) }
    }
    var string: String { String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self) }
    deinit {
        explicit_bzero(pointer, allocationSize)
        munlock(pointer, allocationSize)
        munmap(pointer, allocationSize)
    }
}

struct LocalAgentCode: Codable, Equatable {
    let sender: String
    let code: String
    let expiresInSeconds: Int
}

/// The socket and notification pipeline share this store. Expiry runs even without reads.
/// The continuous clock advances during sleep and cannot be extended by changing the wall clock.
final class LocalAgentCodeStore: @unchecked Sendable {
    private struct Entry {
        let sender: String
        let bytes: LocalCodeBytes
        let received: TimeInterval
        let posted: Date
        let deadline: TimeInterval
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var options = LocalAgentCodeOptions()
    private let now: () -> TimeInterval
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.local-codes.expiry")
    private var expiry: DispatchWorkItem?

    init(now: @escaping () -> TimeInterval = LocalAgentCodeStore.continuousSeconds) { self.now = now }

    static func continuousSeconds() -> TimeInterval {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        return Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1_000_000_000
    }

    func configure(_ options: LocalAgentCodeOptions) {
        lock.lock(); defer { lock.unlock() }
        guard options != self.options else { return }
        self.options = options
        entries.removeAll() // Off, a shorter lifetime or a new block rule takes effect immediately.
        scheduleLocked()
    }

    func retain(code: String, sender: String, identities: [String], posted: Date, age: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        let key = LocalAgentCodeOptions.normalized(sender)
        let lifetime = TimeInterval(max(1, min(30, options.minutes)) * 60)
        guard options.enabled, !key.isEmpty, !options.blocks(identities + [sender]),
              age.isFinite, age >= 0, age < lifetime else { return }
        if let old = entries[key] {
            // A replay or duplicate never extends retention or replaces a newer phone message.
            guard posted > old.posted, old.bytes.string != code else { return }
        }
        guard let bytes = LocalCodeBytes(code) else { return }
        if entries.count >= 128, entries[key] == nil,
           let oldest = entries.min(by: { $0.value.received < $1.value.received })?.key { entries.removeValue(forKey: oldest) }
        let time = now()
        entries[key] = Entry(sender: sender, bytes: bytes, received: time, posted: posted, deadline: time + lifetime - age)
        scheduleLocked()
    }

    func read() -> [LocalAgentCode] {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        guard options.enabled else { return [] }
        let time = now()
        return entries.values.sorted { $0.received > $1.received }.map {
            LocalAgentCode(sender: $0.sender, code: $0.bytes.string, expiresInSeconds: max(0, Int(($0.deadline - time).rounded(.up))))
        }
    }

    // Metadata only, useful for tests of the idle expiry without materializing a code.
    var retainedCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    private func pruneLocked() {
        let time = now()
        entries = entries.filter { $0.value.deadline > time }
    }

    private func scheduleLocked() {
        expiry?.cancel()
        expiry = nil
        guard let deadline = entries.values.map(\.deadline).min() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.pruneLocked()
            self.scheduleLocked()
        }
        expiry = work
        queue.asyncAfter(deadline: .now() + max(0.001, deadline - now()), execute: work)
    }
    deinit { expiry?.cancel() }
}
