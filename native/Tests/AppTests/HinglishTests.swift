import XCTest
import WhisperKit
import CallCore
@testable import CallAssistant

final class HinglishTests:XCTestCase {
    func testKnownHindiAndRetainedEnglish() async throws {
        guard let file=ProcessInfo.processInfo.environment["CALL_ASSISTANT_HINDI_FIXTURE"] else {throw XCTSkip("Set the known Hindi speech WAV fixture")}
        let transcriber=Transcriber()
        let hindi=try await transcriber.file(file)
        print("Known Hindi: \(hindi)")
        for phrase in ["company","dastaavez","bank khaate","satyaapan","mangalvaar"] {XCTAssertTrue(hindi.lowercased().contains(phrase),hindi)}
        XCTAssertTrue(hindi.unicodeScalars.allSatisfy{$0.value<128},"Expected Roman Hinglish: \(hindi)")
        let english=try await transcriber.file("/tmp/call-assistant-local.wav")
        print("English control: \(english)")
        for phrase in ["next step","successful pilot","proposal tomorrow morning","engineering team"] {XCTAssertTrue(english.lowercased().contains(phrase),english)}
        let silentText=try await transcriber.transcribe(AudioChunk(session:"fixture",sequence:0,startedAt:1,samples:[Float](repeating:0,count:256000)))
        XCTAssertEqual(silentText,"")
    }
    func testSavedCallReplayRetainsBothSourcesAndSpeechAfterPause() async throws {
        guard let file=ProcessInfo.processInfo.environment["CALL_ASSISTANT_MULTILINGUAL_FIXTURE"] else {throw XCTSkip("Set the private saved-call audio fixture")}
        let frames=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [[String:Any]]
        let store=try SessionStore(path:":memory:");try store.snapshot(id:"fixture",record:["id":"fixture"])
        for frame in frames {_ = try store.enqueueAudio("fixture",frame:frame)}
        let transcriber=Transcriber();try await transcriber.load()
        var report=[[String:Any]](),finished=0
        while true {
            let batch=try store.nextAudioBatch(now:9_000_000_000_000)
            guard let first=batch.first else {break}
            let chunks=try batch.map{try AudioChunk.decode($0)}
            let chunk=AudioChunk(session:"fixture",sequence:0,startedAt:chunks[0].startedAt,samples:chunks.flatMap(\.samples))
            let start=Date(),text=try await transcriber.transcribe(chunk)
            report.append(["id":first["id"]!,"source":first["source"]!,"t":chunk.startedAt,"duration":Double(chunk.samples.count)/16000,"seconds":Date().timeIntervalSince(start),"text":text])
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/tmp/call-assistant-hinglish-replay.json"))
            try store.finishAudioBatch(batch,text:text);finished+=batch.count
        }
        XCTAssertEqual(finished,frames.count)
        XCTAssertEqual(try store.archivedAudioCount(),frames.count,"Re-transcribing must retain every original frame")
        XCTAssertEqual(try store.audioCount(),0)
        // Content checks catch the observed lost-speech bug; they are not human-reference accuracy scores.
        let local=report.filter{$0["source"] as? String == "local"}.compactMap{$0["text"] as? String}.joined(separator:" ").lowercased()
        let remote=report.filter{$0["source"] as? String == "remote"}.compactMap{$0["text"] as? String}.joined(separator:" ").lowercased()
        XCTAssertTrue(local.contains("verification"),local)
        XCTAssertTrue(remote.contains("admin") && remote.contains("setting"),remote)
        XCTAssertFalse(local.contains("в"),local)
        print("Saved call replay: \(finished) original frames, \(report.count) batches")
    }
}
