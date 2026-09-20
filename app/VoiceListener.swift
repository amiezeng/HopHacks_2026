import AVFoundation
import Speech

@MainActor
final class VoiceListener: ObservableObject {
    @Published private(set) var isListening = false
    /// Deliberately not `@Published`: no view reads it, and `ObservableObject` invalidates *every*
    /// observer on any published change — so a partial result (the recognizer sends one every few
    /// hundredths of a second while someone is talking) rebuilt the whole of `MainScreen`,
    /// `HomeScreen` and `ContentView`, artboard and all, for a string nothing draws.
    private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var commands: [String: [String]] = [:]
    private var onCommand: ((String) -> Void)?
    private var onUtterance: ((String) -> Void)?
    private var silenceAfterSpeech: TimeInterval = 2
    private var silenceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var isStarting = false
    private var wantsListening = false
    private var sessionID = 0

    /// Listens until one of the command keywords is heard, then stops and calls `onCommand` with that command's name.
    /// If `onUtterance` is set, it also stops once the user has spoken and then stayed silent for
    /// `silenceAfterSpeech` seconds, passing the full transcript. The silence timer only starts after the first word.
    func start(
        commands: [String: [String]],
        onCommand: @escaping (String) -> Void,
        onUtterance: ((String) -> Void)? = nil,
        silenceAfterSpeech: TimeInterval = 2
    ) async {
        self.commands = commands
        self.onCommand = onCommand
        self.onUtterance = onUtterance
        self.silenceAfterSpeech = silenceAfterSpeech
        wantsListening = true
        restartTask?.cancel()
        await beginSession()
    }

    func stop() {
        wantsListening = false
        restartTask?.cancel()
        restartTask = nil
        endSession()
    }

    private func beginSession() async {
        guard wantsListening, !isListening, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard await requestPermissions() else { return }
        // stop() may have been called while the permission prompt was showing
        guard wantsListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            print("Speech recognizer unavailable")
            return
        }

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.contextualStrings = commands.values.flatMap { $0 }
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            // Activating the session and starting the engine both block the caller for tens of
            // milliseconds. This class is on the main actor, so run them off it — starting to listen
            // used to stutter whatever the screen was animating.
            let engine = Engine(engine: audioEngine)
            try await Task.detached(priority: .userInitiated) {
                // The session must be configured first: before that (or mid-route-change) the input
                // format reports 0 Hz / 0 channels and installTap asserts.
                try Speaker.configureAudioSession()
                engine.engine.inputNode.removeTap(onBus: 0)
                try Self.installTap(on: engine.engine.inputNode, feeding: request)
                engine.engine.prepare()
                try engine.engine.start()
            }.value

            sessionID += 1
            let id = sessionID
            task = Self.recognize(with: recognizer, request: request) { [weak self] text, finished in
                Task { @MainActor in self?.handle(text: text, finished: finished, session: id) }
            }
            self.request = request
            transcript = ""
            isListening = true
        } catch {
            print("Voice listener error: \(error)")
            endSession()
        }
    }

    private func endSession() {
        sessionID += 1
        silenceTask?.cancel()
        silenceTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }

    private func handle(text: String?, finished: Bool, session: Int) {
        // Late callbacks from a cancelled session must not affect a newer one.
        guard session == sessionID else { return }

        if let text {
            let changed = text != transcript
            transcript = text
            if let command = matchedCommand(in: text) {
                stop()
                onCommand?(command)
                return
            }
            if onUtterance != nil, changed, !text.isEmpty {
                restartSilenceTimer(session: session)
            }
        }

        if finished {
            if onUtterance != nil, !transcript.isEmpty {
                finishUtterance()
                return
            }
            // The recognizer times out after a stretch of silence, so keep listening while the screen wants it.
            endSession()
            if wantsListening {
                restartTask?.cancel()
                restartTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await beginSession()
                }
            }
        }
    }

    private func restartSilenceTimer(session: Int) {
        silenceTask?.cancel()
        silenceTask = Task {
            try? await Task.sleep(for: .seconds(silenceAfterSpeech))
            guard !Task.isCancelled, session == sessionID else { return }
            finishUtterance()
        }
    }

    private func finishUtterance() {
        let text = transcript
        let callback = onUtterance
        stop()
        callback?(text)
    }

    private func matchedCommand(in text: String) -> String? {
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'"))
        let words = text.lowercased().components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        let padded = " " + words.joined(separator: " ") + " "
        return commands.first { _, keywords in
            keywords.contains { padded.contains(" \($0) ") }
        }?.key
    }

    private func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    // These closures run on audio/recognition threads, so they're built outside the main actor.
    /// Carries the engine off the main actor to be started. `AVAudioEngine` isn't `Sendable`; only one
    /// session is ever being started or stopped at a time (`isStarting` guards it).
    private struct Engine: @unchecked Sendable {
        let engine: AVAudioEngine
    }

    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoiceListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone input format unavailable"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onUpdate: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            onUpdate(result?.bestTranscription.formattedString, result?.isFinal == true || error != nil)
        }
    }
}
