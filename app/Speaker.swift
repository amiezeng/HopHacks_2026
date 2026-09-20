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

/// The app's voice. Everything spoken anywhere goes through here, so there is one voice and one queue:
/// two engines talking at once is two voices over each other, and that is what the guidance on the Find
/// screen used to sound like (ElevenLabs asking the question, the on-device synthesiser calling the
/// directions).
///
/// Apple's synthesiser is still here, as the net under it: a line that can't be fetched — no network, a
/// rejected key, a slow request — is spoken on device rather than dropped. Losing the voice is losing the
/// screen for the person using it, so this must degrade rather than fail.
@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    // Static so the conversational agent can be handed the same voice: `AgentSession` overrides its
    // agent's dashboard voice with these, or the user would hear one voice ask the question and
    // another answer it two seconds later.
    static let voiceID = "vChnJZ1Cu89g2XXumPfT"
    static let stability = 0.8
    static let speed = 1.1
    private let modelID = "eleven_flash_v2_5"
    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var playbackFinished: CheckedContinuation<Void, Never>?
    private let onDevice = AVSpeechSynthesizer()
    private var onDeviceFinished: CheckedContinuation<Void, Never>?

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
                    await speakOnDevice(text)
                }
            }
            if !Task.isCancelled { worker = nil }
        }
    }

    /// True only while something is actually coming out of the speaker — a fetched clip or, when that
    /// failed, the on-device voice saying the same line. Used to duck the guidance tone under speech.
    var isSpeaking: Bool { player?.isPlaying == true || onDevice.isSpeaking }

    /// Anything queued, being fetched, or coming out of the speaker. A caller deciding whether to *add*
    /// a line asks this one rather than `isSpeaking`: the fetch is a network round trip, and two lines
    /// queued while it runs play back to back with nothing in between. `DistanceBeepController` holds
    /// its cues back on this, which is what keeps the queue at most one line deep.
    ///
    /// This used to be an unbounded wait, and gating the guidance voice on it meant a slow or
    /// unreachable ElevenLabs left the user in silence with no idea where their hand was. It is safe to
    /// wait on now because the fetch can't take longer than `timeoutInterval` and a failed one is
    /// spoken on device rather than dropped — the line always arrives, and within a few seconds.
    var isBusy: Bool { worker != nil }

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
        onDevice.stopSpeaking(at: .immediate)
        finishOnDevice()
    }

    // The key includes voice, model and settings, so changing any of them regenerates the audio.
    private func cacheURL(for text: String) -> URL {
        let key = "\(Self.voiceID)|\(modelID)|\(Self.stability)|\(Self.speed)|\(text)"
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
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(Self.voiceID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // The default is 60 seconds. Nothing said here is worth waiting that long for — past a few
        // seconds the line has been overtaken by whatever the user did next, and the on-device voice
        // that covers for a failure should get its turn while the line still means something.
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONEncoder().encode(
            SpeechRequest(
                text: text,
                model_id: modelID,
                voice_settings: .init(stability: Self.stability, speed: Self.speed)
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // A key that isn't a key is the usual cause, and on its own it is invisible: every
            // line fails the same way and the app simply never speaks. Worth calling out by
            // name — the dashboard shows each key's *id* next to it, which looks like a key.
            if status == 401 || body.contains("invalid_api_key") {
                print("ElevenLabs rejected elevenLabsAPIKey in Secrets.swift — real keys start with \"sk_\": \(body)")
            } else {
                print("ElevenLabs error \(status): \(body)")
            }
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

    /// Says a line with Apple's synthesiser, when ElevenLabs couldn't give us one. Returns once it has
    /// been spoken, so the queue behaves exactly as it does for a fetched clip.
    private func speakOnDevice(_ text: String) async {
        print("Speaker: saying \"\(text)\" on device instead")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        utterance.volume = 1
        onDevice.delegate = self
        // Same reasoning as the player's watchdog below: a `didFinish` that never arrives would wedge
        // `worker` non-nil, and the app's voice with it.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(text.count) / 12 + 3))
            guard !Task.isCancelled else { return }
            print("Speaker: on-device speech never reported finishing, moving on")
            self?.finishOnDevice()
        }
        await withCheckedContinuation { continuation in
            onDeviceFinished = continuation
            onDevice.speak(utterance)
        }
        watchdog.cancel()
    }

    private func finishOnDevice() {
        onDeviceFinished?.resume()
        onDeviceFinished = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in finishOnDevice() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in finishOnDevice() }
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
