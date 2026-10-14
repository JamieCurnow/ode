@preconcurrency import AVFoundation
import Speech

/// Live on-device speech-to-text using macOS 26's SpeechAnalyzer + DictationTranscriber.
/// Models are managed by the OS (AssetInventory), so nothing for us to download or lose.
@MainActor
final class Transcriber {
    /// Called with the full running transcript (finalised + volatile) as it changes.
    var onUpdate: ((String) -> Void)?
    /// Called on the audio thread with each chunk of 16 kHz mono audio, e.g. to stream it to Deepgram.
    /// Set before `start()`; it's cleared when the dictation ends.
    var audioSink: (([Float]) -> Void)?

    /// The whole dictation as 16 kHz mono samples, for Whisper to transcribe after release.
    var recordedSamples: [Float] { recorder.samples }
    private var recorder = SampleRecorder()
    static let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private var locale: Locale?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""

    private(set) var isRunning = false
    /// Set once this transcriber has been given up on, see `abandon()`.
    private var abandoned = false

    var transcript: String {
        (finalText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve a supported locale and make sure the speech model is installed.
    func prepare() async throws {
        var match = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
        if match == nil {
            match = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-GB"))
        }
        guard let supported = match else { throw OdeError.unsupportedLocale }
        locale = supported
        let module = makeModule(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.info("Downloading speech model for \(supported.identifier)…")
            try await request.downloadAndInstall()
        }
        try await AssetInventory.reserve(locale: supported)
        Log.info("Speech model ready (\(supported.identifier))")
    }

    private func makeModule(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )
    }

    func start() async throws {
        guard !isRunning, !abandoned else { return }
        if locale == nil { try await prepare() }
        guard let locale else { throw OdeError.unsupportedLocale }

        finalText = ""
        volatileText = ""

        let module = makeModule(locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        self.analyzer = analyzer
        try await applyVocabulary(to: analyzer)

        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module], considering: micFormat
        ) else { throw OdeError.audioFormat }
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat),
              let recordConverter = AVAudioConverter(from: micFormat, to: Self.recordingFormat)
        else { throw OdeError.audioFormat }
        let recorder = SampleRecorder()
        self.recorder = recorder
        let sink = audioSink

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        guard let self else { return }
                        if isFinal {
                            self.finalText += text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        self.onUpdate?(self.transcript)
                    }
                }
            } catch {
                Log.error("Transcription results error: \(error)")
            }
        }

        try await analyzer.start(inputSequence: stream)

        // Given up on while starting (the start stalled and Ode moved on): don't turn the mic on.
        guard !abandoned else {
            continuation.finish()
            resultsTask?.cancel()
            await analyzer.cancelAndFinishNow()
            throw OdeError.abandoned
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { buffer, _ in
            if let out = Self.convert(buffer, with: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: out))
            }
            if let out = Self.convert(buffer, with: recordConverter, to: Self.recordingFormat),
               let channel = out.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
                recorder.append(samples)
                sink?(samples)
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// Bias recognition towards names and jargon from the style guide's Vocabulary section.
    private func applyVocabulary(to analyzer: SpeechAnalyzer) async throws {
        let words = StyleGuide.vocabulary()
        guard !words.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = words
        try await analyzer.setContext(context)
    }

    /// Transcribe an audio file through the same pipeline, for testing accuracy without the mic.
    func transcribeFile(_ url: URL, useVocabulary: Bool) async throws -> String {
        if locale == nil { try await prepare() }
        guard let locale else { throw OdeError.unsupportedLocale }
        let module = makeModule(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        if useVocabulary { try await applyVocabulary(to: analyzer) }
        let collector = Task {
            var text = ""
            for try await result in module.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop listening and return the final transcript.
    func stop() async -> String {
        guard isRunning else { return transcript }
        isRunning = false
        audioSink = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.error("Finalize error: \(error)")
        }
        // Results stream ends once the analyzer finishes; wait so we have every final result.
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        return transcript
    }

    /// Abandon the current dictation without producing anything.
    func cancel() {
        audioSink = nil
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }

    /// Give up on this transcriber for good, e.g. when it stalled or the Mac slept, so a fresh one can
    /// take over. Safe at any point: a start() still in flight bails out instead of turning the mic on.
    func abandon() {
        abandoned = true
        onUpdate = nil
        cancel()
    }
}

/// Which recogniser produces the transcript that gets cleaned up and pasted. Apple's always drives the
/// live preview (unless Deepgram is streaming), and is the last fallback for the others.
enum SpeechEngine: String, CaseIterable {
    case whisper, apple, deepgram

    var title: String {
        switch self {
        case .whisper: "On Device: Whisper (Most Accurate)"
        case .apple: "On Device: Apple (No Download)"
        case .deepgram: "Deepgram (Your API Key)"
        }
    }

    /// The user's language for Whisper ("en", "fr"…), from the system locale.
    static var languageCode: String { Locale.current.language.languageCode?.identifier ?? "en" }
}

/// Collects samples from the audio thread for reading back on the main thread.
final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []

    func append(_ samples: [Float]) {
        lock.lock()
        buffer += samples
        lock.unlock()
    }

    var samples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

enum OdeError: LocalizedError {
    case unsupportedLocale, audioFormat, claudeNotFound, abandoned

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: "Your language isn't supported by macOS dictation"
        case .audioFormat: "Couldn't set up the microphone audio format"
        case .claudeNotFound: "Couldn't find the claude CLI"
        case .abandoned: "Dictation was reset"
        }
    }
}
