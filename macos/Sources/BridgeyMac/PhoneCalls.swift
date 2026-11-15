import AppKit
import Foundation

/*
 * Calls window (draft dialer_draft1): each phone's status, contact search and recent calls, and the
 * calls this Mac asks the phone to start. Contacts and recent calls are asked for while the window is
 * open and kept in memory only; nothing is written to disk. A search goes to the phone a moment after
 * typing stops; an answer to an older search is dropped. The transport is a closure, so the logic is
 * tested without a phone. Names and numbers are never logged.
 */

/// One phone as the Calls window knows it.
struct CallsPhoneData: Equatable {
    var status: DialerPhoneStatus?
    var recents: [RecentCall] = []
    var recentsLoaded = false
    var recentsError: String?
    var loadingRecents = false
}

/// What the window says after a call request: it started, waits on the phone, or did not go.
struct CallsNotice: Equatable, Identifiable {
    enum Kind: Equatable {
        case sent
        case started(DialerVia)
        case confirm(DialerVia)
        case refused(DialerRefuseReason)
        /// The phone did not answer within the timeout.
        case noAnswer
    }

    let id: String
    let phoneID: String
    let kind: Kind
    var good: Bool {
        switch kind {
        case .sent, .started, .confirm: true
        case .refused, .noAnswer: false
        }
    }
}

/// What a call goes to: a number on the phone's dialer, or a WhatsApp row on the phone.
enum CallsTarget: Equatable {
    case number(String, subId: Int?)
    case whatsApp(dataID: Int, video: Bool)

    var via: DialerVia {
        switch self {
        case .number: .phone
        case let .whatsApp(_, video): video ? .whatsAppVideo : .whatsAppVoice
        }
    }
}

@MainActor
final class PhoneCalls: ObservableObject {
    static let requestTimeout: TimeInterval = 12
    /// A search goes to the phone this long after the last key.
    static let searchDelay: TimeInterval = 0.12
    /// A second call from this Mac waits this long (the phone allows one every 3 seconds).
    static let callSpacing: TimeInterval = 3

    @Published private(set) var phones: [String: CallsPhoneData] = [:]
    /// The phone's contacts for the current search.
    @Published private(set) var contacts: [DialerContact] = []
    @Published private(set) var contactsQuery = ""
    @Published private(set) var contactsError: String?
    @Published private(set) var searching = false
    /// A call this Mac asked for, until the phone answers.
    @Published private(set) var calling: CallsTarget?
    @Published private(set) var notice: CallsNotice?

    var send: (_ phoneID: String, _ kind: String, _ payload: [String: Any]) -> Bool = { _, _, _ in false }
    /// The Calls window is on here and on the phone for each other, and the phone is connected.
    var isAvailable: (_ phoneID: String) -> Bool = { _ in false }
    /// Settings > Calls > Calls window > Recent calls.
    var recentCount: () -> Int = { 20 }
    var now: () -> Date = Date.init
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    var newRequestID: () -> String = { UUID().uuidString.lowercased() }

    private enum Pending: Equatable {
        case contacts(phoneID: String, query: String)
        case recents(phoneID: String)
        case call(phoneID: String, target: CallsTarget)

        var phoneID: String {
            switch self {
            case let .contacts(id, _), let .recents(id), let .call(id, _): id
            }
        }
    }

    private var pending: [String: Pending] = [:]
    private var searchGeneration = 0
    private var lastCallAt: Date?

    func data(_ phoneID: String) -> CallsPhoneData { phones[phoneID] ?? CallsPhoneData() }

    // MARK: Lifecycle

    /// The phone stopped allowing this Mac, or this Mac turned the window off: what was kept goes.
    func forget(_ phoneID: String) {
        disconnected(phoneID)
        phones.removeValue(forKey: phoneID)
        if notice?.phoneID == phoneID { notice = nil }
    }

    func deleteAll() {
        for id in Array(phones.keys) { forget(id) }
        pending.removeAll()
        contacts = []
        contactsQuery = ""
        contactsError = nil
        searching = false
        calling = nil
    }

    /// The session ended: requests in flight are dropped; the status goes until the phone sends it again.
    func disconnected(_ phoneID: String) {
        for (id, request) in pending where request.phoneID == phoneID {
            pending.removeValue(forKey: id)
            if case .call = request { calling = nil }
            if case .contacts = request { searching = false }
        }
        guard var phone = phones[phoneID] else { return }
        phone.status = nil
        phone.loadingRecents = false
        phones[phoneID] = phone
    }

