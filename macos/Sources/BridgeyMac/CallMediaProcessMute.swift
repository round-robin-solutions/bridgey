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
}

protocol CallMediaProcessTapDriver: AnyObject {
    func target(for session: CallMediaSession) -> Result<CallMediaProcessTarget, CallMediaIssue>
    func observe(_ target: CallMediaProcessTarget, changed: @escaping (CallMediaIssue) -> Void)
        -> Result<() -> Void, CallMediaIssue>
    func create(_ target: CallMediaProcessTarget) -> Result<CallMediaProcessTap, CallMediaIssue>
    /// Success includes an object already removed by Core Audio. A failure retains ownership.
    func destroy(_ tap: CallMediaProcessTap) -> Bool
}

final class CallMediaProcessMute {
    private struct Lease {
        let session: CallMediaSession
        let target: CallMediaProcessTarget
        let tap: CallMediaProcessTap
        let cancelObservation: () -> Void
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
        session.processMuteToken = leases.first(where: { $0.value.session.id == session.id })?.key
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
            if self?.leases[token] == nil { changedDuringCreation = issue }
            else { self?.invalidate(token, issue: issue) }
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
        if !permit.isValid {
            if release(token, sessionID: session.id) { return .failure(.cancelled) }
        } else if changedDuringCreation == nil,
                  case .success(let current) = driver.target(for: session), current == target {
            var after = session; after.processMuteToken = token
            return .success(after)
        } else if release(token, sessionID: session.id) { return .failure(.changedByUser) }
        // Even a cancelled/stale creation must hand back its resource if cleanup failed. The
        // controller can release that exact token; losing it would leave an untracked mute.
        var after = session; after.processMuteToken = token
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
