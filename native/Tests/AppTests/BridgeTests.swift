import XCTest
import Foundation
import CallCore
@testable import CallAssistant
final class BridgeTests: XCTestCase {
    @MainActor func testChangingExtensionIDRejectsPendingHelloAndKeepsAssistant() async throws {
        var extensionID=String(repeating:"b",count:32)
        let server=try BridgeServer(port:17402,extensionID:{extensionID})
        server.handle={_,_ in ["alive":true]}
        var connected=false
        server.extensionConnectionChanged={connected=$0}
        server.start()
        defer {server.stop()}
        try await Task.sleep(nanoseconds:100_000_000)
        let url=URL(string:"ws://127.0.0.1:17402")!
        let assistant=URLSession.shared.webSocketTask(with:url)
        assistant.resume()
        defer {assistant.cancel(with:.normalClosure,reason:nil)}
        try await assistant.send(.string("{\"id\":\"1\",\"method\":\"hello\",\"role\":\"assistant\"}"))
        _ = try await assistant.receive()
        var request=URLRequest(url:url)
        request.setValue("chrome-extension://"+extensionID,forHTTPHeaderField:"Origin")
        let pending=URLSession.shared.webSocketTask(with:request)
        pending.resume()
        defer {pending.cancel(with:.normalClosure,reason:nil)}
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            pending.sendPing { error in
                if let error {continuation.resume(throwing:error)} else {continuation.resume()}
            }
        }
        extensionID=String(repeating:"c",count:32)
        server.disconnectExtensions()
        do {
            try await pending.send(.string("{\"id\":\"2\",\"method\":\"hello\",\"role\":\"extension\"}"))
            _ = try await pending.receive()
            XCTFail("A handshake accepted for the revoked extension ID must not finish")
        } catch { }
        XCTAssertFalse(connected)
        try await assistant.send(.string("{\"id\":\"3\",\"method\":\"status\"}"))
        guard case .string(let response)=try await assistant.receive() else {return XCTFail("Expected assistant reply")}
        XCTAssertTrue(response.contains("\"alive\":true"))
    }
    @MainActor func testLocalWebSocketWithoutPairingAndOriginRejection() async throws {
        let server = try BridgeServer(port:17374,extensionID:{ String(repeating:"b",count:32) })
        server.handle = { _,request in ["echo":request["method"]!] }
        var extensionConnections=[Bool]()
        server.extensionConnectionChanged = { extensionConnections.append($0) }
        defer { server.stop() }
        server.start()
        try await Task.sleep(nanoseconds:100_000_000)
        let socket = URLSession.shared.webSocketTask(with:URL(string:"ws://127.0.0.1:17374")!)
        socket.resume()
        func request(_ text: String) async throws -> [String:Any] {
            try await socket.send(.string(text))
            let response = try await socket.receive()
            guard case .string(let json) = response else { throw BridgeError("Expected JSON") }
            return try JSONSerialization.jsonObject(with:Data(json.utf8)) as! [String:Any]
        }
        let auth = try await request("{\"id\":\"1\",\"method\":\"hello\",\"role\":\"assistant\"}")
        XCTAssertEqual(auth["ok"] as? Bool,true)
        let status = try await request("{\"id\":\"2\",\"method\":\"status\"}")
        XCTAssertEqual(status["ok"] as? Bool,true)
        XCTAssertTrue(extensionConnections.isEmpty,"Assistant clients must not show extension connected")
        socket.cancel(with:.normalClosure,reason:nil)
        var blockedRequest = URLRequest(url:URL(string:"ws://127.0.0.1:17374")!)
        blockedRequest.setValue("https://evil.example",forHTTPHeaderField:"Origin")
        let blocked = URLSession.shared.webSocketTask(with:blockedRequest)
        blocked.resume()
        do { _ = try await blocked.receive(); XCTFail("Web origin was accepted") } catch { }
        blocked.cancel(with:.normalClosure,reason:nil)
        var extensionRequest=URLRequest(url:URL(string:"ws://127.0.0.1:17374")!)
        extensionRequest.setValue("chrome-extension://"+String(repeating:"b",count:32),forHTTPHeaderField:"Origin")
        let browser=URLSession.shared.webSocketTask(with:extensionRequest)
        browser.resume()
        try await browser.send(.string("{\"id\":\"extension\",\"method\":\"hello\",\"role\":\"extension\"}"))
        _ = try await browser.receive()
        XCTAssertEqual(extensionConnections,[true])
        browser.cancel(with:.normalClosure,reason:nil)
        for _ in 0..<50 {
            if extensionConnections.last == false { break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTAssertEqual(extensionConnections,[true,false])
        let reconnected=URLSession.shared.webSocketTask(with:extensionRequest)
        reconnected.resume()
        try await reconnected.send(.string("{\"id\":\"again\",\"method\":\"hello\",\"role\":\"extension\"}"))
        _ = try await reconnected.receive()
        server.disconnectExtensions()
        XCTAssertEqual(extensionConnections,[true,false,true,false])
        reconnected.cancel(with:.normalClosure,reason:nil)
    }
    func testRecordedSpeechWhenExplicitlyRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["CALL_ASSISTANT_AUDIO_FIXTURE"] else { throw XCTSkip("Set CALL_ASSISTANT_AUDIO_FIXTURE to run real local inference") }
        let transcript = try await Transcriber().file(path)
        print("Local WhisperKit transcript: \(transcript)")
        XCTAssertTrue(transcript.lowercased().contains("successful"))
    }
}
