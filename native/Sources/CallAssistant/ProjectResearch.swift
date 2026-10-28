import Foundation
import CallCore

struct ProjectResearch {
    static func search(path:String,query:String) throws -> [[String:String]] {
        guard !path.isEmpty,!query.isEmpty,query.utf8.count<=200 else {return []}
        let root=URL(fileURLWithPath:path).resolvingSymlinksInPath()
        let words=Set(query.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init).filter{$0.count>=3})
        guard !words.isEmpty else {return []}
        let allowed=Set(["md","txt","json","yaml","yml","toml","swift","ts","tsx","js","jsx"])
        let ignored=Set([".git","node_modules",".build","build","dist",".env","secrets"])
        let lockfiles=Set(["package-lock.json","npm-shrinkwrap.json","yarn.lock","pnpm-lock.yaml","bun.lock","bun.lockb"])
        let credentialNames=Set(["auth","credentials","secrets","service-account","service_account"])
        var matches=[(score:Int,file:String,text:String)](),examined=0,seen=Set<String>()
        // shortcut: search at most 160 text files, docs first; add an index when larger repos need broader recall.
        for base in [root.appendingPathComponent("docs"),root] {
        guard let files=FileManager.default.enumerator(at:base,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else {continue}
        while let file=files.nextObject() as? URL {
            try Task.checkCancellation()
            if ignored.contains(file.lastPathComponent) {files.skipDescendants();continue}
            let name=file.lastPathComponent.lowercased(),ext=file.pathExtension.lowercased()
            if lockfiles.contains(name) || (["json","yaml","yml","toml","txt"].contains(ext) && credentialNames.contains(file.deletingPathExtension().lastPathComponent.lowercased())) {continue}
            guard allowed.contains(ext),(try? file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true else {continue}
            let resolved=file.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path+"/"),seen.insert(resolved.path).inserted else {continue}
            examined += 1;if examined>160 {break}
            guard let handle=try? FileHandle(forReadingFrom:resolved) else {continue}
            let bytes:Data
            do {bytes=try handle.read(upToCount:32_000) ?? Data();try handle.close()} catch {try? handle.close();continue}
            var excerptBytes=bytes
            for _ in 0..<3 {if String(data:excerptBytes,encoding:.utf8)==nil,!excerptBytes.isEmpty {excerptBytes.removeLast()}}
            guard let text=String(data:excerptBytes,encoding:.utf8) else {continue}
            let lines=text.split(separator:"\n",omittingEmptySubsequences:false)
            let hits=lines.indices.filter{index in words.contains(where:{lines[index].localizedCaseInsensitiveContains($0)})}
            guard !hits.isEmpty else {continue}
            var selected=Set<Int>()
            for hit in hits.prefix(4) {for index in max(0,hit-1)...min(lines.count-1,hit+1) {selected.insert(index)}}
            let excerpt=selected.sorted().map{"\($0+1): \(lines[$0])"}.joined(separator:"\n")
            matches.append((hits.count,String(resolved.path.dropFirst(root.path.count+1)),String(excerpt.prefix(1800))))
        }
        if examined>=160 {break}
        }
        return matches.sorted{$0.score == $1.score ? $0.file<$1.file:$0.score>$1.score}.prefix(4).map{["file":$0.file,"text":$0.text,"notice":"Local excerpt, not a verified current fact"]}
    }
}
