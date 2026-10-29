import XCTest
import CallCore
@testable import CallAssistant

final class AITests:XCTestCase {
    @MainActor func testRecurringProjectAppliesToPastAndFutureCallsAndCanBeRemoved() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17409);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.server.stop()}
        for id in ["one","two","other"] {
            try model.store.snapshot(id:id,record:["id":id,"series_id":id=="other" ? "different":"weekly"])
        }
        model.select("one")
        let project=AIProject(path:root.path,background:"Shared briefing")
        try model.saveAIProject(project,for:"one",shareProject:true)
        model.select("two");XCTAssertEqual(model.aiProject.path,root.path);XCTAssertEqual(model.aiProject.background,"Shared briefing")
        try model.store.snapshot(id:"future",record:["id":"future","series_id":"weekly"])
        let future=try model.projectForCall(model.store.detail("future"))
        XCTAssertEqual(future.path,root.path);XCTAssertEqual(future.conversation,"")
        model.select("other");XCTAssertEqual(model.aiProject.path,"")
        let reopened=try SessionStore(path:root.appendingPathComponent("sessions.sqlite3").path)
        XCTAssertEqual(try reopened.seriesProject("weekly")?["path"] as? String,root.path)
        model.select("two")
        try model.saveAIProject(AIProject(),for:"two",shareProject:true)
        model.select("one");XCTAssertEqual(model.aiProject.path,"");XCTAssertEqual(model.aiProject.background,"")
    }
    @MainActor func testSummaryTitlesSurviveBrowserUpdatesAndPreserveGrouping() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(path:root.appendingPathComponent("titles.sqlite3").path)
        let record:[String:Any]=["id":"one","title":"Weekly sync","series_id":"weekly"]
        try store.snapshot(id:"one",record:record)
        try store.snapshot(id:"two",record:["id":"two","title":"Weekly sync","series_id":"weekly"])
        try store.append("one",kind:"ai-summary",body:["headline":"Pilot launch and ownership"])
        try store.snapshot(id:"one",record:record)
        let meta=try XCTUnwrap(store.detail("one")["meta"] as? [String:Any])
        XCTAssertEqual(sessionTitle(meta),"Pilot launch and ownership")
        let calls=try store.list()
        XCTAssertEqual(groupedCallHistory(calls).count,1)
        XCTAssertEqual(groupedCallHistory(calls).first?.title,"Weekly sync")
        XCTAssertEqual(try store.search("Pilot launch").count,1)
        XCTAssertEqual(sessionTitle(["title":"Original title"]),"Original title")
    }
    @MainActor func testGlobalProviderAndCallAttachmentsStaySeparate() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let suite="CallAssistant.Tests."+UUID().uuidString
        let preferences=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {preferences.removePersistentDomain(forName:suite)}
        preferences.set(AIProvider.claude.rawValue,forKey:"aiProvider")
        let model=try AppModel(directory:root,port:17403,preferences:preferences);model.setCaptureConsent(true);model.setAIConsent(true)
        defer {model.server.stop()}
        for id in ["one","two"] {try model.store.snapshot(id:id,record:["id":"abc-defg-hij"])}
        let old=AIProject(path:root.path,conversation:UUID().uuidString,provider:.codex)
        try model.store.append("one",kind:"ai-settings",body:try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any])
        model.select("one")
        XCTAssertEqual(model.aiProvider,.claude)
        XCTAssertEqual(model.aiProject.provider,.claude)
        XCTAssertEqual(model.aiProject.conversation,"","A conversation cannot cross providers")
        var attached=model.aiProject;attached.background="Only for call one"
        try model.saveAIProject(attached,for:"one")
        model.select("two");XCTAssertEqual(model.aiProject.background,"")
        XCTAssertThrowsError(try model.saveAIProject(attached,for:"one"),"An open dialog must not attach another call's context")
        model.select("one");XCTAssertEqual(model.aiProject.background,"Only for call one")
        XCTAssertThrowsError(try model.saveAIProject(AIProject(path:root.appendingPathComponent("missing").path),for:"one"))
        XCTAssertEqual(model.aiProject.background,"Only for call one")
        model.aiBusy=true
        XCTAssertThrowsError(try model.saveAIProject(AIProject(),for:"one"))
        model.aiBusy=false
        model.aiProvider = .codex
        model.select("two");XCTAssertEqual(model.aiProject.provider,.codex)
        XCTAssertEqual(preferences.string(forKey:"aiProvider"),"codex")
    }
    @MainActor func testAutomaticSummaryWaitsForAudioAndSurvivesSelectionChanges() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17404);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.server.stop();model.stopAI()}
        model.automaticSummaries=true
        let record:[String:Any]=["id":"abc-defg-hij","captions":[["speaker":"Sam","text":"We need a pilot","t":1]]]
        for id in ["one","two"] {_ = try await model.request(role:"extension",request:["method":"snapshot","session":id,"peer":"fixture","record":record])}
        var ended=record;ended["ended_at"]=2
        _ = try await model.request(role:"assistant",request:["method":"import","session":"historical","record":ended])
        XCTAssertTrue(try model.store.pendingSummaries().isEmpty,"Historical imports must not trigger sends")
        model.historyQuery="no matching title";model.refreshHistory()
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"one","peer":"fixture","record":ended])
        XCTAssertEqual(try model.store.pendingSummaries().count,1,"Search filters must not hide completed calls from automation")
        let reopened=try SessionStore(path:root.appendingPathComponent("sessions.sqlite3").path)
        XCTAssertEqual(try reopened.pendingSummaries().count,1,"Queued summaries must survive reopening the database")
        let frame:[String:Any]=["id":"frame","source":"remote","sampleRate":16000,"startedAt":1.0,"pcm":Data(repeating:0,count:4).base64EncodedString()]
        _ = try model.store.enqueueAudio("one",frame:frame)
        var runs=0
        model.aiGenerate={_,mode,input,_ in
            runs += 1;XCTAssertEqual(mode,.summary)
            try await Task.sleep(nanoseconds:50_000_000)
            return AIResponse(headline:"Pilot",question:"",points:[],summary:"A pilot was discussed.",decisions:[],actions:[],uncertainties:[],evidence:["meet-0"],shouldUpdate:false,refinedTranscript:fixtureRefinement(input))
        }
        model.tickSummaries(now:Date().addingTimeInterval(10));XCTAssertFalse(model.aiBusy)
        try model.store.finishAudio(["id":"frame","session":"one","source":"remote","startedAt":1.0],text:"")
        model.setPaused(true);model.tickSummaries(now:Date().addingTimeInterval(10));XCTAssertFalse(model.aiBusy)
        model.setPaused(false);model.tickSummaries(now:Date().addingTimeInterval(10))
        model.select("two")
        for _ in 0..<50 {if !model.aiBusy {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(runs,1)
        XCTAssertEqual((try model.store.detail("one")["aiSummary"] as? [String:Any])?["summary"] as? String,"A pilot was discussed.")
        XCTAssertTrue((try model.store.detail("two")["aiSummary"] as! [String:Any]).isEmpty)
        XCTAssertEqual(model.activeSession,"two")
        XCTAssertEqual(model.completedAutomaticSummary?.session,"one")
        XCTAssertTrue(try model.store.pendingSummaries().isEmpty)
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"one","peer":"fixture","record":ended])
        XCTAssertTrue(try model.store.pendingSummaries().isEmpty,"Repeated completed snapshots must not regenerate summaries")
    }
    @MainActor func testAutomaticSummaryFailureDoesNotRetryInALoop() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17405);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.server.stop();model.stopAI()}
        model.automaticSummaries=true
        try model.store.snapshot(id:"one",record:["id":"abc-defg-hij","ended_at":2,"captions":[["text":"Pilot","speaker":"Sam","t":1]]])
        try model.store.append("one",kind:"summary-automation",body:["state":"queued","t":0.0,"requestID":"test"])
        var runs=0
        model.aiGenerate={_,_,_,_ in runs += 1;throw BridgeError("Provider unavailable")}
        model.tickSummaries()
        for _ in 0..<50 {if !model.aiBusy {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(try model.store.summaryAutomation("one")["state"] as? String,"failed")
        model.tickSummaries();XCTAssertEqual(runs,1)
        XCTAssertTrue(try model.store.pendingSummaries().isEmpty)
    }
    @MainActor func testLateAudioSupersedesAnAutomaticSummary() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17406);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.server.stop();model.stopAI()}
        model.automaticSummaries=true
        var record:[String:Any]=["id":"abc-defg-hij","captions":[["text":"Pilot","speaker":"Sam","t":1]]]
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"one","peer":"fixture","record":record])
        record["ended_at"]=2
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"one","peer":"fixture","record":record])
        var runs=0
        model.aiGenerate={_,_,input,_ in
            runs += 1
            if runs==2 {XCTAssertTrue(input.prompt.contains("Late detail"))}
            try await Task.sleep(nanoseconds:50_000_000)
            return AIResponse(headline:"Pilot",question:"",points:[],summary:"Pilot summary",decisions:[],actions:[],uncertainties:[],evidence:Array(input.segmentIDs),shouldUpdate:false,refinedTranscript:fixtureRefinement(input))
        }
        model.tickSummaries(now:Date().addingTimeInterval(10))
        let frame:[String:Any]=["id":"late","source":"remote","sampleRate":16000,"startedAt":1.0,"pcm":Data(repeating:0,count:4).base64EncodedString()]
        _ = try await model.request(role:"extension",request:["method":"ingest-audio","session":"one","frame":frame])
        try model.store.finishAudio(["id":"late","session":"one","source":"remote","startedAt":1.0],text:"Late detail")
        for _ in 0..<50 {if !model.aiBusy {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue((try model.store.detail("one")["aiSummary"] as! [String:Any]).isEmpty,"A stale response must not overwrite a newer queued transcript")
        XCTAssertEqual(try model.store.pendingSummaries().count,1)
        model.tickSummaries(now:Date().addingTimeInterval(10))
        for _ in 0..<50 {if !model.aiBusy {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(runs,2)
        XCTAssertEqual(try model.store.summaryAutomation("one")["state"] as? String,"complete")
    }

    private let answer=#"{"headline":"Clarify ownership","question":"Who owns the pilot?","points":["Confirm the deadline"],"summary":"A pilot was discussed.","decisions":[],"actions":[],"uncertainties":["Owner is unknown"],"evidence":["s1"],"shouldUpdate":true}"#
    private func detail()->[String:Any] {["meta":["title":"Test call"],"segments":[["id":"s1","speaker":"Sam","text":"We need a pilot","source":"whisper-remote","t":1],["id":"m1","text":"Duplicate caption","source":"meet","t":1]],"notes":[["text":"Confirm owner"]]]}
    private func folder() throws ->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    func testInputBoundsSourcesNotesProjectAndCitations() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        try "The pilot is called Amber".write(to:root.appendingPathComponent("CLAUDE.md"),atomically:true,encoding:.utf8)
        let project=AIProject(path:root.path)
        let input=try AIInput.make(detail:detail(),mode:.coaching,background:"Ask about ownership",previous:nil,project:project)
        XCTAssertEqual(input.segmentIDs,["s1"])
        XCTAssertTrue(input.prompt.contains("Confirm owner"));XCTAssertTrue(input.prompt.contains("Amber"))
        XCTAssertFalse(input.prompt.contains("Duplicate caption"))
        let response=try JSONDecoder().decode(AIResponse.self,from:Data(answer.utf8))
        XCTAssertThrowsError(try response.validate(segmentIDs:["other"]))
        XCTAssertTrue(try response.canvas().hasPrefix("root = Canvas(Coach("))
        XCTAssertThrowsError(try AIInput.make(detail:detail(),mode:.summary,background:String(repeating:"x",count:4001),previous:nil))
        XCTAssertThrowsError(try AIProject(path:root.path,conversation:UUID().uuidString).validate(provider:.codex))
        try String(repeating:"x",count:12_001).write(to:root.appendingPathComponent("CLAUDE.md"),atomically:true,encoding:.utf8)
        XCTAssertEqual(try project.context().first?["notice"],"Full file","Ordinary files over the old 12 KB cap must work")
        try String(repeating:"अ",count:20_000).write(to:root.appendingPathComponent("CLAUDE.md"),atomically:true,encoding:.utf8)
        let excerpts=try project.context()
        XCTAssertTrue(excerpts[0]["notice"]!.contains("Excerpt"))
        XCTAssertLessThanOrEqual(excerpts[0]["text"]!.utf8.count,32_000)
        XCTAssertFalse(excerpts[0]["text"]!.contains("�"))
        try Data([0xFF,0xFF]).write(to:root.appendingPathComponent("CLAUDE.md"))
        XCTAssertThrowsError(try project.context())
        var resumed=project;resumed.conversation=UUID().uuidString
        let resumedInput=try AIInput.make(detail:detail(),mode:.summary,background:"",previous:nil,project:resumed)
        XCTAssertFalse(resumedInput.prompt.contains("The pilot is called Amber"))
    }
    func testSummaryIncludesBothCompleteTranscriptSources() throws {
        var call=detail()
        call["segments"] = (0..<120).flatMap { index in
            [["id":"w-\(index)","source":"whisper-remote","text":"Audio \(index)","t":Double(index)],
             ["id":"m-\(index)","source":"meet","text":"Caption \(index)","t":Double(index)]]
        }
        let inputs=try AIInput.summaryChunks(detail:call,background:"",project:AIProject())
        let prompt=inputs.map(\.prompt).joined()
        XCTAssertEqual(Set(inputs.flatMap{$0.segmentIDs}).count,240)
        for text in ["Audio 0","Caption 0","Audio 119","Caption 119","whisper-remote","meet","do not double-count"] {
            XCTAssertTrue(prompt.contains(text),text)
        }
        var changed=call
        var segments=changed["segments"] as! [[String:Any]]
        segments[1]["text"]="Corrected caption"
        changed["segments"]=segments
        XCTAssertNotEqual(inputs.map(\.fingerprint),try AIInput.summaryChunks(detail:changed,background:"",project:AIProject()).map(\.fingerprint))
    }
    @MainActor func testSavedResultsProjectAndCancelledRunCannotCrossCalls() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17401);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.server.stop();model.stopAI()}
        for id in ["one","two"] {
            try model.store.snapshot(id:id,record:["id":"abc-defg-hij","ended_at":2,"captions":[["text":"We need a small pilot with a clear owner and a review next week","speaker":"Sam","t":1]]])
        }
        var result=try JSONDecoder().decode(AIResponse.self,from:Data(answer.utf8))
        result=AIResponse(headline:result.headline,question:result.question,points:result.points,summary:result.summary,decisions:[],actions:[],uncertainties:[],evidence:["meet-0"],shouldUpdate:true)
        try model.store.append("one",kind:"ai-coaching",body:["provider":"claude","project":"/other-project","conversationID":UUID().uuidString,"summary":"PRIVATE OTHER PROJECT"])
        model.aiGenerate={_,_,input,project in
            XCTAssertFalse(input.prompt.contains("PRIVATE OTHER PROJECT"))
            XCTAssertEqual(URL(fileURLWithPath:project.path).lastPathComponent,"Conversations")
            XCTAssertTrue(FileManager.default.fileExists(atPath:project.path))
            try await Task.sleep(nanoseconds:100_000_000)
            var refined=result;refined.refinedTranscript=fixtureRefinement(input);return refined
        }
        model.select("one");model.aiProject.background="Project one context";model.runAI(.summary)
        model.select("two")
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertTrue((try model.store.detail("two")["aiSummary"] as! [String:Any]).isEmpty)
        XCTAssertTrue((try model.store.detail("one")["aiSummary"] as! [String:Any]).isEmpty)
        model.select("one");model.runAI(.summary)
        for _ in 0..<50 {if !model.aiBusy {break};try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertEqual((try model.store.detail("one")["aiSummary"] as? [String:Any])?["headline"] as? String,result.headline)
        model.select("two");XCTAssertEqual(model.aiProject.background,"")
        model.select("one");XCTAssertEqual(model.aiProject.background,"Project one context")
        model.startLiveAI();XCTAssertNil(model.liveAISession,"An ended call cannot start automatic coaching")
    }
    @MainActor func testEndingLiveCallCancelsInFlightCoaching() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17402);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.server.stop();model.stopAI()}
        let record:[String:Any]=["id":"abc-defg-hij","captions":[["text":"We need a small pilot with a clear owner and a review next week","speaker":"Sam","t":1]]]
        try model.store.snapshot(id:"live",record:record);model.select("live")
        var calls=0
        model.aiGenerate={_,_,_,_ in
            calls += 1
            try await Task.sleep(nanoseconds:10_000_000_000)
            throw BridgeError("Should have been cancelled")
        }
        model.startLiveAI()
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertTrue(model.aiBusy);XCTAssertEqual(calls,1)
        var ended=record;ended["ended_at"]=2
        try model.store.snapshot(id:"live",record:ended)
        for _ in 0..<30 {if model.liveAISession==nil {break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertNil(model.liveAISession);XCTAssertFalse(model.aiBusy)
        XCTAssertTrue((try model.store.detail("live")["aiCoaching"] as! [String:Any]).isEmpty)
    }
    @MainActor func testRealProvidersWhenExplicitlyEnabled() async throws {
        let client=ACPClient();defer {client.close()}
        guard let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_AI_DETAIL"] else {throw XCTSkip("Set a selected-call detail fixture to test signed-in providers")}
        let selected=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [String:Any]
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        try "This is a meeting assistant integration test. The project codename is Amber.".write(to:root.appendingPathComponent("README.md"),atomically:true,encoding:.utf8)
        for provider in AIProvider.allCases {
            var project=AIProject(path:root.path,provider:provider)
            let input=try AIInput.make(detail:selected,mode:.summary,background:"Do not treat transcription errors as verified facts.",previous:nil,project:project)
            let response=try await client.generate(provider:provider,mode:.summary,input:input,project:project)
            XCTAssertFalse(response.summary.isEmpty);XCTAssertNotNil(response.conversationID)
            try response.json().writePrivate(to:URL(fileURLWithPath:"/tmp/call-assistant-ai-\(provider.rawValue)-summary.json"))
            project.conversation=try XCTUnwrap(response.conversationID)
            try project.validate(provider:provider)
            let choices=try project.conversations()
            XCTAssertTrue(choices.contains{$0.id==project.conversation})
            XCTAssertTrue(choices.contains{$0.project==root.resolvingSymlinksInPath().path})
            // Verify resume against context present only in the first request, not in this prompt.
            let followup=AIInput(prompt:"Integration check: return the required JSON object, with the project codename from our earlier conversation as headline. Set shouldUpdate=false, summary to a short recap of the earlier call, and all other strings/arrays empty. Do not use tools.",segmentIDs:input.segmentIDs,fingerprint:"resume-check")
            let coaching=try await client.generate(provider:provider,mode:.coaching,input:followup,project:project)
            XCTAssertEqual(coaching.conversationID,project.conversation)
            XCTAssertTrue(coaching.headline.contains("Amber"),coaching.headline)
            var ongoing=selected
            var meta=selected["meta"] as! [String:Any];meta["ended"]=false;meta.removeValue(forKey:"endedAt");ongoing["meta"]=meta
            ongoing["segments"]=Array((selected["segments"] as! [[String:Any]]).prefix(20))
            let liveInput=try AIInput.make(detail:ongoing,mode:.coaching,background:"",previous:nil,project:project)
            let live=try await client.generate(provider:provider,mode:.coaching,input:liveInput,project:project)
            XCTAssertTrue(live.shouldUpdate);XCTAssertFalse(live.question.isEmpty)
            try live.json().writePrivate(to:URL(fileURLWithPath:"/tmp/call-assistant-ai-\(provider.rawValue)-live-replay.json"))
            try coaching.json().writePrivate(to:URL(fileURLWithPath:"/tmp/call-assistant-ai-\(provider.rawValue)-coaching.json"))
        }
    }
}
private extension Dictionary where Key==String,Value==Any {
    func writePrivate(to url:URL) throws {try JSONSerialization.data(withJSONObject:self,options:.prettyPrinted).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
}
