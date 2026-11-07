import AVFoundation
import FluidAudio
import Foundation
import os

/// On-device transcription using NVIDIA's Parakeet TDT model via FluidAudio's
/// CoreML port. Records the whole utterance through an AVAudioEngine tap and
/// decodes it in one shot at stop(): Parakeet decodes far faster than
/// realtime on Apple Silicon, so no mid-recording chunking is needed and the
/// model always sees the full utterance when punctuating.
@Observable
@MainActor
final class ParakeetTranscriptionService: TranscriptionEngine {
    var audioEnergy: [Float] = []
    var audioSpectrum: [Float] = []
    private var spectrumGain = SpectrumGain()
    private(set) var isRecording = false
    private(set) var liveTranscript = LiveTranscript()
    let supportsLiveTranscript = true
    @ObservationIgnored var onProgress: ((Double) -> Void)?
    @ObservationIgnored var inputDeviceID: AudioDeviceID?

    private static let modelVersion = AsrModelVersion.v3
    private static let sampleRate = 16_000
    private let maxEnergySamples = 64
    /// Silence added to both ends of the recording before decoding. The
    /// recording starts and stops abruptly at the hotkey, and Parakeet drops
    /// or garbles words that sit right at a hard edge.
    static let edgePaddingSeconds = 0.2
    /// Pause between live-preview decodes. Each decode covers the whole
    /// recording so far, so long recordings refresh a little less often.
    static let previewInterval: Duration = .milliseconds(700)

    private var manager: AsrManager?
    private var isPreparing = false
    /// Bumped by cancel()/stop() so an in-flight start() (suspended in
    /// prepare) knows the session it was starting is already over.
    private var session = 0
    private let capture = AudioCapture()
    /// Token of the capture this recording started; see AudioCapture.stop.
    private var captureGeneration: Int?
    /// Recorded 16 kHz mono samples, appended from the realtime tap thread.
    /// Lock-protected rather than hopped to the main actor so stop() can't
    /// lose buffers that were still in flight between actors.
    private let recordedSamples = OSAllocatedUnfairLock(initialState: [Float]())
    private var previewTask: Task<Void, Never>?

    var isReady: Bool { manager != nil }

