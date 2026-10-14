import CryptoKit
import Foundation
import whisper

/// On-device transcription with Whisper large-v3-turbo (whisper.cpp, Metal). Runs on the whole clip
/// once the key is released, so the live preview still comes from Apple's recogniser.
///
/// The model (574 MB, 5-bit quantised) only downloads once the user agrees to it. Until it's ready,
/// or if it fails, Ode uses Apple's transcript instead.
@MainActor
final class WhisperEngine {
    enum Status: Equatable {
        /// Not loaded yet, whether or not the model file is on disk. `prepare()` sorts it out.
        case idle
        /// The model isn't on disk, and the user hasn't said to download it yet.
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var status: Status = .idle {
        didSet { onStatusChange?(status) }
    }
    var onStatusChange: ((Status) -> Void)?

    static let modelName = "ggml-large-v3-turbo-q5_0.bin"
    private static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)")!
    private static let modelSHA256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    static let modelSize = "574 MB"

    static var modelFile: URL {
        let dir = AppPaths.supportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(modelName)
    }

    /// whisper.cpp isn't thread-safe per context, so every call goes through this queue.
    private let queue = DispatchQueue(label: "ode.whisper", qos: .userInitiated)
    private var context: WhisperContext?
    private var download: ModelDownload?

    var isReady: Bool { status == .ready }

    /// The model isn't on disk and isn't on its way.
    var needsDownload: Bool {
        switch status {
        case .downloading, .loading, .ready: false
        default: !FileManager.default.fileExists(atPath: Self.modelFile.path)
        }
    }

    /// Load the model if it's on disk. Without it, `download` says whether to fetch it now, which only
    /// happens once the user has agreed to. Safe to call repeatedly.
    func prepare(download: Bool = false) {
        switch status {
        case .downloading, .loading, .ready: return
        default: break
        }
        if FileManager.default.fileExists(atPath: Self.modelFile.path) {
            load()
        } else if download {
            startDownload()
        } else {
            status = .notDownloaded
        }
    }

    /// Free the model's memory, e.g. when the user switches to another engine.
    func unload() {
        download?.cancel()
        download = nil
        let context = self.context
        self.context = nil
        queue.async { if let context { whisper_free(context.pointer) } }
        status = .idle
    }

    /// Free the model before the process exits. ggml's Metal teardown asserts (and crashes the app on
    /// Quit) if a model is still loaded when its static destructors run.
    func shutdown() {
        download?.cancel()
        download = nil
        guard let context else { return }
        self.context = nil
        queue.sync { whisper_free(context.pointer) }
    }

    private func startDownload() {
        Log.info("Downloading Whisper model (\(Self.modelSize))…")
        status = .downloading(0)
        let download = ModelDownload(from: Self.modelURL, sha256: Self.modelSHA256, to: Self.modelFile)
        self.download = download
        download.onProgress = { [weak self] fraction in
            guard let self, case .downloading = self.status else { return }
            self.status = .downloading(fraction)
        }
        download.onFinish = { [weak self] error in
            guard let self else { return }
            self.download = nil
            if let error {
                Log.error("Whisper model download failed: \(error.localizedDescription)")
                self.status = .failed("Download failed: \(error.localizedDescription)")
            } else {
                Log.info("Whisper model downloaded")
                self.load()
            }
        }
        download.start()
    }

    private func load() {
        status = .loading
        let path = Self.modelFile.path
        let started = Date()
        queue.async { [weak self] in
            Self.silenceLogs()
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            let context = whisper_init_from_file_with_params(path, params).map(WhisperContext.init)
            // The first run compiles Metal pipelines (~0.5s). Do it now, not on the first dictation.
            if let context {
                var warmup = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                warmup.print_progress = false
                let silence = [Float](repeating: 0, count: 16000)
                _ = silence.withUnsafeBufferPointer { whisper_full(context.pointer, warmup, $0.baseAddress, Int32($0.count)) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let context {
                        self.context = context
                        self.status = .ready
                        Log.info("Whisper model ready (\(Int(Date().timeIntervalSince(started) * 1000))ms to load)")
                    } else {
                        // A corrupt file won't get better on its own: remove it so it can be downloaded again.
                        try? FileManager.default.removeItem(atPath: path)
                        self.status = .failed("The Whisper model couldn't be loaded")
                        Log.error("Whisper model failed to load, removed it so it downloads again")
                    }
                }
            }
        }
    }

