import Foundation
import CallCore
import Darwin

/// One ACP connection per call runner; both providers use the same wire protocol.
@MainActor final class ACPClient {
    private var connection:ACPConnection?
    private var identity=""
    private var session=""
    private var initialized=false
    private var generation=UUID()
    private var canLoad=false
    private let launch:((AIProvider) throws -> (URL,[String], [String:String]))?
    init(launch:((AIProvider) throws -> (URL,[String],[String:String]))? = nil) {self.launch=launch}
    func close() {generation=UUID();connection?.close();connection=nil;identity="";session="";initialized=false}
    func generate(provider:AIProvider,mode:AIMode,input:AIInput,project:AIProject,timeout:TimeInterval=90) async throws -> AIResponse {
        let began=Date()
        let key=provider.rawValue+"\n"+project.path
        var validation=project
        if identity==key,session==project.conversation {validation.conversation=""}
        try validation.validate(provider:provider)
        if identity != key || connection?.isRunning != true {close();identity=key}
        let reused=connection != nil
        if connection == nil {
            let token=generation
            let command:(URL,[String],[String:String])
            if let launch {command=try launch(provider)}
            else {
                let root=try await AgentRuntime.shared.prepare(provider)
                try Task.checkCancellation()
                guard generation == token else {throw CancellationError()}
                command=try Self.runtime(provider,root:root)
            }
            connection=try ACPConnection(executable:command.0,arguments:command.1,environment:command.2,directory:URL(fileURLWithPath:project.path))
        }
        guard let connection else {throw BridgeError("ACP connection unavailable")}
        do {
            if !initialized {
                let hello=try await connection.request("initialize",params:["protocolVersion":1,"clientCapabilities":["session":["notices":[:]]],"clientInfo":["name":"cue","version":"0.1.0"]],timeout:timeout)
                try checkActive(connection)
                guard hello["protocolVersion"] as? Int == 1 else {throw BridgeError("Agent does not support ACP version 1")}
                canLoad=(hello["agentCapabilities"] as? [String:Any])?["loadSession"] as? Bool == true
                initialized=true
            }
            if session.isEmpty || session != project.conversation {
                var params:[String:Any]=["cwd":project.path,"mcpServers":[]]
                // Keep quick coaching tool-free. Research runs separately from the live turn.
                if provider == .claude {params["_meta"]=["claudeCode":["options":["tools":[],"settingSources":[],"hooks":[:],"mcpServers":[:],"allowDangerouslySkipPermissions":false]]]}
                if project.conversation.isEmpty {
                    let result=try await connection.request("session/new",params:params,timeout:timeout)
                    try checkActive(connection)
                    guard let id=result["sessionId"] as? String,UUID(uuidString:id) != nil else {throw BridgeError("ACP agent returned an invalid session identity")}
                    session=id
                } else {
                    guard canLoad else {throw BridgeError("This ACP agent cannot resume saved conversations; choose a new conversation")}
                    params["sessionId"]=project.conversation
                    _ = try await connection.request("session/load",params:params,timeout:timeout)
                    try checkActive(connection)
                    session=project.conversation
                }
            }
            connection.beginTurn(session)
            let ready=Date()
            let result=try await connection.request("session/prompt",params:["sessionId":session,"prompt":[["type":"text","text":input.prompt+"\nJSON_SCHEMA:\n"+AIResponse.schema]]],timeout:timeout)
            try checkActive(connection)
            guard result["stopReason"] as? String == "end_turn" else {throw BridgeError("ACP coaching did not complete: \(result["stopReason"] as? String ?? "unknown reason")")}
            var response=try JSONDecoder().decode(AIResponse.self,from:Data(connection.answer.utf8))
            try response.validate(segmentIDs:input.segmentIDs)
            guard mode != .summary || !response.summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw BridgeError("AI returned an empty summary")}
            response.conversationID=session
            response.providerNotices=connection.notices
            response.timing=["setupMs":ready.timeIntervalSince(began)*1000,"firstTextMs":(connection.firstTextAt ?? Date()).timeIntervalSince(began)*1000,"totalMs":Date().timeIntervalSince(began)*1000,"connectionReused":reused ? 1:0]
            return response
        } catch {
            if self.connection === connection {close()} else {connection.close()}
            throw error
        }
    }
    private func checkActive(_ connection:ACPConnection) throws {
        try Task.checkCancellation()
        guard self.connection === connection else {throw CancellationError()}
    }
    static func runtime(_ provider:AIProvider,root:URL) throws -> (URL,[String],[String:String]) {
        let node=root.appendingPathComponent("node-runtime/bin/node")
        guard FileManager.default.isExecutableFile(atPath:node.path) else {throw BridgeError("Downloaded Node.js is missing; retry AI tools setup in Settings")}
        let package=provider == .codex ? "codex-acp":"claude-agent-acp"
        let script=root.appendingPathComponent("node_modules/@agentclientprotocol/\(package)/dist/index.js")
        guard FileManager.default.fileExists(atPath:script.path) else {throw BridgeError("AI tools are incomplete; download them again in Settings")}
        let allowed=Set(["HOME","USER","LOGNAME","TMPDIR","LANG","LC_ALL","CODEX_HOME","CODEX_API_KEY","OPENAI_API_KEY","ANTHROPIC_API_KEY","ANTHROPIC_AUTH_TOKEN"])
        var env=ProcessInfo.processInfo.environment.filter{allowed.contains($0.key)}
        env["PATH"]=node.deletingLastPathComponent().path+":/usr/bin:/bin:/usr/sbin:/sbin"
        env["INITIAL_AGENT_MODE"]="read-only"
        env["CODEX_CONFIG"]=try Validation.json(["approval_policy":"never","sandbox_mode":"read-only","project_doc_max_bytes":0,"web_search":"disabled","mcp_servers":[:],"hooks":[:],"features":["shell_tool":false,"hooks":false,"apps":false,"multi_agent":false,"skill_search":false,"skip_host_skill_discovery":true]])
        env["CLAUDE_AGENT_ACP_PROTOCOL"]="v1"
        return (node,[script.path],env)
    }
}

