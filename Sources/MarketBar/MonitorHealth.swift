import Foundation

/// One notification per outage. A brief good tick does not end the incident.
struct MonitorHealth {
    private var failureBegan: Date?
    private var recoveryBegan: Date?
    private var noticeIssued = false
    private var lastNotice: Date?

    mutating func observe(failed: Bool, at now: Date) -> Bool {
        guard now.timeIntervalSince1970.isFinite else { return false }
        if !failed {
            failureBegan = nil
            recoveryBegan = recoveryBegan ?? now
            if now.timeIntervalSince(recoveryBegan!) >= 30 { noticeIssued = false }
            return false
        }
        recoveryBegan = nil
        failureBegan = failureBegan ?? now
        guard !noticeIssued, now.timeIntervalSince(failureBegan!) >= 20,
              lastNotice == nil || now.timeIntervalSince(lastNotice!) >= 300 else { return false }
        noticeIssued = true
        lastNotice = now
        return true
    }
}

func runMonitorHealthChecks() -> Bool {
    let base = Date(timeIntervalSince1970: 1_795_233_600)
    var health = MonitorHealth()
    var notices: [Int] = []
    for second in 0...400 {
        // Repeated brief recoveries, then one stable recovery and a new outage.
        let failed = second != 25 && second != 50 && !(200...240).contains(second)
        if health.observe(failed: failed, at: base.addingTimeInterval(Double(second))) {
            notices.append(second)
        }
    }
    guard notices == [20, 320] else {
        print("FAIL health incident dedup: \(notices)")
        return false
    }
    print("PASS health incidents: 20s grace, stable recovery, independent cooldown")
    return true
}
