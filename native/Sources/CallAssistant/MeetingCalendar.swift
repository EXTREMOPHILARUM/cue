import EventKit
import SwiftUI

struct CalendarMeeting:Identifiable {
    let id:String
    let title:String
    let start:Date
    let end:Date
    let meetCode:String?
    static func code(in text:String) -> String? {
        let pattern=#"https://meet\.google\.com/(?:meet/)?([a-z]{3}-[a-z]{4}-[a-z]{3})(?=[/?#\s]|$)"#
        guard let range=text.range(of:pattern,options:.regularExpression) else {return nil}
        return text[range].split(separator:"/").last.map{String($0.prefix(12))}
    }
    func matches(_ meta:[String:Any]) -> Bool {
        guard let meetCode,let time=meta["startedAt"] as? Double,time.isFinite,
              let url=URL(string:meta["url"] as? String ?? ""),url.scheme=="https",url.host=="meet.google.com",
              Self.code(in:url.absoluteString)==meetCode else {return false}
        let date=Date(timeIntervalSince1970:time/1000)
        return date>=start.addingTimeInterval(-1800) && date<=end.addingTimeInterval(1800)
    }
}

@MainActor final class MeetingCalendar:ObservableObject {
    private let store=EKEventStore()
    @Published private(set) var meetings=[CalendarMeeting]()
    @Published private(set) var status="Calendar is not connected"
    @Published private(set) var busy=false
    func connect() {
        guard !busy else {return};busy=true
        Task {
            defer {busy=false}
            do {
                let allowed=try await store.requestFullAccessToEvents()
                guard allowed else {meetings=[];status="Calendar access denied. Enable it in System Settings → Privacy & Security → Calendars.";return}
                let now=Date(),start=now.addingTimeInterval(-86400),end=now.addingTimeInterval(7*86400)
                meetings=store.events(matching:store.predicateForEvents(withStart:start,end:end,calendars:nil)).map {event in
                    CalendarMeeting(id:event.calendarItemIdentifier+"-"+String(event.startDate.timeIntervalSince1970),title:event.title ?? "Untitled meeting",start:event.startDate,end:event.endDate,
                                    meetCode:CalendarMeeting.code(in:[event.url?.absoluteString,event.location,event.notes].compactMap{$0}.joined(separator:"\n")))
                }.sorted{$0.start<$1.start}
                status="Connected · yesterday through the next 7 days · read only"
            } catch {meetings=[];status="Calendar unavailable: "+error.localizedDescription}
        }
    }
}

struct CallCalendarContext:View {
    @ObservedObject var calendar:MeetingCalendar
    let meta:[String:Any]
    var body:some View {
        if let match=calendar.meetings.filter({$0.matches(meta)}).min(by:{abs($0.start.timeIntervalSince1970-((meta["startedAt"] as? Double ?? 0)/1000))<abs($1.start.timeIntervalSince1970-((meta["startedAt"] as? Double ?? 0)/1000))}) {
            Label {Text(match.title)+Text(" · ")+Text(match.start,format:.dateTime.day().month().hour().minute())} icon:{Image(systemName:"calendar")}
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct CalendarSettings:View {
    @ObservedObject var calendar:MeetingCalendar
    var body:some View {
        Section("macOS Calendar") {
            Text(calendar.status).font(.caption).foregroundStyle(.secondary)
            Button("Connect / refresh Calendar",systemImage:"calendar") {calendar.connect()}.disabled(calendar.busy)
            Text("Matches calls by Meet link and time. Events stay local; the app does not create or edit them.").font(.caption).foregroundStyle(.secondary)
            ForEach(calendar.meetings.filter{$0.end>Date()}.prefix(3)) {meeting in
                VStack(alignment:.leading) {Text(meeting.title);Text(meeting.start,format:.dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)}
            }
        }
    }
}
