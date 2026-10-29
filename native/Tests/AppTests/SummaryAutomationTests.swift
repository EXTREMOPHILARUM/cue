import XCTest
import CallCore
@testable import CallAssistant

@MainActor final class SummaryAutomationTests:XCTestCase {
    private func model() throws -> (AppModel,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=try AppModel(directory:root,port:0)
        model.setCaptureConsent(true);model.setAIConsent(true)
        return (model,root)
    }
    private func wait(_ model:AppModel) async throws {
        for _ in 0..<100 {
            if !model.aiBusy {return}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        XCTFail("AI task did not finish")
    }
    private func response(_ input:AIInput) -> AIResponse {
        AIResponse(headline:"Call recap",question:"",points:[],summary:"Saved recap",decisions:[],actions:[],uncertainties:[],evidence:Array(input.segmentIDs.prefix(12)),shouldUpdate:true,refinedTranscript:fixtureRefinement(input))
    }
    private func snapshot(_ model:AppModel,_ record:[String:Any]) async throws {
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"call","peer":"test","record":record])
    }
    func testCaptionRevisionsRetryFailuresInvalidateRunningResultsAndNotifyEachCompletion() async throws {
        let (model,root)=try model();defer {model.stopAI();model.server.stop();try? FileManager.default.removeItem(at:root)}
        model.automaticSummaries=true
        var record:[String:Any]=["id":"call"]
        try await snapshot(model,record)
        record["ended_at"]=2
        try await snapshot(model,record)
        model.tickSummaries(now:Date().addingTimeInterval(10))
        XCTAssertEqual(try model.store.summaryAutomation("call")["state"] as? String,"failed")
        var runs=0
        model.aiGenerate={_,_,input,_ in
            runs += 1
            try await Task.sleep(nanoseconds:30_000_000)
            return self.response(input)
        }
        record["captions"]=[["text":"First version","speaker":"You","t":1.0]]
        try await snapshot(model,record)
        model.tickSummaries(now:Date().addingTimeInterval(10));try await wait(model)
        let first=try XCTUnwrap(model.completedAutomaticSummary)
        XCTAssertEqual(runs,1)
        record["captions"]=[["text":"Second version","speaker":"You","t":1.0]]
        try await snapshot(model,record)
        model.tickSummaries(now:Date().addingTimeInterval(10))
        record["captions"]=[["text":"Final corrected version","speaker":"You","t":1.0]]
        try await snapshot(model,record)
        try await wait(model)
        XCTAssertEqual(try model.store.summaryAutomation("call")["state"] as? String,"queued")
        XCTAssertEqual(model.completedAutomaticSummary,first,"Stale results cannot emit completion")
        model.tickSummaries(now:Date().addingTimeInterval(10));try await wait(model)
        XCTAssertEqual(runs,3)
        XCTAssertEqual(model.completedAutomaticSummary?.session,first.session)
        XCTAssertNotEqual(model.completedAutomaticSummary?.requestID,first.requestID)
        try await snapshot(model,record)
        XCTAssertTrue(try model.store.pendingSummaries().isEmpty,"Identical snapshots cannot trigger regeneration")
    }
    func testLegacyRecurringProjectIsUsedByAutomaticGenerationAndConversationsStayConsistent() async throws {
        let (model,root)=try model();defer {model.stopAI();model.server.stop();try? FileManager.default.removeItem(at:root)}
        model.automaticSummaries=true
        for (id,title) in [("past","Meet — Weekly   Review"),("future","weekly review")] {
            try model.store.snapshot(id:id,record:["id":id,"title":title,"ended_at":2,"captions":[["text":"Discussion","speaker":"Sam","t":1]]])
        }
        model.select("past")
        try model.saveAIProject(AIProject(path:root.path,background:"Shared context"),for:"past",shareProject:true)
        let groups=groupedCallHistory(try model.store.list())
        XCTAssertEqual(groups.count,1)
        var received=false
        model.aiGenerate={_,_,input,project in
            received=true
            XCTAssertEqual(project.path,root.path)
            XCTAssertEqual(project.background,"Shared context")
            return self.response(input)
        }
        try model.store.append("future",kind:"summary-automation",body:["state":"queued","t":0,"requestID":"future"])
        model.tickSummaries();try await wait(model)
        XCTAssertTrue(received)
        model.select("future")
        let conflicting=AIProject(path:FileManager.default.temporaryDirectory.path,conversation:UUID().uuidString)
        XCTAssertThrowsError(try model.saveAIProject(conflicting,for:"future")) { error in
            XCTAssertTrue(error.localizedDescription.contains("recurring call’s project"))
        }
        try model.saveAIProject(AIProject(),for:"future",shareProject:true)
        let managed=AIProject(path:root.appendingPathComponent("Conversations").path,conversation:UUID().uuidString)
        try model.store.append("past",kind:"ai-settings",body:try JSONSerialization.jsonObject(with:JSONEncoder().encode(managed)) as! [String:Any])
        model.select("past")
        XCTAssertEqual(model.aiProject.conversation,managed.conversation,"Removing a folder must not discard a managed per-call conversation")
        XCTAssertEqual(model.aiProject.path,managed.path)
        XCTAssertNil(SessionStore.recurringProjectKey(["title":"Meet"]))
        XCTAssertEqual(SessionStore.recurringProjectKey(["title":"Meet","recordID":"record-one"]),"record:record-one")
    }
    func testBadQueuedSettingsDoNotStarveOtherCalls() async throws {
        let (model,root)=try model();defer {model.stopAI();model.server.stop();try? FileManager.default.removeItem(at:root)}
        model.automaticSummaries=true
        for id in ["bad","good"] {
            try model.store.snapshot(id:id,record:["id":id,"ended_at":2,"captions":[["text":"Discussion","speaker":"Sam","t":1]]])
            try model.store.append(id,kind:"summary-automation",body:["state":"queued","requestID":id,"t":0])
        }
        try model.store.append("bad",kind:"ai-settings",body:["path":42])
        model.aiGenerate={_,_,input,_ in self.response(input)}
        model.tickSummaries();try await wait(model)
        XCTAssertEqual(try model.store.summaryAutomation("bad")["state"] as? String,"failed")
        XCTAssertEqual(try model.store.summaryAutomation("good")["state"] as? String,"complete")
        XCTAssertTrue(try model.store.pendingSummaries().isEmpty)
    }
}
