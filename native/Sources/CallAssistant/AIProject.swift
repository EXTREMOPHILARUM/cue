import Foundation
import CallCore

struct AIConversation:Identifiable {let id:String;let title:String;let project:String}

struct AIProject:Codable,Equatable {
    var path=""
    var conversation=""
    var provider:AIProvider = .codex
    var background=""
    var skill:String? = nil
    func validate(provider:AIProvider) throws {
        if !path.isEmpty {
            var directory:ObjCBool=false
            guard path.hasPrefix("/"),FileManager.default.fileExists(atPath:path,isDirectory:&directory),directory.boolValue else {throw BridgeError("Choose an existing project folder")}
        }
        if let skill,!skill.isEmpty {guard skills().contains(skill) else {throw BridgeError("Choose an existing skill inside this project")}}
        guard conversation.isEmpty || UUID(uuidString:conversation) != nil else {throw BridgeError("Conversation ID must be a UUID")}
        if !conversation.isEmpty {
            guard !path.isEmpty,try conversationProject(provider:provider)==URL(fileURLWithPath:path).resolvingSymlinksInPath().path else {throw BridgeError("Conversation was not found in this project; check the provider, folder and ID")}
        }
    }
    private func conversationProject(provider:AIProvider) throws -> String? {
        let home=FileManager.default.homeDirectoryForCurrentUser
        let root:URL
        if provider == .codex {
            root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path).appendingPathComponent("sessions")
        } else {root=home.appendingPathComponent(".claude/projects")}
        guard let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles]) else {return nil}
        for case let file as URL in files where file.lastPathComponent.hasSuffix(conversation+".jsonl") {
            return try recordedDirectory(file)
        }
        return nil
    }
    func conversations(allProjects:Bool=false) throws -> [AIConversation] {
        guard allProjects || !path.isEmpty else {return []}
        let home=FileManager.default.homeDirectoryForCurrentUser
        let codexRoot=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
        let root=provider == .codex ? codexRoot.appendingPathComponent("sessions"):home.appendingPathComponent(".claude/projects")
        var titles=[String:String]()
        let index=codexRoot.appendingPathComponent("session_index.jsonl")
        if provider == .codex,FileManager.default.fileExists(atPath:index.path) {
            let handle=try FileHandle(forReadingFrom:index);defer {try? handle.close()}
            for line in String(decoding:try handle.read(upToCount:2_000_000) ?? Data(),as:UTF8.self).split(separator:"\n") {
                if let entry=try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],let id=entry["id"] as? String {titles[id]=entry["thread_name"] as? String}
            }
        }
        guard let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.contentModificationDateKey],options:[.skipsHiddenFiles]) else {return []}
        let expected=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
        var matches=[(value:AIConversation,date:Date)](),seen=Set<String>()
        for case let file as URL in files where file.pathExtension=="jsonl" {
            let id=String(file.deletingPathExtension().lastPathComponent.suffix(36))
            guard UUID(uuidString:id) != nil,!seen.contains(id),let info=try conversationInfo(file),allProjects || info.project==expected else {continue}
            seen.insert(id)
            let date=try file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let name=titles[id] ?? info.title
            let title=(name.isEmpty ? String(id.prefix(8)):String(name.prefix(80)))+" · "+URL(fileURLWithPath:info.project).lastPathComponent+" · "+date.formatted(date:.abbreviated,time:.shortened)
            matches.append((AIConversation(id:id,title:title,project:info.project),date))
        }
        return matches.sorted{$0.date>$1.date}.prefix(allProjects ? 200:50).map(\.value)
    }
    private func conversationInfo(_ file:URL) throws -> (project:String,title:String)? {
        let handle=try FileHandle(forReadingFrom:file);defer {try? handle.close()}
        let data=try handle.read(upToCount:128_000) ?? Data()
        var cwd:String?,title=""
        for line in String(decoding:data,as:UTF8.self).split(separator:"\n") {
            guard let record=try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else {continue}
            let meta=provider == .codex ? record["payload"] as? [String:Any]:record
            if cwd==nil {cwd=meta?["cwd"] as? String}
            if record["type"] as? String == "custom-title" {title=record["customTitle"] as? String ?? title}
            if provider == .claude,title.isEmpty,record["type"] as? String == "user",let message=record["message"] as? [String:Any] {
                title=(message["content"] as? String) ?? (message["content"] as? [[String:Any]])?.first(where:{$0["type"] as? String == "text"})?["text"] as? String ?? ""
                title=title.replacingOccurrences(of:"\n",with:" ")
            }
        }
        return cwd.map{(URL(fileURLWithPath:$0).resolvingSymlinksInPath().path,title)}
    }
    private func recordedDirectory(_ file:URL) throws ->String? {try conversationInfo(file)?.project}
    func skills() -> [String] {
        guard !path.isEmpty else {return []}
        let root=URL(fileURLWithPath:path).resolvingSymlinksInPath()
        return [".codex/skills",".claude/skills",".agents/skills"].flatMap { directory -> [String] in
            let folder=root.appendingPathComponent(directory)
            guard let names=try? FileManager.default.contentsOfDirectory(atPath:folder.path) else {return []}
            return names.sorted().compactMap { name in
                let relative=directory+"/"+name+"/SKILL.md",file=root.appendingPathComponent(relative).resolvingSymlinksInPath()
                return file.path.hasPrefix(root.path+"/") && FileManager.default.fileExists(atPath:file.path) ? relative:nil
            }
        }
    }
    func skillContext() throws -> String {
        guard let skill,!skill.isEmpty else {return ""}
        guard skills().contains(skill) else {throw BridgeError("Selected coaching skill is no longer in the project")}
        let file=URL(fileURLWithPath:path).appendingPathComponent(skill).resolvingSymlinksInPath()
        let handle=try FileHandle(forReadingFrom:file);defer {try? handle.close()}
        let data=try handle.read(upToCount:16_001) ?? Data()
        guard data.count<=16_000,let text=String(data:data,encoding:.utf8) else {throw BridgeError("Coaching skill must be UTF-8 and under 16,000 bytes")}
        return text
    }
    func context() throws -> [[String:String]] {
        guard !path.isEmpty else {return []}
        let root=URL(fileURLWithPath:path).resolvingSymlinksInPath()
        var context=[[String:String]]()
        var remaining=64_000
        // shortcut: bounded project briefing files; attach a conversation for broader working context.
        for name in ["README.md","AGENTS.md","CLAUDE.md",".claude/CLAUDE.md",".codex/AGENTS.md"] {
            let file=root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path+"/"),FileManager.default.fileExists(atPath:file.path) else {continue}
            let handle=try FileHandle(forReadingFrom:file);defer {try? handle.close()}
            let limit=min(32_000,remaining)
            let bytes=try handle.read(upToCount:limit+1) ?? Data()
            let truncated=bytes.count>limit
            var excerpt=Data(bytes.prefix(limit))
            // A byte budget can cut through the final UTF-8 character.
            if truncated {for _ in 0..<3 {if !excerpt.isEmpty,String(data:excerpt,encoding:.utf8)==nil {excerpt.removeLast()}}}
            guard let text=String(data:excerpt,encoding:.utf8) else {throw BridgeError("Project context file \(name) is not UTF-8")}
            remaining -= excerpt.count
            context.append(["file":name,"text":text,"notice":truncated ? "Excerpt only; remaining file contents omitted by the context budget":"Full file"])
            if remaining==0 {context.append(["notice":"Project context budget reached; later briefing files were omitted"]);break}
        }
        return context
    }
}
