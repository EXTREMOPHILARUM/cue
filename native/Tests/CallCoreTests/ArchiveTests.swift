import XCTest
@testable import CallCore
final class ArchiveTests:XCTestCase {
    func testDurableAudioAcknowledgementAndSearch() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["","-wal","-shm"] {try? FileManager.default.removeItem(atPath:path+suffix)} }
        let store=try SessionStore(path:path)
        try store.snapshot(id:"session",record:["id":"call","title":"Pilot review"])
        let pcm=[Float](repeating:0.2,count:1600).withUnsafeBytes{Data($0).base64EncodedString()}
        let frame:[String:Any]=["id":"frame-one","source":"remote","sampleRate":16000,"startedAt":1.0,"pcm":pcm]
        XCTAssertTrue(try store.enqueueAudio("session",frame:frame))
        XCTAssertFalse(try store.enqueueAudio("session",frame:frame))
        let reopened=try SessionStore(path:path)
        XCTAssertEqual(try reopened.audioCount(),1)
        let pending=try reopened.nextAudio()!
        try reopened.finishAudio(pending,text:"A successful pilot needs an owner.")
        XCTAssertEqual(try store.audioCount(),0)
        XCTAssertEqual(try store.archivedAudioCount(),1)
        XCTAssertEqual(try reopened.archivedAudio("session").first?["pcm"] as? String,pcm,"Original audio must survive transcription and reopening")
        XCTAssertEqual(try store.detail("session")["audioChunks"] as? Int,1)
        XCTAssertFalse(try store.enqueueAudio("session",frame:frame),"A retransmission after an ACK was lost must not duplicate audio")
        XCTAssertEqual(try store.search("successful").count,1)
        XCTAssertTrue(try store.search("%_").isEmpty)
        let segments=try store.detail("session")["segments"] as! [[String:Any]]
        XCTAssertEqual(segments.count,1)
        XCTAssertEqual(segments[0]["speaker"] as? String,"Unknown")
        var changed=frame;changed["source"]="local"
        XCTAssertThrowsError(try store.enqueueAudio("session",frame:changed))
    }
}

extension ArchiveTests {
    func testEachCallIsIndependentEvenOnTheSameMeetingLink() throws {
        let store=try SessionStore(path:":memory:")
        let record:[String:Any]=["id":"call-one","independent_call":true,"series_id":"same-link","captions":[["text":"Opening","speaker":"Sam","t":1000.0],["text":"After a long pause","speaker":"Sam","t":86401000.0]]]
        try store.snapshot(id:"chrome-call-one",record:record)
        XCTAssertEqual(try store.list().count,1,"New calls must never be split on the fly")
        XCTAssertEqual((try store.detail("chrome-call-one")["segments"] as! [[String:Any]]).count,2)
        try store.snapshot(id:"chrome-call-two",record:["id":"call-two","independent_call":true,"series_id":"same-link"])
        XCTAssertEqual(try store.list().count,2,"A second call on the same link needs its own record")
        try store.snapshot(id:"old-source",record:["id":"old-source","source_backup":true])
        XCTAssertTrue(try store.exists("old-source"))
        XCTAssertEqual(try store.list().count,2,"Source backups must not appear as extra calls")
    }
}

extension ArchiveTests {
    func testHistoricalBackfillFixtureWhenProvided() throws {
        guard let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_BACKFILL_FIXTURE"] else {throw XCTSkip("Set a private backfill fixture to verify the existing library")}
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [String:Any]
        let records=fixture["records"] as! [[String:Any]],expected=fixture["expectedSessions"] as! Int
        let store=try SessionStore(path:":memory:")
        for item in records {try store.snapshot(id:item["id"] as! String,record:item["record"] as! [String:Any])}
        let calls=try store.list()
        XCTAssertEqual(calls.count,expected)
        let count=try calls.reduce(0){sum,call in sum+(try store.detail(call["id"] as! String)["segments"] as! [[String:Any]]).filter{$0["source"] as? String=="meet"}.count}
        XCTAssertEqual(count,fixture["expectedCaptions"] as? Int)
        var cursors=[String:Int]()
        for call in calls {let id=call["id"] as! String;cursors[id]=try store.read(id)["latestCursor"] as? Int}
        for item in records {try store.snapshot(id:item["id"] as! String,record:item["record"] as! [String:Any])}
        XCTAssertEqual(try store.list().count,expected)
        for (id,cursor) in cursors {XCTAssertEqual(try store.read(id)["latestCursor"] as? Int,cursor)}
        print("Backfill verified: \(calls.count) calls, \(count) captions, stable repeated import")
    }
}

extension ArchiveTests {
    func testAudioBatchesKeepSourcesTracksAndCallsSeparateAndFlushTail() throws {
        let store=try SessionStore(path:":memory:")
        for id in ["one","two"] { try store.snapshot(id:id,record:["id":id]) }
        let pcm=[Float](repeating:0.2,count:64000).withUnsafeBytes{Data($0).base64EncodedString()}
        func enqueue(_ id:String,_ t:Double,_ source:String="local",_ track:String="mic",_ session:String="one") throws {
            _ = try store.enqueueAudio(session,frame:["id":id,"source":source,"trackID":track,"sampleRate":16000,"startedAt":t,"pcm":pcm])
        }
        try enqueue("l1",1000)
        try enqueue("r1",1000,"remote","speaker")
        XCTAssertTrue(try store.nextAudioBatch(now:6000).isEmpty,"Wait for context while capture is active")
        for i in 2...4 {try enqueue("l\(i)",Double(1000+(i-1)*4000))}
        try enqueue("other-track",17000,"local","other-mic")
        try enqueue("other-call",17000,"local","mic","two")
        let reopenedBatch=try store.nextAudioBatch(now:17000)
        XCTAssertEqual(reopenedBatch.map{$0["id"] as! String},["l1","l2","l3","l4"])
        try store.finishAudioBatch(reopenedBatch,text:"One coherent sentence.")
        XCTAssertEqual(try store.audioCount(),3)
        XCTAssertEqual(try store.archivedAudioCount(),7,"Inference must never delete original frames")
        XCTAssertEqual((try store.detail("one")["segments"] as! [[String:Any]]).count,1)
        let tail=try store.nextAudioBatch(now:17000)
        XCTAssertEqual(tail.map{$0["id"] as! String},["r1"],"Short remote tail must not wait forever")
        XCTAssertThrowsError(try store.finishAudioBatch([tail[0],["id":"other","session":"two","source":"remote"]],text:"Mixed"))
        XCTAssertEqual(try store.audioCount(),3,"Failed completion must retain queued audio")
        try store.finishAudioBatch(tail,text:"Remote sentence.")
        XCTAssertTrue(try store.nextAudioBatch(now:22000).isEmpty)
        XCTAssertEqual(try store.nextAudioBatch(now:26000).first?["id"] as? String,"other-track")
    }
    func testAudioBatchDoesNotJoinAcrossMutedGaps() throws {
        let store=try SessionStore(path:":memory:")
        try store.snapshot(id:"one",record:["id":"one"])
        let pcm=[Float](repeating:0.2,count:64000).withUnsafeBytes{Data($0).base64EncodedString()}
        for (id,t) in [("before",1000.0),("after",20000.0)] {
            _ = try store.enqueueAudio("one",frame:["id":id,"source":"local","sampleRate":16000,"startedAt":t,"pcm":pcm])
        }
        XCTAssertEqual(try store.nextAudioBatch(now:21000).map{$0["id"] as! String},["before"])
    }
}
