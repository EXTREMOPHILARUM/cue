import XCTest
@testable import CallCore

final class SpeakerTests:XCTestCase {
    func testMeetSelfCaptionUsesRosterNameWithoutChangingContentOrRepeatingRevisions() throws {
        let store=try SessionStore(path:":memory:")
        var record:[String:Any]=["id":"call","captions":[["speaker":"You","text":"Keep this wording","t":1234.0],["speaker":"Casey","text":"Reply","t":2345.0]]]
        try store.snapshot(id:"call",record:record)
        XCTAssertEqual((try store.detail("call")["segments"] as! [[String:Any]])[0]["speaker"] as? String,"You")
        record["speaker_roster"]=[["id":"self","name":"Morgan Lee","isSelf":true],["id":"other","name":"Casey","isSelf":false]]
        try store.snapshot(id:"call",record:record)
        let rows=try store.detail("call")["segments"] as! [[String:Any]]
        XCTAssertEqual(rows[0]["speaker"] as? String,"Morgan Lee")
        XCTAssertEqual(rows[0]["text"] as? String,"Keep this wording")
        XCTAssertEqual(rows[0]["t"] as? Double,1234)
        XCTAssertEqual(rows[0]["attribution"] as? String,"meet-self")
        XCTAssertEqual(rows[1]["speaker"] as? String,"Casey")
        let cursor=try store.read("call")["latestCursor"] as! Int
        try store.snapshot(id:"call",record:record)
        XCTAssertEqual(try store.read("call")["latestCursor"] as? Int,cursor)
    }
    func testGroupCallChangesSplitBatchesAndLateRosterNamesStayDurable() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer{for suffix in ["","-wal","-shm"]{try? FileManager.default.removeItem(atPath:path+suffix)}}
        let store=try SessionStore(path:path)
        try store.snapshot(id:"group",record:["id":"group"])
        let pcm=[Float](repeating:0.2,count:64000).withUnsafeBytes{Data($0).base64EncodedString()}
        func frame(_ id:String,_ speaker:String,_ t:Double)->[String:Any]{["id":id,"source":"remote","trackID":"shared-track","participantID":speaker,"attribution":"meet-rtp","speaker":"Unknown","sampleRate":16000,"startedAt":t,"pcm":pcm]}
        for value in [frame("a1","casey",1000),frame("b1","riley",5000),frame("a2","casey",9000)]{_ = try store.enqueueAudio("group",frame:value)}
        let all=try store.archivedAudio("group")
        XCTAssertThrowsError(try store.finishAudioBatch(Array(all.prefix(2)),text:"Wrong combined speaker"))
        XCTAssertEqual(try store.audioCount(),3)
        for text in ["First speaker","Second speaker","First speaker again"] {
            let batch=try store.nextAudioBatch(now:20000)
            XCTAssertEqual(batch.count,1,"A shared WebRTC track must split at every participant change")
            try store.finishAudioBatch(batch,text:text)
        }
        let roster:[[String:Any]]=[["id":"self","name":"Morgan","isSelf":true],["id":"casey","name":"Casey Rivera","isSelf":false],["id":"riley","name":"Riley","isSelf":false]]
        try store.snapshot(id:"group",record:["id":"group","speaker_roster":roster])
        let segments=try store.detail("group")["segments"] as! [[String:Any]]
        XCTAssertEqual(segments.compactMap{$0["speaker"] as? String},["Casey Rivera","Riley","Casey Rivera"])
        XCTAssertEqual(segments.compactMap{$0["participantID"] as? String},["casey","riley","casey"])
        let cursor=try store.read("group")["latestCursor"] as! Int
        try store.snapshot(id:"group",record:["id":"group","speaker_roster":roster])
        XCTAssertEqual(try store.read("group")["latestCursor"] as? Int,cursor,"Repeat roster updates must not duplicate transcript revisions")
        let reopened=try SessionStore(path:path)
        XCTAssertEqual(try reopened.archivedAudio("group").count,3)
        XCTAssertEqual((try reopened.archivedAudio("group")[0])["pcm"] as? String,pcm)
        XCTAssertEqual((try reopened.detail("group")["segments"] as! [[String:Any]])[1]["speaker"] as? String,"Riley")
    }
    func testLocalNamesMixedSpeechAndUnresolvedSourcesAreNotGuessed() throws {
        let store=try SessionStore(path:":memory:")
        try store.snapshot(id:"group",record:["id":"group","speaker_roster":[["id":"self","name":"Morgan","isSelf":true],["id":"remote","name":"Casey Rivera","isSelf":false]]])
        let pcm=[Float](repeating:0.1,count:1600).withUnsafeBytes{Data($0).base64EncodedString()}
        for (id,source,method) in [("local","local","local"),("overlap","remote","mixed"),("missing","remote","unresolved")] {
            var frame:[String:Any]=["id":id,"source":source,"attribution":method,"sampleRate":16000,"startedAt":1000.0,"pcm":pcm]
            _ = try store.enqueueAudio("group",frame:frame)
            try store.finishAudio(try store.nextAudio()!,text:"Speech")
            frame["id"]="invalid";frame["speaker"]=String(repeating:"x",count:501)
            XCTAssertThrowsError(try store.enqueueAudio("group",frame:frame))
        }
        let rows=try store.detail("group")["segments"] as! [[String:Any]]
        XCTAssertEqual(rows.compactMap{$0["speaker"] as? String},["Morgan","Multiple speakers","Unknown"],"A one-name roster is not proof that all remote audio belongs to that person")
        XCTAssertEqual(try store.archivedAudioCount(),3)
    }
}