    /// True until the model files are on disk. This is
    /// re-checked against the cache, so a completed download flips it false
    /// across relaunches.
    var needsDownload: Bool {
        !AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: Self.modelVersion),
            version: Self.modelVersion
        )
    }

    // MARK: - Model loading

    func prepare() async throws {
        guard manager == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        Log.engine.info("Downloading/loading model...")
        let models = try await AsrModels.downloadAndLoad(
            version: Self.modelVersion,
            progressHandler: { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in self?.onProgress?(fraction) }
            }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        Log.engine.info("Model loaded")
        await capture.warmUp()
    }

    // MARK: - Recording lifecycle

    func start() async throws {
        let startedSession = session
        try await prepare()
        guard manager != nil else { throw ParakeetTranscriptionError.modelNotLoaded }
        // Cancelled or stopped while prepare was suspended — don't start an
        // engine nobody will stop.
        guard session == startedSession, !isRecording else { return }

        recordedSamples.withLock { $0 = [] }
        audioEnergy = []

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw ParakeetTranscriptionError.audioFormatUnavailable
        }

        // The tap callback runs on a realtime audio thread: append samples
        // under the lock, publish energy via a MainActor hop. Buffers are
        // converted from whatever format they arrive in (TapConverter), so
        // AirPods dropping to 24 kHz mid-recording just works.
        let tapConverter = TapConverter(targetFormat: targetFormat)
        let samplesBox = recordedSamples
        let generation = try await capture.start(deviceID: inputDeviceID) { [weak self] buffer in
            let level = Self.rmsLevel(buffer)
            let spectrum = SpectrumAnalyzer.bandAmplitudes(buffer)
            Task { @MainActor [weak self] in self?.appendEnergy(level, spectrum: spectrum) }
            guard let converted = tapConverter.convert(buffer),
                  let channel = converted.floatChannelData?[0] else { return }
            let frames = Int(converted.frameLength)
            guard frames > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
            samplesBox.withLock { $0.append(contentsOf: samples) }
        }
        // The key was released (or Escape pressed) while the mic was still
        // opening, which takes a second or more on Bluetooth. Nobody will
        // stop this capture, so stop it here.
        guard session == startedSession else {
            await capture.stop(generation: generation)
            return
        }
        captureGeneration = generation
        isRecording = true
        Log.engine.info("Recording started")
    }

    /// Stops the engine and throws the recording away without transcribing —
    /// used when the hotkey was released before the accidental-tap threshold.
    func cancel() {
        session += 1
        endLivePreview()
        guard isRecording else { return }
        isRecording = false
        let generation = captureGeneration
        Task { await capture.stop(generation: generation) }
        teardownAudio()
        recordedSamples.withLock { $0 = [] }
        audioEnergy = []
        Log.engine.info("Recording cancelled, discarded")
    }

    func stop() async throws -> String {
        session += 1
        guard isRecording, manager != nil else {
            endLivePreview()
            return ""
        }
        // People let go while still finishing a sentence, so keep
        // capturing until they go quiet. A cancel() during the wait tears
        // down and empties the buffer, so this stop returns "".
        await waitForReleaseTail()
        isRecording = false
        // Let an in-flight preview decode finish before the final one, so
        // two decodes never interleave inside the AsrManager actor.
        let preview = previewTask
        endLivePreview()
        await preview?.value
        await capture.stop(generation: captureGeneration)
        teardownAudio()
        audioEnergy = []

        let samples = recordedSamples.withLock { samples in
            let taken = samples
            samples = []
            return taken
        }
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: Self.sampleRate)
        guard samples.count >= minimumSamples else {
            Log.engine.info("Recording too short (\(samples.count, privacy: .public) samples), skipping")
            return ""
        }

        Log.engine.info("Recording stopped: \(samples.count, privacy: .public) samples, transcribing")
        return try await transcribeRecording(samples)
    }

    /// Waits at least ReleaseTail.minimum, then until the speaker has
    /// been quiet for a moment or ReleaseTail.maximum has passed.
    private func waitForReleaseTail() async {
        let clock = ContinuousClock()
        let released = clock.now
        try? await Task.sleep(for: ReleaseTail.minimum)
        while clock.now - released < ReleaseTail.maximum {
            let samples = recordedSamples.withLock { $0 }
            if samples.isEmpty || ReleaseTail.endsQuietly(samples, sampleRate: Self.sampleRate) { break }
            try? await Task.sleep(for: ReleaseTail.pollInterval)
        }
        let waited = clock.now - released
        Log.engine.info("Release tail: \(waited, privacy: .public)")
    }

    /// Decodes one full recording with a fresh decoder state. Internal (not
    /// private) so the end-to-end test can drive the exact production decode
    /// path via `@testable import` instead of re-implementing it.
    func transcribeRecording(_ samples: [Float]) async throws -> String {
        let decodeStarted = ProcessInfo.processInfo.systemUptime
        do {
            let text = try await decode(samples)
            let timing = String(
                format: "decode=%.3fs audio=%.1fs chars=%d",
                ProcessInfo.processInfo.systemUptime - decodeStarted,
                Float(samples.count) / Float(Self.sampleRate),
                text.count
            )
            Log.engine.debug("Parakeet timing \(timing, privacy: .public)")
            Log.engine.info("Result: \"\(text, privacy: .private)\"")
            return text
        } catch {
            Log.engine.error("Transcription failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func decode(_ samples: [Float]) async throws -> String {
        guard let manager else { throw ParakeetTranscriptionError.modelNotLoaded }
        var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let padded = Self.padded(samples, seconds: Self.edgePaddingSeconds, sampleRate: Self.sampleRate)
        let result = try await manager.transcribe(padded, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Live preview

    /// Starts re-decoding the recording so far every `previewInterval`, for
    /// the hands-free HUD. Off for ordinary hold-to-talk, where nobody sees
    /// it and a preview in flight would delay the final decode. May arrive
    /// just before start() finishes; the loop waits for recording to begin,
    /// and stop()/cancel() always end it.
    func beginLivePreview() {
        guard previewTask == nil else { return }
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: Self.sampleRate)
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.previewInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.isRecording else { continue }
                let samples = self.recordedSamples.withLock { $0 }
                guard samples.count >= minimumSamples,
                      let text = try? await self.decode(samples),
                      !Task.isCancelled, self.isRecording else { continue }
                self.liveTranscript = LiveTranscript.comparing(
                    previous: self.liveTranscript.fullText,
                    current: text
                )
            }
        }
    }

    private func endLivePreview() {
        previewTask?.cancel()
        previewTask = nil
        liveTranscript = LiveTranscript()
    }

    /// Resets the HUD-facing audio state once the capture is stopped.
    private func teardownAudio() {
        captureGeneration = nil
        audioSpectrum = []
        spectrumGain = SpectrumGain()
    }

    private func appendEnergy(_ level: Float, spectrum: [Float]) {
        audioSpectrum = spectrumGain.levels(amplitudes: spectrum)
        audioEnergy.append(Self.normalizedEnergy(rms: level))
        if audioEnergy.count > maxEnergySamples {
            audioEnergy.removeFirst(audioEnergy.count - maxEnergySamples)
        }
    }

    // MARK: - Pure helpers (testable)

    /// Maps an RMS level (~0...0.3 for speech) into the 0...1 range the HUD
    /// waveform expects, matching the Apple engine's scaling.
    nonisolated static func normalizedEnergy(rms: Float) -> Float {
        min(max(rms * 6, 0), 1)
    }

    /// The recording with `seconds` of silence on each end.
    nonisolated static func padded(_ samples: [Float], seconds: Double, sampleRate: Int) -> [Float] {
        let silence = [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
        return silence + samples + silence
    }

    /// RMS of the first channel of a PCM buffer.
    nonisolated static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { let s = channel[i]; sum += s * s }
        return (sum / Float(count)).squareRoot()
    }
}

enum ParakeetTranscriptionError: LocalizedError {
    case modelNotLoaded
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "The Parakeet model failed to load."
        case .audioFormatUnavailable:
            return "Couldn't create a compatible audio format for Parakeet."
        }
    }
}
