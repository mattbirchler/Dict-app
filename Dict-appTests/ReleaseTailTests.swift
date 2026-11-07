import Foundation
import Testing
@testable import Dict_app

struct ReleaseTailTests {
    private let rate = 16_000

    private func noise(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -level...level) }
    }

    /// A 200 Hz tone standing in for a voice.
    private func voice(_ seconds: Double, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { level * sin(2 * .pi * 200 * Float($0) / Float(rate)) }
    }

    @Test func stillTalkingIsNotQuiet() {
        let recording = noise(0.5, level: 0.002) + voice(3)
        #expect(!ReleaseTail.endsQuietly(recording, sampleRate: rate))
    }

    @Test func aShortPauseIsNotYetQuiet() {
        let recording = voice(3) + noise(0.15, level: 0.002)
        #expect(!ReleaseTail.endsQuietly(recording, sampleRate: rate))
    }

    @Test func silenceAfterSpeechIsQuiet() {
        let recording = noise(0.5, level: 0.002) + voice(3) + noise(0.4, level: 0.002)
        #expect(ReleaseTail.endsQuietly(recording, sampleRate: rate))
    }

    @Test func quietIsJudgedAgainstANoisyRoom() {
        let room = { self.noise($0, level: 0.03) }
        let recording = room(1) + zip(voice(3), room(3)).map(+) + room(0.4)
        #expect(ReleaseTail.endsQuietly(recording, sampleRate: rate))
    }

    @Test func recordingWithNoSpeechDoesNotWait() {
        #expect(ReleaseTail.endsQuietly(noise(2, level: 0.002), sampleRate: rate))
    }

    @Test func tooShortToJudgeKeepsListening() {
        #expect(!ReleaseTail.endsQuietly(voice(0.1), sampleRate: rate))
    }
}
