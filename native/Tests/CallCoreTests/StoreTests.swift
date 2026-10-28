import XCTest
@testable import CallCore
final class StoreTests: XCTestCase {
    func testRevisionsPersistenceAndIsolation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SessionStore(path: path)
        var record: [String: Any] = ["id":"abc-defg-hij", "captions":[["text":"Hello", "speaker":"Sam", "t":1]]]
        try store.snapshot(id:"one",record:record)
        let cursor = try store.read("one")["cursor"] as! Int
        try store.snapshot(id:"one",record:record)
        XCTAssertEqual(try store.read("one")["cursor"] as? Int, cursor)
        record["captions"] = [["text":"Hello again", "speaker":"Sam", "t":1]]
        try store.snapshot(id:"one",record:record)
        let events = try store.read("one", after:cursor)["events"] as! [[String:Any]]
        XCTAssertEqual(events.count,1)
        XCTAssertEqual((events[0]["body"] as! [String:Any])["revision"] as? Int,2)
        XCTAssertThrowsError(try store.snapshot(id:"one", record:["id":"other"]))
        XCTAssertThrowsError(try store.read("missing"))
        XCTAssertEqual(try SessionStore(path:path).list().count,1)
        try store.delete("one")
        XCTAssertTrue(try store.list().isEmpty)
    }
    func testRollbackAndTrustBoundaries() throws {
        let store = try SessionStore(path:":memory:")
        XCTAssertThrowsError(try store.snapshot(id:"safe",record:["id":"call", "captions":[["text":String(repeating:"x",count:20_001)]]]))
        XCTAssertFalse(try store.exists("safe"))
        XCTAssertFalse(Validation.originAllowed("https://evil.example",extensionID:String(repeating:"a",count:32)))
        XCTAssertTrue(Validation.originAllowed("chrome-extension://"+String(repeating:"a",count:32),extensionID:String(repeating:"a",count:32)))
        XCTAssertThrowsError(try Validation.identifier("../secret"))
    }
}

extension StoreTests {
    func testEmptyLegacyCaptureArtifactsAreHiddenWithoutDeletingConfirmedSilentOrAnnotatedCalls() throws {
        let store=try SessionStore(path:":memory:")
        let empty="chrome-call-00000000-0000-0000-0000-000000000001"
        let silent="chrome-call-00000000-0000-0000-0000-000000000002"
        let noted="chrome-call-00000000-0000-0000-0000-000000000003"
        let imported="chrome-call-00000000-0000-0000-0000-000000000004"
        for id in [empty,silent,noted,imported] {
            var record:[String:Any]=["id":String(id.dropFirst(7)),"source":"meet","started_at":1000.0,"ended_at":2000.0]
            if id==silent {record["presence_confirmed"]=true}
            if id==imported {record["source_record_id"]="legacy"}
            try store.snapshot(id:id,record:record)
        }
        try store.append(empty,kind:"summary-automation",body:["state":"skipped"])
        try store.append(noted,kind:"note",body:["text":"Keep this call"])
        XCTAssertEqual(Set(try store.list().compactMap{$0["id"] as? String}),Set([silent,noted,imported]))
        XCTAssertTrue(try store.exists(empty),"Filtering must not delete the original record")
        XCTAssertNotNil(try store.detail(empty)["meta"])
        XCTAssertFalse(try store.search("legacy").contains{$0["id"] as? String==empty})
        let pcm=[Float](repeating:0.1,count:1600).withUnsafeBytes{Data($0).base64EncodedString()}
        _ = try store.enqueueAudio(empty,frame:["id":"late-audio","source":"remote","sampleRate":16000,"startedAt":1000.0,"pcm":pcm])
        XCTAssertTrue(try store.list().contains{$0["id"] as? String==empty},"Late durable audio makes the call visible again")
        try store.snapshot(id:silent,record:["id":String(silent.dropFirst(7)),"source":"meet","ended_at":2000.0])
        XCTAssertTrue(try store.list().contains{$0["id"] as? String==silent},"An older snapshot cannot erase confirmed presence")
    }
}
