import Foundation
import AVFAudio
import Speech

/// C callback type matching the Rust trampoline signature.
/// event_type: 0=Interim, 1=Definite, 2=Final, 3=Error, 4=Connected, 5=Closed
typealias AppleSpeechEventCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    UnsafePointer<CChar>?
) -> Void

/// Manages Apple Speech framework streaming recognition sessions.
///
/// Uses `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) for on-device
/// speech recognition. Audio is fed through closures that capture the typed
/// `AsyncStream` continuation, avoiding `@available` constraints on properties.
class AppleSpeechManager {
    private var callback: AppleSpeechEventCallback?
    private var callbackCtx: UnsafeMutableRawPointer?
    private let callbackLock = NSLock()

    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Closure that yields an AVAudioPCMBuffer into the AsyncStream.
    /// Captures the typed continuation from startSessionImpl, avoiding @available on properties.
    private var yieldAudio: ((AVAudioPCMBuffer) -> Void)?

    /// Closure that finishes the AsyncStream (signals end of audio input).
    private var finishAudio: (() -> Void)?

    /// Audio format for PCM buffers: 16kHz mono Int16.
    /// SpeechAnalyzer requires 16-bit signed integer samples.
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    // MARK: - Session Lifecycle

    /// Start a new session. Returns the session generation (>0) on success, 0 on failure.
    func startSession(
        locale localeStr: String,
        contextualStrings: [String],
        callback: AppleSpeechEventCallback,
        context: UnsafeMutableRawPointer?
    ) -> UInt64 {
        guard #available(macOS 26.0, *) else {
            callback(context, 3, "Apple Speech requires macOS 26.0 or later")
            callback(context, 5, nil)
            return 0
        }

        // Cancel any in-flight session
        cancelInternal()

        // Bump generation and install callback atomically so that
        // invokeCallback's generation check is consistent.
        callbackLock.lock()
        generation &+= 1
        let thisGeneration = generation
        self.callback = callback
        self.callbackCtx = context
        callbackLock.unlock()

