import Foundation

/// A tap owns a temporary audio resource, never the player's volume. All access is on the
/// platform's serial queue, including driver notifications. Tokens cannot cross app launches.
struct CallMediaProcessTarget: Equatable {
    let sessionID: String
    let processObject: UInt32
    let routeID: String
}

struct CallMediaProcessTap: Equatable {
    let objectID: UInt32
    let uid: UUID
    var aggregateObject: UInt32? = nil
}

protocol CallMediaProcessTapDriver: AnyObject {
    func target(for session: CallMediaSession) -> Result<CallMediaProcessTarget, CallMediaIssue>
    func observe(_ target: CallMediaProcessTarget, changed: @escaping (CallMediaIssue) -> Void)
        -> Result<() -> Void, CallMediaIssue>
    func create(_ target: CallMediaProcessTarget) -> Result<CallMediaProcessTap, CallMediaIssue>
    /// Preparation has no reader. Start may quiet playback, so revalidate immediately before
    /// and after it; the final phase only confirms the native reader-controlled mute.
    func startReading(_ tap: CallMediaProcessTap) -> Result<Void, CallMediaIssue>
    func activateMute(_ tap: CallMediaProcessTap, permit: CallMediaPermit) -> Result<Void, CallMediaIssue>
    /// Success includes an object already removed by Core Audio. A failure retains ownership.
    func destroy(_ tap: CallMediaProcessTap) -> Bool
}

// The live platform publishes this object to its serial queue before use. Every operation,
// driver callback and observer installation/removal is confined to that queue; no mutable
// state is read by the main actor. Test drivers use the same synchronous ownership model.
final class CallMediaProcessMute: @unchecked Sendable {
    private struct Lease {
        let session: CallMediaSession
        let target: CallMediaProcessTarget
        let tap: CallMediaProcessTap
        let cancelObservation: () -> Void
        var active = false
    }
    private let driver: CallMediaProcessTapDriver
    private var leases: [UUID: Lease] = [:]
    var onInvalidated: ((UUID, CallMediaIssue, Bool) -> Void)?

    init(driver: CallMediaProcessTapDriver) { self.driver = driver }

    deinit {
        for lease in leases.values { lease.cancelObservation(); _ = driver.destroy(lease.tap) }
    }

    func decorate(_ original: CallMediaSession) -> CallMediaSession {
        var session = original
        session.canMute = false
        session.processMuteRouteID = nil
        if case .success(let target) = driver.target(for: session) {
            session.processMuteRouteID = target.routeID
            session.canMute = true
        }
        let owned = leases.first(where: { $0.value.session.id == session.id })
        session.processMuteToken = owned?.key
        session.processMuteActive = owned?.value.active
        return session
    }

    func mute(_ session: CallMediaSession, token: UUID, permit: CallMediaPermit)
        -> Result<CallMediaSession, CallMediaIssue> {
        guard permit.isValid else { return .failure(.cancelled) }
        guard leases.count < 32, leases[token] == nil,
              !leases.values.contains(where: { $0.session.id == session.id }) else { return .failure(.changedByUser) }
        let target: CallMediaProcessTarget
        switch driver.target(for: session) {
        case .success(let value): target = value
        case .failure(let issue): return .failure(issue)
        }
        guard target.routeID == session.processMuteRouteID else { return .failure(.changedByUser) }
        // Install listeners before the last safety check and before taking ownership.
        var changedDuringCreation: CallMediaIssue?
        let cancel: () -> Void
        switch driver.observe(target, changed: { [weak self] issue in
            changedDuringCreation = issue
            if self?.leases[token] != nil { self?.invalidate(token, issue: issue) }
        }) {
        case .success(let value): cancel = value
        case .failure(let issue): return .failure(issue)
        }
        guard permit.isValid else { cancel(); return .failure(.cancelled) }
        guard changedDuringCreation == nil else { cancel(); return .failure(.changedByUser) }
        guard case .success(let current) = driver.target(for: session), current == target else {
            cancel(); return .failure(.changedByUser)
        }
        let tap: CallMediaProcessTap
        switch driver.create(target) {
        case .success(let value): tap = value
        case .failure(let issue): cancel(); return .failure(issue)
        }
        leases[token] = Lease(session: session, target: target, tap: tap, cancelObservation: cancel)
        func interruption() -> CallMediaIssue? {
            if !permit.isValid { return .cancelled }
            if let issue = changedDuringCreation { return issue }
            guard leases[token] != nil else { return .changedByUser }
            switch driver.target(for: session) {
            case .success(let current): return current == target ? nil : .changedByUser
            case .failure(let issue): return issue
            }
        }
        func failed(_ issue: CallMediaIssue) -> Result<CallMediaSession, CallMediaIssue> {
            if release(token, sessionID: session.id) { return .failure(issue) }
            // A cleanup-only lease never counts as verified muting. Keep its exact token
            // available to the backup/reset path even when startup or cancellation failed.
            onInvalidated?(token, issue, false)
            var after = session; after.processMuteToken = token; after.processMuteActive = false
            return .success(after)
        }
        if let issue = interruption() { return failed(issue) }
        if case .failure(let issue) = driver.startReading(tap) { return failed(issue) }
        if let issue = interruption() { return failed(issue) }
        if case .failure(let issue) = driver.activateMute(tap, permit: permit) { return failed(issue) }
        if let issue = interruption() { return failed(issue) }
        leases[token]?.active = true
        var after = session; after.processMuteToken = token; after.processMuteActive = true
        return .success(after)
    }

    func contains(_ token: UUID) -> Bool { leases[token] != nil }

    func release(_ token: UUID, sessionID: String) -> Bool {
        guard let lease = leases[token] else { return true }
        guard lease.session.id == sessionID, driver.destroy(lease.tap) else { return false }
        lease.cancelObservation()
        leases.removeValue(forKey: token)
        return true
    }

    private func invalidate(_ token: UUID, issue: CallMediaIssue) {
        guard let lease = leases[token] else { return }
        let released = release(token, sessionID: lease.session.id)
        onInvalidated?(token, released ? issue : .commandFailed, released)
    }
}
