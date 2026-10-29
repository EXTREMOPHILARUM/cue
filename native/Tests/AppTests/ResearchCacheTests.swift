import XCTest
@testable import CallAssistant

@MainActor final class ResearchCacheTests:XCTestCase {
    private func settle(_ condition:() -> Bool) async throws {
        for _ in 0..<100 {
            if condition() {return}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        XCTFail("Research task did not reach expected state")
    }
    func testSwitchingProjectClearsExcerptsAndLateOldResultsCannotOverwriteNewOwner() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=try AppModel(directory:root,port:0);model.setCaptureConsent(true);model.setAIConsent(true)
        defer {model.stopAI();model.server.stop();try? FileManager.default.removeItem(at:root)}
        let a=AIProject(path:root.appendingPathComponent("a").path),b=AIProject(path:root.appendingPathComponent("b").path),c=AIProject(path:root.appendingPathComponent("c").path)
        var delayed:CheckedContinuation<[[String:String]],Error>?
        model.researchSearch={path,_ in
            if path==b.path {return try await withCheckedThrowingContinuation {delayed=$0}}
            return [["file":path,"text":"Only "+path]]
        }
        model.lookupProject("pricing",id:"call",project:a)
        try await settle {!model.researchContext(id:"call",project:a).isEmpty}
        model.lookupProject("pricing",id:"call",project:b)
        try await settle {delayed != nil}
        XCTAssertTrue(model.researchContext(id:"call",project:b).isEmpty,"Pending B must not expose A excerpts")
        XCTAssertTrue(model.researchContext(id:"call",project:a).isEmpty)
        model.lookupProject("pricing",id:"call",project:c)
        try await settle {!model.researchContext(id:"call",project:c).isEmpty}
        delayed?.resume(returning:[["file":"b","text":"Late B"]]);delayed=nil
        await Task.yield()
        XCTAssertEqual(model.researchContext(id:"call",project:c).first?["file"],c.path)
    }
    func testCanceledAndFailedLookupsCanRetryTheSameQuery() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=try AppModel(directory:root,port:0);model.setCaptureConsent(true);model.setAIConsent(true)
        defer {model.stopAI();model.server.stop();try? FileManager.default.removeItem(at:root)}
        try model.store.snapshot(id:"call",record:["id":"call"])
        model.liveAISession="call"
        let project=AIProject(path:root.path)
        var calls=0,delayed:CheckedContinuation<[[String:String]],Error>?
        model.researchSearch={_,_ in
            calls += 1
            if calls==1 {return try await withCheckedThrowingContinuation {delayed=$0}}
            if calls==2 {throw NSError(domain:"test",code:1)}
            return [["file":"verified.md","text":"Result"]]
        }
        model.lookupProject("pricing",id:"call",project:project)
        try await settle {delayed != nil}
        model.setCoachingPaused(true)
        delayed?.resume(returning:[["file":"canceled","text":"Ignore"]]);delayed=nil
        model.setCoachingPaused(false)
        model.lookupProject("pricing",id:"call",project:project)
        try await settle {model.researchContext(id:"call",project:project).first?["file"]=="Lookup unavailable"}
        model.lookupProject("pricing",id:"call",project:project)
        try await settle {model.researchContext(id:"call",project:project).first?["file"]=="verified.md"}
        XCTAssertEqual(calls,3)
    }
}
