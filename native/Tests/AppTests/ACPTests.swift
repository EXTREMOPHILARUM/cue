import XCTest
import CallCore
@testable import CallAssistant

final class ACPTests:XCTestCase {
    private func nodeExecutable() throws -> URL {
        let paths=(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map{String($0)+"/node"}
        return URL(fileURLWithPath:try XCTUnwrap(paths.first{FileManager.default.isExecutableFile(atPath:$0)},"Development checks require Node.js on PATH"))
    }

    @MainActor func testStalledInputDoesNotBlockTimeoutOrMainActor() async throws {
        let connection=try ACPConnection(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["10"],environment:[:],directory:FileManager.default.temporaryDirectory)
        defer {connection.close()}
        let began=Date()
        let request=Task {try await connection.request("initialize",params:["text":String(repeating:"x",count:1_000_000)],timeout:0.15)}
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(began),1,"Pipe writes blocked the main actor")
        do {_ = try await request.value;XCTFail("Stalled input accepted")}
        catch {XCTAssertTrue(error.localizedDescription.contains("time limit"),error.localizedDescription)}
        XCTAssertLessThan(Date().timeIntervalSince(began),1)
    }
    @MainActor func testOutputFloodFailsWithinBounds() async throws {
        let node=try nodeExecutable()
        let connection=try ACPConnection(executable:node,arguments:["-e","process.stdout.write('x'.repeat(4000000));setTimeout(()=>{},10000)"],environment:[:],directory:FileManager.default.temporaryDirectory)
        defer {connection.close()}
        do {_ = try await connection.request("initialize",params:[:],timeout:2);XCTFail("Output flood accepted")}
        catch {XCTAssertTrue(error.localizedDescription.contains("output exceeded limit"),error.localizedDescription)}
    }
    @MainActor func testStalledInputCanBeCancelled() async throws {
        let connection=try ACPConnection(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["10"],environment:[:],directory:FileManager.default.temporaryDirectory)
        defer {connection.close()}
        let request=Task {try await connection.request("initialize",params:["text":String(repeating:"x",count:1_000_000)],timeout:10)}
        try await Task.sleep(nanoseconds:50_000_000)
        request.cancel()
        do {_ = try await request.value;XCTFail("Stalled write ignored cancellation")}
        catch {XCTAssertTrue(error is CancellationError)}
        XCTAssertFalse(connection.isRunning)
    }
    private func folder() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    @MainActor private func fixture(_ root:URL,behavior:String="normal") throws -> ACPClient {
        let script=root.appendingPathComponent("agent.mjs")
        try #"""
        import readline from 'node:readline';
        import fs from 'node:fs';
        const behavior=process.argv[2],session='11111111-1111-4111-8111-111111111111';
        const send=m=>process.stdout.write(JSON.stringify({jsonrpc:'2.0',...m})+'\n');
        let turns=0;
        fs.appendFileSync('launches','start\n');
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const m=JSON.parse(line);fs.appendFileSync('requests',m.method+'\n');
          if(m.method==='initialize')return send({id:m.id,result:{protocolVersion:1,agentCapabilities:{loadSession:true}}});
          if(m.method==='session/new'||m.method==='session/load')return send({id:m.id,result:{sessionId:session}});
          if(m.method==='session/prompt'){
            if(behavior==='disconnect')return process.exit(0);
            if(behavior==='timeout')return;
            turns++;
            const answer=JSON.stringify({headline:'Turn '+turns,question:'What is next?',points:[],summary:'Pilot discussed.',decisions:[],actions:[],uncertainties:[],evidence:[behavior==='bad-evidence'?'other':'s1'],shouldUpdate:true});
            send({method:'session/update',params:{sessionId:session,update:{sessionUpdate:'notice',severity:'warning',title:'Synthetic provider warning'}}});
            send({method:'session/update',params:{sessionId:session,update:{sessionUpdate:'agent_message_chunk',messageId:'commentary',content:{type:'text',text:'Separate commentary message'}}}});
            send({method:'session/update',params:{sessionId:'other-session',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'IGNORE THIS'}}}});
            send({method:'session/update',params:{sessionId:session,update:{sessionUpdate:'agent_thought_chunk',content:{type:'text',text:'NOT THE ANSWER'}}}});
            for(const text of [answer.slice(0,30),answer.slice(30)])send({method:'session/update',params:{sessionId:session,update:{sessionUpdate:'agent_message_chunk',messageId:'answer',content:{type:'text',text}}}});
            send({id:m.id,result:{stopReason:behavior==='cancelled'?'cancelled':'end_turn'}});
          }
        });
        """#.write(to:script,atomically:true,encoding:.utf8)
        let node=try nodeExecutable()
        return ACPClient(launch:{_ in (node,[script.path,behavior],[:])})
    }
    @MainActor func testPersistentConnectionStreamsAndIsolatesSessionsForBothProviders() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let client=try fixture(root);defer {client.close()}
        let input=AIInput(prompt:"Synthetic coaching fixture",segmentIDs:["s1"],fingerprint:"one")
        for provider in AIProvider.allCases {
            var project=AIProject(path:root.path,provider:provider)
            let first=try await client.generate(provider:provider,mode:.coaching,input:input,project:project)
            XCTAssertEqual(first.headline,"Turn 1")
            XCTAssertEqual(first.providerNotices,["Synthetic provider warning"])
            project.conversation=try XCTUnwrap(first.conversationID)
            let next=try await client.generate(provider:provider,mode:.coaching,input:input,project:project)
            XCTAssertEqual(next.headline,"Turn 2")
            XCTAssertEqual(next.timing?["connectionReused"],1)
        }
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("launches")).split(separator:"\n").count,2,"One process per provider, not one per turn")
        let requests=try String(contentsOf:root.appendingPathComponent("requests")).split(separator:"\n")
        XCTAssertEqual(requests.filter{$0=="initialize"}.count,2)
        XCTAssertEqual(requests.filter{$0=="session/prompt"}.count,4)
    }
    @MainActor func testDownloadedProvidersWithSyntheticTranscriptWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CUE_ACP_SMOKE"]=="1" else {throw XCTSkip("Opt in to signed-in provider smoke tests")}
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let client=ACPClient()
        defer {client.close()}
        let detail:[String:Any]=["meta":["title":"Synthetic integration test"],"segments":[["id":"s1","source":"meet","speaker":"Other","text":"Who will own the pilot?","t":1.0]]]
        for provider in AIProvider.allCases {
            var project=AIProject(path:root.path,provider:provider)
            let input=try AIInput.make(detail:detail,mode:.coaching,background:"This is a synthetic integration test. No tools or research are needed. Return only the requested JSON.",previous:nil,project:project)
            let first=try await client.generate(provider:provider,mode:.coaching,input:input,project:project)
            project.conversation=try XCTUnwrap(first.conversationID)
            let next=try await client.generate(provider:provider,mode:.coaching,input:input,project:project)
            XCTAssertEqual(next.timing?["connectionReused"],1)
            client.close()
            let resumed=try await client.generate(provider:provider,mode:.coaching,input:input,project:project)
            XCTAssertEqual(resumed.conversationID,project.conversation)
            print("ACP synthetic smoke \(provider.title): first \(Int(first.timing?["totalMs"] ?? 0)) ms; reused \(Int(next.timing?["totalMs"] ?? 0)) ms")
        }
    }
    @MainActor func testDisconnectTimeoutCancellationAndInvalidResponses() async throws {
        let input=AIInput(prompt:"Fixture",segmentIDs:["s1"],fingerprint:"")
        for behavior in ["disconnect","timeout","bad-evidence","cancelled"] {
            let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
            let client=try fixture(root,behavior:behavior);defer {client.close()}
            do {
                _ = try await client.generate(provider:.codex,mode:.coaching,input:input,project:AIProject(path:root.path),timeout:0.4)
                XCTFail("Accepted \(behavior)")
            } catch {XCTAssertFalse(error.localizedDescription.isEmpty)}
        }
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let client=try fixture(root,behavior:"timeout");defer {client.close()}
        let task=Task {try await client.generate(provider:.claude,mode:.coaching,input:input,project:AIProject(path:root.path))}
        try await Task.sleep(nanoseconds:100_000_000);task.cancel()
        do {_ = try await task.value;XCTFail("Cancellation ignored")} catch {XCTAssertTrue(error is CancellationError)}
    }
}
