import XCTest
@testable import CallAssistant

final class ExtensionSetupTests:XCTestCase {
    func testPrepareKeepsStableFolderAndRefreshesBundledFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("source")
        let destination=root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at:source.appendingPathComponent("icons"),withIntermediateDirectories:true)
        try Data("{}".utf8).write(to:source.appendingPathComponent("manifest.json"))
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
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("manifest.json")),Data("{}".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:root.path)),["source","installed"])
        XCTAssertThrowsError(try ExtensionInstall.prepare(source:root.appendingPathComponent("missing"),destination:destination))
    }
}
