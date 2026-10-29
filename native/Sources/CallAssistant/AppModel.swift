import Foundation
import AppKit
import CallCore

struct SummaryCompletion:Equatable {let session:String;let requestID:String}

@MainActor final class AppModel: ObservableObject {
    @Published var bridgeStatus = "Starting"
    @Published var extensionConnected = false
    @Published var modelStatus = "Not loaded"
    @Published var errorMessage = ""
    @Published var historyQuery = ""
    @Published var selectedDetail: [String: Any]?
    @Published private(set) var completedAutomaticSummary:SummaryCompletion?
    @Published var sessions: [[String: Any]] = []
    @Published var activeSession: String?
    @Published private(set) var paused = true
    @Published private(set) var captureConsentGranted=false
    @Published private(set) var aiConsentGranted=false
    @Published var liveRefinementEnabled=true {didSet {preferences?.set(liveRefinementEnabled,forKey:"liveRefinementEnabled")}}
    private var refinementOwner=""
    private var nextLiveRefinement=Date.distantPast
    private var lastLiveRefinement=""
    var speechModelDownloaded:Bool {Transcriber.downloaded(at:Transcriber.modelFolder())}
    @Published var prompt = "Canvas is loading"
    @Published var coachingTransparencyOverride=false {
        didSet {
            preferences?.set(coachingTransparencyOverride,forKey:"coachingTransparencyOverride")
            panel?.updateTransparency()
        }
    }
    @Published var coachingBackdropOpacity=0.72 {
        didSet {
            let value=coachingBackdropOpacity.isFinite ? min(1,max(0,coachingBackdropOpacity)):0.72
            if coachingBackdropOpacity != value {coachingBackdropOpacity=value;return}
            preferences?.set(coachingBackdropOpacity,forKey:"coachingBackdropOpacity")
            panel?.updateTransparency()
        }
    }
    @Published var extensionID = UserDefaults.standard.string(forKey:"extensionID") ?? "" {
        didSet {
            UserDefaults.standard.set(extensionID,forKey:"extensionID")
            if extensionID != oldValue { server?.disconnectExtensions() }
        }
    }
    @Published var aiProject = AIProject()
    @Published var aiProvider:AIProvider = .codex {
        didSet {
            preferences?.set(aiProvider.rawValue,forKey:"aiProvider")
            let restart=aiProvider != oldValue && liveAISession != nil && liveAISession==activeSession
            if aiProvider != oldValue {stopAI()}
            if aiProject.provider != aiProvider {aiProject.provider=aiProvider;aiProject.conversation=""}
            if restart {startLiveAI()}
        }
    }
    @Published var automaticSummaries=false {
        didSet {
            preferences?.set(automaticSummaries,forKey:"automaticSummaries")
            if !automaticSummaries,automaticSummarySession != nil {stopAI()}
        }
    }
    @Published private(set) var aiSession:String?
    private var automaticSummarySession:String?
    @Published var aiBusy = false
    @Published var aiStatus = ""
    @Published var aiError = ""
    @Published private(set) var aiErrorSession:String?
    @Published var liveAISession:String?
    @Published private(set) var coachingPaused=false
    var aiGenerate:(AIProvider,AIMode,AIInput,AIProject) async throws -> AIResponse
    private let acpClient=ACPClient()
    private var aiTask:Task<Void,Never>?
    private var aiRun=UUID()
    private var liveAIProject=AIProject()
    private var nextAI=Date.distantPast
    private var lastAIInput=""
    private var coachingSchedule=CoachingSchedule()
    var researchSearch:(String,String) async throws -> [[String:String]] = {path,query in
        let worker=Task.detached {try ProjectResearch.search(path:path,query:query)}
        return try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    }
    private var researchTask:Task<Void,Never>?
    private var research=[[String:String]]()
    private var researchQueries=Set<String>()
    private var researchRun=UUID()
    private var researchOwner=""
    private let aiDirectory:URL
    private let preferences:UserDefaults?
    let store: SessionStore
    let transcriber = Transcriber()
    var server: BridgeServer!
    let calendar=MeetingCalendar()
    var panel: CoachingPanel?
    private var owners: [String: String] = [:]
    private var captureSession: String?
    private var captureRunID = UUID().uuidString
    private var expectedSequence = 0
    private var pending = [AudioChunk]()
    private var processing = false
    private var processingArchive = false
    @Published private(set) var modelReady = false
    private var audioEpoch = 0
    private var drainingSession: String?
    private(set) var coaching: [String: Any]?
    private var timer: Timer?
    init(directory: URL? = nil, port: UInt16 = 17373, preferences:UserDefaults? = nil) throws {
        self.preferences=preferences ?? (directory == nil ? .standard:nil)
        let root = try directory ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("Cue",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        aiDirectory=root.appendingPathComponent("Conversations",isDirectory:true)
        store = try SessionStore(path:root.appendingPathComponent("sessions.sqlite3").path)
        let client=acpClient
        aiGenerate={try await client.generate(provider:$0,mode:$1,input:$2,project:$3)}
        captureConsentGranted=self.preferences?.bool(forKey:"captureConsentGranted") ?? false
        aiConsentGranted=self.preferences?.bool(forKey:"aiConsentGranted") ?? false
        liveRefinementEnabled=self.preferences?.object(forKey:"liveRefinementEnabled") as? Bool ?? true
        paused = !captureConsentGranted
        aiProvider=AIProvider(rawValue:self.preferences?.string(forKey:"aiProvider") ?? "") ?? .codex
        aiProject.provider=aiProvider
        automaticSummaries=self.preferences?.bool(forKey:"automaticSummaries") ?? false
        coachingTransparencyOverride=self.preferences?.bool(forKey:"coachingTransparencyOverride") ?? false
        let opacity=self.preferences?.object(forKey:"coachingBackdropOpacity") as? Double ?? 0.72
        coachingBackdropOpacity=opacity.isFinite ? min(1,max(0,opacity)):0.72
        server = try BridgeServer(port:port,extensionID:{ [weak self] in self?.extensionID ?? "" })
        server.handle = { [weak self] role, request in
            guard let self else { throw BridgeError("App stopped") }
            return try await self.request(role:role,request:request)
        }
        server.state = { [weak self] status in self?.bridgeStatus = status }
        server.extensionConnectionChanged = { [weak self] connected in self?.extensionConnected = connected }
        server.disconnected = { [weak self] id in self?.disconnect(id.uuidString) }
        sessions = try store.list()
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.drainArchive()
                self.tickLiveRefinement()
                self.tickAI()
                self.tickSummaries()
            }
        }
        server.start()
    }
    func attachPanel() { if panel == nil { panel = CoachingPanel(model:self) } }
    func loadModel() {
        guard modelStatus != "Loading" else { return }
        modelStatus = "Loading"
        Task {
            do { try await transcriber.load(); modelReady = true; modelStatus = "Ready · Roman Hinglish + English"; drainArchive() }
            catch { modelReady=false;modelStatus = "Model failed"; errorMessage = error.localizedDescription }
        }
    }
    func setCaptureConsent(_ granted:Bool) {
        captureConsentGranted=granted;preferences?.set(granted,forKey:"captureConsentGranted")
        setPaused(!granted)
    }
    func setAIConsent(_ granted:Bool) {
        aiConsentGranted=granted;preferences?.set(granted,forKey:"aiConsentGranted")
        if !granted {automaticSummaries=false;stopAI()}
    }
    func setPaused(_ value: Bool) { guard value || captureConsentGranted else {return};paused = value; if value { stopAI(); audioEpoch += 1; pending.removeAll(); clearCoaching(); server.broadcast("paused",role:"extension") } else { server.broadcast("resumed",role:"extension"); drainArchive() } }
    func clearCoaching() { coaching = nil; panel?.update(nil) }
    func select(_ id: String) {
        do {
            let detail=try store.detail(id)
            if activeSession != id {
                let project=try projectForCall(detail)
                if liveAISession == nil,automaticSummarySession == nil {stopAI()}
                activeSession=id;clearCoaching();aiProject=project;aiError=""
            }
            selectedDetail=detail
        } catch {errorMessage=error.localizedDescription}
    }
    func refreshHistory() {
        do { sessions = try historyQuery.isEmpty ? store.list() : store.search(historyQuery); if let activeSession { selectedDetail = try store.detail(activeSession) } }
        catch { errorMessage = error.localizedDescription }
    }
    func projectForCall(_ detail:[String:Any]) throws -> AIProject {
        let settings=detail["aiSettings"] as? [String:Any] ?? [:]
        var project=settings.isEmpty ? AIProject():try JSONDecoder().decode(AIProject.self,from:JSONSerialization.data(withJSONObject:settings))
        if let meta=detail["meta"] as? [String:Any],let series=SessionStore.recurringProjectKey(meta),
           let shared=try store.seriesProject(series) {
            let path=shared["path"] as? String ?? ""
            let conversationPath=path.isEmpty ? aiDirectory.path:path
            if URL(fileURLWithPath:project.path).resolvingSymlinksInPath().path != URL(fileURLWithPath:conversationPath).resolvingSymlinksInPath().path {project.conversation=""}
            project.path=project.conversation.isEmpty ? path:conversationPath;project.background=shared["background"] as? String ?? ""
            project.skill=shared["skill"] as? String
        }
        if project.provider != aiProvider {project.provider=aiProvider;project.conversation=""}
        return project
    }
    func saveAIProject(_ project:AIProject,for id:String,shareProject:Bool = false) throws {
        guard id==activeSession else {throw BridgeError("The selected call changed. Reopen its attachment dialog.")}
        guard !aiBusy,liveAISession == nil else {throw BridgeError("Wait for coaching to stop before changing attachments")}
        var project=project
        project.provider=aiProvider
        let meta=try store.detail(id)["meta"] as? [String:Any] ?? [:]
        let series=SessionStore.recurringProjectKey(meta)
        if !shareProject,!project.conversation.isEmpty,let series,let shared=try store.seriesProject(series) {
            let sharedPath=shared["path"] as? String ?? ""
            let expected=sharedPath.isEmpty ? aiDirectory.path:sharedPath
            guard URL(fileURLWithPath:project.path).resolvingSymlinksInPath().path == URL(fileURLWithPath:expected).resolvingSymlinksInPath().path else {
                throw BridgeError("Choose a conversation in the recurring call’s project, or change the folder in Project first.")
            }
        }
        try project.validate(provider:aiProvider)
        try store.append(id,kind:"ai-settings",body:try JSONSerialization.jsonObject(with:JSONEncoder().encode(project)) as! [String:Any])
        if shareProject,let series {
            try store.saveSeriesProject(series,path:hasProjectAttachment(project) ? project.path:"",background:project.background,skill:project.skill)
        }
        aiProject=project
        refreshHistory()
    }
    func hasProjectAttachment(_ project:AIProject) -> Bool {
        !project.path.isEmpty && URL(fileURLWithPath:project.path).standardizedFileURL != aiDirectory.standardizedFileURL
    }
    private func disconnect(_ peer: String) {
        let lost = owners.filter { $0.value == peer }.map(\.key)
        for id in lost { owners.removeValue(forKey:id) }
        if let captureSession, lost.contains(captureSession) {
            self.captureSession = nil
            do { try store.append(captureSession,kind:"audio-gap",body:["reason":"connection-lost","nextSequence":expectedSequence]) }
            catch { errorMessage = "Could not save audio gap: \(error.localizedDescription)" }
            drainingSession = captureSession
            errorMessage = "Capture connection lost. Restart capture explicitly; audio may have a gap."
        }
    }
    private func session(_ request: [String: Any]) throws -> String {
        let id = try Validation.identifier(request["session"])
        guard try store.exists(id) else { throw BridgeError("Unknown session") }
        return id
    }
    func request(role: String, request: [String: Any]) async throws -> [String: Any] {
        let method = try Validation.text(request["method"],limit:40)
        let assistantOnly = ["coach","note","delete","export","prompt","import"]
        if role == "extension", assistantOnly.contains(method) { throw BridgeError("Method is not available to extension") }
        switch method {
        case "status": return ["bridge":bridgeStatus,"model":modelStatus,"audioReady":modelReady,"captureConsentGranted":captureConsentGranted,"aiConsentGranted":aiConsentGranted,"activeSession":activeSession as Any? ?? NSNull(),"captureSession":captureSession as Any? ?? NSNull(),"paused":paused,"pendingAudio":pending.count + (try store.audioCount()),"storedAudioChunks":try store.archivedAudioCount(),"error":errorMessage,"aiBusy":aiBusy,"aiStatus":aiStatus,"aiError":aiError,"liveAISession":liveAISession as Any? ?? NSNull()]
        case "list": return ["sessions":try store.list()]
        case "detail": return try store.detail(session(request))
        case "ingest-audio":
            guard captureConsentGranted,!paused else { return ["paused":true] }
            let id = try session(request)
            guard let frame = request["frame"] as? [String:Any] else { throw BridgeError("Missing audio frame") }
            let added = try store.enqueueAudio(id,frame:frame)
            if added,automaticSummaries {
                let state=try store.summaryAutomation(id)["state"] as? String
                if state=="queued" || state=="complete" || state=="failed" {try queueSummary(id)}
            }
            select(id)
            drainArchive()
            return ["stored":true,"added":added]
        case "prompt": return ["prompt":prompt]
        case "snapshot", "import":
            if role == "extension", !captureConsentGranted || paused { return ["paused":true] }
            let id = try Validation.identifier(request["session"])
            guard let record = request["record"] as? [String: Any] else { throw BridgeError("Missing record") }
            if role == "extension" {
                guard let peer = request["peer"] as? String else { throw BridgeError("Missing connection identity") }
                if let owner = owners[id], owner != peer { throw BridgeError("Session is already owned by another connection") }
                owners[id] = peer
            }
            var newlyEnded=false
            if role=="extension",automaticSummaries,record["ended_at"] is NSNumber {
                newlyEnded=try store.list().contains{$0["id"] as? String==id && $0["ended"] as? Bool==false}
            }
            let transcriptVersion=try store.transcriptVersion(id)
            try store.snapshot(id:id,record:record)
            if role=="extension",automaticSummaries,record["ended_at"] is NSNumber,record["source_backup"] as? Bool != true {
                let state=try store.summaryAutomation(id)["state"] as? String
                let revised=try store.transcriptVersion(id) != transcriptVersion
                if newlyEnded || (revised && ["queued","complete","failed"].contains(state ?? "")) {try queueSummary(id)}
            }
            refreshHistory()
            if record["source_backup"] as? Bool == true {
                if activeSession==id {activeSession=nil;selectedDetail=nil}
            } else if role == "extension",activeSession==nil {select(id)}
            return ["session":id]
        case "read", "events":
            let id = try session(request)
            let after = request["after"] as? Int ?? 0
            guard after >= 0 else { throw BridgeError("Invalid cursor") }
            return try store.read(id,after:after)
        case "note":
            let id = try session(request)
            try store.append(id,kind:"note",body:["text":try Validation.text(request["text"]),"t":Date().timeIntervalSince1970*1000])
            return ["saved":true]
        case "export": return try store.export(session(request))
        case "delete":
            let id = try session(request)
            guard id != captureSession, id != drainingSession else { throw BridgeError("Stop and drain audio before deletion") }
            if id == liveAISession || id == activeSession || id == automaticSummarySession {stopAI()}
            try store.delete(id); sessions = try store.list()
            if activeSession == id { activeSession = nil; clearCoaching() }
            return ["deleted":true]
        case "coach":
            let id = try session(request)
            guard id == activeSession, !paused else { throw BridgeError("Coaching session is not active or is paused") }
            let value: [String: Any] = ["id":UUID().uuidString,"session":id,"program":try Validation.text(request["program"],limit:16000),"fallback":try Validation.text(request["fallback"] ?? "",limit:1000)]
            try store.append(id,kind:"coaching",body:value)
            coaching = value; panel?.update(value); panel?.show()
            return ["displayed":true]
        case "capture-start":
            let id = try session(request)
            guard role == "extension", owners[id] == request["peer"] as? String, captureSession == nil, !processing, pending.isEmpty, !processingArchive, modelReady, !paused else { throw BridgeError("Audio unavailable: load model, stop existing capture, and wait for the queue") }
            captureSession = id; drainingSession = nil; captureRunID = UUID().uuidString; expectedSequence = 0; select(id); errorMessage = ""
            try store.append(id,kind:"capture-start",body:["t":Date().timeIntervalSince1970*1000,"source":"remote-tab"])
            return ["started":true]
        case "audio":
            let chunk = try AudioChunk.decode(request)
            guard role == "extension", owners[chunk.session] == request["peer"] as? String, chunk.session == captureSession else { throw BridgeError("Audio session mismatch") }
            guard chunk.sequence == expectedSequence else { throw BridgeError("Audio sequence gap; restart capture") }
            guard !paused else { return ["paused":true] }
            guard pending.count < 4 else { errorMessage = "Transcription is behind; capture stopped. Audio gap recorded."; try store.append(chunk.session,kind:"audio-gap",body:["sequence":chunk.sequence]); captureSession = nil; drainingSession = chunk.session; throw BridgeError(errorMessage) }
            var frame = request
            frame["id"] = "legacy-\(captureRunID)-\(chunk.sequence)"; frame["source"] = "remote"
            _ = try store.enqueueAudio(chunk.session,frame:frame)
            expectedSequence += 1
            pending.append(chunk); drain()
            return ["queued":true]
        case "capture-stop":
            let id = try session(request)
            guard role == "extension", owners[id] == request["peer"] as? String, captureSession == id else { throw BridgeError("Capture session mismatch") }
            captureSession = nil; drainingSession = id
            try store.append(id,kind:"capture-stop",body:["t":Date().timeIntervalSince1970*1000])
            if !processing && pending.isEmpty { drainingSession = nil }
            return ["draining":processing || !pending.isEmpty]
        default: throw BridgeError("Unknown method")
        }
    }
    func feedback(_ value: [String: Any]) {
        if value["action"] as? String == "hide" { panel?.hide(); return }
        guard let activeSession=coaching?["session"] as? String, value["coachingID"] as? String == coaching?["id"] as? String else { return }
        do { try store.append(activeSession,kind:"feedback",body:value) }
        catch { errorMessage = error.localizedDescription }
        if ["dismiss","asked"].contains(value["action"] as? String ?? "") { clearCoaching() }
    }
    func stopAI() {
        aiRun=UUID();aiTask?.cancel();aiTask=nil;aiBusy=false;liveAISession=nil
        acpClient.close()
        researchRun=UUID();researchTask?.cancel();researchTask=nil;research=[];researchQueries=[];researchOwner=""
        coachingSchedule=CoachingSchedule()
        coachingPaused=false;panel?.updateControls()
        aiSession=nil;automaticSummarySession=nil;aiStatus="Stopped";clearCoaching()
    }
    func startLiveAI() {
        guard let id=activeSession else {return}
        do {
            guard aiConsentGranted else {throw BridgeError("Allow optional AI processing in Settings → Setup before starting coaching")}
            guard !paused,(try store.detail(id)["meta"] as? [String:Any])?["ended"] as? Bool != true else {throw BridgeError("Select an ongoing call for live coaching")}
            try aiProject.validate(provider:aiProject.provider)
            stopAI();liveAISession=id;liveAIProject=aiProject;lastAIInput="";nextAI = .distantPast;panel?.beginSession();tickAI()
        } catch {aiError=error.localizedDescription;aiErrorSession=id}
    }
    func runAI(_ mode:AIMode) {
        guard let id=activeSession,!paused,!aiBusy else {return}
        if mode == .coaching {panel?.show()}
        performAI(id:id,mode:mode,project:aiProject)
    }
    func tickAI(now:Date = Date()) {
        guard let id=liveAISession,!paused else {return}
        do {
            let detail=try store.detail(id)
            if (detail["meta"] as? [String:Any])?["ended"] as? Bool == true {
                stopAI();aiStatus="Call ended";return
            }
            guard !coachingPaused,!aiBusy,now>=nextAI else {return}
            guard !(detail["segments"] as? [[String:Any]] ?? []).isEmpty else {aiStatus="Listening · waiting for transcript";return}
            let context=researchContext(id:id,project:liveAIProject)
            let input=try AIInput.make(detail:detail,mode:.coaching,background:liveAIProject.background,previous:nil,project:liveAIProject,research:context)
            guard coachingSchedule.ready(input.fingerprint,context:input.spokenText,now:now) else {return}
            coachingSchedule.submitted(input.fingerprint,context:input.spokenText,now:now)
            performAI(id:id,mode:.coaching,project:liveAIProject)
        } catch {stopAI();aiError=error.localizedDescription;aiErrorSession=id}
    }
    func tickLiveRefinement(now:Date=Date()) {
        guard liveRefinementEnabled,aiConsentGranted,captureConsentGranted,!paused,extensionConnected,!aiBusy,
              let id=activeSession,liveAISession==nil || liveAISession==id else {return}
        if refinementOwner != id {refinementOwner=id;nextLiveRefinement=now.addingTimeInterval(20);lastLiveRefinement="";return}
        guard now>=nextLiveRefinement else {return}
        nextLiveRefinement=now.addingTimeInterval(30)
        do {
            let detail=try store.detail(id)
            guard (detail["meta"] as? [String:Any])?["ended"] as? Bool != true,!(detail["segments"] as? [[String:Any]] ?? []).isEmpty else {return}
            let project=try projectForCall(detail)
            let input=try AIInput.liveRefinement(detail:detail)
            guard input.fingerprint != lastLiveRefinement else {return}
            lastLiveRefinement=input.fingerprint
            performAI(id:id,mode:.refinement,project:project)
        } catch {aiError="Live refinement: "+error.localizedDescription}
    }
    func setCoachingPaused(_ value:Bool) {
        guard liveAISession != nil else {return}
        coachingPaused=value;panel?.updateControls()
        if value {
            aiRun=UUID();aiTask?.cancel();aiTask=nil;aiBusy=false;aiSession=nil;acpClient.close()
            researchRun=UUID();researchTask?.cancel();researchTask=nil
            aiStatus="Coaching paused · capture continues"
        } else {coachingSchedule=CoachingSchedule();lastAIInput="";nextAI = .distantPast;tickAI()}
    }
    private func queueSummary(_ id:String) throws {
        try store.append(id,kind:"summary-automation",body:["state":"queued","t":Date().timeIntervalSince1970,"requestID":UUID().uuidString])
    }
    func tickSummaries(now:Date = Date()) {
        guard automaticSummaries,aiConsentGranted,!paused,!aiBusy,liveAISession == nil else {return}
        do {
            for pending in try store.pendingSummaries() {
                guard let id=pending["session"] as? String,let requestID=pending["requestID"] as? String,
                      now.timeIntervalSince1970 >= (pending["t"] as? Double ?? 0)+5 else {continue}
                do {
                    guard try store.audioCount(session:id)==0 else {continue}
                    let detail=try store.detail(id)
                    guard let meta=detail["meta"] as? [String:Any],meta["ended"] as? Bool==true,meta["archived"] as? Bool != true else {continue}
                    let project=try projectForCall(detail)
                    performAI(id:id,mode:.summary,project:project,automaticRequest:requestID)
                    if aiBusy {return}
                } catch {
                    try finishSummary(id,state:"failed",error:error.localizedDescription)
                    refreshHistory()
                }
            }
        } catch {errorMessage="Automatic summary could not start: \(error.localizedDescription)"}
    }
    private func finishSummary(_ id:String,state:String,error:String = "") throws {
        try store.append(id,kind:"summary-automation",body:["state":state,"error":error])
    }
    private func performAI(id:String,mode:AIMode,project:AIProject,automaticRequest:String? = nil) {
        aiStatus="Preparing conversation…";aiError="";aiErrorSession=nil
        var project=project
        do {
            guard aiConsentGranted else {throw BridgeError("Allow optional AI processing in Settings → Setup before using summaries or coaching")}
            if project.path.isEmpty {
                try FileManager.default.createDirectory(at:aiDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                project.path=aiDirectory.path
            }
            try project.validate(provider:project.provider)
            let detail=try store.detail(id)
            let saved=detail["aiCoaching"] as? [String:Any]
            var previous = !project.conversation.isEmpty && saved?["provider"] as? String==project.provider.rawValue && saved?["project"] as? String==project.path && saved?["conversationID"] as? String==project.conversation ? saved:nil
            if mode == .coaching,let active=coaching,active["session"] as? String==id {
                if previous==nil {previous=[:]}
                previous?["activeSuggestion"]=["headline":active["headline"] ?? "","response":active["fallback"] ?? "","points":active["points"] ?? []]
            }
            let context=researchContext(id:id,project:project)
            let inputs:[AIInput]
            if mode == .summary {inputs=try AIInput.summaryChunks(detail:detail,background:project.background,project:project,research:context)}
            else if mode == .refinement {inputs=[try AIInput.liveRefinement(detail:detail)]}
            else {inputs=[try AIInput.make(detail:detail,mode:mode,background:project.background,previous:previous,project:project,research:context)]}
            let input=inputs[0]
            nextAI = .distantPast
            if mode == .coaching,liveAISession==id,input.fingerprint==lastAIInput {aiStatus="Listening · waiting for new transcript";return}
            try store.append(id,kind:"ai-settings",body:try JSONSerialization.jsonObject(with:JSONEncoder().encode(project)) as! [String:Any])
            aiRun=UUID();let run=aiRun
            aiBusy=true;aiSession=id;automaticSummarySession=automaticRequest == nil ? nil:id;aiError="";aiStatus="\(project.provider.title) · generating \(mode.rawValue)…"
            let generate=aiGenerate
            aiTask=Task { [weak self] in
                do {
                    let response:AIResponse
                    if mode == .summary {response=try await AISummary.generate(inputs:inputs,provider:project.provider,project:project,generate:generate)}
                    else {response=try await generate(project.provider,mode,input,project)}
                    guard let self,self.aiRun==run,!Task.isCancelled else {return}
                    if let automaticRequest,try self.store.summaryAutomation(id)["requestID"] as? String != automaticRequest {
                        self.aiBusy=false;self.aiSession=nil;self.automaticSummarySession=nil;self.aiTask=nil
                        self.aiStatus="Waiting for the final transcript";self.refreshHistory();return
                    }
                    try response.validate(segmentIDs:Set(inputs.flatMap{$0.segmentIDs}))
                    var result=try response.json();result["provider"]=project.provider.rawValue;result["project"]=project.path;result["t"]=Date().timeIntervalSince1970*1000
                    if mode == .summary {
                        let sources=detail["segments"] as? [[String:Any]] ?? []
                        result["refinedSegments"]=response.refinedSegments(sources:sources)
                        result["refinementSources"]=try Validation.json(sources)
                    }
                    if mode == .refinement {
                        try response.validateRefinement(segmentIDs:input.segmentIDs)
                        let sources=(detail["segments"] as? [[String:Any]] ?? []).filter{input.segmentIDs.contains($0["id"] as? String ?? "")}
                        try self.store.saveLiveRefinement(id,sources:sources,turns:response.refinedSegments(sources:sources))
                    } else {try self.store.append(id,kind:"ai-"+mode.rawValue,body:result)}
                    if mode == .summary {try self.finishSummary(id,state:"complete")}
                    var updated=project
                    if let conversation=response.conversationID {updated.conversation=conversation}
                    try self.store.append(id,kind:"ai-settings",body:try JSONSerialization.jsonObject(with:JSONEncoder().encode(updated)) as! [String:Any])
                    if self.activeSession==id {self.aiProject=updated}
                    if self.liveAISession==id {self.liveAIProject=updated;if mode == .coaching {self.lastAIInput=input.fingerprint}}
                    if mode == .coaching,(self.activeSession==id || self.liveAISession==id) {
                        let priorKey=self.coaching?["signature"] as? String
                        if response.retirePrevious == true {self.clearCoaching()}
                        if response.shouldUpdate,priorKey != response.coachingKey {
                            let value:[String:Any]=["id":UUID().uuidString,"session":id,"headline":response.headline,"program":try response.canvas(research:context),"fallback":response.question,"points":response.points,"signature":response.coachingKey]
                            self.coaching=value;self.panel?.update(value);self.panel?.showSuggestion()
                        }
                        if let query=response.researchQuery,!query.isEmpty {self.lookupProject(query,id:id,project:updated)}
                    }
                    self.aiBusy=false;self.aiSession=nil;self.automaticSummarySession=nil;self.aiTask=nil;self.aiStatus="Saved · \(project.provider.title)";self.refreshHistory()
                    if let automaticRequest {self.completedAutomaticSummary=SummaryCompletion(session:id,requestID:automaticRequest)}
                } catch {
                    guard let self,self.aiRun==run else {return}
                    self.aiBusy=false;self.aiSession=nil;self.automaticSummarySession=nil;self.aiTask=nil
                    self.aiError=error.localizedDescription;self.aiErrorSession=id;self.aiStatus=mode == .refinement ? "Live refinement paused · capture continues":"AI stopped"
                    if mode != .refinement {self.liveAISession=nil}
                    if mode == .summary {
                        do {
                            let currentRequest=try self.store.summaryAutomation(id)["requestID"] as? String
                            if automaticRequest == nil || currentRequest==automaticRequest {
                                try self.finishSummary(id,state:"failed",error:error.localizedDescription)
                            }
                        }
                        catch {self.errorMessage="Could not save summary failure: \(error.localizedDescription)"}
                        self.refreshHistory()
                    }
                }
            }
        } catch {
            nextAI=Date().addingTimeInterval(30)
            aiStatus="Could not start · no text sent";aiError=error.localizedDescription;aiErrorSession=id
            if mode == .summary {
                do {try finishSummary(id,state:"failed",error:error.localizedDescription)}
                catch {errorMessage="Could not save summary failure: \(error.localizedDescription)"}
                refreshHistory()
            }
        }
    }
    func researchContext(id:String,project:AIProject) -> [[String:String]] {
        researchOwner==id+"\n"+project.path ? research:[]
    }
    func lookupProject(_ query:String,id:String,project:AIProject) {
        guard !project.path.isEmpty else {return}
        let owner=id+"\n"+project.path
        if researchOwner != owner {
            researchRun=UUID();researchTask?.cancel();researchTask=nil
            research=[];researchQueries=[];researchOwner=owner
        }
        guard researchTask==nil,!researchQueries.contains(query),researchQueries.count<8 else {return}
        let run=researchRun,search=researchSearch
        researchTask=Task { [weak self] in
            do {
                let found=try await search(project.path,query)
                guard let self,!Task.isCancelled,self.researchRun==run,self.researchOwner==owner else {return}
                self.researchQueries.insert(query)
                self.research=found.isEmpty ? [["file":"Lookup unavailable","text":"No matching project excerpt found for: "+query]]:found
                self.researchTask=nil
                if let current=self.coaching,current["session"] as? String==id,
                   let saved=try self.store.detail(id)["aiCoaching"] as? [String:Any] {
                    let response=try JSONDecoder().decode(AIResponse.self,from:JSONSerialization.data(withJSONObject:saved))
                    var value=current;value["program"]=try response.canvas(research:self.research)
                    self.coaching=value;self.panel?.update(value)
                }
            } catch {
                guard let self,!Task.isCancelled,self.researchRun==run,self.researchOwner==owner else {return}
                self.researchTask=nil;self.research=[["file":"Lookup unavailable","text":"The local project search could not be completed."]]
            }
        }
    }
    private func drainArchive() {
        guard modelReady, !paused, !processingArchive, !processing, captureSession == nil else { return }
        do {
            let frames = try store.nextAudioBatch()
            guard let first = frames.first else { return }
            let chunks = try frames.map { try AudioChunk.decode($0) }
            let chunk = AudioChunk(session:first["session"] as! String,sequence:0,startedAt:chunks[0].startedAt,samples:chunks.flatMap(\.samples))
            processingArchive = true
            Task {
                do {
                    let text = try await transcriber.transcribe(chunk)
                    try store.finishAudioBatch(frames,text:text)
                    refreshHistory()
                    processingArchive = false
                    drainArchive()
                } catch {
                    processingArchive = false; modelReady = false; modelStatus = "Model failed"
                    errorMessage = "Audio retained for retry: \(error.localizedDescription)"
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func drain() {
        guard !processing, !pending.isEmpty else { return }
        processing = true
        let chunk = pending.removeFirst()
        let epoch = audioEpoch
        let frameID = "legacy-\(captureRunID)-\(chunk.sequence)"
        Task {
            do {
                let text = try await transcriber.transcribe(chunk)
                if !paused && epoch == audioEpoch {
                    try store.finishAudio(["id":frameID,"session":chunk.session,"source":"remote","startedAt":chunk.startedAt],text:text)
                    refreshHistory()
                }
            } catch {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
                captureSession = nil; pending.removeAll(); modelReady = false; modelStatus = "Model failed";paused=true
                server.broadcast("capture-failed",role:"extension")
                do { try store.append(chunk.session,kind:"audio-gap",body:["sequence":chunk.sequence,"error":error.localizedDescription]) } catch { errorMessage += "; could not save gap: \(error.localizedDescription)" }
            }
            processing = false
            if pending.isEmpty { drainingSession = nil; drainArchive() } else { drain() }
        }
    }
}
