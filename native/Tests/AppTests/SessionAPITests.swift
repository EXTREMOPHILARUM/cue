import XCTest
import CallCore
import WhisperKit
@testable import CallAssistant
final class SessionAPITests: XCTestCase {
    @MainActor func testCoachingSelectionPersistenceAndRoles() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let model=try AppModel(directory:folder,port:17375)
        defer { model.server.stop() }
        let snapshot: [String:Any] = ["method":"snapshot","peer":"test-peer","session":"one","record":["id":"abc-defg-hij","captions":[["speaker":"Sam","text":"Pilot","t":1]]]]
        _ = try await model.request(role:"extension",request:snapshot)
        XCTAssertEqual(model.activeSession,"one")
        let coach: [String:Any] = ["method":"coach","session":"one","program":"root = Canvas(Coach(\"Ask\",\"What is success?\",[],\"\"),[])","fallback":"Ask about success","expiresIn":0]
        do { _ = try await model.request(role:"extension",request:coach); XCTFail("Extension could coach itself") } catch { }
        _ = try await model.request(role:"assistant",request:coach)
        let saved=try XCTUnwrap(model.coaching)
        XCTAssertNil(saved["expiresAt"])
        try await Task.sleep(nanoseconds:1_100_000_000)
        XCTAssertEqual(model.coaching?["id"] as? String,saved["id"] as? String)
        model.feedback(["action":"asked","coachingID":"wrong"])
        let events=try model.store.read("one")["events"] as! [[String:Any]]
        XCTAssertFalse(events.contains { $0["kind"] as? String == "feedback" })
        model.setPaused(true)
        do { _ = try await model.request(role:"assistant",request:coach); XCTFail("Paused coaching accepted") } catch { }
        let result=try await model.request(role:"extension",request:snapshot)
        XCTAssertEqual(result["paused"] as? Bool,true)
        do { _ = try await model.request(role:"extension",request:["method":"capture-start","peer":"test-peer","session":"one"]); XCTFail("Audio accepted without model") } catch { }
        _ = try await model.request(role:"assistant",request:["method":"delete","session":"one"])
        XCTAssertNil(model.activeSession)
    }
}

extension SessionAPITests {
    @MainActor func testAudioRestartKeepsBothTranscriptsWhenExplicitlyRequested() async throws {
        guard let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_AUDIO_FIXTURE"] else { throw XCTSkip("Set CALL_ASSISTANT_AUDIO_FIXTURE for streaming inference test") }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let model=try AppModel(directory:folder,port:17377)
        defer { model.server.stop() }
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"audio-test","peer":"fixture","record":["id":"abc-defg-hij"]])
        model.loadModel()
        for _ in 0..<600 {
            if model.modelStatus.hasPrefix("Ready") { break }
            if model.modelStatus == "Model failed" { XCTFail(model.errorMessage); return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        XCTAssertTrue(model.modelStatus.hasPrefix("Ready"),model.errorMessage)
        let samples=try AudioProcessor.loadAudioAsFloatArray(fromPath:path)
        let pcm=Array(samples.prefix(16000*8)).withUnsafeBytes { Data($0).base64EncodedString() }
        for attempt in 1...2 {
            _ = try await model.request(role:"extension",request:["method":"capture-start","session":"audio-test","peer":"fixture"])
            _ = try await model.request(role:"extension",request:["method":"audio","session":"audio-test","peer":"fixture","sequence":0,"sampleRate":16000,"startedAt":Date().timeIntervalSince1970*1000,"pcm":pcm])
            _ = try await model.request(role:"extension",request:["method":"capture-stop","session":"audio-test","peer":"fixture"])
            var count=0
            for _ in 0..<600 {
                let result=try model.store.export("audio-test")
                count=(result["segments"] as! [[String:Any]]).count
                if count >= attempt { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            XCTAssertEqual(try model.store.archivedAudioCount(),attempt)
            XCTAssertEqual(count,attempt,"Restart replaced a previous transcript or inference failed: \(model.errorMessage)")
        }
    }
}

extension SessionAPITests {
    @MainActor func testDesktopRetainsAudioMeetCaptionsAndLocalTranscript() async throws {
        guard let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_AUDIO_FIXTURE"] else { throw XCTSkip("Set CALL_ASSISTANT_AUDIO_FIXTURE for archive inference test") }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let model=try AppModel(directory:folder,port:17379)
        defer { model.server.stop() }
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"archive-test","peer":"fixture","record":["id":"abc-defg-hij","captions":[["text":"Meet supplied caption","speaker":"Sam","t":1]]]])
        let samples=try AudioProcessor.loadAudioAsFloatArray(fromPath:path)
        let pcm=Array(samples.prefix(16000*8)).withUnsafeBytes { Data($0).base64EncodedString() }
        let request:[String:Any]=["method":"ingest-audio","session":"archive-test","frame":["id":"archive-frame","source":"remote","sampleRate":16000,"startedAt":2.0,"pcm":pcm]]
        let ack=try await model.request(role:"extension",request:request)
        XCTAssertEqual(ack["stored"] as? Bool,true)
        XCTAssertEqual(try SessionStore(path:folder.appendingPathComponent("sessions.sqlite3").path).audioCount(),1,"ACK must mean durable storage before the model is loaded")
        model.loadModel()
        for _ in 0..<600 {
            if try model.store.audioCount()==0 { break }
            if model.modelStatus == "Model failed" { XCTFail(model.errorMessage);return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        XCTAssertEqual(try model.store.audioCount(),0,model.errorMessage)
        let segments=try model.store.detail("archive-test")["segments"] as! [[String:Any]]
        XCTAssertTrue(segments.contains{$0["source"] as? String == "meet" && $0["text"] as? String == "Meet supplied caption"})
        XCTAssertTrue(segments.contains{$0["source"] as? String == "whisper-remote" && !($0["text"] as? String ?? "").isEmpty})
        XCTAssertEqual(try model.store.archivedAudio("archive-test").first?["pcm"] as? String,pcm)
        let replay=try await model.request(role:"extension",request:request)
        XCTAssertEqual(replay["added"] as? Bool,false)
        XCTAssertEqual(try model.store.archivedAudioCount(),1)
    }
}
