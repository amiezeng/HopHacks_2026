import AVFoundation
import Speech

@MainActor
final class VoiceListener: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var commands: [String: [String]] = [:]
    private var onCommand: ((String) -> Void)?
    private var wantsListening = false
    private var sessionID = 0

    /// Listens until one of the command keywords is heard, then stops and calls `onCommand` with that command's name.
    func start(commands: [String: [String]], onCommand: @escaping (String) -> Void) async {
        self.commands = commands
        self.onCommand = onCommand
        wantsListening = true
        await beginSession()
    }

    func stop() {
        wantsListening = false
        endSession()
    }

    private func beginSession() async {
        guard wantsListening, !isListening, await requestPermissions() else { return }
        // stop() may have been called while the permission prompt was showing
        guard wantsListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            print("Speech recognizer unavailable")
            return
        }

        do {
            try Speaker.configureAudioSession()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.contextualStrings = commands.values.flatMap { $0 }
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            Self.installTap(on: audioEngine.inputNode, feeding: request)
            audioEngine.prepare()
            try audioEngine.start()

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
            transcript = text
            print("Heard: \(text)")
            if let command = matchedCommand(in: text) {
                stop()
                onCommand?(command)
                return
            }
        }

        if finished {
            // The recognizer times out after a stretch of silence, so keep listening while the screen wants it.
            endSession()
            if wantsListening {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    await beginSession()
                }
            }
        }
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
    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
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