    /// Transcribe 16 kHz mono samples. `vocabulary` biases spelling towards those names and terms.
    /// Returns nil if the model isn't ready or nothing was recognised.
    func transcribe(_ samples: [Float], vocabulary: [String], language: String) async -> String? {
        guard status == .ready, let context else { return nil }
        let prompt = Self.prompt(from: vocabulary)
        return await withCheckedContinuation { continuation in
            queue.async {
                var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
                params.beam_search.beam_size = 5
                params.greedy.best_of = 5
                params.n_threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
                params.no_timestamps = true
                params.print_progress = false
                params.print_realtime = false
                params.print_special = false
                params.print_timestamps = false
                params.suppress_nst = true
                let result: Int32 = language.withCString { lang in
                    prompt.withCString { promptPtr in
                        params.language = lang
                        params.initial_prompt = prompt.isEmpty ? nil : promptPtr
                        return samples.withUnsafeBufferPointer { buffer in
                            whisper_full(context.pointer, params, buffer.baseAddress, Int32(buffer.count))
                        }
                    }
                }
                guard result == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                var text = ""
                for i in 0..<whisper_full_n_segments(context.pointer) {
                    if let segment = whisper_full_get_segment_text(context.pointer, i) { text += String(cString: segment) }
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }

    /// Whisper only reads the first ~224 tokens of its prompt, so keep to whole terms within ~700 characters.
    nonisolated static func prompt(from vocabulary: [String]) -> String {
        var prompt = ""
        for term in vocabulary {
            let next = prompt.isEmpty ? term : "\(prompt), \(term)"
            if next.count > 700 { break }
            prompt = next
        }
        return prompt
    }

    /// whisper.cpp prints a lot to stderr. Keep only warnings and errors, in our own log.
    private nonisolated static func silenceLogs() {
        whisper_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            // It looks for an optional Core ML encoder first and falls back to Metal; that's expected.
            if !line.isEmpty, !line.contains("Core ML") { Log.info("whisper: \(line)") }
        }, nil)
    }
}

/// A loaded model. Only ever used from WhisperEngine's queue.
private final class WhisperContext: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

/// Downloads a file with progress, checks its SHA-256, then moves it into place.
@MainActor
final class ModelDownload: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onFinish: ((Error?) -> Void)?

    private let source: URL
    private let sha256: String
    private let destination: URL
    private var session: URLSession?
    private var lastReported = -1.0

    init(from source: URL, sha256: String, to destination: URL) {
        self.source = source
        self.sha256 = sha256
        self.destination = destination
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: source).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        let fraction = Double(written) / Double(expected)
        MainActor.assumeIsolated {
            // Every whole percent is plenty for a progress readout.
            guard fraction - lastReported >= 0.01 else { return }
            lastReported = fraction
            onProgress?(fraction)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so verify and move it now.
        let result: Error? = {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                return DownloadError.http(http.statusCode)
            }
            do {
                let data = try Data(contentsOf: location, options: .alwaysMapped)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == sha256 else { return DownloadError.checksum }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                return nil
            } catch {
                return error
            }
        }()
        MainActor.assumeIsolated {
            session.finishTasksAndInvalidate()
            self.session = nil
            onFinish?(result)
            onFinish = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            self.session = nil
            onFinish?(error)
            onFinish = nil
        }
    }

    enum DownloadError: LocalizedError {
        case http(Int), checksum
        var errorDescription: String? {
            switch self {
            case let .http(code): "the server returned HTTP \(code)"
            case .checksum: "the file was corrupted in transit"
            }
        }
    }
}
