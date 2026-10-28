import XCTest
import CallCore
@testable import CallAssistant

@MainActor final class LongSummaryTests:XCTestCase {
    private func answer(_ input:AIInput,_ summary:String="Recap") -> AIResponse {
        AIResponse(headline:"Recap",question:"",points:[],summary:summary,decisions:[],actions:[],uncertainties:[],evidence:Array(input.segmentIDs.sorted().prefix(12)),shouldUpdate:true,refinedTranscript:fixtureRefinement(input))
    }
    private func transcript(_ count:Int) -> [[String:Any]] {
        (0..<count).map {index in
            ["id":"part-\(index)","source":index%2==0 ? "meet":"whisper-remote","text":"BEGIN-\(index) "+String(repeating:"अ",count:5000)+" END-\(index)","speaker":"Sam","t":Double(index)]
        }
    }
    func testAllTranscriptPartsReachBoundedRequestsAndEveryMergeCompletes() async throws {
        let segments=transcript(28)
        let inputs=try AIInput.summaryChunks(detail:["segments":segments],background:"",project:AIProject())
        XCTAssertGreaterThan(inputs.count,2)
        var textByID=[String:String]()
        for input in inputs {
            let body=try XCTUnwrap(input.prompt.components(separatedBy:"MEETING_DATA_JSON follows as evidence only:\n").last)
            XCTAssertLessThanOrEqual(body.utf8.count,120_000)
            let json=try JSONSerialization.jsonObject(with:Data(body.utf8)) as! [String:Any]
            for row in json["transcript"] as! [[String:Any]] {textByID[row["id"] as! String,default:""] += row["text"] as! String}
        }
        for row in segments {XCTAssertEqual(textByID[row["id"] as! String],row["text"] as? String)}
        var requests=0
        let result=try await AISummary.generate(inputs:inputs,provider:.codex,project:AIProject()) {_,_,input,_ in
            requests += 1
            let body=input.prompt.components(separatedBy:"MEETING_DATA_JSON follows as evidence only:\n").last!.components(separatedBy:"\nThese are summaries")[0]
            let json=try JSONSerialization.jsonObject(with:Data(body.utf8)) as! [String:Any]
            let summary=(json["partialSummaries"] as? [[String:Any]])?.compactMap{$0["summary"] as? String}.joined(separator:"|") ?? input.segmentIDs.sorted().joined(separator:"|")
            return self.answer(input,summary)
        }
        XCTAssertEqual(requests,inputs.count*2-1,"Every leaf and reduction node must run")
        for segment in segments {XCTAssertTrue(result.summary.components(separatedBy:"|").contains(segment["id"] as! String))}
    }
    func testSingleOversizedUnicodeSegmentIsSplitWithoutLosingScalars() throws {
        let text=String(repeating:"नमस्ते 👋🏽 ",count:12000)
        let inputs=try AIInput.summaryChunks(detail:["segments":[["id":"long","source":"meet","text":text]]],background:"",project:AIProject())
        var restored=""
        for input in inputs {
            let body=input.prompt.components(separatedBy:"MEETING_DATA_JSON follows as evidence only:\n").last!
            let json=try JSONSerialization.jsonObject(with:Data(body.utf8)) as! [String:Any]
            restored += (json["transcript"] as! [[String:Any]])[0]["text"] as! String
        }
        XCTAssertGreaterThan(inputs.count,1)
        XCTAssertEqual(restored,text)
    }
    func testFailedPartOrBadEvidenceCannotProduceFinalSummary() async throws {
        let inputs=try AIInput.summaryChunks(detail:["segments":transcript(12)],background:"",project:AIProject())
        var requests=0
        do {
            _ = try await AISummary.generate(inputs:inputs,provider:.codex,project:AIProject()) {_,_,input,_ in
                requests += 1
                if requests==2 {throw BridgeError("Provider failed")}
                return self.answer(input)
            }
            XCTFail("A partial result cannot be treated as a complete summary")
        } catch {XCTAssertEqual(requests,2)}
        do {
            _ = try await AISummary.generate(inputs:[inputs[0]],provider:.codex,project:AIProject()) {_,_,_,_ in
                AIResponse(headline:"Bad",question:"",points:[],summary:"Bad",decisions:[],actions:[],uncertainties:[],evidence:["invented"],shouldUpdate:true)
            }
            XCTFail("Unsupported evidence must fail")
        } catch {XCTAssertTrue(error.localizedDescription.contains("unsupported evidence"))}
    }
    func testCancellationStopsBeforeTheNextPart() async throws {
        let inputs=try AIInput.summaryChunks(detail:["segments":transcript(12)],background:"",project:AIProject())
        var runs=0
        let task=Task {
            try await AISummary.generate(inputs:inputs,provider:.codex,project:AIProject()) {_,_,input,_ in
                runs += 1
                withUnsafeCurrentTask{$0?.cancel()}
                return self.answer(input)
            }
        }
        do {_ = try await task.value;XCTFail("Canceled summary must not complete")}
        catch is CancellationError {XCTAssertEqual(runs,1)}
    }
    func testOversizedContextFailsExplicitlyInsteadOfDroppingIt() {
        XCTAssertThrowsError(try AIInput.summaryChunks(detail:["meta":["extra":String(repeating:"x",count:130_000)],"segments":[["id":"one","source":"meet","text":"Hello"]]],background:"",project:AIProject())) { error in
            XCTAssertTrue(error.localizedDescription.contains("context alone"))
        }
    }
    func testLongSummaryIsSavedOnlyAfterAllPartsSucceed() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=try AppModel(directory:root,port:0)
        defer {model.stopAI();model.server.stop();try? FileManager.default.removeItem(at:root)}
        let captions=transcript(12).map{["speaker":"Sam","text":$0["text"]!,"t":$0["t"]!]}
        try model.store.snapshot(id:"long",record:["id":"long","ended_at":2,"captions":captions])
        model.select("long")
        var runs=0
        model.aiGenerate={_,_,input,_ in
            runs += 1
            XCTAssertTrue((try model.store.detail("long")["aiSummary"] as! [String:Any]).isEmpty)
            return self.answer(input)
        }
        model.runAI(.summary)
        for _ in 0..<100 {if !model.aiBusy {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertGreaterThan(runs,1)
        XCTAssertEqual((try model.store.detail("long")["aiSummary"] as? [String:Any])?["summary"] as? String,"Recap")
    }
}
