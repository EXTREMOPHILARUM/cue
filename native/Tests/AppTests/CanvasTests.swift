import XCTest
import AppKit
import WebKit
@testable import CallAssistant
final class CanvasTests: XCTestCase {
    @MainActor func testCoachingLayoutInBothThemesAtCompactWidths() async throws {
        _ = NSApplication.shared
        let folder=try XCTUnwrap(Bundle.module.url(forResource:"Canvas",withExtension:nil))
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            for width in [320,480] {
                let web=WKWebView(frame:NSRect(x:0,y:0,width:width,height:720))
                web.appearance=NSAppearance(named:appearance)
                let window=NSWindow(contentRect:web.frame,styleMask:[.borderless],backing:.buffered,defer:false)
                window.appearance=web.appearance;window.contentView=web;window.orderFront(nil)
                defer {window.orderOut(nil)}
                web.loadFileURL(folder.appendingPathComponent("index.html"),allowingReadAccessTo:folder)
                var ready=false
                for _ in 0..<100 {
                    ready=(try? await web.evaluateJavaScript("Boolean(window.callAssistant)")) as? Bool ?? false
                    if ready {break}
                    try await Task.sleep(nanoseconds:50_000_000)
                }
                XCTAssertTrue(ready)
                let program="root = Canvas(Coach(\"Make the next step concrete\",\"What would a successful pilot look like for your team?\",[\"Agree on an owner and a review date.\"],\"The conversation has not yet established a success measure.\"),[Context(\"Reference\",\""+String(repeating:"long-reference-",count:30)+"\")])"
                let payload=try JSONSerialization.data(withJSONObject:["id":"layout","program":program,"expiresAt":Date().addingTimeInterval(60).timeIntervalSince1970*1000])
                let json=try XCTUnwrap(String(data:payload,encoding:.utf8))
                _ = try await web.evaluateJavaScript("window.callAssistant.update("+json+")")
                var rendered=false
                for _ in 0..<100 {
                    rendered=try await web.evaluateJavaScript("Boolean(document.querySelector('.question'))") as? Bool ?? false
                    if rendered {break}
                    try await Task.sleep(nanoseconds:20_000_000)
                }
                XCTAssertTrue(rendered)
                let translucent=try await web.evaluateJavaScript("CSS.supports('background', 'color-mix(in srgb, white 32%, transparent)') && ['html','body','#root'].every(selector => getComputedStyle(document.querySelector(selector)).backgroundColor === 'rgba(0, 0, 0, 0)')") as? Bool
                XCTAssertEqual(translucent,true,"Web surfaces must let the native backdrop show through")
                _ = try await web.evaluateJavaScript("document.querySelectorAll('details').forEach(element => element.open=true)")
                let fits=try await web.evaluateJavaScript("document.documentElement.scrollWidth <= window.innerWidth") as? Bool
                XCTAssertEqual(fits,true,"Overflow in \(name) at \(width)px")
                if let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_DESIGN_SNAPSHOTS"] {
                    let image=try await web.takeSnapshot(configuration:nil)
                    let data=try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init)?.representation(using:.png,properties:[:]))
                    try data.write(to:URL(fileURLWithPath:path).appendingPathComponent("coaching-\(name)-\(width).png"))
                }
            }
        }
    }
    @MainActor func testBundledWebKitCanvasAndFeedback() async throws {
        _ = NSApplication.shared
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let model=try AppModel(directory:folder,port:17376)
        defer { model.server.stop(); model.panel?.hide() }
        model.attachPanel()
        for _ in 0..<150 {
            if model.prompt.contains("Canvas") { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        XCTAssertTrue(model.prompt.contains("Canvas"),"Bundled WKWebView did not load: \(model.errorMessage)")
        guard model.prompt.contains("Canvas") else { return }
        _ = try await model.request(role:"extension",request:["method":"snapshot","session":"canvas-test","peer":"fixture","record":["id":"abc-defg-hij"]])
        _ = try await model.request(role:"assistant",request:["method":"coach","session":"canvas-test","program":"root = Canvas(Coach(\"Clarify the outcome\",\"What would success look like?\",[],\"Test fixture\"),[])","fallback":"Ask about success","expiresIn":5])
        let web=model.panel!.web
        var text=""
        for _ in 0..<50 {
            text = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
            if text.contains("What would success") { break }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        XCTAssertTrue(text.contains("What would success"),text)
        model.coachingTransparencyOverride=true
        var overrideApplied=false
        for _ in 0..<50 {
            overrideApplied=try await web.evaluateJavaScript("document.documentElement.classList.contains('translucent-coaching')") as? Bool ?? false
            if overrideApplied {break}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTAssertTrue(overrideApplied,"The coaching-only override must reach the rendered canvas")
        let primaryAction=try await web.evaluateJavaScript("document.querySelector('.actions .primary')?.textContent") as? String
        XCTAssertEqual(primaryAction,"Covered")
        if let path=ProcessInfo.processInfo.environment["CALL_ASSISTANT_CANVAS_SCREENSHOT"] {
            let image=try await web.takeSnapshot(configuration:nil)
            let data=image.tiffRepresentation.flatMap(NSBitmapImageRep.init)?.representation(using:.png,properties:[:])
            try data?.write(to:URL(fileURLWithPath:path))
        }
        _ = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('button')).find(b=>b.textContent==='Covered').click()")
        try await Task.sleep(nanoseconds:100_000_000)
        let events=try model.store.read("canvas-test")["events"] as! [[String:Any]]
        XCTAssertTrue(events.contains { $0["kind"] as? String == "feedback" })
        if ProcessInfo.processInfo.environment["CALL_ASSISTANT_AI_CANVAS"] == "1" {
            for provider in AIProvider.allCases {
                let result=try JSONDecoder().decode(AIResponse.self,from:Data(contentsOf:URL(fileURLWithPath:"/tmp/call-assistant-ai-\(provider.rawValue)-live-replay.json")))
                _ = try await model.request(role:"assistant",request:["method":"coach","session":"canvas-test","program":try result.canvas(),"fallback":result.question])
                for _ in 0..<50 {
                    text=try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
                    if text.contains(result.question) {break}
                    try await Task.sleep(nanoseconds:100_000_000)
                }
                XCTAssertTrue(text.contains(result.question),text)
                XCTAssertTrue(text.contains(result.headline),text)
            }
        }
        model.clearCoaching()
    }
}