    // MARK: Requests

    /// Recent calls, when the window opens or after a call.
    func loadRecents(_ phoneID: String) {
        guard isAvailable(phoneID), data(phoneID).status?.recents == .on else { return }
        guard !pending.values.contains(.recents(phoneID: phoneID)) else { return }
        let requestID = newRequestID()
        guard send(phoneID, DialerKinds.recents, DialerRequests.recents(requestID: requestID, limit: min(DialerLimits.recents, recentCount()))) else { return }
        pending[requestID] = .recents(phoneID: phoneID)
        update(phoneID) { $0.loadingRecents = true }
        expire(requestID)
    }

    /// What was typed changed: the phone is asked a moment after typing stops; an empty search clears.
    func search(_ query: String, phoneID: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        guard !trimmed.isEmpty, isAvailable(phoneID), data(phoneID).status?.contacts == .on else {
            contacts = []
            contactsQuery = trimmed
            contactsError = nil
            searching = false
            return
        }
        searching = true
        schedule(Self.searchDelay) { [weak self] in
            guard let self, generation == self.searchGeneration else { return }
            let requestID = self.newRequestID()
            guard self.send(phoneID, DialerKinds.contacts, DialerRequests.contacts(requestID: requestID, query: trimmed)) else {
                self.searching = false
                return
            }
            self.pending[requestID] = .contacts(phoneID: phoneID, query: trimmed)
            self.expire(requestID)
        }
    }

    /// Asks the phone to start a call; false when it could not go (not available, or one is on its way).
    @discardableResult
    func call(_ target: CallsTarget, phoneID: String) -> Bool {
        guard isAvailable(phoneID), calling == nil else { return false }
        if let last = lastCallAt, now().timeIntervalSince(last) < Self.callSpacing { return false }
        let requestID = newRequestID()
        let payload: [String: Any]
        switch target {
        case let .number(number, subId): payload = DialerRequests.call(requestID: requestID, number: number, subId: subId)
        case let .whatsApp(dataID, video): payload = DialerRequests.whatsApp(requestID: requestID, dataID: dataID, video: video)
        }
        guard send(phoneID, DialerKinds.call, payload) else { return false }
        pending[requestID] = .call(phoneID: phoneID, target: target)
        calling = target
        lastCallAt = now()
        notice = CallsNotice(id: requestID, phoneID: phoneID, kind: .sent)
        expire(requestID)
        return true
    }

    func dismissNotice() { notice = nil }

    private func expire(_ requestID: String) {
        schedule(Self.requestTimeout) { [weak self] in
            guard let self, let request = self.pending.removeValue(forKey: requestID) else { return }
            switch request {
            case let .call(phoneID, _):
                self.calling = nil
                self.notice = CallsNotice(id: requestID, phoneID: phoneID, kind: .noAnswer)
            case .contacts:
                self.searching = false
            case let .recents(phoneID):
                self.update(phoneID) { $0.loadingRecents = false }
            }
        }
    }

    private func update(_ phoneID: String, _ change: (inout CallsPhoneData) -> Void) {
        var phone = phones[phoneID] ?? CallsPhoneData()
        change(&phone)
        phones[phoneID] = phone
    }

    // MARK: Answers

