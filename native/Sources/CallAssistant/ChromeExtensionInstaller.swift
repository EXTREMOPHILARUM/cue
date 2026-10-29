import Foundation
import CryptoKit
import CallCore
import Darwin

// This profile belongs to Cue; never attach the installer to a user's normal Chrome profile.
enum ChromeExtensionInstaller {
    static func runningPID(profile:URL) -> Int32? {
        guard let lock=try? FileManager.default.destinationOfSymbolicLink(atPath:profile.appendingPathComponent("SingletonLock").path),
              let pid=Int32(lock.split(separator:"-").last ?? ""),pid>0 else {return nil}
        return kill(pid,0)==0 || errno==EPERM ? pid:nil
    }
    static func isRunning(profile:URL) -> Bool {runningPID(profile:profile) != nil}
    static func fingerprint(folder:URL) throws -> String {
        let files=FileManager.default
        guard let enumerator=files.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey]) else {
            throw BridgeError("The bundled Chrome extension is missing.")
        }
        var hash=SHA256()
        for file in enumerator.compactMap({$0 as? URL}).sorted(by:{$0.path<$1.path}) {
            guard try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else {continue}
            hash.update(data:Data(file.path.dropFirst(folder.path.count).utf8))
            hash.update(data:Data([0]))
            hash.update(data:try Data(contentsOf:file))
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func runningInstallation(profile:URL) -> [String:String]? {
        guard let data=try? Data(contentsOf:profile.appendingPathComponent("cue-extension.json")),
              let value=try? JSONDecoder().decode([String:String].self,from:data),
              let pid=runningPID(profile:profile),value["pid"]==String(pid),
              let id=value["id"],id.range(of:"^[a-p]{32}$",options:.regularExpression) != nil else {return nil}
        return value
    }
    static func endpoint(profile:URL) throws -> URL {
        let lines=try String(contentsOf:profile.appendingPathComponent("DevToolsActivePort")).split(separator:"\n")
        guard lines.count==2,let port=Int(lines[0]),(1...65535).contains(port),
              lines[1].hasPrefix("/devtools/browser/"),
              lines[1].dropFirst("/devtools/browser/".count).allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0=="-")}),
              let url=URL(string:"ws://127.0.0.1:\(port)\(lines[1])") else {
            throw BridgeError("Chrome returned an invalid local setup endpoint.")
        }
        return url
    }
    static func extensionID(response:Data) throws -> String {
        guard let value=try JSONSerialization.jsonObject(with:response) as? [String:Any],value["id"] as? Int == 1 else {
            throw BridgeError("Chrome returned an invalid installation response.")
        }
        if let error=value["error"] as? [String:Any] {
            throw BridgeError("Chrome could not load Cue: \(error["message"] as? String ?? "unknown error"). Update Chrome and retry, or use manual setup.")
        }
        guard let result=value["result"] as? [String:Any],let id=result["id"] as? String,
              id.range(of:"^[a-p]{32}$",options:.regularExpression) != nil else {
            throw BridgeError("Chrome did not return a valid extension ID.")
        }
        return id
    }
    static func install(chrome:URL,folder:URL,profile:URL) async throws -> String {
        guard !isRunning(profile:profile) else {
            throw BridgeError("Quit Cue Chrome (⌘Q), then retry. Your regular Chrome windows can stay open.")
        }
        let files=FileManager.default
        try files.createDirectory(at:profile,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let portFile=profile.appendingPathComponent("DevToolsActivePort")
        if files.fileExists(atPath:portFile.path) {try files.removeItem(at:portFile)}
        let process=Process()
        process.executableURL=chrome
        process.arguments=["--user-data-dir=\(profile.path)","--remote-debugging-port=0","--remote-debugging-address=127.0.0.1","--enable-unsafe-extension-debugging","--no-first-run","--no-default-browser-check","--new-window","https://meet.google.com/"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
        do {
            let deadline=Date().addingTimeInterval(20)
            while (try? endpoint(profile:profile)) == nil {
                guard process.isRunning else {throw BridgeError("Cue Chrome could not start. Close its windows and retry, or update Chrome.")}
                guard Date()<deadline else {throw BridgeError("Chrome setup timed out. Close Cue Chrome and retry.")}
                try await Task.sleep(nanoseconds:100_000_000)
            }
            let session=URLSession(configuration:.ephemeral)
            defer {session.invalidateAndCancel()}
            let socket=session.webSocketTask(with:try endpoint(profile:profile))
            socket.maximumMessageSize=64*1024
            socket.resume()
            defer {socket.cancel(with:.normalClosure,reason:nil)}
            let request=try JSONSerialization.data(withJSONObject:["id":1,"method":"Extensions.loadUnpacked","params":["path":folder.path]])
            let id=try await withThrowingTaskGroup(of:String.self) {group in
                group.addTask {
                    try await socket.send(.string(String(decoding:request,as:UTF8.self)))
                    let response=try await socket.receive()
                    switch response {
                    case .data(let data):return try extensionID(response:data)
                    case .string(let text):return try extensionID(response:Data(text.utf8))
                    @unknown default:throw BridgeError("Chrome returned an unsupported setup response.")
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds:15_000_000_000)
                    socket.cancel(with:.goingAway,reason:nil)
                    throw BridgeError("Chrome extension installation timed out. Update Chrome and retry, or use manual setup.")
                }
                defer {group.cancelAll()}
                return try await group.next()!
            }
            let marker=try JSONEncoder().encode(["id":id,"pid":String(process.processIdentifier),"fingerprint":try fingerprint(folder:folder)])
            try marker.write(to:profile.appendingPathComponent("cue-extension.json"),options:.atomic)
            return id
        } catch {
            // Only the browser started by this attempt can be stopped on setup failure.
            if process.isRunning {process.terminate()}
            throw error
        }
    }
}
