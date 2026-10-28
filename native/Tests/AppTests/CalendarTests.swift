import XCTest
@testable import CallAssistant

final class CalendarTests:XCTestCase {
    func testMatchRequiresExactMeetLinkAndOccurrenceTime() {
        let start=Date(timeIntervalSince1970:10_000)
        let meeting=CalendarMeeting(id:"event",title:"Weekly call",start:start,end:start.addingTimeInterval(3600),meetCode:CalendarMeeting.code(in:"Join https://meet.google.com/abc-defg-hij?authuser=0"))
        XCTAssertTrue(meeting.matches(["url":"https://meet.google.com/abc-defg-hij","startedAt":10_000_000.0]))
        XCTAssertFalse(meeting.matches(["url":"https://meet.google.com/xyz-abcd-efg","startedAt":10_000_000.0]))
        XCTAssertFalse(meeting.matches(["url":"https://evil.test/?next=https://meet.google.com/abc-defg-hij","startedAt":10_000_000.0]))
        XCTAssertFalse(meeting.matches(["url":"https://meet.google.com/abc-defg-hij","startedAt":100_000_000.0]))
        XCTAssertNil(CalendarMeeting.code(in:"https://evil.test/abc-defg-hij"))
        XCTAssertNil(CalendarMeeting.code(in:"https://meet.google.com/abc-defg-hij-suffix"))
        XCTAssertEqual(CalendarMeeting.code(in:"https://meet.google.com/meet/abc-defg-hij"),"abc-defg-hij")
    }
}