        return startSessionImpl(
            localeStr: localeStr,
            contextualStrings: contextualStrings,
            generation: thisGeneration
        ) ? thisGeneration : 0
    }

    /// Feed raw PCM16 LE audio bytes.
    func feedAudio(_ bytes: UnsafePointer<UInt8>, count: Int, generation gen: UInt64) {
        guard gen == generation, count >= 2, let yield = yieldAudio else { return }

        let sampleCount = count / 2

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ), let channelData = buffer.int16ChannelData?[0] else { return }

        buffer.frameLength = AVAudioFrameCount(sampleCount)

        // Copy raw PCM16 LE bytes directly — no conversion needed
        memcpy(channelData, bytes, count)

        yield(buffer)
    }

    /// Signal end of audio input, triggering finalization.
    func stop(generation gen: UInt64) {
        guard gen == generation else { return }
        finishAudio?()
        finishAudio = nil
        yieldAudio = nil
    }

    /// Cancel the session immediately.
    func cancel(generation gen: UInt64) {
        guard gen == generation else { return }
        cancelInternal()
    }

    // MARK: - Private

    private func cancelInternal() {
        // Clear callback under lock FIRST (matches KoeMLX pattern)
        callbackLock.lock()
        callback = nil
        callbackCtx = nil
        callbackLock.unlock()

        finishAudio?()
        finishAudio = nil
        yieldAudio = nil
        analyzerTask?.cancel()
        resultsTask?.cancel()
        analyzerTask = nil
        resultsTask = nil
    }

    private func invokeCallback(eventType: Int32, text: String?, generation expectedGen: UInt64) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard self.generation == expectedGen, let cb = callback, let ctx = callbackCtx else { return }
        if let text = text {
            text.withCString { cstr in
                cb(ctx, eventType, cstr)
            }
        } else {
            cb(ctx, eventType, nil)
        }
    }

    // MARK: - macOS 26+ Implementation

    @available(macOS 26.0, *)
    private func startSessionImpl(
        localeStr: String,
        contextualStrings: [String],
        generation thisGeneration: UInt64
    ) -> Bool {
        let locale = Locale(identifier: localeStr)
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )

        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings[.general] = contextualStrings
        }

        // AsyncStream bridge: Rust pushes PCM → continuation → SpeechAnalyzer pulls
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.yieldAudio = { buffer in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        self.finishAudio = {
            continuation.finish()
        }

        let options = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .processLifetime
        )

        // Emit Connected event
        invokeCallback(eventType: 4, text: "", generation: thisGeneration)

        // Task 1: Check asset status, install if needed, then drive the analyzer
        analyzerTask = Task { [weak self] in
            do {
                // Check if speech recognition assets are installed for this locale
                let status = await AssetInventory.status(forModules: [transcriber])
                switch status {
                case .unsupported:
                    guard let self = self, self.generation == thisGeneration else { return }
                    self.invokeCallback(eventType: 3, text: "Speech recognition is not supported for locale \"\(localeStr)\"", generation: thisGeneration)
                    self.invokeCallback(eventType: 5, text: nil, generation: thisGeneration)
                    return
                case .supported:
                    // Asset available but not downloaded — trigger installation
                    guard let self = self, self.generation == thisGeneration else { return }
                    NSLog("KoeAppleSpeech: downloading speech model for %@", localeStr)
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                case .downloading:
                    // Already downloading — wait for it to finish
                    guard let self = self, self.generation == thisGeneration else { return }
                    NSLog("KoeAppleSpeech: waiting for speech model download for %@", localeStr)
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                case .installed:
                    break // Ready to go
                @unknown default:
                    break
                }

                let analyzer = SpeechAnalyzer(
                    inputSequence: stream,
                    modules: [transcriber],
                    options: options,
                    analysisContext: context
                )
                try await analyzer.prepareToAnalyze(in: self?.audioFormat)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch is CancellationError {
                // Normal cancellation
            } catch {
                guard let self = self, self.generation == thisGeneration else { return }
                self.invokeCallback(eventType: 3, text: error.localizedDescription, generation: thisGeneration)
            }
        }

        // Task 2: Iterate progressive transcription results
        //
        // Each result from SpeechTranscriber represents a segment of audio.
        // result.isFinal distinguishes confirmed segments from volatile ones.
        // We accumulate finalized segments and combine with the current volatile
        // segment to always deliver the full transcript via Interim events
        // (matching TranscriptAggregator.update_interim's replacement semantics).
        resultsTask = Task { [weak self] in
            var finalizedTranscript = ""
            var volatileTranscript = ""
            do {
                for try await result in transcriber.results {
                    guard let self = self, self.generation == thisGeneration else { break }
                    let text = String(result.text.characters)

                    if result.isFinal {
                        finalizedTranscript += text
                        volatileTranscript = ""
                    } else {
                        volatileTranscript = text
                    }

                    let fullText = finalizedTranscript + volatileTranscript
                    self.invokeCallback(eventType: 0, text: fullText, generation: thisGeneration)
                }
                // Results stream ended — emit final + closed
                guard let self = self, self.generation == thisGeneration else { return }
                let finalText = finalizedTranscript + volatileTranscript
                if !finalText.isEmpty {
                    self.invokeCallback(eventType: 2, text: finalText, generation: thisGeneration)
                }
                self.invokeCallback(eventType: 5, text: nil, generation: thisGeneration)
            } catch is CancellationError {
                // Normal cancellation
            } catch {
                guard let self = self, self.generation == thisGeneration else { return }
                self.invokeCallback(eventType: 3, text: error.localizedDescription, generation: thisGeneration)
                self.invokeCallback(eventType: 5, text: nil, generation: thisGeneration)
            }
        }

        return true
    }
}
