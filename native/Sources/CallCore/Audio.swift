import Foundation

public struct AudioChunk {
    public let session: String
    public let sequence: Int
    public let startedAt: Double
    public let samples: [Float]
    public init(session: String, sequence: Int, startedAt: Double, samples: [Float]) {
        self.session = session; self.sequence = sequence; self.startedAt = startedAt; self.samples = samples
    }
    public static func decode(_ request: [String: Any]) throws -> AudioChunk {
        let session = try Validation.identifier(request["session"])
        guard let seq = request["sequence"] as? Int, seq >= 0,
              let t = request["startedAt"] as? Double, t.isFinite, t > 0,
              request["sampleRate"] as? Int == 16000,
              let base64 = request["pcm"] as? String, base64.count <= 700_000,
              let data = Data(base64Encoded:base64), !data.isEmpty,
              data.count <= 16000 * 8 * 4, data.count % 4 == 0 else { throw BridgeError("Invalid audio frame (expected <=8s of 16kHz mono float32 PCM)") }
        let samples = data.withUnsafeBytes { bytes in stride(from:0,to:data.count,by:4).map { Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:$0,as:UInt32.self))) } }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else { throw BridgeError("Invalid PCM samples") }
        return AudioChunk(session:session,sequence:seq,startedAt:t,samples:samples)
    }
    public var speechSamples: [Float] {
        // Preserve quiet word boundaries, but do not ask Whisper to invent text for long silent tails.
        let window = 320, padding = 4000
        let voiced = stride(from:0,to:samples.count,by:window).filter { offset in
            let end = min(offset+window,samples.count)
            return samples[offset..<end].reduce(Float(0)) { $0+$1*$1 } / Float(end-offset) > 0.00001
        }
        guard let first=voiced.first, let last=voiced.last else { return [] }
        return Array(samples[max(0,first-padding)..<min(samples.count,last+window+padding)])
    }
    public var hasSpeechEnergy: Bool {
        samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(samples.count,1)) > 0.00001
    }
}
