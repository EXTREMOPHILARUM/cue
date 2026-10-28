import XCTest
import AppKit
import SwiftUI
@testable import CallAssistant

final class DesignTests:XCTestCase {
    @MainActor func testWorkspaceAndSheetsRenderInBothThemes() async throws {
        _ = NSApplication.shared
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let model=try AppModel(directory:folder,port:17418)
        defer {model.server.stop()}
        let time=Date().timeIntervalSince1970*1000
        try model.store.snapshot(id:"design-call",record:["id":"design-room","title":"Product design review","started_at":time,"ended_at":time+1000,"participants":["Alex","Morgan"],"captions":[
            ["speaker":"Alex","text":"Let’s make the next step clear. We should test the prototype with a small group before expanding the rollout.","t":time],
            ["speaker":"Morgan","text":"Agreed. I’ll share a draft on Friday, and we can review the open questions together.","t":time+500]
        ]])
        let summary:[String:Any]=["headline":"A clearer path from conversation to action","summary":"The team agreed to validate the prototype before expanding the rollout.","decisions":["Start with a small pilot."],"actions":["Share a draft on Friday."],"uncertainties":["Confirm who will join the pilot."]]
        try model.store.append("design-call",kind:"ai-summary",body:summary)
        model.refreshHistory();model.select("design-call")
        for index in 1...154 {
            model.sessions.append(["id":"history-\(index)","title":"Earlier conversation \(index)","startedAt":time-Double(index)*86400000])
        }
        model.activeSession=nil;model.selectedDetail=nil
        let nativeWindow=makeLibraryWindow(model:model)
        nativeWindow.orderFront(nil)
        defer {nativeWindow.orderOut(nil)}
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertLessThanOrEqual(nativeWindow.frame.height,820,"A long sidebar must not enlarge the window")
        func assertSplitBounds(_ view:NSView) {
            if view is NSSplitView {
                XCTAssertLessThanOrEqual(view.frame.height,nativeWindow.contentView!.bounds.height,"Split view must stay inside the window")
            }
            for child in view.subviews {assertSplitBounds(child)}
        }
        assertSplitBounds(nativeWindow.contentView!)
        model.select("design-call")
        for (theme,name) in [(ColorScheme.light,"light"),(ColorScheme.dark,"dark")] {
            try await render(LibraryView(model:model).preferredColorScheme(theme),name:"library-"+name,size:NSSize(width:1120,height:760))
            try await render(LibraryView(model:model).preferredColorScheme(theme),name:"library-compact-"+name,size:NSSize(width:800,height:540))
            try await render(CallSettings(model:model).preferredColorScheme(theme),name:"settings-"+name,size:NSSize(width:580,height:620))
            try await render(ScrollView {CallAIResult(result:summary).padding(28)}.background(CallPalette.canvas).preferredColorScheme(theme),name:"summary-"+name,size:NSSize(width:700,height:700))
            try await render(ExtensionSetup(model:model).preferredColorScheme(theme),name:"setup-"+name,size:NSSize(width:580,height:680))
        }
    }
    @MainActor func testReadmeScreenshotsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CUE_README_SCREENSHOTS"] != nil else {throw XCTSkip("Opt in to native documentation screenshots")}
        _ = NSApplication.shared
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=try AppModel(directory:folder,port:17419)
        defer {model.server.stop();try? FileManager.default.removeItem(at:folder)}
        let time=1793176200000.0
        let turns:[(String,String)]=[
            ("Alex","Let’s keep the pilot focused: five teams, two weeks, and one clear success measure."),
            ("Morgan","Agreed. We should measure whether people can finish their first project without asking for help."),
            ("Alex","I’ll share the prototype on Friday. Can you line up the five teams and collect their feedback?"),
            ("Morgan","Yes. I’ll confirm the participants tomorrow and send a short interview guide before we start."),
            ("Alex","Then let’s review the results together in two weeks and decide what to improve next.")
        ]
        let captions=turns.enumerated().map {index,turn in ["speaker":turn.0,"text":turn.1,"t":time+Double(index)*45000] as [String:Any]}
        try model.store.snapshot(id:"demo-pilot",record:["id":"demo-pilot","title":"Product pilot · Planning review","started_at":time,"ended_at":time+900000,"participants":["Alex","Morgan"],"captions":captions])
        for (index,title) in ["Website direction","Customer feedback review","Engineering weekly","Launch planning"].enumerated() {
            try model.store.snapshot(id:"demo-\(index)",record:["id":"demo-\(index)","title":title,"started_at":time-Double(index+1)*86400000,"ended_at":time-Double(index+1)*86400000+900000,"participants":["Alex","Morgan"],"captions":[]])
        }
        model.refreshHistory();model.select("demo-pilot")
        try await render(LibraryView(model:model).preferredColorScheme(.light),name:"readme-library",size:NSSize(width:1120,height:760))
        let summary:[String:Any]=["headline":"A focused pilot, with a clear next step","summary":"Test the prototype with five teams over two weeks. Measure whether each team can complete its first project independently, then review the findings before expanding the rollout.","decisions":["Start with five teams and a two-week pilot.","Use independent first-project completion as the success measure."],"actions":["Alex: share the prototype on Friday.","Morgan: confirm participants tomorrow and prepare an interview guide.","Together: review the findings in two weeks."],"uncertainties":["Confirm the five participating teams."]]
        try await render(ScrollView {CallAIResult(result:summary).padding(28)}.background(CallPalette.canvas).preferredColorScheme(.light),name:"readme-summary",size:NSSize(width:700,height:760))
        try await render(CallSettings(model:model).preferredColorScheme(.light),name:"readme-settings",size:NSSize(width:580,height:680))
    }
    @MainActor private func render<V:View>(_ root:V,name:String,size:NSSize) async throws {
        let controller=NSHostingController(rootView:root)
        controller.sizingOptions=[]
        let view=controller.view
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:name.hasSuffix("dark") ? .darkAqua:.aqua)
        view.frame=NSRect(origin:.zero,size:size)
        window.contentViewController=controller;window.orderFront(nil)
        defer {window.orderOut(nil)}
        try await Task.sleep(nanoseconds:100_000_000)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.size,size,"Content must scroll rather than enlarge the window")
        XCTAssertEqual(view.bounds.size,size)
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        XCTAssertGreaterThan(data.count,1000)
        if let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_DESIGN_SNAPSHOTS"] {
            let folder=URL(fileURLWithPath:path,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let target=folder.appendingPathComponent(name+".png")
            if ProcessInfo.processInfo.environment["CUE_README_SCREENSHOTS"] != nil {
                let capture=Process()
                capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
                capture.arguments=["-x","-o","-l",String(window.windowNumber),target.path]
                try capture.run();capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus,0,"Native window capture failed")
            } else {try data.write(to:target)}
        }
    }
}
