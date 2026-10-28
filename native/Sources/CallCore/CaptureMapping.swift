import Foundation

public enum CaptureMapping {
    public static func validate(_ frame:[String:Any]) throws {
        if let value=frame["captureDiscontinuities"] {
            guard let gaps=value as? [[String:Any]],gaps.count<=8 else {throw BridgeError("Invalid capture discontinuities")}
            for gap in gaps {
                guard let time=gap["observedAt"] as? Double,time.isFinite,time>0,
                      let pending=gap["pendingPackets"] as? Int,(0...100).contains(pending) else {throw BridgeError("Invalid capture discontinuity")}
                _ = try Validation.text(gap["reason"],limit:500)
            }
        }
        guard let value=frame["mappingHistory"] else {return}
        guard let history=value as? [[String:Any]],!history.isEmpty,history.count<=16,JSONSerialization.isValidJSONObject(history),
              try Validation.json(history).utf8.count<=32000 else {throw BridgeError("Invalid mapping history")}
        guard let range=frame["packetRange"] as? [String:Any],let first=range["firstObservedAt"] as? Double,
              let last=range["lastObservedAt"] as? Double,first.isFinite,last.isFinite,first>0,last>=first,
              let pcm=frame["pcm"] as? String,let bytes=Data(base64Encoded:pcm),!bytes.isEmpty,bytes.count%4==0 else {throw BridgeError("Invalid audio packet range")}
        var previousTime=first,previousOffset = -1
        for (index,item) in history.enumerated() {
            guard item["version"] as? Int==1, let time=item["observedAt"] as? Double,time.isFinite,time>0,
                  let contributors=item["contributors"] as? [String],contributors.count<=32,
                  contributors.allSatisfy({$0.utf8.count<=200}),
                  let active=item["active"] as? [[String:Any]],active.count<=32,
                  let method=item["method"] as? String,["meet-rtp","meet-activity","mixed","unresolved"].contains(method),
                  method==frame["attribution"] as? String else {throw BridgeError("Invalid mapping history entry")}
            guard time>=previousTime,time<=last,(index != 0 || time==first) else {throw BridgeError("Mapping history outside packet range")}
            // Older single-snapshot archives omitted offset and track; preserve their import compatibility.
            let offset=(item["sampleOffset"] as? Int) ?? (history.count==1 && item["sampleOffset"]==nil ? 0 : -1)
            guard offset>previousOffset,offset<bytes.count/4,(index != 0 || offset==0) else {throw BridgeError("Invalid mapping sample offset")}
            previousTime=time;previousOffset=offset
            if let track=item["trackID"] as? String {guard track==frame["trackID"] as? String else {throw BridgeError("Mapping track mismatch")}}
            if let expected=frame["contributors"] as? [String] {guard contributors.sorted()==expected.sorted() else {throw BridgeError("Mapping contributors mismatch")}}
            for key in ["trackID","synchronizationSource","reason","protocolError"] {if let value=item[key] {_ = try Validation.text(value,limit:500)}}
            for person in active {
                _ = try Validation.text(person["id"],limit:500)
                _ = try Validation.text(person["name"],limit:500)
                guard person["isSelf"] is Bool else {throw BridgeError("Invalid active participant")}
            }
            if let protocolValue=item["protocol"],!(protocolValue is NSNull) {
                guard let mapping=protocolValue as? [String:Any] else {throw BridgeError("Invalid protocol mapping")}
                for key in ["rawDeviceID","participantID","speaker"] {_ = try Validation.text(mapping[key],limit:500)}
                guard mapping["disabled"] is Bool,mapping["isSelf"] is Bool else {throw BridgeError("Invalid protocol mapping state")}
            }
        }
    }
}
