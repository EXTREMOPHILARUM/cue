import Foundation

struct CoachingSchedule {
    private var observed=""
    private var sent=""
    private var changedAt=Date.distantPast
    private var pendingAt=Date.distantPast
    private var sentAt=Date.distantPast
    mutating func ready(_ fingerprint:String,now:Date) -> Bool {
        if fingerprint != observed {
            if observed==sent {pendingAt=now}
            observed=fingerprint;changedAt=now
        }
        guard fingerprint != sent,now.timeIntervalSince(sentAt)>=3 else {return false}
        return sent.isEmpty || now.timeIntervalSince(changedAt)>=1 || now.timeIntervalSince(pendingAt)>=3
    }
    mutating func submitted(_ fingerprint:String,now:Date) {sent=fingerprint;observed=fingerprint;sentAt=now}
}
