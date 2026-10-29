import Foundation

struct CoachingSchedule {
    private var observed=""
    private var sent=""
    private var sentContext=""
    private var changedAt=Date.distantPast
    private var pendingAt=Date.distantPast
    private var sentAt=Date.distantPast
    mutating func ready(_ fingerprint:String,context:String?=nil,now:Date) -> Bool {
        if fingerprint != observed {
            if observed==sent {pendingAt=now}
            observed=fingerprint;changedAt=now
        }
        let question=context?.trimmingCharacters(in:.whitespacesAndNewlines).hasSuffix("?")==true && context != sentContext
        guard fingerprint != sent,now.timeIntervalSince(sentAt)>=(question ? 3:12) else {return false}
        if let context {
            let words=context.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber})
            let previous=sentContext.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber})
            if sent.isEmpty {guard words.count>=12 || question else {return false}}
            else {guard words != previous || question else {return false}}
        }
        return sent.isEmpty || now.timeIntervalSince(changedAt)>=2 || now.timeIntervalSince(pendingAt)>=12
    }
    mutating func submitted(_ fingerprint:String,context:String="",now:Date) {sent=fingerprint;observed=fingerprint;sentContext=context;sentAt=now}
}
