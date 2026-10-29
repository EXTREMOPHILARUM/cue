import Foundation
import CSQLite
import CryptoKit

public final class SessionStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw BridgeError("Cannot open session database") }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, meta TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS series_projects(series TEXT PRIMARY KEY, body TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS segments(session TEXT REFERENCES sessions(id) ON DELETE CASCADE, id TEXT, body TEXT NOT NULL, PRIMARY KEY(session,id))")
        try execute("CREATE TABLE IF NOT EXISTS events(cursor INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT REFERENCES sessions(id) ON DELETE CASCADE, kind TEXT NOT NULL, body TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS event_session ON events(session,cursor)")
        try execute("CREATE TABLE IF NOT EXISTS audio_queue(id TEXT PRIMARY KEY, session TEXT REFERENCES sessions(id) ON DELETE CASCADE, body TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS audio_receipts(id TEXT PRIMARY KEY, session TEXT REFERENCES sessions(id) ON DELETE CASCADE, hash TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS audio_archive(id TEXT PRIMARY KEY, session TEXT REFERENCES sessions(id) ON DELETE CASCADE, body TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS audio_archive_session ON audio_archive(session)")
        try execute("INSERT OR IGNORE INTO audio_archive(id,session,body) SELECT id,session,body FROM audio_queue")
        try execute("BEGIN IMMEDIATE")
        do {
            for row in try rows("SELECT DISTINCT session FROM segments WHERE json_extract(body,'$.source') IN ('whisper-local','whisper-remote','meet')") {try updateSpeakerNames(row["session"]!)}
            try execute("COMMIT")
        } catch {try? execute("ROLLBACK");throw error}
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String, _ args: [String] = []) throws {
        _ = try rows(sql, args)
    }
    private func rows(_ sql: String, _ args: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (index, arg) in args.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), arg, -1, transient) }
        var result = [[String: String]]()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw error() }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let name = sqlite3_column_name(statement, index), let value = sqlite3_column_text(statement, index) {
                    row[String(cString: name)] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
    private func error() -> BridgeError { BridgeError(String(cString: sqlite3_errmsg(db))) }
    private func decode(_ s: String) throws -> [String: Any] {
        guard let d = s.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw BridgeError("Corrupt session data") }
        return object
    }
    public func exists(_ id: String) throws -> Bool { try !rows("SELECT id FROM sessions WHERE id=?", [id]).isEmpty }
    public func list() throws -> [[String: Any]] {
        // Keep empty legacy pre/post-call captures recoverable, but out of normal history.
        let sql="""
        SELECT id,meta FROM sessions s WHERE COALESCE(json_extract(meta,'$.archived'),0)=0 AND NOT (
            s.id GLOB 'chrome-call-????????-????-????-????-????????????'
            AND json_extract(meta,'$.source')='meet' AND json_extract(meta,'$.ended')=1
            AND json_extract(meta,'$.recordID') IS NULL
            AND COALESCE(json_extract(meta,'$.presenceConfirmed'),0)=0
            AND COALESCE(json_extract(meta,'$.topic'),'')=''
            AND NOT EXISTS (SELECT 1 FROM audio_archive WHERE session=s.id)
            AND NOT EXISTS (SELECT 1 FROM segments WHERE session=s.id)
            AND NOT EXISTS (SELECT 1 FROM events WHERE session=s.id AND kind NOT IN ('session','summary-automation'))
        ) ORDER BY json_extract(meta,'$.startedAt') DESC,s.rowid DESC
        """
        return try rows(sql).map { row in var m = try decode(row["meta"]!); m["id"] = row["id"]; m["summaryTitle"] = try summaryTitle(row["id"]!); return m }
    }
    public func snapshot(id: String, record: [String: Any]) throws {
        var saved=record
        saved["_archived"]=record["source_backup"] as? Bool ?? false
        try snapshotRecord(id:id,record:saved)
    }
    private func snapshotRecord(id: String, record: [String: Any]) throws {
        _ = try Validation.identifier(id)
        let callID = try Validation.identifier(record["id"])
        let previous=try rows("SELECT meta FROM sessions WHERE id=?",[id]).first.map{try decode($0["meta"]!)}
        if let previous,previous["callID"] as? String != callID {throw BridgeError("Session belongs to another call")}
        let captions = record["captions"] as? [[String: Any]] ?? []
        guard captions.count <= 50_000 else { throw BridgeError("Too many captions") }
        var meta: [String: Any] = ["callID": callID, "title": try Validation.text(record["title"] ?? "", limit: 1000), "topic": try Validation.text(record["topic"] ?? "", limit: 2000), "source": record["source"] as? String ?? "meet", "ended": record["ended_at"] is NSNumber]
        let participants = record["participants"] as? [String] ?? []
        guard participants.count <= 500, participants.allSatisfy({ $0.utf8.count <= 500 }) else { throw BridgeError("Invalid participants") }
        meta["archived"] = record["_archived"] as? Bool ?? false
        meta["participants"] = participants
        if let value=record["speaker_roster"] {
            guard let roster=value as? [[String:Any]],roster.count<=500 else {throw BridgeError("Invalid speaker roster")}
            for person in roster {_ = try Validation.text(person["id"],limit:500);_ = try Validation.text(person["name"],limit:500);guard person["isSelf"] is Bool else {throw BridgeError("Invalid speaker identity")}}
            meta["speakerRoster"]=roster
        } else if let roster=previous?["speakerRoster"] {meta["speakerRoster"]=roster}
        // A user-confirmed historical two-person call cannot be inferred from a partial caption roster.
        if let confirmed=previous?["confirmedRemoteSpeaker"] {meta["confirmedRemoteSpeaker"]=confirmed}
        if let parent=record["_recordID"] as? String { meta["recordID"]=try Validation.identifier(parent) }
        else if let parent=record["source_record_id"] as? String { meta["recordID"]="chrome-"+(try Validation.identifier(parent)) }
        if let series=record["series_id"] as? String {meta["seriesID"]=try Validation.text(series,limit:1000)}
        if let code=record["meeting_code"] as? String {meta["meetingCode"]=try Validation.text(code,limit:1000)}
        if let url=record["url"] as? String {meta["url"]=try Validation.text(url,limit:4000)}
        meta["independentCall"]=record["independent_call"] as? Bool ?? false
        meta["presenceConfirmed"]=(record["presence_confirmed"] as? Bool) ?? (previous?["presenceConfirmed"] as? Bool) ?? false
        if let ended=record["ended_at"] as? Double { meta["endedAt"]=ended }
        if let started = record["started_at"] as? Double { meta["startedAt"] = started }
        let body = try Validation.json(meta)
        try execute("BEGIN IMMEDIATE")
        do {
            let old = try rows("SELECT meta FROM sessions WHERE id=?", [id]).first?["meta"]
            try execute("INSERT INTO sessions(id,meta) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET meta=excluded.meta", [id, body])
            if old != body { try append(id, kind: "session", body: meta) }
            for (index, caption) in captions.enumerated() {
                let key = "meet-\(index)" // The existing raw caption array is append-only; index survives rolling revisions.
                let segment: [String: Any] = ["id": key, "text": try Validation.text(caption["text"]), "speaker": try Validation.text(caption["speaker"] ?? "Unknown", limit: 500), "t": caption["t"] as? Double ?? 0, "source": "meet", "final": false]
                try upsert(id, segment: attributed(segment,meta:meta))
            }
            try updateSpeakerNames(id)
            for (index, note) in (record["notes"] as? [[String: Any]] ?? []).enumerated() {
                let key = "import-note-\(index)"
                if try rows("SELECT cursor FROM events WHERE session=? AND kind=?", [id, key]).isEmpty {
                    try append(id, kind: key, body: ["text": try Validation.text(note["text"]), "t": note["t"] as? Double ?? 0])
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func upsert(_ session: String, segment: [String: Any]) throws {
        guard try exists(session) else { throw BridgeError("Unknown session") }
        let key = try Validation.identifier(segment["id"])
        let body = try Validation.json(segment)
        let prior = try rows("SELECT body FROM segments WHERE session=? AND id=?", [session,key]).first?["body"]
        if prior == body { return }
        var event = segment
        let revision = (try prior.map(decode)?["revision"] as? Int ?? 0) + 1
        event["revision"] = revision
        // Compare without revision so unchanged snapshots do not emit another event.
        if let prior, var old = try? decode(prior) { old.removeValue(forKey: "revision"); if try Validation.json(old) == body { return } }
        try execute("INSERT INTO segments(session,id,body) VALUES(?,?,?) ON CONFLICT(session,id) DO UPDATE SET body=excluded.body", [session,key,try Validation.json(event)])
        try append(session, kind: "segment", body: event)
    }
    public func append(_ session: String, kind: String, body: [String: Any]) throws {
        guard try exists(session) else { throw BridgeError("Unknown session") }
        try execute("INSERT INTO events(session,kind,body) VALUES(?,?,?)", [session,kind,try Validation.json(body)])
    }
    public func read(_ id: String, after: Int = 0) throws -> [String: Any] {
        guard let meta = try rows("SELECT meta FROM sessions WHERE id=?", [id]).first?["meta"] else { throw BridgeError("Unknown session") }
        let eventRows = try rows("SELECT cursor,kind,body FROM events WHERE session=? AND cursor>? ORDER BY cursor LIMIT 1000",[id,String(after)])
        let events: [[String: Any]] = try eventRows.map { ["cursor": Int($0["cursor"]!)!, "kind": $0["kind"]!, "body": try decode($0["body"]!)] }
        let latest = try rows("SELECT COALESCE(MAX(cursor),0) AS cursor FROM events WHERE session=?",[id]).first?["cursor"] ?? "0"
        return ["id": id, "meta": try decode(meta), "events": events, "cursor": eventRows.last?["cursor"].flatMap(Int.init) ?? after, "latestCursor": Int(latest)!, "hasMore": (eventRows.last?["cursor"].flatMap(Int.init) ?? after) < Int(latest)!]
    }
    public func export(_ id: String) throws -> [String: Any] {
        let detail=try detail(id),meta=detail["meta"] as! [String:Any]
        return ["id":id,"meta":meta,"segments":detail["segments"]!,"events":try rows("SELECT cursor,kind,body FROM events WHERE session=? ORDER BY cursor",[id]).map{["cursor":$0["cursor"]!,"kind":$0["kind"]!,"body":try decode($0["body"]!)]}]
    }
    public func enqueueAudio(_ session: String, frame: [String: Any]) throws -> Bool {
        guard try exists(session) else { throw BridgeError("Unknown audio session") }
        let id = try Validation.identifier(frame["id"])
        guard ["local","remote"].contains(frame["source"] as? String ?? "") else { throw BridgeError("Invalid audio source") }
        for key in ["trackID","participantID","speaker"] {if let value=frame[key] {_ = try Validation.text(value,limit:500)}}
        if let value=frame["attribution"] {guard let method=value as? String,["meet-rtp","meet-activity","mixed","unresolved","local"].contains(method) else {throw BridgeError("Invalid speaker attribution")}}
        if let value=frame["contributors"] {guard let contributors=value as? [String],contributors.count<=32,contributors.allSatisfy({$0.utf8.count<=200}) else {throw BridgeError("Invalid audio contributors")}}
        try CaptureMapping.validate(frame)
        var checked = frame
        checked["session"] = session; checked["sequence"] = 0
        _ = try AudioChunk.decode(checked)
        let body = try Validation.json(checked)
        let hash = SHA256.hash(data:Data(body.utf8)).map { String(format:"%02x",$0) }.joined()
        if let existing = try rows("SELECT session,hash FROM audio_receipts WHERE id=?",[id]).first {
            guard existing["session"] == session, existing["hash"] == hash else { throw BridgeError("Audio ID reused with different data") }
            return false
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT INTO audio_archive(id,session,body) VALUES(?,?,?)",[id,session,body])
            try execute("INSERT INTO audio_queue(id,session,body) VALUES(?,?,?)",[id,session,body])
            try execute("INSERT INTO audio_receipts(id,session,hash) VALUES(?,?,?)",[id,session,hash])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return true
    }
    public func nextAudio() throws -> [String: Any]? {
        try rows("SELECT body FROM audio_queue ORDER BY rowid LIMIT 1").first.map { try decode($0["body"]!) }
    }
    // Keep each source/track separate and wait briefly for sentence context; raw frames are already durable.
    public func nextAudioBatch(now: Double = Date().timeIntervalSince1970 * 1000) throws -> [[String:Any]] {
        guard let first = try nextAudio() else { return [] }
        let session = first["session"] as! String, source = first["source"] as! String
        let track = first["trackID"] as? String ?? ""
        var statement:OpaquePointer?
        let sql="SELECT body FROM audio_queue WHERE session=? AND json_extract(body,'$.source')=? AND COALESCE(json_extract(body,'$.trackID'),'')=? ORDER BY rowid LIMIT 1024"
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else {throw error()}
        defer {sqlite3_finalize(statement)}
        for (index,arg) in [session,source,track].enumerated(){sqlite3_bind_text(statement,Int32(index+1),arg,-1,transient)}
        var batch = [[String:Any]](), duration = 0.0, end = 0.0, discontinuity = false
        let firstSpeaker=try speakerKey(first)
        while true {
            let code=sqlite3_step(statement)
            if code==SQLITE_DONE {break}
            guard code==SQLITE_ROW,let body=sqlite3_column_text(statement,0) else {throw error()}
            let frame=try decode(String(cString:body))
            let chunk = try AudioChunk.decode(frame)
            let differentSpeaker=try speakerKey(frame) != firstSpeaker
            if !batch.isEmpty && (abs(chunk.startedAt - end) > 1000 || differentSpeaker) { discontinuity = true; break }
            batch.append(frame)
            let seconds = Double(chunk.samples.count) / 16000
            duration += seconds; end = chunk.startedAt + seconds * 1000
            if duration >= 16 { break }
        }
        return duration >= 16 || discontinuity || now - end >= 5000 ? batch : []
    }
    public func archivedAudioCount() throws -> Int { Int(try rows("SELECT COUNT(*) AS n FROM audio_archive").first!["n"]!)! }
    public func archivedAudio(_ session: String) throws -> [[String:Any]] {
        guard try exists(session) else { throw BridgeError("Unknown session") }
        return try rows("SELECT body FROM audio_archive WHERE session=? ORDER BY rowid",[session]).map { try decode($0["body"]!) }
    }
    public func audioCount(session:String? = nil) throws -> Int {
        let result = try session.map {try rows("SELECT COUNT(*) AS n FROM audio_queue WHERE session=?",[$0])} ?? rows("SELECT COUNT(*) AS n FROM audio_queue")
        return Int(result.first!["n"]!)!
    }
    public func pendingSummaries() throws -> [[String:Any]] {
        try rows("SELECT e.session,e.body FROM events e WHERE e.kind='summary-automation' AND json_extract(e.body,'$.state')='queued' AND NOT EXISTS (SELECT 1 FROM events newer WHERE newer.session=e.session AND newer.kind=e.kind AND newer.cursor>e.cursor) ORDER BY e.cursor")
            .map {row in var value=try decode(row["body"]!);value["session"]=row["session"];return value}
    }
    public func transcriptVersion(_ id:String) throws -> Int {
        Int(try rows("SELECT COALESCE(MAX(cursor),0) AS version FROM events WHERE session=? AND kind='segment'",[id]).first!["version"]!)!
    }
    public func summaryAutomation(_ id:String) throws -> [String:Any] {
        try rows("SELECT body FROM events WHERE session=? AND kind='summary-automation' ORDER BY cursor DESC LIMIT 1",[id]).first.map{try decode($0["body"]!)} ?? [:]
    }
    public func finishAudio(_ frame: [String: Any], text: String) throws {
        try finishAudioBatch([frame],text:text)
    }
    public func finishAudioBatch(_ frames: [[String:Any]], text: String) throws {
        guard let frame = frames.first else { return }
        let session = try Validation.identifier(frame["session"]), id = try Validation.identifier(frame["id"])
        guard frames.allSatisfy({ $0["session"] as? String == session && $0["source"] as? String == frame["source"] as? String && $0["trackID"] as? String == frame["trackID"] as? String }) else { throw BridgeError("Mixed audio batch") }
        guard try frames.allSatisfy({try speakerKey($0)==speakerKey(frame)}) else {throw BridgeError("Mixed speaker batch")}
        let ids = try frames.map { try Validation.identifier($0["id"]) }
        try execute("BEGIN IMMEDIATE")
        do {
            if !text.isEmpty {
                var segment:[String:Any]=["id":"browser-\(id)","text":text,"speaker":frame["source"] as? String == "local" ? "You":"Unknown","source":"whisper-\(frame["source"] as? String ?? "remote")","t":frame["startedAt"] as? Double ?? 0,"final":true]
                for key in ["trackID","participantID","speaker","attribution","contributors"] {if let value=frame[key] {segment[key]=value}}
                let evidence=frames.compactMap { item -> [String:Any]? in
                    guard let history=item["mappingHistory"] else {return nil}
                    return ["frameID":item["id"]!,"mappingHistory":history,"packetRange":item["packetRange"]!]
                }
                if !evidence.isEmpty {segment["speakerEvidence"]=["method":"capture-timeline-v1","audioFrames":evidence]}
                let meta=try decode(rows("SELECT meta FROM sessions WHERE id=?",[session]).first!["meta"]!)
                try upsert(session,segment:attributed(segment,meta:meta))
            }
            for frameID in ids { try execute("DELETE FROM audio_queue WHERE id=?",[frameID]) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func speakerKey(_ frame:[String:Any]) throws -> String {
        try Validation.json(["id":frame["participantID"] ?? "","name":frame["speaker"] ?? "","method":frame["attribution"] ?? "","contributors":frame["contributors"] ?? []])
    }
    private func attributed(_ segment:[String:Any],meta:[String:Any]) -> [String:Any] {
        var result=segment
        let roster=meta["speakerRoster"] as? [[String:Any]] ?? []
        if segment["attribution"] as? String == "mixed" {result["speaker"]="Multiple speakers";return result}
        if segment["source"] as? String == "meet",segment["speaker"] as? String == "You" {
            let selves=roster.filter{$0["isSelf"] as? Bool==true}
            if selves.count==1,let person=selves.first,let name=person["name"] as? String,!name.isEmpty {
                result["speaker"]=name;result["participantID"]=person["id"];result["attribution"]="meet-self"
            }
            return result
        }
        if let id=segment["participantID"] as? String,let person=roster.first(where:{$0["id"] as? String==id}),let name=person["name"] as? String,!name.isEmpty {result["speaker"]=name;if segment["attribution"] as? String != "meet-activity",segment["attribution"] as? String != "meet-self" {result["attribution"]="meet-rtp"}}
        else if segment["source"] as? String == "whisper-local",let person=roster.first(where:{$0["isSelf"] as? Bool==true}),let name=person["name"] as? String,!name.isEmpty {result["speaker"]=name;result["participantID"]=person["id"];result["attribution"]="meet-rtp"}
        else if segment["source"] as? String == "whisper-remote",let name=meta["confirmedRemoteSpeaker"] as? String,!name.isEmpty {result["speaker"]=name;result["attribution"]="confirmed-two-person"}
        return result
    }
    private func updateSpeakerNames(_ session:String) throws {
        let meta=try decode(rows("SELECT meta FROM sessions WHERE id=?",[session]).first!["meta"]!)
        for row in try rows("SELECT body FROM segments WHERE session=? AND json_extract(body,'$.source') IN ('whisper-local','whisper-remote','meet')",[session]) {
            let segment=try decode(row["body"]!),resolved=attributed(segment,meta:meta)
            if try Validation.json(segment) != Validation.json(resolved) {var value=resolved;value.removeValue(forKey:"revision");try upsert(session,segment:value)}
        }
    }
    private func summaryTitle(_ id:String) throws -> String {
        try rows("SELECT json_extract(body,'$.headline') AS title FROM events WHERE session=? AND kind='ai-summary' ORDER BY cursor DESC LIMIT 1",[id]).first?["title"] ?? ""
    }
    public static func recurringProjectKey(_ record:[String:Any]) -> String? {
        if let series=record["seriesID"] as? String,!series.isEmpty {return series}
        let title=["topic","title","callID"].compactMap{record[$0] as? String}.first{!$0.trimmingCharacters(in:.whitespaces).isEmpty} ?? ""
        let normalized=title.replacingOccurrences(of:#"^Meet\s*[–—-]\s*"#,with:"",options:[.regularExpression,.caseInsensitive]).trimmingCharacters(in:.whitespacesAndNewlines)
        let generic=normalized.range(of:#"^(untitled(?: call)?|meet|[a-z]{3}-[a-z]{4}-[a-z]{3})$"#,options:[.regularExpression,.caseInsensitive]) != nil
        if !normalized.isEmpty,!generic {return "title:"+normalized.lowercased().replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression)}
        if let recordID=record["recordID"] as? String,!recordID.isEmpty {return "record:"+recordID}
        return nil
    }
    public func seriesProject(_ series:String) throws -> [String:Any]? {
        try rows("SELECT body FROM series_projects WHERE series=?",[series]).first.map{try decode($0["body"]!)}
    }
    public func saveSeriesProject(_ series:String,path:String,background:String,skill:String? = nil) throws {
        guard !series.isEmpty else {throw BridgeError("Missing recurring call identity")}
        let body=try Validation.json(["path":try Validation.text(path,limit:4000),"background":try Validation.text(background,limit:4000),"skill":try Validation.text(skill ?? "",limit:4000)])
        try execute("INSERT INTO series_projects(series,body) VALUES(?,?) ON CONFLICT(series) DO UPDATE SET body=excluded.body",[series,body])
    }
    public func detail(_ id: String) throws -> [String: Any] {
        guard let body=try rows("SELECT meta FROM sessions WHERE id=?",[id]).first?["meta"] else { throw BridgeError("Unknown session") }
        var meta=try decode(body)
        meta["summaryTitle"]=try summaryTitle(id)
        let audio=Int(try rows("SELECT COUNT(*) AS n FROM audio_archive WHERE session=?",[id]).first!["n"]!)!
        return ["id":id,"meta":meta,"segments":try rows("SELECT body FROM segments WHERE session=? ORDER BY json_extract(body,'$.t'),rowid",[id]).map{try decode($0["body"]!)},"audioChunks":audio,
                "notes":try rows("SELECT body FROM events WHERE session=? AND (kind='note' OR kind LIKE 'import-note-%') ORDER BY cursor DESC LIMIT 50",[id]).reversed().map{try decode($0["body"]!)},
                "aiSettings":try rows("SELECT body FROM events WHERE session=? AND kind='ai-settings' ORDER BY cursor DESC LIMIT 1",[id]).first.map{try decode($0["body"]!)} ?? [:],
                "aiSummary":try rows("SELECT body FROM events WHERE session=? AND kind='ai-summary' ORDER BY cursor DESC LIMIT 1",[id]).first.map{try decode($0["body"]!)} ?? [:],
                "liveRefinement":try rows("SELECT body FROM events WHERE session=? AND kind='ai-refinement' ORDER BY cursor DESC LIMIT 1",[id]).first.map{try decode($0["body"]!)} ?? [:],
                "summaryAutomation":try summaryAutomation(id),
                "feedback":try rows("SELECT body FROM events WHERE session=? AND kind='feedback' ORDER BY cursor DESC LIMIT 8",[id]).reversed().map{try decode($0["body"]!)},
                "aiCoaching":try rows("SELECT body FROM events WHERE session=? AND kind='ai-coaching' ORDER BY cursor DESC LIMIT 1",[id]).first.map{try decode($0["body"]!)} ?? [:]]
    }
    public func refinedTranscript(_ detail:[String:Any]) throws -> [[String:Any]] {
        let summary=detail["aiSummary"] as? [String:Any] ?? [:]
        let originals=detail["segments"] as? [[String:Any]] ?? []
        if let snapshot=summary["refinementSources"] as? String,snapshot == (try Validation.json(originals)) {return summary["refinedSegments"] as? [[String:Any]] ?? []}
        let live=detail["liveRefinement"] as? [String:Any] ?? [:]
        guard let snapshot=live["refinementSources"] as? String,
              let sources=try JSONSerialization.jsonObject(with:Data(snapshot.utf8)) as? [[String:Any]] else {return []}
        var covered=Set<String>(),valid=[[String:Any]]()
        var before=[String:String](),after=[String:String]()
        for source in sources {if let id=source["id"] as? String {before[id]=try Validation.json(source)}}
        for source in originals {if let id=source["id"] as? String {after[id]=try Validation.json(source)}}
        for turn in live["refinedSegments"] as? [[String:Any]] ?? [] {
            let ids=turn["sourceIDs"] as? [String] ?? []
            let unchanged = !ids.isEmpty && ids.allSatisfy{before[$0] != nil && before[$0]==after[$0]}
            if unchanged {valid.append(turn);covered.formUnion(ids)}
        }
        guard !valid.isEmpty else {return []}
        return (valid+originals.filter{!covered.contains($0["id"] as? String ?? "")}).sorted{($0["t"] as? Double ?? 0)<($1["t"] as? Double ?? 0)}
    }
    public func saveLiveRefinement(_ session:String,sources:[[String:Any]],turns:[[String:Any]]) throws {
        let detail=try detail(session)
        let current=detail["segments"] as? [[String:Any]] ?? []
        let ids=Set(sources.compactMap{$0["id"] as? String})
        let covered=Set(turns.flatMap{$0["sourceIDs"] as? [String] ?? []})
        guard !ids.isEmpty,sources.count==ids.count,ids==covered,ids.isSubset(of:Set(current.compactMap{$0["id"] as? String})),turns.allSatisfy({!($0["sourceIDs"] as? [String] ?? []).isEmpty}) else {throw BridgeError("Live refinement has incomplete or invented sources")}
        let previous=detail["liveRefinement"] as? [String:Any] ?? [:]
        let oldSources=try (previous["refinementSources"] as? String).flatMap{try JSONSerialization.jsonObject(with:Data($0.utf8)) as? [[String:Any]]} ?? []
        let oldTurns=(previous["refinedSegments"] as? [[String:Any]] ?? []).filter{Set($0["sourceIDs"] as? [String] ?? []).isDisjoint(with:ids)}
        let corrected=turns.enumerated().map {index,turn -> [String:Any] in
            let linked=sources.filter{(turn["sourceIDs"] as? [String] ?? []).contains($0["id"] as? String ?? "")}
            let names=Set(linked.compactMap{$0["speaker"] as? String}.filter{!$0.isEmpty && $0 != "Unknown"})
            var result=turn;result["id"]="live-refined-\(linked.first?["id"] as? String ?? "")-\(index)";result["source"]="Refined transcript"
            result["speaker"]=names.count==1 ? names.first!:"Unknown";result["t"]=linked.compactMap{$0["t"] as? Double}.min() ?? 0
            return result
        }
        // shortcut: retain 400 live turns; add paged refinement storage for longer corrected live histories.
        let merged=Array((oldTurns+corrected).sorted{($0["t"] as? Double ?? 0)<($1["t"] as? Double ?? 0)}.suffix(400))
        let retained=Set(merged.flatMap{$0["sourceIDs"] as? [String] ?? []})
        try append(session,kind:"ai-refinement",body:["refinedSegments":merged,"refinementSources":try Validation.json((oldSources.filter{!ids.contains($0["id"] as? String ?? "")}+sources).filter{retained.contains($0["id"] as? String ?? "")})])
    }
    public func search(_ query: String) throws -> [[String: Any]] {
        let needle=query.lowercased()
        return try list().filter { record in
            if try Validation.json(record).lowercased().contains(needle) { return true }
            return try Validation.json(detail(record["id"] as! String)["segments"]!).lowercased().contains(needle)
        }
    }
    public func delete(_ id: String) throws { try execute("DELETE FROM sessions WHERE id=?", [id]) }
}
