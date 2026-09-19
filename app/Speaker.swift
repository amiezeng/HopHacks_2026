import AVFoundation
import CryptoKit

private struct SpeechRequest: Encodable {
    struct VoiceSettings: Encodable {
        let stability: Double
        let speed: Double
    }

    let text: String
    let model_id: String
    let voice_settings: VoiceSettings
}

@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate {
    static let shared = Speaker()

    private let voiceID = "vChnJZ1Cu89g2XXumPfT"
    private let modelID = "eleven_flash_v2_5"
    private let stability = 0.8
    private let speed = 1.1
    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var playbackFinished: CheckedContinuation<Void, Never>?

    func speak(_ text: String) {
        queue.append(text)
        guard worker == nil else { return }
        worker = Task {
            while !Task.isCancelled, !queue.isEmpty {
                let text = queue.removeFirst()
                do {
                    let audio = try await loadAudio(for: text)
                    guard !Task.isCancelled else { return }
                    try await play(audio)
                } catch {
                    if Task.isCancelled { return }
                    print("Speaker error: \(error)")
                }
            }
            if !Task.isCancelled { worker = nil }
        }
    }

    func waitUntilIdle() async {
        while worker != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // .defaultToSpeaker keeps playback on the loudspeaker; recording mode otherwise uses the earpiece.
    nonisolated static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    func stop() {
        queue.removeAll()
        worker?.cancel()
        worker = nil
        player?.stop()
        finishPlayback()
    }

    // The key includes voice, model and settings, so changing any of them regenerates the audio.
    private func cacheURL(for text: String) -> URL {
        let key = "\(voiceID)|\(modelID)|\(stability)|\(speed)|\(text)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speech", isDirectory: true)
            .appendingPathComponent("\(hash).mp3")
    }

    private func loadAudio(for text: String) async throws -> Data {
        let file = cacheURL(for: text)
        if let cached = try? Data(contentsOf: file) { return cached }

        let audio = try await fetchAudio(for: text)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? audio.write(to: file)
        return audio
    }

    private func fetchAudio(for text: String) async throws -> Data {
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONEncoder().encode(
            SpeechRequest(
                text: text,
                model_id: modelID,
                voice_settings: .init(stability: stability, speed: speed)
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("ElevenLabs error: \(String(data: data, encoding: .utf8) ?? "")")
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func play(_ data: Data) async throws {
        try Self.configureAudioSession()
        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = self
        player = newPlayer
        await withCheckedContinuation { continuation in
            playbackFinished = continuation
            newPlayer.play()
        }
    }

    private func finishPlayback() {
        playbackFinished?.resume()
        playbackFinished = nil
    }

    // AVAudioPlayer.stop() doesn't call this, so stop() resumes the continuation itself.
    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(finished)
        Task { @MainActor in
            if let current = player, ObjectIdentifier(current) == id { finishPlayback() }
        }
    }
}
