import Foundation

enum HeartbeatAction: Equatable { case wait, sendPing, reconnect }

/// Transport liveness is proved by a valid application frame as well as pong.
/// Malformed or unrelated frames must not keep a broken subscription alive.
struct TransportHeartbeat {
    private(set) var lastValidAt: TimeInterval
    private(set) var pingSentAt: TimeInterval?

    init(now: TimeInterval) { lastValidAt = now }

    mutating func observeValidFrame(at now: TimeInterval) {
        guard now.isFinite, now >= lastValidAt else { return }
        lastValidAt = now
        pingSentAt = nil
    }

    mutating func beginPing(at now: TimeInterval) {
        guard now.isFinite, now >= lastValidAt else { return }
        pingSentAt = now
    }

    func action(at now: TimeInterval) -> HeartbeatAction {
        guard now.isFinite, now >= lastValidAt else { return .wait }
        if let sent = pingSentAt {
            return now - sent >= 10 && lastValidAt <= sent ? .reconnect : .wait
        }
        return now - lastValidAt >= 15 ? .sendPing : .wait
    }
}

enum TransportReadiness {
    static func isReady(required: Set<String>, acknowledged: Set<String>, failed: Set<String>) -> Bool {
        !required.isEmpty && required.isSubset(of: acknowledged) && required.isDisjoint(with: failed)
    }

    static func timedOut(required: Set<String>, acknowledged: Set<String>, failed: Set<String>,
                         elapsed: TimeInterval) -> Set<String> {
        guard elapsed >= 20 else { return [] }
        return required.subtracting(acknowledged).subtracting(failed)
    }
}
