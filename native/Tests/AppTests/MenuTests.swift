import XCTest
import AppKit
import SwiftUI
@testable import CallAssistant
final class MenuTests: XCTestCase {
    @MainActor func testMenuBarSymbolExistsOnThisMac() {
        XCTAssertNotNil(NSImage(systemSymbolName:MenuContent.symbol,accessibilityDescription:"Cue"))
    }
    @MainActor func testOpaquePaletteTextContrast() throws {
        func luminance(_ color:NSColor) throws -> Double {
            let rgb=try XCTUnwrap(color.usingColorSpace(.sRGB))
            let values=[rgb.redComponent,rgb.greenComponent,rgb.blueComponent].map { value in
                value<=0.04045 ? value/12.92:pow((value+0.055)/1.055,2.4)
            }
            return values[0]*0.2126+values[1]*0.7152+values[2]*0.0722
        }
        func contrast(_ foreground:NSColor,_ background:NSColor) throws -> Double {
            let a=try luminance(foreground),b=try luminance(background)
            return (max(a,b)+0.05)/(min(a,b)+0.05)
        }
        for name in [NSAppearance.Name.aqua,.darkAqua] {
            let appearance=try XCTUnwrap(NSAppearance(named:name))
            var colors=[NSColor?]()
            appearance.performAsCurrentDrawingAppearance {
                colors=[NSColor.labelColor,NSColor(CallPalette.canvas),NSColor(CallPalette.surface),NSColor(CallPalette.muted),NSColor(CallPalette.accent),NSColor(CallPalette.onAccent),NSColor(CallPalette.sidebar)]
                    .map{$0.usingColorSpace(.sRGB)}
            }
            let resolved=try colors.map{try XCTUnwrap($0)}
            let ratios=[try contrast(resolved[0],resolved[1]),try contrast(resolved[0],resolved[2]),
                        try contrast(resolved[3],resolved[1]),try contrast(resolved[3],resolved[2])]
            for ratio in ratios {XCTAssertGreaterThanOrEqual(ratio,4.5,"Unreadable text in \(name.rawValue)")}
            XCTAssertGreaterThanOrEqual(try contrast(resolved[4],resolved[5]),4.5)
            for background in [resolved[1],resolved[2],resolved[6]] {
                XCTAssertGreaterThanOrEqual(try contrast(resolved[3],background),4.5,"Unreadable secondary text in \(name.rawValue)")
            }
        }
    }

    @MainActor func testMenuRedrawsWhenModelFinishesLoading() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let model = try AppModel(directory:folder,port:17378)
        defer { model.server.stop() }
        model.modelStatus = "Loading"
        let view = NSHostingView(rootView:MenuContent(model:model,openHistory:{}))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:290,height:280),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func snapshot() throws -> Data {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            return try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        }
        try await Task.sleep(nanoseconds:100_000_000)
        let loading = try snapshot()
        model.modelStatus = "Ready · small.en"
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertNotEqual(loading,try snapshot(),"The menu must redraw after the model status changes")
    }
}
