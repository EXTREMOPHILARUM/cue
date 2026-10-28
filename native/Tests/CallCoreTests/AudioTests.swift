import XCTest
@testable import CallCore
final class AudioTests: XCTestCase {
    func testPCMValidationAndSilence() throws {
        var sample: Float = 0.25
        let data = Data(bytes:&sample,count:4)
        var message: [String:Any] = ["session":"one","sequence":0,"sampleRate":16000,"startedAt":1.0,"pcm":data.base64EncodedString()]
        XCTAssertTrue(try AudioChunk.decode(message).hasSpeechEnergy)
        message["sampleRate"] = 48000
        XCTAssertThrowsError(try AudioChunk.decode(message))
        message["sampleRate"] = 16000
        sample = .nan
        message["pcm"] = Data(bytes:&sample,count:4).base64EncodedString()
        XCTAssertThrowsError(try AudioChunk.decode(message))
        XCTAssertFalse(AudioChunk(session:"one",sequence:0,startedAt:1,samples:[0,0]).hasSpeechEnergy)
    }
}

extension AudioTests {
    func testTrimOnlyOuterSilenceWithWordBoundaryPadding() {
        let silence=[Float](repeating:0,count:16000)
        let voice=[Float](repeating:0.02,count:3200)
        let audio=AudioChunk(session:"one",sequence:0,startedAt:1,samples:silence+voice+silence+voice+silence)
        let trimmed=audio.speechSamples
        XCTAssertEqual(trimmed.count,voice.count*2+silence.count+8000)
        XCTAssertEqual(trimmed.filter{$0 != 0}.count,voice.count*2,"Never discard speech or internal pauses")
        XCTAssertTrue(AudioChunk(session:"one",sequence:0,startedAt:1,samples:silence).speechSamples.isEmpty)
        XCTAssertEqual(AudioChunk(session:"one",sequence:0,startedAt:1,samples:voice).speechSamples,voice)
    }
}
