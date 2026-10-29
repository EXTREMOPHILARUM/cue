import XCTest
import CallCore
@testable import CallAssistant

func fixtureRefinement(_ input:AIInput) -> [RefinedTurn] {
    input.segmentIDs.sorted().map{RefinedTurn(sourceIDs:[$0],text:"Fixture speech",uncertainty:"")}
}

@MainActor final class RefinementTests:XCTestCase {
    func testReconciledTranscriptPreservesSourcesAndRejectsOmissions() async throws {
        let sources:[[String:Any]]=[
            ["id":"meet-0","source":"meet","text":"Budget is fifteen","speaker":"Sam","t":10.0],
            ["id":"audio-0","source":"whisper-remote","text":"Budget is fifty","speaker":"Unknown","t":11.0]]
        let inputs=try AIInput.summaryChunks(detail:["segments":sources],background:"",project:AIProject())
        let response=try await AISummary.generate(inputs:inputs,provider:.codex,project:AIProject()) {_,_,input,_ in
            AIResponse(headline:"Budget",question:"",points:[],summary:"Budget discussed",decisions:[],actions:[],uncertainties:["Amount unclear"],evidence:["meet-0"],shouldUpdate:true,
                       refinedTranscript:[RefinedTurn(sourceIDs:Array(input.segmentIDs),text:"Budget is [fifteen or fifty]",uncertainty:"Sources disagree on the amount")])
        }
        let refined=response.refinedSegments(sources:sources)
        XCTAssertEqual(refined.count,1);XCTAssertEqual(refined[0]["speaker"] as? String,"Sam")
        XCTAssertEqual(refined[0]["t"] as? Double,10)
        XCTAssertEqual(Set(refined[0]["sourceIDs"] as! [String]),Set(["meet-0","audio-0"]))
        var incomplete=response;incomplete.refinedTranscript=[RefinedTurn(sourceIDs:["meet-0"],text:"Budget",uncertainty:"")]
        XCTAssertThrowsError(try incomplete.validateRefinement(segmentIDs:inputs[0].segmentIDs))
        incomplete.refinedTranscript=[RefinedTurn(sourceIDs:["invented"],text:"Budget",uncertainty:"")]
        XCTAssertThrowsError(try incomplete.validateRefinement(segmentIDs:inputs[0].segmentIDs))
    }
    func testRefinementSurvivesReopeningButDisappearsAfterSourceRevision() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let path=folder.appendingPathComponent("test.sqlite").path,store=try SessionStore(path:path)
        try store.snapshot(id:"call",record:["id":"call","captions":[["text":"Original","speaker":"Sam","t":1.0]]])
        let sources=try store.detail("call")["segments"]!
        try store.append("call",kind:"ai-summary",body:["refinementSources":try Validation.json(sources),"refinedSegments":[["id":"refined-0","text":"Refined"]]])
        let reopened=try SessionStore(path:path)
        XCTAssertEqual(try reopened.refinedTranscript(reopened.detail("call")).count,1)
        try reopened.snapshot(id:"call",record:["id":"call","captions":[["text":"Revised","speaker":"Sam","t":1.0]]])
        XCTAssertTrue(try reopened.refinedTranscript(reopened.detail("call")).isEmpty)
        XCTAssertEqual((try reopened.detail("call")["segments"] as! [[String:Any]])[0]["text"] as? String,"Revised")
    }
    func testLiveRefinementKeepsPendingSpeechAndRejectsStaleTurnsAfterReopening() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let path=folder.appendingPathComponent("test.sqlite").path,store=try SessionStore(path:path)
        let first:[String:Any] = ["text":"First sentence","speaker":"Sam","t":1.0]
        let second:[String:Any] = ["text":"Second sentence","speaker":"Jo","t":2.0]
        try store.snapshot(id:"call",record:["id":"call","captions":[first,second]])
        let sources=try XCTUnwrap(store.detail("call")["segments"] as? [[String:Any]])
        let id=try XCTUnwrap(sources[0]["id"] as? String)
        try store.saveLiveRefinement("call",sources:[sources[0]],turns:[["sourceIDs":[id],"text":"First corrected sentence"]])
        var display=try store.refinedTranscript(store.detail("call"))
        XCTAssertEqual(display.count,2)
        XCTAssertEqual(display[0]["text"] as? String,"First corrected sentence")
        XCTAssertEqual(display[1]["text"] as? String,"Second sentence")
        XCTAssertEqual(display[0]["speaker"] as? String,"Sam")
        XCTAssertThrowsError(try store.saveLiveRefinement("call",sources:sources,turns:[["sourceIDs":[id],"text":"Incomplete"]]))
        XCTAssertThrowsError(try store.saveLiveRefinement("call",sources:sources,turns:[["sourceIDs":["invented"],"text":"Invented"]]))
        let secondID=try XCTUnwrap(sources[1]["id"] as? String)
        try store.saveLiveRefinement("call",sources:[sources[1]],turns:[["sourceIDs":[secondID],"text":"Second corrected sentence"]])
        let reopened=try SessionStore(path:path)
        XCTAssertEqual(try reopened.refinedTranscript(reopened.detail("call")).count,2)
        try reopened.snapshot(id:"call",record:["id":"call","captions":[["text":"Revised first","speaker":"Sam","t":1.0],second,["text":"New speech","t":3.0]]])
        display=try reopened.refinedTranscript(reopened.detail("call"))
        XCTAssertEqual(display.compactMap{$0["text"] as? String},["Revised first","Second corrected sentence","New speech"])
        XCTAssertEqual((try reopened.detail("call")["segments"] as! [[String:Any]]).count,3)
    }
    func testLiveRefinementIsConsentGatedBoundedAndDoesNotRepeatUnchangedSpeech() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17445,preferences:nil)
        defer {model.stopAI();model.server.stop()}
        try model.store.snapshot(id:"live",record:["id":"live","captions":[["text":"A useful sentence","speaker":"Sam","t":1.0]]])
        model.select("live");model.extensionConnected=true
        var requests=0
        model.aiGenerate={_,mode,input,_ in
            requests += 1;XCTAssertEqual(mode,.refinement)
            XCTAssertTrue(input.prompt.contains("Do not default to questions"))
            return AIResponse(headline:"",question:"",points:[],summary:"",decisions:[],actions:[],uncertainties:[],evidence:[],shouldUpdate:false,refinedTranscript:fixtureRefinement(input))
        }
        let now=Date()
        model.tickLiveRefinement(now:now);model.tickLiveRefinement(now:now.addingTimeInterval(60))
        XCTAssertEqual(requests,0)
        model.setCaptureConsent(true);model.setAIConsent(true)
        model.tickLiveRefinement(now:now)
        model.tickLiveRefinement(now:now.addingTimeInterval(20))
        try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertEqual(requests,1)
        XCTAssertFalse(try model.store.refinedTranscript(model.store.detail("live")).isEmpty)
        model.tickLiveRefinement(now:now.addingTimeInterval(60))
        try await Task.sleep(nanoseconds:10_000_000)
        XCTAssertEqual(requests,1)
        let sources=(0..<100).map{["id":"s-\($0)","source":"meet","text":"Sentence \($0)","t":Double($0)] as [String:Any]}
        let input=try AIInput.liveRefinement(detail:["segments":sources])
        XCTAssertEqual(input.segmentIDs.count,60);XCTAssertTrue(input.segmentIDs.contains("s-99"));XCTAssertFalse(input.segmentIDs.contains("s-0"))
    }

    func testRefinementFailureDoesNotStopLiveCoaching() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17446,preferences:nil)
        defer {model.stopAI();model.server.stop()}
        model.setCaptureConsent(true);model.setAIConsent(true)
        try model.store.snapshot(id:"live",record:["id":"live","captions":[["text":"A sentence","t":1.0]]])
        model.select("live");model.extensionConnected=true
        model.aiGenerate={_,mode,_,_ in
            if mode == .refinement {throw BridgeError("Fixture provider failure")}
            return AIResponse(headline:"",question:"",points:[],summary:"",decisions:[],actions:[],uncertainties:[],evidence:[],shouldUpdate:false)
        }
        model.startLiveAI()
        try await Task.sleep(nanoseconds:20_000_000)
        let now=Date();model.tickLiveRefinement(now:now);model.tickLiveRefinement(now:now.addingTimeInterval(20))
        try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertEqual(model.liveAISession,"live");XCTAssertFalse(model.paused)
        XCTAssertEqual(model.aiError,"Fixture provider failure")
    }

}
