import XCTest
import CallCore
@testable import CallAssistant

@MainActor final class SetupTests:XCTestCase {
    func testConsentIsExplicitPersistentAndRevocableWithoutDeletingCalls() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name="cue-setup-test-"+UUID().uuidString
        let preferences=try XCTUnwrap(UserDefaults(suiteName:name))
        defer {preferences.removePersistentDomain(forName:name);try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:0,preferences:preferences)
        defer {model.stopAI();model.server.stop()}
        XCTAssertFalse(model.captureConsentGranted);XCTAssertFalse(model.aiConsentGranted);XCTAssertTrue(model.paused)
        model.setPaused(false);XCTAssertTrue(model.paused,"Resume cannot bypass permission")
        let record:[String:Any]=["id":"synthetic","captions":[["speaker":"You","text":"Test recording permission","t":1]]]
        let request:[String:Any]=["method":"snapshot","session":"synthetic","peer":"test","record":record]
        let blocked=try await model.request(role:"extension",request:request)
        XCTAssertEqual(blocked["paused"] as? Bool,true);XCTAssertFalse(try model.store.exists("synthetic"))
        model.setCaptureConsent(true)
        _ = try await model.request(role:"extension",request:request)
        XCTAssertTrue(try model.store.exists("synthetic"))
        var requests=0
        model.aiGenerate={_,_,_,_ in requests+=1;throw BridgeError("Synthetic provider")}
        model.runAI(.coaching)
        XCTAssertEqual(requests,0);XCTAssertTrue(model.aiError.contains("Allow optional AI"))
        model.setAIConsent(true);model.runAI(.coaching)
        for _ in 0..<100 {if !model.aiBusy {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(requests,1)
        let reopened=try AppModel(directory:root,port:0,preferences:preferences)
        defer {reopened.server.stop()}
        XCTAssertTrue(reopened.captureConsentGranted);XCTAssertTrue(reopened.aiConsentGranted)
        model.setAIConsent(false);XCTAssertFalse(preferences.bool(forKey:"aiConsentGranted"))
        model.setCaptureConsent(false);XCTAssertTrue(model.paused)
        XCTAssertTrue(try model.store.exists("synthetic"),"Revocation must retain existing recordings")
    }
    func testSpeechCacheCheckRejectsMissingAndPartialDownloads() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        XCTAssertFalse(Transcriber.downloaded(at:root))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data().write(to:root.appendingPathComponent("config.json"))
        XCTAssertFalse(Transcriber.downloaded(at:root))
        for name in ["AudioEncoder.mlmodelc","MelSpectrogram.mlmodelc","TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)
        }
        XCTAssertTrue(Transcriber.downloaded(at:root))
    }
}
