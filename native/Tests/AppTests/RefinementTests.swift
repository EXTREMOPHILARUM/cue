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
        try store.snapshot(id:"call",record:["id":"call","captions":[["text":"Original","speaker":"Sam","t":1]]])
        let sources=try store.detail("call")["segments"]!
        try store.append("call",kind:"ai-summary",body:["refinementSources":try Validation.json(sources),"refinedSegments":[["id":"refined-0","text":"Refined"]]])
        let reopened=try SessionStore(path:path)
        XCTAssertEqual(try reopened.refinedTranscript(reopened.detail("call")).count,1)
        try reopened.snapshot(id:"call",record:["id":"call","captions":[["text":"Revised","speaker":"Sam","t":1]]])
        XCTAssertTrue(try reopened.refinedTranscript(reopened.detail("call")).isEmpty)
        XCTAssertEqual((try reopened.detail("call")["segments"] as! [[String:Any]])[0]["text"] as? String,"Revised")
    }
}
