import Foundation
import CryptoKit
import Combine
import CallCore

@MainActor final class AgentRuntime:ObservableObject {
    static let shared=AgentRuntime()
    @Published private(set) var status:[AIProvider:String]=[:]
    @Published private(set) var downloading:Set<AIProvider>=[]
    private var tasks:[AIProvider:Task<URL,Error>]=[:]
    private let install:(AIProvider,@escaping @Sendable (String) async -> Void) async throws -> URL
    init(install:@escaping (AIProvider,@escaping @Sendable (String) async -> Void) async throws -> URL = RuntimeDownload.prepare) {self.install=install}
    func prepare(_ provider:AIProvider) async throws -> URL {
        if let task=tasks[provider] {return try await task.value}
        downloading.insert(provider)
        let task=Task {try await install(provider) {message in await MainActor.run {self.status[provider]=message}}}
        tasks[provider]=task
        defer {tasks[provider]=nil;downloading.remove(provider)}
        do {
            let root=try await task.value
            status[provider]="Ready on this Mac"
            return root
        } catch {
            status[provider]="Download failed: \(error.localizedDescription). Try again."
            throw error
        }
    }
}

enum RuntimeDownload {
    static let nodeVersion="24.16.0"
    #if arch(arm64)
    static let architecture="arm64"
    static let nodeSHA256="39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6"
    #else
    static let architecture="x64"
    static let nodeSHA256="298b4c7b3cb80765c8703e42b90324a4ece3b6634947b89e769c3c980ab55185"
    #endif
    static func digest(_ data:Data) -> String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func verify(_ data:Data,sha256:String) throws {
        guard digest(data) == sha256 else {throw BridgeError("Node.js download failed its integrity check")}
    }
    static func script(_ provider:AIProvider,in root:URL) -> URL {
        root.appendingPathComponent("node_modules/@agentclientprotocol/\(provider == .codex ? "codex-acp":"claude-agent-acp")/dist/index.js")
    }
    static func ready(_ provider:AIProvider,at root:URL) -> Bool {
        FileManager.default.isExecutableFile(atPath:root.appendingPathComponent("node-runtime/bin/node").path) && FileManager.default.fileExists(atPath:script(provider,in:root).path) && FileManager.default.fileExists(atPath:root.appendingPathComponent("ready").path)
    }
    static func prepare(_ provider:AIProvider,progress:@escaping @Sendable (String) async -> Void) async throws -> URL {
        guard let manifests=Bundle.module.url(forResource:"AgentDependencies",withExtension:nil)?.appendingPathComponent(provider.rawValue) else {throw BridgeError("AI download manifest is missing")}
        let lock=try Data(contentsOf:manifests.appendingPathComponent("package-lock.json"))
        let key="node-\(nodeVersion)-\(architecture)-"+digest(lock)
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let destination=support.appendingPathComponent("Cue/AgentRuntimes/\(provider.rawValue)/\(key)",isDirectory:true)
        if ready(provider,at:destination) {return destination}
        await progress("Downloading Node.js for \(provider.title)…")
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource=600
        let session=URLSession(configuration:config)
        defer {session.invalidateAndCancel()}
        let archiveName="node-v\(nodeVersion)-darwin-\(architecture)"
        let (download,response)=try await session.download(from:URL(string:"https://nodejs.org/dist/v\(nodeVersion)/\(archiveName).tar.gz")!)
        defer {try? FileManager.default.removeItem(at:download)}
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {throw BridgeError("Node.js download failed")}
        try verify(Data(contentsOf:download,options:.mappedIfSafe),sha256:nodeSHA256)
        await progress("Installing \(provider.title) tools…")
        return try await Task.detached {
            try install(provider,at:destination) {stage in
                let unpack=stage.appendingPathComponent("unpack")
                try FileManager.default.createDirectory(at:unpack,withIntermediateDirectories:true)
                try run("/usr/bin/tar",["-xzf",download.path,"-C",unpack.path],directory:stage)
                try FileManager.default.moveItem(at:unpack.appendingPathComponent(archiveName),to:stage.appendingPathComponent("node-runtime"))
                try FileManager.default.removeItem(at:unpack)
                for name in ["package.json","package-lock.json"] {try FileManager.default.copyItem(at:manifests.appendingPathComponent(name),to:stage.appendingPathComponent(name))}
                let node=stage.appendingPathComponent("node-runtime/bin/node")
                let npm=stage.appendingPathComponent("node-runtime/lib/node_modules/npm/bin/npm-cli.js")
                try run(node.path,[npm.path,"ci","--ignore-scripts","--omit=dev","--no-audit","--no-fund","--registry=https://registry.npmjs.org"],directory:stage)
            }
        }.value
    }
    // Publish only a complete installation; a failed attempt never replaces a usable cache.
    static func install(_ provider:AIProvider,at destination:URL,body:(URL) throws -> Void) throws -> URL {
        let files=FileManager.default
        try files.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        let stage=destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
        try files.createDirectory(at:stage,withIntermediateDirectories:true)
        defer {try? files.removeItem(at:stage)}
        try body(stage)
        try Data().write(to:stage.appendingPathComponent("ready"))
        guard ready(provider,at:stage) else {throw BridgeError("Downloaded AI tools are incomplete")}
        if ready(provider,at:destination) {return destination}
        if files.fileExists(atPath:destination.path) {try files.removeItem(at:destination)}
        try files.moveItem(at:stage,to:destination)
        return destination
    }
    private static func run(_ executable:String,_ arguments:[String],directory:URL) throws {
        let process=Process()
        process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments;process.currentDirectoryURL=directory
        let log=directory.appendingPathComponent("install.log")
        _ = FileManager.default.createFile(atPath:log.path,contents:nil)
        let output=try FileHandle(forWritingTo:log)
        defer {try? output.close()}
        process.standardOutput=output;process.standardError=output
        let allowed=Set(["HOME","USER","LOGNAME","TMPDIR","LANG","LC_ALL"])
        process.environment=ProcessInfo.processInfo.environment.filter{allowed.contains($0.key)}
        process.environment?["PATH"]=directory.appendingPathComponent("node-runtime/bin").path+":/usr/bin:/bin:/usr/sbin:/sbin"
        try process.run()
        defer {if process.isRunning {process.terminate()}}
        let deadline=Date().addingTimeInterval(600)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date()<deadline else {throw BridgeError("AI tool installation timed out")}
            Thread.sleep(forTimeInterval:0.1)
        }
        guard process.terminationStatus == 0 else {throw BridgeError("AI tool installation failed (\(process.terminationStatus))")}
    }
}
