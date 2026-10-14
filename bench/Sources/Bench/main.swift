import FluidAudio
import Foundation

// Parakeet (FluidAudio) on every clip in a folder, as JSON lines on stdout.
//
//   Bench parakeet <v2|v3|ultra> <clips dir> [vocab.txt]
//
// With a vocab file (one term per line), the transcript is also rescored with FluidAudio's CTC
// vocabulary boosting and printed as a second engine ("parakeet-v2+vocab").
// Model load and download happen before timing, and the first clip is run once untimed to warm up.

@main
struct Bench {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 4, args[1] == "parakeet" else {
            FileHandle.standardError.write("usage: Bench parakeet <v2|v3|ultra> <clips dir> [vocab.txt]\n".data(using: .utf8)!)
            exit(2)
        }
        do {
            try await runParakeet(versionName: args[2], dir: URL(fileURLWithPath: args[3]), vocabFile: args.count > 4 ? args[4] : nil)
        } catch {
            FileHandle.standardError.write("Bench failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func runParakeet(versionName: String, dir: URL, vocabFile: String?) async throws {
        let version: AsrModelVersion
        switch versionName {
        case "v2": version = .v2
        case "v3": version = .v3
        case "ultra": version = .ultra
        default: throw NSError(domain: "Bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown version \(versionName)"])
        }
        let engine = "parakeet-\(versionName)"

        let models = try await AsrModels.downloadAndLoad(version: version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)

        var boosting: VocabularyBoostingSession?
        if let vocabFile {
            let terms = try String(contentsOfFile: vocabFile, encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { CustomVocabularyTerm(text: $0) }
            let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            boosting = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctc)
        }

        let clips = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let converter = AudioConverter()

        if let first = clips.first {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            _ = try await asr.transcribe(try converter.resampleAudioFile(first), decoderState: &state)
        }

        for clip in clips {
            let id = clip.deletingPathExtension().lastPathComponent
            let samples = try converter.resampleAudioFile(clip)
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let start = Date()
            let result = try await asr.transcribe(samples, decoderState: &state)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            emit(id: id, engine: engine, text: result.text, ms: ms)

            if let boosting {
                let boostStart = Date()
                let rescored = await boosting.rescore(
                    text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
                // Time on top of the plain transcription, since it runs after it.
                let extra = Int(Date().timeIntervalSince(boostStart) * 1000)
                emit(id: id, engine: engine + "+vocab", text: rescored?.text ?? result.text, ms: ms + extra)
            }
        }
    }

    static func emit(id: String, engine: String, text: String, ms: Int) {
        let row: [String: Any] = ["id": id, "engine": engine, "text": text, "ms": ms]
        if let data = try? JSONSerialization.data(withJSONObject: row) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }
}
