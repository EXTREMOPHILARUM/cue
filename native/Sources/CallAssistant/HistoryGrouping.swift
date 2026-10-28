import Foundation
import CallCore

struct CallHistoryGroup:Identifiable {
    let id:String
    let title:String
    var calls:[[String:Any]]
    var latestCallID:String? { calls.first?["id"] as? String }
}

struct HistoryListRow:Identifiable {
    let id:String
    let call:[String:Any]
    let title:String?
    let series:CallHistoryGroup?
    var selectionID:String {series?.id ?? (call["id"] as! String)}
}

func historyListRows(_ groups:[CallHistoryGroup],expanded:Set<String>) -> [HistoryListRow] {
    var rows=[HistoryListRow]()
    for group in groups {
        guard let first=group.calls.first,let id=first["id"] as? String else {continue}
        if group.calls.count>1 {
            rows.append(HistoryListRow(id:group.id,call:first,title:group.title,series:group))
            if expanded.contains(group.id) {
                for call in group.calls {
                    guard let id=call["id"] as? String else {continue}
                    rows.append(HistoryListRow(id:"call:"+id,call:call,title:nil,series:nil))
                }
            }
        } else {
            rows.append(HistoryListRow(id:"call:"+id,call:first,title:group.title,series:nil))
        }
    }
    return rows
}

struct TranscriptSegment:Identifiable {
    let id:String
    let value:[String:Any]
    init?(_ value:[String:Any]) {
        guard let id=value["id"] as? String,!id.isEmpty else {return nil}
        self.id=id;self.value=value
    }
}

func groupedCallHistory(_ calls:[[String:Any]]) -> [CallHistoryGroup] {
    var groups=[String:CallHistoryGroup]()
    for call in calls.sorted(by:{($0["startedAt"] as? Double ?? 0)>($1["startedAt"] as? Double ?? 0)}) {
        guard let id=call["id"] as? String else {continue}
        var groupingCall=call;groupingCall.removeValue(forKey:"summaryTitle")
        let title=sessionTitle(groupingCall).replacingOccurrences(of:#"^Meet\s*[–—-]\s*"#,with:"",options:[.regularExpression,.caseInsensitive]).trimmingCharacters(in:.whitespacesAndNewlines)
        let sharedKey=SessionStore.recurringProjectKey(call)
        let key:String
        if let series=call["seriesID"] as? String,!series.isEmpty {key="series:"+series}
        else {key=sharedKey ?? "id:"+id}
        if groups[key]==nil {groups[key]=CallHistoryGroup(id:key,title:title.isEmpty ? id:title,calls:[])}
        groups[key]!.calls.append(call)
    }
    return groups.values.sorted {($0.calls.first?["startedAt"] as? Double ?? 0)>($1.calls.first?["startedAt"] as? Double ?? 0)}
}
