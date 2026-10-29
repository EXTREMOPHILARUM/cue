import XCTest
@testable import CallAssistant

final class ExtensionSetupTests:XCTestCase {
    func testNewInstallUsesVisibleHomeFolderAndLinkedLegacyInstallKeepsItsPath() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let home=root.appendingPathComponent("home"),support=root.appendingPathComponent("support")
        let visible=home.appendingPathComponent("Cue Extension",isDirectory:true)
        let legacy=support.appendingPathComponent("Cue/Extension",isDirectory:true)
        XCTAssertEqual(ExtensionInstall.destination(home:home,support:support,extensionID:""),visible)
        try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
        try Data("{\"name\":\"Cue\"}".utf8).write(to:legacy.appendingPathComponent("manifest.json"))
        XCTAssertEqual(ExtensionInstall.destination(home:home,support:support,extensionID:""),visible)
        XCTAssertEqual(ExtensionInstall.destination(home:home,support:support,extensionID:"linked"),legacy)
        try FileManager.default.createDirectory(at:visible,withIntermediateDirectories:true)
        try Data("{\"name\":\"Cue\"}".utf8).write(to:visible.appendingPathComponent("manifest.json"))
        XCTAssertEqual(ExtensionInstall.destination(home:home,support:support,extensionID:"linked"),legacy)
        XCTAssertEqual(ExtensionInstall.destination(home:home,support:support,extensionID:"linked",preparedPath:visible.path),visible)
        XCTAssertEqual(ExtensionInstall.destination(home:home,support:support,extensionID:"linked",preparedPath:"/unrelated"),legacy)
    }
    func testPreparationDoesNotReplaceAnUnrelatedHomeFolder() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source"),destination=root.appendingPathComponent("Cue Extension")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        try Data("{\"name\":\"Cue\"}".utf8).write(to:source.appendingPathComponent("manifest.json"))
        let existing=destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to:existing)
        XCTAssertThrowsError(try ExtensionInstall.prepare(source:source,destination:destination))
        XCTAssertEqual(try String(contentsOf:existing),"keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("manifest.json").path))
        try Data("{\"name\":\"Another project\"}".utf8).write(to:destination.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ExtensionInstall.prepare(source:source,destination:destination))
        XCTAssertEqual(try String(contentsOf:existing),"keep")
    }
    func testPrepareKeepsStableFolderAndRefreshesBundledFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("source")
        let destination=root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at:source.appendingPathComponent("icons"),withIntermediateDirectories:true)
        try Data("{\"name\":\"Cue\"}".utf8).write(to:source.appendingPathComponent("manifest.json"))
        try Data([1,2]).write(to:source.appendingPathComponent("icons/icon.png"))
        XCTAssertEqual(try ExtensionInstall.prepare(source:source,destination:destination),destination)
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("icons/icon.png")),Data([1,2]))
        try Data([9]).write(to:destination.appendingPathComponent("obsolete.js"))
        try Data([3]).write(to:source.appendingPathComponent("icons/icon.png"))
        XCTAssertEqual(try ExtensionInstall.prepare(source:source,destination:destination),destination)
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("icons/icon.png")),Data([3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("obsolete.js").path))
        try Data("invalid manifest".utf8).write(to:source.appendingPathComponent("manifest.json"))
        try Data([4]).write(to:source.appendingPathComponent("icons/icon.png"))
        XCTAssertThrowsError(try ExtensionInstall.prepare(source:source,destination:destination))
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("icons/icon.png")),Data([3]))
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("manifest.json")),Data("{\"name\":\"Cue\"}".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:root.path)),["source","installed"])
        XCTAssertThrowsError(try ExtensionInstall.prepare(source:root.appendingPathComponent("missing"),destination:destination))
    }
}