@MainActor final class ACPConnection {
    private let process=Process()
    private let input=Pipe()
    private let output=Pipe()
    private let errors=Pipe()
    private let writer=DispatchQueue(label:"cue.acp.write")
    private var reader:Task<Void,Never>?
    private var pending=[Int:CheckedContinuation<[String:Any],Error>]()
    private var timers=[Int:Task<Void,Never>]()
    private var nextID=0
    private var turnSession=""
    private var messageID=""
    private var closed=false
    private(set) var answer=""
    private(set) var firstTextAt:Date?
    private(set) var notices=[String]()
    var isRunning:Bool {!closed && process.isRunning}
    init(executable:URL,arguments:[String],environment:[String:String],directory:URL) throws {
        process.executableURL=executable;process.arguments=arguments;process.environment=environment;process.currentDirectoryURL=directory
        process.standardInput=input;process.standardOutput=output;process.standardError=errors
        guard fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1) != -1 else {throw BridgeError("Cannot configure ACP pipe")}
        // Drain diagnostics without retaining transcript or credential-bearing provider logs.
        errors.fileHandleForReading.readabilityHandler={handle in _ = handle.availableData}
        let (stream,continuation)=AsyncStream<Data>.makeStream(bufferingPolicy:.bufferingOldest(32))
        let handle=output.fileHandleForReading
        DispatchQueue(label:"cue.acp.read").async { [weak self] in
            defer {continuation.finish()}
            while true {
                let data=handle.availableData
                if data.isEmpty {break}
                if case .dropped = continuation.yield(data) {
                    Task { @MainActor [weak self] in self?.fail(BridgeError("ACP output exceeded limit")) }
                    break
                }
            }
        }
        do {try process.run()} catch {
            try? output.fileHandleForWriting.close();try? input.fileHandleForWriting.close()
            errors.fileHandleForReading.readabilityHandler=nil
            throw error
        }
        // The parent must close its copies so EOF follows an agent exit.
        try? output.fileHandleForWriting.close();try? errors.fileHandleForWriting.close()
        reader=Task { [weak self] in
            var buffer=Data()
            for await chunk in stream {
                guard let self,!self.closed else {break}
                buffer.append(chunk)
                guard buffer.count<=2_000_000 else {self.fail(BridgeError("ACP output exceeded limit"));return}
                while let newline=buffer.firstIndex(of:10) {
                    let line=Data(buffer[..<newline]);buffer.removeSubrange(...newline)
                    if !line.isEmpty {self.receive(line)}
                }
            }
            self?.fail(BridgeError("ACP agent disconnected; restart coaching to reconnect"))
        }
    }
    func beginTurn(_ session:String) {turnSession=session;answer="";messageID="";firstTextAt=nil;notices=[]}
    func request(_ method:String,params:[String:Any],timeout:TimeInterval) async throws -> [String:Any] {
        try Task.checkCancellation()
        nextID += 1;let id=nextID
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                guard isRunning else {continuation.resume(throwing:BridgeError("ACP agent is not running"));return}
                pending[id]=continuation
                timers[id]=Task { [weak self] in
                    do {try await Task.sleep(nanoseconds:UInt64(max(0.01,timeout)*1_000_000_000))} catch {return}
                    self?.fail(BridgeError("ACP request exceeded its time limit"))
                }
                do {try send(["jsonrpc":"2.0","id":id,"method":method,"params":params])}
                catch {fail(error)}
            }
        },onCancel:{Task { @MainActor [weak self] in self?.fail(CancellationError()) }})
    }
    private func send(_ message:[String:Any]) throws {
        var data=try JSONSerialization.data(withJSONObject:message);data.append(10)
        let handle=input.fileHandleForWriting
        // A stalled agent must not block the UI actor or its timeout/cancellation tasks.
        writer.async { [weak self] in
            do {try handle.write(contentsOf:data)}
            catch {Task { @MainActor in self?.fail(error) }}
        }
    }
    private func receive(_ data:Data) {
        do {
            guard let message=try JSONSerialization.jsonObject(with:data) as? [String:Any],message["jsonrpc"] as? String == "2.0" else {throw BridgeError("Invalid ACP response")}
            if let method=message["method"] as? String {
                if let id=message["id"] {
                    if method == "session/request_permission" {
                        try send(["jsonrpc":"2.0","id":id,"result":["outcome":["outcome":"cancelled"]]])
                    } else {try send(["jsonrpc":"2.0","id":id,"error":["code":-32601,"message":"Client method not supported"]])}
                    return
                }
                guard method == "session/update",let params=message["params"] as? [String:Any],params["sessionId"] as? String == turnSession,
                      let update=params["update"] as? [String:Any] else {return}
                if update["sessionUpdate"] as? String == "notice" {
                    if notices.count<8,let title=update["title"] as? String {notices.append(String(title.prefix(500)))}
                    return
                }
                guard update["sessionUpdate"] as? String == "agent_message_chunk",
                      let content=update["content"] as? [String:Any],content["type"] as? String == "text",let text=content["text"] as? String else {return}
                if let id=update["messageId"] as? String,id != messageID {messageID=id;answer=""}
                guard answer.utf8.count+text.utf8.count<=100_000 else {throw BridgeError("ACP coaching response exceeded limit")}
                if !text.isEmpty,firstTextAt==nil {firstTextAt=Date()}
                answer += text
            } else if let id=message["id"] as? Int,let continuation=pending.removeValue(forKey:id) {
                timers.removeValue(forKey:id)?.cancel()
                if let error=message["error"] as? [String:Any] {
                    let code=error["code"] as? Int ?? 0
                    continuation.resume(throwing:BridgeError("ACP request failed (\(code)); check the provider sign-in and usage limits"))
                } else if let result=message["result"] as? [String:Any] {continuation.resume(returning:result)}
                else {continuation.resume(throwing:BridgeError("ACP response is missing its result"))}
            }
        } catch {fail(error)}
    }
    func close() {fail(CancellationError())}
    private func fail(_ error:Error) {
        guard !closed else {return};closed=true
        if !turnSession.isEmpty {try? send(["jsonrpc":"2.0","method":"session/cancel","params":["sessionId":turnSession]])}
        let handle=input.fileHandleForWriting
        writer.async {try? handle.close()}
        reader?.cancel();reader=nil
        errors.fileHandleForReading.readabilityHandler=nil
        let requests=pending;pending.removeAll()
        for timer in timers.values {timer.cancel()};timers.removeAll()
        for continuation in requests.values {continuation.resume(throwing:error)}
        let child=process
        DispatchQueue.global().asyncAfter(deadline:.now()+1) {
            if child.isRunning {child.terminate()}
            DispatchQueue.global().asyncAfter(deadline:.now()+1) {if child.isRunning {kill(child.processIdentifier,SIGKILL)}}
        }
    }
}
