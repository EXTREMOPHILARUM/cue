import XCTest
import CallCore
import AppKit
@testable import CallAssistant

final class CoachingLoopTests:XCTestCase {
    @MainActor func testCoachingTransparencyOverridePersistsWithoutChangingSystemPreference() throws {
        let suite="coaching-appearance-"+UUID().uuidString
        let preferences=try XCTUnwrap(UserDefaults(suiteName:suite))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {preferences.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        let system=NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let first=try AppModel(directory:root,port:17428,preferences:preferences);first.setCaptureConsent(true);first.setAIConsent(true)
        defer {first.server.stop()}
        XCTAssertFalse(first.coachingTransparencyOverride)
        first.coachingTransparencyOverride=true
        first.coachingBackdropOpacity=0.45
        XCTAssertTrue(preferences.bool(forKey:"coachingTransparencyOverride"))
        let reopened=try AppModel(directory:root,port:17429,preferences:preferences);reopened.setCaptureConsent(true);reopened.setAIConsent(true)
        defer {reopened.server.stop()}
        XCTAssertTrue(reopened.coachingTransparencyOverride)
        XCTAssertEqual(reopened.coachingBackdropOpacity,0.45)
        reopened.coachingBackdropOpacity = -.infinity
        XCTAssertEqual(reopened.coachingBackdropOpacity,0.72)
        reopened.coachingBackdropOpacity = -1
        XCTAssertEqual(reopened.coachingBackdropOpacity,0)
        reopened.coachingBackdropOpacity = 2
        XCTAssertEqual(reopened.coachingBackdropOpacity,1)
        XCTAssertEqual(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,system)
    }
    @MainActor func testCompactPanelUsesMenuStateAndHonorsHideAcrossUpdates() throws {
        _ = NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17423);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.server.stop();model.panel?.hide()}
        model.attachPanel();let panel=try XCTUnwrap(model.panel)
        let backdrop=try XCTUnwrap(panel.web.superview?.subviews.compactMap{$0 as? NSVisualEffectView}.first)
        XCTAssertFalse(panel.web.superview is NSVisualEffectView)
        XCTAssertEqual(backdrop.material,.popover)
        XCTAssertEqual(backdrop.blendingMode,.behindWindow)
        XCTAssertEqual(backdrop.alphaValue,NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1:0.72)
        XCTAssertEqual(panel.web.alphaValue,1)
        model.coachingBackdropOpacity=0.45
        XCTAssertEqual(backdrop.alphaValue,NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1:0.45)
        XCTAssertEqual(panel.web.underPageBackgroundColor.alphaComponent,0)
        XCTAssertFalse(panel.web.isOpaque)
        XCTAssertEqual(backdrop.layer?.backgroundColor?.alpha,NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1:0)
        model.coachingTransparencyOverride=true
        XCTAssertEqual(backdrop.alphaValue,0.45)
        XCTAssertEqual(backdrop.layer?.backgroundColor?.alpha,0)
        XCTAssertEqual(panel.web.alphaValue,1)
        model.coachingTransparencyOverride=false
        XCTAssertEqual(backdrop.alphaValue,NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1:0.45)
        panel.beginSession();XCTAssertFalse(panel.expanded);XCTAssertEqual(panel.frame.height,52)
        panel.showSuggestion();XCTAssertTrue(panel.expanded)
        panel.toggleExpanded();panel.showSuggestion();XCTAssertFalse(panel.expanded)
        panel.toggleExpanded();XCTAssertTrue(panel.expanded)
        XCTAssertTrue(NSScreen.screens.contains{$0.visibleFrame.contains(panel.frame)})
        panel.hide();panel.update(["headline":"New point"]);panel.showSuggestion()
        XCTAssertTrue(panel.hiddenByUser);XCTAssertFalse(panel.isVisible)
        panel.show();XCTAssertFalse(panel.hiddenByUser);XCTAssertTrue(panel.expanded)
        let center=panel.frame.midX,top=panel.frame.maxY
        for _ in 0..<4 {
            panel.toggleExpanded()
            XCTAssertEqual(panel.frame.midX,center)
            XCTAssertEqual(panel.frame.maxY,top)
        }
    }
    @MainActor func testPanelCentersOnDisplayDespiteSideDockAndBoundsContentHeight() {
        let screen=NSRect(x:100,y:0,width:1440,height:900),usable=NSRect(x:180,y:0,width:1360,height:875)
        let short=CoachingPanel.layout(screen:screen,usable:usable,expanded:true,contentHeight:240)
        XCTAssertEqual(short.midX,screen.midX);XCTAssertEqual(short.height,240)
        let tall=CoachingPanel.layout(screen:screen,usable:usable,expanded:true,contentHeight:2000)
        XCTAssertLessThanOrEqual(tall.height,usable.height-16)
    }
    @MainActor func testSkillSelectionPersistsForRecurringCallsAndRejectsExternalFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skill=".codex/skills/coach/SKILL.md",file=root.appendingPathComponent(skill)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try "Ask one relevant follow-up.".write(to:file,atomically:true,encoding:.utf8)
        let model=try AppModel(directory:root,port:17424);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.server.stop()}
        try model.store.snapshot(id:"first",record:["id":"first","series_id":"weekly"])
        model.select("first")
        try model.saveAIProject(AIProject(path:root.path,skill:skill),for:"first",shareProject:true)
        try model.store.snapshot(id:"next",record:["id":"next","series_id":"weekly"])
        let project=try model.projectForCall(model.store.detail("next"))
        XCTAssertEqual(project.skill,skill);XCTAssertEqual(try project.skillContext(),"Ask one relevant follow-up.")
        XCTAssertThrowsError(try AIProject(path:root.path,skill:"../outside.md").validate(provider:.codex))
    }
    @MainActor func testPausingCoachingDoesNotPauseCaptureOrLoseTheCall() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17425);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.stopAI();model.server.stop()}
        try model.store.snapshot(id:"live",record:["id":"abc-defg-hij","captions":[["text":"We need a small pilot with a clear owner and a review next week","t":1]]]);model.select("live")
        var requests=0
        model.aiGenerate={_,_,_,_ in requests += 1;try await Task.sleep(nanoseconds:10_000_000_000);throw CancellationError()}
        model.startLiveAI();try await Task.sleep(nanoseconds:20_000_000)
        model.setCoachingPaused(true)
        XCTAssertTrue(model.coachingPaused);XCTAssertFalse(model.paused);XCTAssertEqual(model.liveAISession,"live")
        model.tickAI(now:Date().addingTimeInterval(10));XCTAssertEqual(requests,1)
        model.setCoachingPaused(false);try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertEqual(requests,2);XCTAssertFalse(model.paused)
        model.aiProvider = .claude
        try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertEqual(requests,3);XCTAssertEqual(model.aiProject.provider,.claude)
        XCTAssertEqual(model.liveAISession,"live")
    }
    func testTranscriptDebounceWaitsForContextAndDoesNotRepeatMetadataOnlyUpdates() {
        var schedule=CoachingSchedule()
        let start=Date(timeIntervalSince1970:100)
        XCTAssertFalse(schedule.ready("fragment",context:"To",now:start))
        let context="We need a small pilot with a clear owner and a review next week"
        XCTAssertTrue(schedule.ready("first",context:context,now:start.addingTimeInterval(2)))
        schedule.submitted("first",context:context,now:start.addingTimeInterval(2))
        XCTAssertFalse(schedule.ready("metadata-only",context:context,now:start.addingTimeInterval(60)))
        let next=context+" The team can share its plan tomorrow."
        XCTAssertFalse(schedule.ready("next",context:next,now:start.addingTimeInterval(61)))
        XCTAssertTrue(schedule.ready("next",context:next,now:start.addingTimeInterval(63)))
        schedule.submitted("next",context:next,now:start.addingTimeInterval(63))
        let question=next+" What should we propose?"
        XCTAssertFalse(schedule.ready("question",context:question,now:start.addingTimeInterval(66)))
        XCTAssertTrue(schedule.ready("question",context:question,now:start.addingTimeInterval(68)))
    }
    func testProjectSearchKeepsSourcesBoundedAndSkipsSecretsAndExternalSymlinks() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try "# Pricing\nCurrent plan price must be confirmed with billing.\nMore context.".write(to:root.appendingPathComponent("pricing.md"),atomically:true,encoding:.utf8)
        try "SECRET price".write(to:root.appendingPathComponent(".env"),atomically:true,encoding:.utf8)
        let other=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".md")
        try "SECRET price".write(to:other,atomically:true,encoding:.utf8);defer {try? FileManager.default.removeItem(at:other)}
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("outside.md"),withDestinationURL:other)
        let found=try ProjectResearch.search(path:root.path,query:"price")
        XCTAssertEqual(found.count,1);XCTAssertEqual(found[0]["file"],"pricing.md")
        XCTAssertFalse(found[0]["text"]!.contains("SECRET"));XCTAssertTrue(found[0]["text"]!.contains("2:"))
        XCTAssertEqual(try ProjectResearch.search(path:root.path,query:"unmatched"),[])
    }
    func testResearchIncludesBlockersButExcludesCredentialAndLockFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        for name in ["blockers.md","clock.md","auth.ts","credentials.json","auth.json","secrets.yaml","service-account.json","package-lock.json","pnpm-lock.yaml"] {
            try "pricing context".write(to:root.appendingPathComponent(name),atomically:true,encoding:.utf8)
        }
        let found=try ProjectResearch.search(path:root.path,query:"pricing")
        XCTAssertEqual(Set(found.compactMap{$0["file"]}),Set(["blockers.md","clock.md","auth.ts"]))
    }
    func testUnreadableResearchFileDoesNotDiscardOtherSources() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let unreadable=root.appendingPathComponent("unreadable.md")
        try "pricing private".write(to:unreadable,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:unreadable.path)
        defer {try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:unreadable.path)}
        try "pricing public".write(to:root.appendingPathComponent("pricing.md"),atomically:true,encoding:.utf8)
        XCTAssertEqual(try ProjectResearch.search(path:root.path,query:"pricing").compactMap{$0["file"]},["pricing.md"])
    }
    func testFreshCaptionsAreNotBlockedByOlderWhisperAndUserIdentityIsPreserved() throws {
        let detail:[String:Any]=["segments":[["id":"local","source":"whisper-local","speaker":"Sam","text":"Already discussed","t":1.0,"participantID":"self"], ["id":"caption","source":"meet","speaker":"Other","text":"What is the price?","t":2.0]]]
        let input=try AIInput.make(detail:detail,mode:.coaching,background:"",previous:nil)
        XCTAssertEqual(input.segmentIDs,["local","caption"])
        XCTAssertTrue(input.prompt.contains("participantID"));XCTAssertTrue(input.prompt.contains("retirePrevious"))
        XCTAssertTrue(input.prompt.contains("not a checklist"))
    }
    @MainActor func testCoveredAdviceRetiresWithoutRequiringReplacement() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(directory:root,port:17422);model.setCaptureConsent(true);model.setAIConsent(true);defer {model.stopAI();model.server.stop()}
        try model.store.snapshot(id:"live",record:["id":"abc-defg-hij","captions":[["text":"The question is answered","speaker":"You","t":1]]])
        model.select("live")
        _ = try await model.request(role:"assistant",request:["method":"coach","session":"live","program":"root = Canvas(Coach(\"Old\",\"Ask again?\",[],\"\"),[])","fallback":"Old"])
        XCTAssertNotNil(model.coaching)
        model.aiGenerate={_,_,input,_ in AIResponse(headline:"",question:"",points:[],summary:"Question answered",decisions:[],actions:[],uncertainties:[],evidence:Array(input.segmentIDs),shouldUpdate:false,retirePrevious:true)}
        model.runAI(.coaching)
        for _ in 0..<50 {if !model.aiBusy {break};try await Task.sleep(nanoseconds:20_000_000)}
        let saved=try XCTUnwrap(model.store.detail("live")["aiCoaching"] as? [String:Any])
        XCTAssertEqual(saved["retirePrevious"] as? Bool,true)
        XCTAssertFalse(model.aiBusy);XCTAssertTrue(model.aiError.isEmpty,model.aiError)
        XCTAssertNil(model.coaching)
    }
    func testCoachingIdentityIgnoresHeadlineAndPunctuationOnlyChanges() {
        let first=AIResponse(headline:"Pilot",question:"Start with a small pilot.",points:["Review next week."],summary:"",decisions:[],actions:[],uncertainties:[],evidence:["one"],shouldUpdate:true)
        let reworded=AIResponse(headline:"Next step",question:"Start with a small pilot!",points:["Review next week"],summary:"",decisions:[],actions:[],uncertainties:[],evidence:["two"],shouldUpdate:true)
        XCTAssertEqual(first.coachingKey,reworded.coachingKey)
    }

}
