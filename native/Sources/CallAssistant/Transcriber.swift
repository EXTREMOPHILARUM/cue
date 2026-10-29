import Foundation
import WhisperKit
import CallCore

actor Transcriber {
    static let modelName="vocahq_voca-hinglish_820MB"
    static func modelFolder(support:URL?=nil) -> URL {
        (support ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0])
            .appendingPathComponent("Cue/models/VocaHQ/whisperkit-coreml/"+modelName)
    }
    static func downloaded(at folder:URL) -> Bool {
        ["AudioEncoder.mlmodelc","MelSpectrogram.mlmodelc","TextDecoder.mlmodelc","config.json"].allSatisfy {
            FileManager.default.fileExists(atPath:folder.appendingPathComponent($0).path)
        }
    }
    private var kit: WhisperKit?
    func load() async throws {
        if kit == nil {
            let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Cue")
            let folder=Self.modelFolder()
            kit=try await WhisperKit(WhisperKitConfig(model:Self.modelName,downloadBase:base,modelRepo:"VocaHQ/whisperkit-coreml",modelFolder:FileManager.default.fileExists(atPath:folder.path) ? folder.path:nil,verbose:false,load:true))
        }
    }
    func transcribe(_ chunk: CallCore.AudioChunk) async throws -> String {
        guard let kit else { throw BridgeError("Load WhisperKit before enabling audio") }
        let samples=chunk.speechSamples
        if samples.isEmpty { return "" }
        // This fine-tune uses English tokens for Roman Hindi; timestamps can discard later speech after a pause.
        let results = try await kit.transcribe(audioArray:samples,decodeOptions:DecodingOptions(task:.transcribe,language:"en",temperatureFallbackCount:0,detectLanguage:false,skipSpecialTokens:true,withoutTimestamps:true,windowClipTime:0,suppressBlank:true,firstTokenLogProbThreshold:nil,concurrentWorkerCount:1))
        return results.flatMap(\.segments).compactMap { segment -> String? in
            let text=segment.text.replacingOccurrences(of:#"\[(?:BLANK_AUDIO|NO_AUDIO|NO AUDIO)\]"#,with:"",options:[.regularExpression,.caseInsensitive]).trimmingCharacters(in:.whitespacesAndNewlines)
            // This fine-tune emits literal "nan" on non-speech; Whisper also emits sound labels and punctuation.
            guard text != "nan", text.contains(where: \.isLetter), text.range(of:#"^[\[(].*[\])]$"#,options:.regularExpression) == nil else { return nil }
            return text
        }.joined(separator:" ")
    }
    func file(_ path: String) async throws -> String {
        try await load()
        let samples=try AudioProcessor.loadAudioAsFloatArray(fromPath:path)
        return try await transcribe(AudioChunk(session:"file",sequence:0,startedAt:1,samples:samples))
    }
}
