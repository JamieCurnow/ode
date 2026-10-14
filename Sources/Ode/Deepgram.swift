import Foundation
import Security

/// The user's own Deepgram API key, kept in the login Keychain.
enum DeepgramKey {
    private static let service = "Ode Deepgram"
    private static let account = "deepgram"

    /// Read once and cached: a key Ode didn't save itself (e.g. added with the `security` CLI) makes macOS
    /// ask for the login password before Ode can read it, so don't go back to the Keychain every dictation.
    @MainActor private static var cached: String??

    /// The key if it's already been read, without touching the Keychain. Used mid-dictation, where a
    /// password prompt would steal focus from the held key.
    @MainActor static var unlocked: String? { cached ?? nil }

    /// Reads the key, which may show macOS's password prompt. Never call this while a menu is open:
    /// the menu holds the keyboard, so the prompt can't be typed into and the menu freezes.
    @MainActor static func read() -> String? {
        if let cached { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let key = status == errSecSuccess ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only cache a definite answer, so a dismissed Keychain prompt can be retried.
        if status == errSecSuccess || status == errSecItemNotFound { cached = .some(trimmed) }
        return trimmed
    }

    /// Whether a key is saved. Only looks at the item's attributes, which never prompts.
    @MainActor static var exists: Bool {
        if let cached { return cached?.isEmpty == false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    @MainActor @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: service,
            kSecValueData as String: Data(key.utf8),
        ]
        let ok = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        cached = ok ? .some(key) : nil
        return ok
    }

    @MainActor static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        cached = .some(nil)
    }

    /// Checks the key against Deepgram. nil means Deepgram couldn't be reached, so we can't tell.
    static func validate(_ key: String) async -> Bool? {
        var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return http.statusCode == 200
    }
}

/// One dictation streamed live to Deepgram nova-3: audio goes up as you talk, the transcript comes
/// back as you talk, and `finish()` returns the final text a few hundred ms after the key is released.
@MainActor
final class DeepgramStream {
    /// The running transcript (finalised + in-progress words), for the live overlay.
    var onUpdate: ((String) -> Void)?
    private(set) var failure: String?

    private nonisolated let task: URLSessionWebSocketTask
    private let session: URLSession
    private var finals: [String] = []
    private var interim = ""
    private var finalized: CheckedContinuation<Void, Never>?
    private var closed = false

    var transcript: String {
        (finals + [interim]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    init(key: String, vocabulary: [String], language: String) {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var query = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        // Keyterm prompting: names and jargon from the style guide (Deepgram allows up to 100).
        query += vocabulary.prefix(100).map { URLQueryItem(name: "keyterm", value: $0) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
    }

    func start() {
        task.resume()
        receive()
    }

    /// Called from the audio thread with 16 kHz mono samples. Sends are queued until the socket opens.
    nonisolated func send(_ samples: [Float]) {
        var pcm = Data(count: samples.count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                out[i] = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            }
        }
        task.send(.data(pcm)) { _ in }
    }

    /// Flush what Deepgram is still holding and return the full transcript, or nil if it failed or
    /// didn't answer in time (the caller then falls back to on-device transcription).
    func finish(timeout: TimeInterval) async -> String? {
        if failure == nil {
            task.send(.string(#"{"type":"Finalize"}"#)) { _ in }
            let answered = try? await withDeadline(timeout) {
                await withCheckedContinuation { continuation in
                    if self.failure != nil || self.closed { continuation.resume() } else { self.finalized = continuation }
                }
                return true
            }
            if answered == nil {
                failure = "no answer within \(String(format: "%.1f", timeout))s"
            }
        }
        close()
        guard failure == nil else { return nil }
        let text = finals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func cancel() {
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        task.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
        resumeFinalized()
    }

    private func resumeFinalized() {
        finalized?.resume()
        finalized = nil
    }

    private func receive() {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    switch result {
                    case let .success(message):
                        if case let .string(text) = message { self.handle(text) }
                        self.receive()
                    case let .failure(error):
                        self.failure = self.describe(error)
                        self.resumeFinalized()
                    }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              json["type"] as? String == "Results",
              let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String
        else { return }
        if json["is_final"] as? Bool == true {
            if !transcript.isEmpty { finals.append(transcript) }
            interim = ""
        } else {
            interim = transcript
        }
        onUpdate?(self.transcript)
        if json["from_finalize"] as? Bool == true { resumeFinalized() }
    }

    private func describe(_ error: Error) -> String {
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            switch http.statusCode {
            case 401, 403: return "Deepgram rejected the API key"
            case 402: return "the Deepgram account is out of credit"
            default: return "Deepgram returned HTTP \(http.statusCode)"
            }
        }
        return error.localizedDescription
    }
}
