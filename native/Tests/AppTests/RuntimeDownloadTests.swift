import XCTest
import CallCore
@testable import CallAssistant

final class RuntimeDownloadTests:XCTestCase {
    private func fixture(_ root:URL,provider:AIProvider = .codex) throws {
        let node=root.appendingPathComponent("node-runtime/bin/node")
        let script=RuntimeDownload.script(provider,in:root)
        try FileManager.default.createDirectory(at:node.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:script.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:node)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:node.path)
        try Data("fixture".utf8).write(to:script)
    }
    func testIntegrityRejectsChangedDownload() throws {
        let digest="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertNoThrow(try RuntimeDownload.verify(Data("abc".utf8),sha256:digest))
        XCTAssertThrowsError(try RuntimeDownload.verify(Data("changed".utf8),sha256:digest))
    }
    func testFailedIncompleteAndRetriedInstallationPreserveCache() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:base)}
        let destination=base.appendingPathComponent("runtime")
        XCTAssertThrowsError(try RuntimeDownload.install(.codex,at:destination) {stage in
            try fixture(stage);throw CancellationError()
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:base.path),[])
        XCTAssertThrowsError(try RuntimeDownload.install(.codex,at:destination) {_ in})
        _ = try RuntimeDownload.install(.codex,at:destination) {try fixture($0)}
        XCTAssertTrue(RuntimeDownload.ready(.codex,at:destination))
        XCTAssertFalse(RuntimeDownload.ready(.claude,at:destination))
        let script=RuntimeDownload.script(.codex,in:destination)
        XCTAssertThrowsError(try RuntimeDownload.install(.codex,at:destination) {_ in throw CancellationError()})
        XCTAssertEqual(try String(contentsOf:script),"fixture")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:base.path),["runtime"])
    }
    @MainActor func testSharedDownloadReportsFailureAllowsRetryAndDeduplicates() async throws {
        var attempts=0
        let runtime=AgentRuntime {provider,progress in
            attempts+=1
            await progress("Installing fixture")
            try await Task.sleep(nanoseconds:30_000_000)
            if attempts == 1 {throw BridgeError("Offline")}
            return URL(fileURLWithPath:"/fixture/"+provider.rawValue)
        }
        do {_ = try await runtime.prepare(.codex);XCTFail("Failed download accepted")} catch {}
        XCTAssertTrue(runtime.status[.codex]?.contains("Offline") == true)
        XCTAssertTrue(runtime.downloading.isEmpty)
        async let first=runtime.prepare(.codex)
        async let second=runtime.prepare(.codex)
        let paths=try await [first,second]
        XCTAssertEqual(attempts,2)
        XCTAssertEqual(paths[0],paths[1])
        XCTAssertEqual(runtime.status[.codex],"Ready on this Mac")
        XCTAssertTrue(runtime.downloading.isEmpty)
    }
    @MainActor func testRealDownloadsAndUnauthenticatedInitializeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CUE_RUNTIME_DOWNLOAD_SMOKE"] == "1" else {throw XCTSkip("Opt in to downloading provider tools")}
        for provider in AIProvider.allCases {
            let root=try await AgentRuntime.shared.prepare(provider)
            XCTAssertTrue(RuntimeDownload.ready(provider,at:root))
            let command=try ACPClient.runtime(provider,root:root)
            let connection=try ACPConnection(executable:command.0,arguments:command.1,environment:command.2,directory:FileManager.default.temporaryDirectory)
            defer {connection.close()}
            let response=try await connection.request("initialize",params:["protocolVersion":1,"clientCapabilities":[:],"clientInfo":["name":"cue-download-test","version":"1"]],timeout:30)
            XCTAssertEqual(response["protocolVersion"] as? Int,1)
            let cached=try await AgentRuntime.shared.prepare(provider)
            XCTAssertEqual(cached,root)
        }
    }
}
