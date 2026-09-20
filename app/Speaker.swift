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

    /// True only while a clip is actually coming out of the speaker. `DistanceBeepController` checks it
    /// before its own speech: the two use different engines (this one plays ElevenLabs clips, that one
    /// synthesises on device), so neither can hear the other and they would otherwise talk at once.
    ///
    /// Deliberately not `worker != nil`: the worker is also set for the whole of a *network* fetch, and
    /// gating the guidance voice on that meant a slow or unreachable ElevenLabs left the user in
    /// silence with no idea where their hand was.
    var isSpeaking: Bool { player?.isPlaying == true }

    /// Waits for the queue to drain. The timeout matters: four screens gate their microphone on this
    /// call, so without it one wedged fetch takes the whole app's voice control down with it.
    func waitUntilIdle(timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while worker != nil, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // The one audio session the talking half of the app runs on; `AudioLevels` asks for this same one
    // rather than its own, so nothing reconfigures the microphone under anything else's tap.
    //
    // .defaultToSpeaker keeps playback on the loudspeaker; recording mode otherwise uses the earpiece.
    // .measurement keeps iOS's own processing off the input — automatic gain control above all. The
    // water in `WaterVisualizer` is drawn from raw levels, and AGC winds a silent room up to a voice's
    // reading (and pumps it over a few seconds, which reads as syllables); it is also the mode Apple's
    // own speech-recognition sample records in.
    //
    // Call this off the main thread: both calls are synchronous IPC to the media server and take long
    // enough to drop frames. The category is only set when it isn't already what we want, because
    // `DistanceBeepController` sets its own and every switch costs that again (and can restart a
    // running engine under it).
    nonisolated static func configureAudioSession() throws {
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .measurement || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .measurement, options: options)
        }
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

    // Reading and writing the cache is file I/O, and this class is on the main actor: done here it
    // stalls whatever is animating on the screen that started talking. Both go off the actor.
    private func loadAudio(for text: String) async throws -> Data {
        let file = cacheURL(for: text)
        let cached = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
        if let cached { return cached }

        let audio = try await fetchAudio(for: text)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? audio.write(to: file)
        }
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
        // Activating the audio session talks to the media server and decoding the clip parses it, and
        // both block the thread they're on for long enough to drop frames. On the main actor — where
        // this class lives — that landed in the middle of the screens' entrance animations, which is
        // what made them stutter. Only handing the prepared player its cue comes back to the actor.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.configureAudioSession()
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            return Prepared(player: player)
        }.value
        // Re-checked after the hop off and back: `stop()` cancels this task, but a cancellation that
        // lands while the clip is being decoded used to arrive too late to matter — `stop()` would
        // stop the *old* player, and then this one would start anyway, playing the line the screen we
        // just left was in the middle of saying.
        guard !Task.isCancelled else { return }
        let newPlayer = prepared.player
        newPlayer.delegate = self
        player = newPlayer

        // `audioPlayerDidFinishPlaying` never arrives if playback is refused or interrupted — and a
        // continuation that is never resumed wedges `worker` non-nil for good, which stops the queue,
        // hangs every `waitUntilIdle`, and so silences the app until it is relaunched.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(newPlayer.duration, 1) + 2))
            guard !Task.isCancelled else { return }
            print("Speaker: playback never reported finishing, moving on")
            self?.finishPlayback()
        }
        await withCheckedContinuation { continuation in
            playbackFinished = continuation
            if !newPlayer.play() {
                print("Speaker: AVAudioPlayer refused to start")
                finishPlayback()
            }
        }
        watchdog.cancel()
    }

    /// Carries a player built off the main actor back to it. `AVAudioPlayer` isn't `Sendable`; this one
    /// is handed straight over and only ever used on the actor from here on.
    private struct Prepared: @unchecked Sendable {
        let player: AVAudioPlayer
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
