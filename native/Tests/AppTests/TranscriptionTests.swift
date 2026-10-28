import XCTest
import WhisperKit
import CallCore
@testable import CallAssistant

final class TranscriptionTests: XCTestCase {
    @MainActor func testBothWebRTCSpeechTracksReachDurableTranscripts() async throws {
        guard let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_WEBRTC_FIXTURE"] else { throw XCTSkip("Set the isolated WebRTC speech fixture") }
        let frames=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [[String:Any]]
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let model=try AppModel(directory:directory,port:17380)
        defer { model.server.stop() }
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"webrtc","peer":"fixture","record":["id":"webrtc","ended":true]])
        for frame in frames {
            var value=frame;value["sampleRate"]=16000
            let ack=try await model.request(role:"extension",request:["method":"ingest-audio","session":"webrtc","frame":value])
            XCTAssertEqual(ack["stored"] as? Bool,true)
        }
        XCTAssertEqual(try SessionStore(path:directory.appendingPathComponent("sessions.sqlite3").path).audioCount(),frames.count)
        model.loadModel()
        for _ in 0..<1200 {
            if try model.store.audioCount()==0 { break }
            if model.modelStatus == "Model failed" { XCTFail(model.errorMessage);return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        XCTAssertEqual(try model.store.audioCount(),0,model.errorMessage)
        XCTAssertEqual(try model.store.archivedAudioCount(),frames.count)
        let segments=try model.store.detail("webrtc")["segments"] as! [[String:Any]]
        for source in ["whisper-local","whisper-remote"] {
            let text=segments.filter{$0["source"] as? String == source}.compactMap{$0["text"] as? String}.joined(separator:" ").lowercased()
            print("WebRTC \(source): \(text)")
            XCTAssertTrue(text.contains("successful pilot"),text)
            XCTAssertTrue(text.range(of:#"\b(?:twenty thousand|20,?000)\b"#,options:.regularExpression) != nil,text)
            XCTAssertFalse(text.contains("blank_audio"))
        }
        let silence=AudioChunk(session:"webrtc",sequence:0,startedAt:1,samples:[Float](repeating:0,count:256000))
        let transcriber=Transcriber();try await transcriber.load()
        let silentText=try await transcriber.transcribe(silence)
        XCTAssertEqual(silentText,"")
    }
    func testModelAndContextAgainstKnownSpeech() async throws {
        guard ProcessInfo.processInfo.environment["CALL_ASSISTANT_BENCHMARK"] == "1" else { throw XCTSkip("Set CALL_ASSISTANT_BENCHMARK for the local model comparison") }
        let references=[
            ("local","We should agree on the next step before ending the call. The customer needs a clear timeline, a named owner, and a successful pilot. Please send the proposal tomorrow morning so the engineering team can review the requirements."),
            ("remote","Our budget is twenty thousand dollars for the first quarter. We need to connect the calendar, review the security requirements, and schedule a demonstration. Can you confirm the delivery date and send a written summary after this meeting?")
        ]
        func words(_ text:String)->[String] {text.lowercased().split{!$0.isLetter && !$0.isNumber}.map(String.init)}
        func errors(_ expected:[String],_ actual:[String])->Int {
            var row=Array(0...actual.count)
            for (i,word) in expected.enumerated() {
                var next=[i+1]
                for (j,other) in actual.enumerated() {next.append(min(row[j+1]+1,next[j]+1,row[j]+(word==other ? 0:1)))}
                row=next
            }
            return row.last!
        }
        let old=try await WhisperKit(WhisperKitConfig(model:"tiny.en",verbose:false))
        let improved=Transcriber();try await improved.load()
        var oldErrors=0,newErrors=0,total=0
        for (name,reference) in references {
            let samples=try AudioProcessor.loadAudioAsFloatArray(fromPath:"/tmp/call-assistant-\(name).wav")
            var oldText="",newText=""
            let started=Date()
            for offset in stride(from:0,to:samples.count,by:64000) {
                oldText += try await old.transcribe(audioArray:Array(samples[offset..<min(offset+64000,samples.count)])).map(\.text).joined(separator:" ")+" "
            }
            let oldSeconds=Date().timeIntervalSince(started),newStarted=Date()
            for offset in stride(from:0,to:samples.count,by:256000) {
                newText += try await improved.transcribe(AudioChunk(session:"fixture",sequence:0,startedAt:1,samples:Array(samples[offset..<min(offset+256000,samples.count)])))+" "
            }
            let count=words(reference).count,oldCount=errors(words(reference),words(oldText)),newCount=errors(words(reference),words(newText))
            oldErrors+=oldCount;newErrors+=newCount;total+=count
            print("Benchmark \(name): old \(oldCount)/\(count) errors in \(oldSeconds)s: \(oldText)")
            print("Benchmark \(name): new \(newCount)/\(count) errors in \(Date().timeIntervalSince(newStarted))s: \(newText)")
        }
        print("Known speech WER: old \(oldErrors)/\(total), new \(newErrors)/\(total)")
        XCTAssertLessThan(newErrors,oldErrors)
    }
}

extension TranscriptionTests {
    func testPrivateCallClipWhenProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_REAL_CALL_FIXTURE"] else { throw XCTSkip("Set a private saved-call clip for manual accuracy review") }
        let samples=try AudioProcessor.loadAudioAsFloatArray(fromPath:path)
        let old=try await WhisperKit(WhisperKitConfig(model:"tiny.en",verbose:false))
        var oldText=""
        for offset in stride(from:0,to:samples.count,by:64000) {
            oldText += try await old.transcribe(audioArray:Array(samples[offset..<min(offset+64000,samples.count)])).map(\.text).joined(separator:" ")+" "
        }
        let improved=Transcriber();try await improved.load()
        let start=Date()
        let text=try await improved.transcribe(AudioChunk(session:"private",sequence:0,startedAt:1,samples:samples))
        print("Private clip old: \(oldText)")
        print("Private clip new (\(Date().timeIntervalSince(start))s for \(Double(samples.count)/16000)s audio): \(text)")
        XCTAssertFalse(text.isEmpty)
    }
}

extension TranscriptionTests {
    func testRealMeetNoiseAndSpeechWhenProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_NOISE_FIXTURE"] else {throw XCTSkip("Set a private Meet noise/speech fixture")}
        let examples=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [[String:Any]]
        let kit=try await WhisperKit(WhisperKitConfig(model:"small.en",verbose:false))
        let transcriber=Transcriber();try await transcriber.load()
        for example in examples {
            let chunks=try (example["frames"] as! [[String:Any]]).map{try AudioChunk.decode($0)}
            let chunk=AudioChunk(session:"fixture",sequence:0,startedAt:1,samples:chunks.flatMap(\.samples))
            let raw=try await kit.transcribe(audioArray:chunk.speechSamples,decodeOptions:DecodingOptions(language:"en",skipSpecialTokens:true,suppressBlank:true,concurrentWorkerCount:1))
            for segment in raw.flatMap(\.segments) {print("Noise diagnostic \(example["kind"]!): \(segment.text) noSpeech=\(segment.noSpeechProb) logprob=\(segment.avgLogprob)")}
            let text=try await transcriber.transcribe(chunk)
            if example["kind"] as? String == "noise" {XCTAssertEqual(text,"")}
            else {XCTAssertTrue(text.lowercased().contains("testing"),text)}
        }
    }
}
