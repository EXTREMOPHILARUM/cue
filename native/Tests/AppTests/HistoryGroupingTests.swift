import XCTest
@testable import CallAssistant

final class HistoryGroupingTests:XCTestCase {
    func testFlattenedHistoryRowsKeepIdentityWhenExpandedAndUpdated() {
        let calls:[[String:Any]]=[
            ["id":"a1","title":"Weekly sync","seriesID":"a","startedAt":1000.0],
            ["id":"a2","title":"Weekly sync","seriesID":"a","startedAt":3000.0],
            ["id":"b","title":"Other call","startedAt":2000.0]
        ]
        let groups=groupedCallHistory(calls)
        let collapsed=historyListRows(groups,expanded:[])
        let expanded=historyListRows(groups,expanded:["series:a"])
        XCTAssertEqual(collapsed.map(\.id),["series:a","call:b"])
        XCTAssertEqual(expanded.map(\.id),["series:a","call:a2","call:a1","call:b"])
        XCTAssertEqual(Set(expanded.map(\.id)).count,expanded.count)
        XCTAssertEqual(expanded.map(\.selectionID),["series:a","a2","a1","b"])
        let updated=groupedCallHistory(calls+[["id":"a3","title":"Weekly sync","seriesID":"a","startedAt":4000.0]])
        let updatedRows=historyListRows(updated,expanded:["series:a"])
        XCTAssertTrue(Set(expanded.map(\.id)).isSubset(of:Set(updatedRows.map(\.id))))
        XCTAssertEqual(historyListRows(updated,expanded:[]).first?.series?.latestCallID,"a3")
    }
    func testTranscriptIdentityComesFromSavedSegments() throws {
        let first=try XCTUnwrap(TranscriptSegment(["id":"segment-one","text":"First version"]))
        let revised=try XCTUnwrap(TranscriptSegment(["id":"segment-one","text":"Corrected version"]))
        let inserted=try XCTUnwrap(TranscriptSegment(["id":"segment-new","text":"Earlier speech"]))
        XCTAssertEqual(first.id,revised.id)
        XCTAssertEqual([inserted,revised].map(\.id),["segment-new","segment-one"])
        XCTAssertNil(TranscriptSegment(["text":"Missing identity"]))
    }

    func testRecurringMeetingsStayIndependentAndNewestFirst() {
        let calls:[[String:Any]]=[
            ["id":"a1","title":"Meet – Weekly sync","seriesID":"meeting-a","startedAt":1000.0],
            ["id":"a2","title":"Meet – Renamed sync","seriesID":"meeting-a","startedAt":3000.0],
            ["id":"b1","title":"Meet – Weekly sync","seriesID":"meeting-b","startedAt":2000.0],
            ["id":"u1","title":"Untitled","startedAt":500.0],
            ["id":"u2","title":"Untitled","startedAt":400.0]
        ]
        let groups=groupedCallHistory(calls)
        XCTAssertEqual(groups.count,4)
        XCTAssertEqual(groups[0].id,"series:meeting-a")
        XCTAssertEqual(groups[0].calls.map{$0["id"] as! String},["a2","a1"])
        XCTAssertEqual(groups[0].latestCallID,"a2","Opening a recurring call must select its newest occurrence")
        XCTAssertEqual(groups.flatMap(\.calls).count,calls.count,"Grouping must never merge or discard individual calls")
        XCTAssertEqual(groups[1].id,"series:meeting-b","Identical titles with different meeting IDs stay separate")
    }
    func testLegacyTitleFallbackMatchesExtensionAndSearchKeepsCallIdentity() {
        let calls:[[String:Any]]=[
            ["id":"one","title":"Meet — Weekly   Sync","startedAt":2000.0],
            ["id":"two","title":"weekly sync","startedAt":1000.0]
        ]
        XCTAssertEqual(groupedCallHistory(calls).count,1)
        XCTAssertEqual(groupedCallHistory([calls[1]]).first?.calls.first?["id"] as? String,"two")
        XCTAssertEqual(groupedCallHistory([calls[1]]).first?.latestCallID,"two","A filtered series must open the matching occurrence")
    }
}