extension SpeakerTests {
    func testCaptureTimelineSurvivesTranscriptionAndReopeningWithoutClaimingActivityIsRTP() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let path=directory.appendingPathComponent("calls.sqlite3").path
        let store=try SessionStore(path:path)
        try store.snapshot(id:"group",record:["id":"group","speaker_roster":[["id":"a","name":"Taylor","isSelf":false],["id":"d","name":"Jordan","isSelf":false]]])
        let pcm=[Float](repeating:0.2,count:64000).withUnsafeBytes{Data($0).base64EncodedString()}
        var history:[[String:Any]]=[["version":1,"observedAt":1000.0,"contributors":["101"],"active":[["id":"a","name":"Taylor","isSelf":false]],"method":"meet-activity","reason":"sustained-exclusive-activity","protocol":["rawDeviceID":"d","participantID":"d","speaker":"Jordan","disabled":false,"isSelf":false]]]
        history[0]["sampleOffset"]=0;history[0]["trackID"]="track"
        var transition=history[0];transition["observedAt"]=2000.0;transition["sampleOffset"]=16000;transition["reason"]="protocol-changed";history.append(transition)
        let frame:[String:Any]=["captureDiscontinuities":[["observedAt":999.0,"pendingPackets":2,"reason":"decoder-stalled"]],"id":"audio","source":"remote","trackID":"track","participantID":"a","speaker":"Taylor","attribution":"meet-activity","contributors":["101"],"sampleRate":16000,"startedAt":1000.0,"pcm":pcm,"mappingHistory":history,"packetRange":["firstObservedAt":1000.0,"lastObservedAt":4980.0]]
        XCTAssertTrue(try store.enqueueAudio("group",frame:frame))
        try store.finishAudio(try store.nextAudio()!,text:"Original transcript")
        let reopened=try SessionStore(path:path)
        let audio=try reopened.archivedAudio("group")[0]
        XCTAssertEqual(audio["pcm"] as? String,pcm)
        XCTAssertEqual(try Validation.json(audio["captureDiscontinuities"]!),try Validation.json(frame["captureDiscontinuities"]!))
        XCTAssertEqual(try Validation.json(audio["mappingHistory"]!),try Validation.json(history))
        let segment=(try reopened.detail("group")["segments"] as! [[String:Any]])[0]
        XCTAssertEqual(segment["speaker"] as? String,"Taylor")
        XCTAssertEqual(segment["attribution"] as? String,"meet-activity")
        XCTAssertEqual(segment["text"] as? String,"Original transcript")
        XCTAssertEqual((segment["speakerEvidence"] as? [String:Any])?["method"] as? String,"capture-timeline-v1")
        var bad=frame;bad["id"]="bad";bad["mappingHistory"]=[["version":1,"observedAt":Double.nan]]
        XCTAssertThrowsError(try reopened.enqueueAudio("group",frame:bad))
        bad["mappingHistory"]=history;bad["packetRange"]=["firstObservedAt":2000.0,"lastObservedAt":1000.0]
        XCTAssertThrowsError(try reopened.enqueueAudio("group",frame:bad))
    }
}

extension SpeakerTests {
    func testCaptureMappingRejectsContradictoryTimelinesAndPreservesLegacySnapshots() throws {
        let pcm=[Float](repeating:0.2,count:640).withUnsafeBytes{Data($0).base64EncodedString()}
        let first:[String:Any] = ["version":1,"observedAt":1000.0,"sampleOffset":0,"trackID":"t","contributors":["101"],"active":[],"method":"meet-rtp"]
        var second=first;second["observedAt"]=1020.0;second["sampleOffset"]=320;second["reason"]="protocol-and-activity-agree"
        let frame:[String:Any] = ["trackID":"t","contributors":["101"],"attribution":"meet-rtp","pcm":pcm,"mappingHistory":[first,second],"packetRange":["firstObservedAt":1000.0,"lastObservedAt":1020.0]]
        XCTAssertNoThrow(try CaptureMapping.validate(frame))
        for (key,value) in [("observedAt",999.0 as Any),("observedAt",1021.0 as Any),("sampleOffset",-1 as Any),("sampleOffset",640 as Any),("sampleOffset",0 as Any),("trackID","other" as Any),("contributors",["102"] as Any)] {
            var invalid=second;invalid[key]=value;var bad=frame;bad["mappingHistory"]=[first,invalid]
            XCTAssertThrowsError(try CaptureMapping.validate(bad),"Must reject \(key)=\(value)")
        }
        var legacy=first;legacy.removeValue(forKey:"sampleOffset");legacy.removeValue(forKey:"trackID")
        var old=frame;old["mappingHistory"]=[legacy];XCTAssertNoThrow(try CaptureMapping.validate(old))
        var gap=frame;gap["captureDiscontinuities"]=[["observedAt":1000.0,"pendingPackets":50,"reason":"decoder-backpressure"]]
        XCTAssertNoThrow(try CaptureMapping.validate(gap))
        gap["captureDiscontinuities"]=[["observedAt":Double.nan,"pendingPackets":101,"reason":"bad"]]
        XCTAssertThrowsError(try CaptureMapping.validate(gap))
    }
}
