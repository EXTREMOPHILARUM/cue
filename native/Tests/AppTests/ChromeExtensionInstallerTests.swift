import XCTest
import Foundation
import Darwin
@testable import CallAssistant

final class ChromeExtensionInstallerTests:XCTestCase {
    func testRejectsInvalidResponsesAndEndpoints() throws {
        let id=String(repeating:"a",count:32)
        XCTAssertEqual(try ChromeExtensionInstaller.extensionID(response:Data("{\"id\":1,\"result\":{\"id\":\"\(id)\"}}".utf8)),id)
        for value in ["{}","{\"id\":2,\"result\":{\"id\":\"\(id)\"}}","{\"id\":1,\"result\":{\"id\":\"wrong\"}}","{\"id\":1,\"error\":{\"message\":\"Not supported\"}}"] {
            XCTAssertThrowsError(try ChromeExtensionInstaller.extensionID(response:Data(value.utf8)))
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let port=root.appendingPathComponent("DevToolsActivePort")
        for value in ["0\n/devtools/browser/abc","65536\n/devtools/browser/abc","1234\n//example.com","1234\n/devtools/browser/a?redirect=elsewhere"] {
            try Data(value.utf8).write(to:port)
            XCTAssertThrowsError(try ChromeExtensionInstaller.endpoint(profile:root))
        }
        try Data("1234\n/devtools/browser/abc-123\n".utf8).write(to:port)
        XCTAssertEqual(try ChromeExtensionInstaller.endpoint(profile:root).absoluteString,"ws://127.0.0.1:1234/devtools/browser/abc-123")
    }
    func testFingerprintIncludesChangedAndRemovedFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("manifest.json")
        try Data("first".utf8).write(to:file)
        let first=try ChromeExtensionInstaller.fingerprint(folder:root)
        XCTAssertEqual(first,try ChromeExtensionInstaller.fingerprint(folder:root))
        try Data("second".utf8).write(to:file)
        XCTAssertNotEqual(first,try ChromeExtensionInstaller.fingerprint(folder:root))
        try FileManager.default.removeItem(at:file)
        XCTAssertNotEqual(first,try ChromeExtensionInstaller.fingerprint(folder:root))
    }
    func testRunningProfileIsNeverLaunchedOrChanged() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("SingletonLock").path,withDestinationPath:"fixture-\(getpid())")
        let port=root.appendingPathComponent("DevToolsActivePort")
        try Data("untouched".utf8).write(to:port)
        XCTAssertTrue(ChromeExtensionInstaller.isRunning(profile:root))
        let marker=root.appendingPathComponent("cue-extension.json")
        let id=String(repeating:"a",count:32)
        try JSONEncoder().encode(["id":id,"pid":"0"]).write(to:marker)
        XCTAssertNil(ChromeExtensionInstaller.runningInstallation(profile:root),"An earlier browser's installation must not apply to a new process")
        try JSONEncoder().encode(["id":id,"pid":String(getpid())]).write(to:marker)
        XCTAssertEqual(ChromeExtensionInstaller.runningInstallation(profile:root)?["id"],id)
        do {
            _ = try await ChromeExtensionInstaller.install(chrome:URL(fileURLWithPath:"/not/a/browser"),folder:root,profile:root)
            XCTFail("Running profile accepted")
        } catch {XCTAssertTrue(error.localizedDescription.contains("Quit Cue Chrome"))}
        XCTAssertEqual(try String(contentsOf:port),"untouched")
    }
    func testRealChromeInstallRelaunchAndStorageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CUE_CHROME_INSTALL_SMOKE"] == "1" else {throw XCTSkip("Opt in to isolated local Chrome installation")}
        let files=FileManager.default
        let root=files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder=root.appendingPathComponent("Extension")
        let profile=root.appendingPathComponent("Profile")
        try files.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {
            if let lock=try? files.destinationOfSymbolicLink(atPath:profile.appendingPathComponent("SingletonLock").path),
               let pid=Int32(lock.split(separator:"-").last ?? ""),pid>0 {kill(pid,SIGTERM)}
            try? files.removeItem(at:root)
        }
        try Data("{\"manifest_version\":3,\"name\":\"Cue install fixture\",\"version\":\"1.0\",\"permissions\":[\"storage\"]}".utf8).write(to:folder.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>Cue fixture</title>".utf8).write(to:folder.appendingPathComponent("check.html"))
        let launcher=root.appendingPathComponent("chrome")
        try Data("#!/bin/sh\nexec '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' --headless=new --host-resolver-rules='MAP * ~NOTFOUND' \"$@\"\n".utf8).write(to:launcher)
        try files.setAttributes([.posixPermissions:0o700],ofItemAtPath:launcher.path)
        var firstID=""
        for run in 0..<2 {
            let id=try await ChromeExtensionInstaller.install(chrome:launcher,folder:folder,profile:profile)
            XCTAssertTrue(ChromeExtensionInstaller.isRunning(profile:profile))
            XCTAssertEqual(ChromeExtensionInstaller.runningInstallation(profile:profile)?["id"],id)
            if run==0 {firstID=id} else {XCTAssertEqual(firstID,id)}
            let session=URLSession(configuration:.ephemeral)
            let socket=session.webSocketTask(with:try ChromeExtensionInstaller.endpoint(profile:profile))
            socket.resume()
            let list=try await request(socket,id:1,method:"Extensions.getExtensions")
            XCTAssertTrue((list["extensions"] as? [[String:Any]])?.contains(where:{$0["id"] as? String == id && $0["enabled"] as? Bool == true}) == true)
            let target=try await request(socket,id:4,method:"Target.createTarget",params:["url":"chrome-extension://\(id)/check.html"])
            let page=try XCTUnwrap(target["targetId"] as? String)
            let attached=try await request(socket,id:5,method:"Target.attachToTarget",params:["targetId":page,"flatten":true])
            let context=try XCTUnwrap(attached["sessionId"] as? String)
            for _ in 0..<50 {
                let ready=try await request(socket,id:6,method:"Runtime.evaluate",params:["expression":"typeof chrome.storage"],sessionID:context)
                if (ready["result"] as? [String:Any])?["value"] as? String == "object" {break}
                try await Task.sleep(nanoseconds:100_000_000)
            }
            if run==0 {
                _ = try await request(socket,id:2,method:"Extensions.setStorageItems",params:["id":id,"storageArea":"local","values":["retained":"yes"]],sessionID:context)
            } else {
                let stored=try await request(socket,id:2,method:"Extensions.getStorageItems",params:["id":id,"storageArea":"local","keys":["retained"]],sessionID:context)
                XCTAssertEqual((stored["data"] as? [String:String])?["retained"],"yes")
            }
            _ = try await request(socket,id:3,method:"Browser.close")
            socket.cancel(with:.normalClosure,reason:nil);session.invalidateAndCancel()
            for _ in 0..<100 {
                if !ChromeExtensionInstaller.isRunning(profile:profile) {break}
                try await Task.sleep(nanoseconds:100_000_000)
            }
            XCTAssertFalse(ChromeExtensionInstaller.isRunning(profile:profile))
        }
    }
    private func request(_ socket:URLSessionWebSocketTask,id:Int,method:String,params:[String:Any]=[:],sessionID:String?=nil) async throws -> [String:Any] {
        var command:[String:Any]=["id":id,"method":method,"params":params]
        if let sessionID {command["sessionId"]=sessionID}
        let data=try JSONSerialization.data(withJSONObject:command)
        try await socket.send(.string(String(decoding:data,as:UTF8.self)))
        while true {
        let message=try await socket.receive()
        let response:Data
        switch message {
        case .data(let data):response=data
        case .string(let text):response=Data(text.utf8)
        @unknown default:throw NSError(domain:"ChromeFixture",code:1)
        }
        let value=try XCTUnwrap(JSONSerialization.jsonObject(with:response) as? [String:Any])
        if value["id"] as? Int != id {continue}
        XCTAssertNil(value["error"],method)
        return try XCTUnwrap(value["result"] as? [String:Any])
        }
    }
}
