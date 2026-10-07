import AVFoundation
import Speech

/// Live on-device speech-to-text using macOS 26's SpeechAnalyzer + DictationTranscriber.
/// Models are managed by the OS (AssetInventory), so nothing for us to download or lose.
@MainActor
final class Transcriber {
    /// Called with the full running transcript (finalised + volatile) as it changes.
    var onUpdate: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var locale: Locale?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""

    private(set) var isRunning = false

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
        guard !isRunning else { return }
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
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            throw OdeError.audioFormat
        }

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { buffer, _ in
            let ratio = analyzerFormat.sampleRate / micFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
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
            if error == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
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
}

enum OdeError: LocalizedError {
    case unsupportedLocale, audioFormat, claudeNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: "Your language isn't supported by macOS dictation"
        case .audioFormat: "Couldn't set up the microphone audio format"
        case .claudeNotFound: "Couldn't find the claude CLI"
        }
    }
}