    /// One decrypted dialer.* plaintext from the phone; malformed ones are dropped.
    func receive(kind: String, data: Data, from phoneID: String) {
        guard let limit = DialerLimits.incoming(kind), data.count <= limit else { return }
        switch kind {
        case DialerKinds.status:
            guard let status = decodeDialerStatus(data) else { return }
            let first = phones[phoneID]?.status == nil
            update(phoneID) { phone in
                phone.status = status
                if status.recents != .on { phone.recents = []; phone.recentsLoaded = false }
            }
            if first || !self.data(phoneID).recentsLoaded { loadRecents(phoneID) }
        case DialerKinds.contactsResult:
            guard let result = decodeDialerContactsResult(data),
                  case let .contacts(owner, query)? = pending[result.requestID], owner == phoneID else { return }
            pending.removeValue(forKey: result.requestID)
            contacts = result.contacts
            contactsQuery = query
            contactsError = result.error
            if !pending.values.contains(where: { if case .contacts = $0 { true } else { false } }) { searching = false }
        case DialerKinds.recentsResult:
            guard let result = decodeDialerRecentsResult(data),
                  case let .recents(owner)? = pending[result.requestID], owner == phoneID else { return }
            pending.removeValue(forKey: result.requestID)
            update(phoneID) { phone in
                phone.loadingRecents = false
                phone.recentsError = result.error
                if result.error == nil {
                    phone.recents = result.calls.sorted { $0.date > $1.date }
                    phone.recentsLoaded = true
                }
            }
        case DialerKinds.callResult:
            guard let result = decodeDialerCallResult(data),
                  case let .call(owner, target)? = pending[result.requestID], owner == phoneID else { return }
            pending.removeValue(forKey: result.requestID)
            calling = nil
            switch result.outcome {
            case .started: notice = CallsNotice(id: result.requestID, phoneID: phoneID, kind: .started(target.via))
            case .confirm: notice = CallsNotice(id: result.requestID, phoneID: phoneID, kind: .confirm(target.via))
            case .refused: notice = CallsNotice(id: result.requestID, phoneID: phoneID, kind: .refused(result.reason ?? .failed))
            }
            // The new call shows in the phone's call log once it starts.
            if result.outcome != .refused { schedule(5) { [weak self] in self?.loadRecents(phoneID) } }
        default:
            break
        }
    }
}

// MARK: - Words

/// The line the window shows after a call request.
func callsNoticeText(_ notice: CallsNotice, phone: String) -> String {
    switch notice.kind {
    case .sent:
        return String(format: L10n.text("calls.notice.sent", fallback: "Asking %@\u{2026}"), phone)
    case .started(.phone):
        return String(format: L10n.text("calls.notice.started", fallback: "Calling on %@. Talk on the phone or its earbuds."), phone)
    case .started:
        return String(format: L10n.text("calls.notice.whatsApp", fallback: "WhatsApp is calling on %@."), phone)
    case .confirm:
        return String(format: L10n.text("calls.notice.confirm", fallback: "Tap the notification on %@ to start the call."), phone)
    case let .refused(reason):
        switch reason {
        case .disabled: return String(format: L10n.text("calls.notice.disabled", fallback: "%@ doesn\u{2019}t allow this Mac to call. Turn it on in Bridgey there: Settings > Calls."), phone)
        case .permission: return String(format: L10n.text("calls.notice.permission", fallback: "Allow Bridgey\u{2019}s notifications or Phone access on %@."), phone)
        case .invalid: return L10n.text("calls.notice.invalid", fallback: "That number can\u{2019}t be called from here.")
        case .emergency: return L10n.text("calls.notice.emergency", fallback: "Call emergency numbers from your phone.")
        case .noSim: return String(format: L10n.text("calls.notice.noSim", fallback: "That SIM isn\u{2019}t on %@ any more. Pick another."), phone)
        case .rateLimited: return L10n.text("calls.notice.rateLimited", fallback: "Too many calls at once. Wait a moment and try again.")
        case .notFound: return String(format: L10n.text("calls.notice.notFound", fallback: "That WhatsApp contact isn\u{2019}t on %@ any more."), phone)
        case .unavailable: return String(format: L10n.text("calls.notice.unavailable", fallback: "WhatsApp isn\u{2019}t available on %@."), phone)
        case .failed: return String(format: L10n.text("calls.notice.failed", fallback: "%@ couldn\u{2019}t start the call."), phone)
        }
    case .noAnswer:
        return String(format: L10n.text("calls.notice.noAnswer", fallback: "%@ didn\u{2019}t answer. Check it\u{2019}s connected and try again."), phone)
    }
}

// MARK: - WhatsApp on this Mac

/// WhatsApp Desktop's chat for a number, when an app on this Mac opens whatsapp: links.
enum WhatsAppOnMac {
    /// The app that opens whatsapp: links, if any (WhatsApp Desktop registers the scheme).
    static var handler: () -> URL? = {
        guard let probe = URL(string: "whatsapp://send") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    static var isInstalled: Bool { handler() != nil }

    /// whatsapp://send?phone=<digits>: the international number without the +.
    static func chatURL(for number: String) -> URL? {
        let digits = dialerDigits(number)
        guard (3...15).contains(digits.count) else { return nil }
        return URL(string: "whatsapp://send?phone=\(digits)")
    }

    @discardableResult
    static func open(_ number: String) -> Bool {
        guard let url = chatURL(for: number), let app = handler() else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        return true
    }
}
