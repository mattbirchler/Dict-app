import Foundation

/// Decides when to stop recording after the hotkey is released. People
/// often let go while still finishing a sentence, and a fixed cutoff lost
/// those last words. So the mic stays on until the speaker has been quiet
/// for a moment, measured against this recording's own noise floor so a
/// noisy room still ends.
enum ReleaseTail {
    /// Always keep at least this much after release.
    static let minimum: Duration = .milliseconds(250)
    /// Never keep more than this, so steady background noise can't hold
    /// the recording open.
    static let maximum: Duration = .milliseconds(2500)
    /// How often to check whether the speaker has gone quiet.
    static let pollInterval: Duration = .milliseconds(50)
    /// How long the speaker must be quiet before the recording ends.
    static let quietSeconds = 0.35

    /// Audio is judged in frames this long.
    static let frameSeconds = 0.02

    /// Whether the end of `samples` is quiet: every frame in the last
    /// `quietSeconds` sits near the recording's noise floor rather than its
    /// speech level.
    static func endsQuietly(_ samples: [Float], sampleRate: Int) -> Bool {
        let frameLength = Int(frameSeconds * Double(sampleRate))
        let quietFrames = Int(quietSeconds / frameSeconds)
        guard frameLength > 0, samples.count >= frameLength * quietFrames else { return false }

        let levels = frameLevels(samples, frameLength: frameLength)
        let sorted = levels.sorted()
        let speech = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        // No clear speech in the recording: nothing to wait for.
        guard speech > 0.005 else { return true }
        // Capped so a recording that is speech from start to finish, with
        // no quiet stretch to measure, still gets a sensible floor.
        let floor = min(sorted[sorted.count / 10], speech * 0.25)
        let threshold = floor + (speech - floor) * 0.15
        return levels.suffix(quietFrames).allSatisfy { $0 < threshold }
    }

    /// RMS level of each whole frame.
    static func frameLevels(_ samples: [Float], frameLength: Int) -> [Float] {
        stride(from: 0, to: samples.count - frameLength + 1, by: frameLength).map { start in
            var sum: Float = 0
            for i in start..<(start + frameLength) { sum += samples[i] * samples[i] }
            return (sum / Float(frameLength)).squareRoot()
        }
    }
}
