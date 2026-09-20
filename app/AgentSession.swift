import Combine
import Foundation
import ElevenLabs
// The agent's audio runs through LiveKit, and this is the only place the app reaches into it —
// see `prepareAudio`, which stops it from taking the audio session off everything else.
import LiveKit

@MainActor
final class AgentSession: ObservableObject {
    enum Status {
        case idle, connecting, listening, speaking, thinking

        init(_ state: ElevenLabs.AgentState) {
            switch state {
            case .listening: self = .listening
            case .speaking: self = .speaking
            case .thinking: self = .thinking
            }
        }
    }

    /// Called when the user says a phrase like "go back" or "end conversation".
    var onEndRequested: (() -> Void)?

    /// Called when the agent asks for a rescan (the "rescan" tool). Returns the newly scanned lines.
    var onRescan: (() async -> [String])?

    /// Called when the conversation ends on its own: it never connected, or the server dropped it. Not
    /// called by `stop()` — the screen asked for that one and already knows. A screen whose audio depends
    /// on the agent needs this, or a refused connection just leaves it silent with nothing to react to.
    var onEnded: (() -> Void)?

    /// Every phrase the user says, once it has been checked against the keywords above. This is the
    /// agent's transcription standing in for the one `VoiceListener` used to produce — `ContentView`
    /// reads the object to find out of it.
    var onTranscript: ((String) -> Void)?

    /// Saying one of these ends the screen. Overridable: while the user is naming an object, a bare
    /// "back" or "bye" is as likely to be part of the name as a command, so `ContentView` narrows it.
    var endKeywords = [
        "go back", "end conversation", "end the conversation", "end call", "end the call",
        "take me back", "goodbye", "bye", "exit", "quit", "i'm done", "i am done", "we're done",
        "stop the conversation", "stop conversation"
    ]

    // Saying one of these starts a rescan right away. The agent hears the request too and usually asks for the result
    // through its rescan tool, which is then answered with this same scan instead of starting another one.
    private let rescanKeywords = [
        "rescan", "re scan", "scan again", "scan it again", "scan one more time", "scan once more",
        "try again", "another scan", "new scan"
    ]

    // The mic only opens once the agent has been quiet for this long, and never before the estimated end of
    // whatever it last said (the SDK's "listening" state also flips on during the agent's pauses and on noise).
    private let steadyListening: TimeInterval = 0.25
    private let charactersPerSecond = 16.0
    private let greetingGrace: TimeInterval = 5

    /// What the pill shows. Derived from the real microphone state, not the SDK's raw agent state, which flickers.
    @Published private(set) var status: Status = .idle
    var isRunning: Bool { status != .idle }

    private var conversation: Conversation?
    private var startTask: Task<Void, Never>?
    private var stateSubscription: AnyCancellable?
    private var stopTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var micPolicyTask: Task<Void, Never>?
    private var toolSubscription: AnyCancellable?
    private var toolTask: Task<Void, Never>?
    private var handledToolCalls = Set<String>()
    private var holdingForTool = false
    private var rescanTask: Task<[String], Never>?
    private var isStopping = false
    private var personaPrompt: String?
    private var personaFirstMessage: String?
    private var pendingInitialMessage: String?
    private var retriedWithoutOverrides = false
    /// Whether the connection that is up was made with overrides. A refused override presents as a
    /// connection that is dropped before the agent says anything, and only one made with overrides is
    /// worth retrying without them.
    private var usedOverrides = false
    private var hasPersona: Bool { personaPrompt != nil || personaFirstMessage != nil }
    private var keywordFollowUp: Task<Void, Never>?
    private var lastRescan: (lines: [String], finishedAt: Date, delivered: Bool)?

    private var rawState: Status = .listening
    private var heardAgent = false
    // From connecting until the reply to our summary request starts, the agent is busy even though the SDK
    // reports it as quiet (it is waiting for the language model), so the microphone stays closed.
    private var initialMessagePending = false
    private var awaitingReplyUntil = Date.distantPast
    private var voiceHeard = false
    private var speakingUntil = Date.distantPast
    private var listeningSince: Date?
    private var desiredMuted = true
    private var appliedMuted: Bool?
    private var isApplyingMute = false

    private var agentIsBusy: Bool {
        rawState == .speaking || rawState == .thinking || Date() < speakingUntil
    }

    private var holdingForReply: Bool {
        initialMessagePending || holdingForTool || Date() < awaitingReplyUntil
    }

    private var listeningSteadily: Bool {
        guard let since = listeningSince else { return false }
        return Date().timeIntervalSince(since) >= steadyListening
    }

    /// `initialMessage` is sent to the agent as if the user had said it, once the agent's own greeting is done.
    ///
    /// `prompt`/`firstMessage` re-skin the one agent for the screen that is asking: the same agent ID backs
    /// both Find and Analyze, so Find hands over its own persona rather than needing a second agent. The
    /// voice is overridden either way, persona or not: it is the same voice `Speaker` has been talking in
    /// for the whole screen up to this point, and the agent's own dashboard voice is a different person
    /// answering the question Probe just asked.
    ///
    /// The agent has to allow that — `prompt.prompt`, `first_message` and the TTS voice, under Security on
    /// the ElevenLabs dashboard. An override the agent hasn't allowlisted is refused rather than ignored
    /// ("Override is not allowed for this AI agent"), and it takes the whole conversation down with it, so
    /// the connection is retried once as the agent is configured. The wrong persona is worth more than no
    /// agent: the screens fall back to on-device speech when this gives up, and that is the worse outcome.
    func start(initialMessage: String? = nil, prompt: String? = nil, firstMessage: String? = nil) {
        guard !isRunning else { return }
        initialMessagePending = initialMessage != nil
        holdingForTool = false
        rescanTask = nil
        lastRescan = nil
        handledToolCalls.removeAll()
        isStopping = false
        personaPrompt = prompt
        personaFirstMessage = firstMessage
        pendingInitialMessage = initialMessage
        retriedWithoutOverrides = false
        usedOverrides = false
        resetForConnection()
        beginConnecting(withOverrides: true)
    }

    /// Per-connection state, so a retry starts as clean as a first attempt.
    private func resetForConnection() {
        rawState = .listening
        heardAgent = false
        awaitingReplyUntil = .distantPast
        voiceHeard = false
        speakingUntil = .distantPast
        listeningSince = nil
        desiredMuted = true
        appliedMuted = nil
        isApplyingMute = false
    }

    private func beginConnecting(withOverrides: Bool) {
        status = .connecting
        startTask = Task { [self] in
            defer { startTask = nil }
            var useOverrides = withOverrides
            while true {
                do {
                    // Off the main actor: both halves of this are synchronous IPC to the media server.
                    try await Task.detached(priority: .userInitiated) { try Self.prepareAudio() }.value
                    try await connect(withOverrides: useOverrides)
                    return
                } catch {
                    guard useOverrides, !Task.isCancelled else {
                        print("Agent start failed: \(error)")
                        status = .idle
                        onEnded?()
                        return
                    }
                    print("Agent refused the overrides (\(error)) — retrying as it is configured")
                    retriedWithoutOverrides = true
                    useOverrides = false
                    resetForConnection()
                }
            }
        }
    }

    /// Puts the agent on the app's own audio session instead of letting LiveKit take the hardware.
    ///
    /// Left to itself, LiveKit configures the session as a *call*: `.playAndRecord` in `.videoChat` mode
    /// driven by Apple's Voice Processing I/O. That changes what comes out of the phone halfway through a
    /// screen — iOS swaps its media gain for the quieter call-tuned one, and a screen recording leaves
    /// call audio out altogether. On Analyze that was the seam: everything `Speaker` said before the label
    /// was read was on the recording, and everything the agent said after it was missing.
    ///
    /// So the two halves are made one. `isAutomaticConfigurationEnabled = false` leaves
    /// `Speaker.configureAudioSession` as the only thing in the app that ever sets a category — the same
    /// session the tone, the microphone and every spoken line already share — and LiveKit no longer
    /// deactivates it on its way out, which used to cut whatever was queued to say next. Disallowing the
    /// platform voice-processing path is the other half: instantiating VPIO makes iOS rewrite the mode to
    /// `.voiceChat` underneath us however the session was configured, so the call gain would come back on
    /// its own. WebRTC's software echo cancellation stands in, and the microphone is muted the whole time
    /// the agent is speaking anyway (see `runMicPolicy`), so there is little echo left for it to cancel.
    ///
    /// Done once, because it is global to the SDK and outlives any one conversation.
    nonisolated static func prepareAudio() throws {
        _ = handedLiveKitOurAudioSession
        try Speaker.configureAudioSession()
    }

    /// A `static let` because its initialiser is the work, and Swift runs that exactly once however many
    /// conversations the app has.
    private static let handedLiveKitOurAudioSession: Bool = {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        do {
            try AudioManager.shared.setPlatformVoiceProcessingAllowed(false)
        } catch {
            // Not fatal: the agent still connects, it just sounds like a phone call and the screen
            // recording loses it.
            print("Agent: couldn't turn off the platform voice-processing path: \(error)")
        }
        return true
    }()

    private func connect(withOverrides: Bool) async throws {
        var config = ConversationConfig(
            onError: { print("Agent error: \($0)") },
            onAgentResponse: { [weak self] text, _ in
                print("Agent: \(text)")
                Task { @MainActor in self?.agentSaid(text) }
            },
            onUserTranscript: { [weak self] text, _ in
                print("You said: \(text)")
                Task { @MainActor in self?.handleUserTranscript(text) }
            },
            onVadScore: { [weak self] score in
                Task { @MainActor in self?.voiceScoreChanged(score) }
            }
        )
        // Without this the SDK waits a full second after the agent stops before it reports "listening".
        config.agentStateConfiguration = AgentStateConfiguration(speakingToListeningDelay: 0.2)
        usedOverrides = withOverrides
        if withOverrides {
            // Only for a caller that is re-skinning the agent. A screen that takes the agent as
            // configured (Analyze) still gets the voice override below, but not this.
            if hasPersona {
                config.agentOverrides = AgentOverrides(prompt: personaPrompt, firstMessage: personaFirstMessage)
            }
            // The voice `Speaker` has been using, always: the agent picks up mid-conversation from
            // whatever the screen last said, and a change of voice there reads as a second person.
            config.ttsOverrides = TTSOverrides(
                voiceId: Speaker.voiceID,
                stability: Speaker.stability,
                speed: Speaker.speed
            )
        }
        let started = try await ElevenLabs.startConversation(
            agentId: Secrets.elevenLabsAgentID,
            config: config,
            onDisconnect: { [weak self] reason in
                Task { @MainActor in self?.handleDisconnect(reason) }
            }
        )
        // stop() cancels a connection that was still being set up
        guard !Task.isCancelled else {
            await started.endConversation()
            return
        }
        conversation = started
        stateSubscription = started.$agentState.sink { [weak self] state in
            self?.agentStateChanged(state)
        }
        toolSubscription = started.$pendingToolCalls.sink { [weak self] calls in
            self?.handleToolCalls(calls, on: started)
        }
        micPolicyTask = Task { await runMicPolicy(for: started) }
        if let initialMessage = pendingInitialMessage {
            messageTask = Task { await sendAfterGreeting(initialMessage, on: started) }
        }
    }

    func stop() {
        isStopping = true
        startTask?.cancel()
        startTask = nil
        cancelBackgroundWork()
        status = .idle
        guard let conversation else { return }
        self.conversation = nil
        stopTask = Task { await conversation.endConversation() }
    }

    /// Returns once a conversation that is being ended has released the audio hardware.
    func waitUntilStopped() async {
        await stopTask?.value
    }

    private func cancelBackgroundWork() {
        messageTask?.cancel()
        messageTask = nil
        micPolicyTask?.cancel()
        micPolicyTask = nil
        toolTask?.cancel()
        toolTask = nil
        rescanTask?.cancel()
        rescanTask = nil
        keywordFollowUp?.cancel()
        keywordFollowUp = nil
        holdingForTool = false
        toolSubscription = nil
        stateSubscription = nil
    }

    private func handleToolCalls(_ calls: [ClientToolCallEvent], on conversation: Conversation) {
        for call in calls where handledToolCalls.insert(call.toolCallId).inserted {
            print("Tool call: \(call.toolName)")
            toolTask = Task { await runTool(call, on: conversation) }
        }
    }

    // Only one scan runs at a time. Whoever asks for a rescan (the user's voice or the agent's tool) shares it.
    // The agent waits for the result, so the microphone stays closed while it runs.
    private func sharedRescan() -> Task<[String], Never> {
        if let rescanTask { return rescanTask }
        holdingForTool = true
        let task = Task { [self] () -> [String] in
            let lines = await onRescan?() ?? []
            holdingForTool = false
            rescanTask = nil
            lastRescan = (lines, Date(), false)
            return lines
        }
        rescanTask = task
        return task
    }

    private static func rescanResult(_ lines: [String]) -> String {
        lines.isEmpty
            ? "No text could be read."
            : "Text read, in reading order:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private func runTool(_ call: ClientToolCallEvent, on conversation: Conversation) async {
        guard call.toolName == "rescan", onRescan != nil else {
            try? await conversation.sendToolResult(for: call.toolCallId, result: "Unknown tool.", isError: true)
            return
        }

        // A scan the user just asked for (still running, or finished moments ago) is reused, not repeated.
        let lines: [String]
        if let rescanTask {
            lines = await rescanTask.value
        } else if let last = lastRescan, !last.delivered, Date().timeIntervalSince(last.finishedAt) < 15 {
            lines = last.lines
        } else {
            lines = await sharedRescan().value
        }
        guard !Task.isCancelled else { return }

        lastRescan?.delivered = true
        awaitingReplyUntil = Date().addingTimeInterval(10)
        do {
            try await conversation.sendToolResult(for: call.toolCallId, result: Self.rescanResult(lines))
            print("Tool result sent")
        } catch {
            print("Tool result failed: \(error)")
            awaitingReplyUntil = .distantPast
        }
    }

    // The user asked for a rescan by voice: scan now. If the agent hasn't asked for the result a few seconds after the
    // scan finishes (its tool isn't set up, or it chose to just talk), send the new text to it directly.
    private func startVoiceRescan() {
        guard rescanTask == nil, let conversation, onRescan != nil else { return }
        print("Rescan requested by voice")
        let scan = sharedRescan()
        keywordFollowUp = Task { [self] in
            _ = await scan.value
            let giveUp = Date().addingTimeInterval(5)
            while !Task.isCancelled, Date() < giveUp, lastRescan?.delivered == false {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, let last = lastRescan, !last.delivered else { return }

            lastRescan?.delivered = true
            awaitingReplyUntil = Date().addingTimeInterval(10)
            do {
                try await conversation.sendMessage("Rescanned. \(Self.rescanResult(last.lines)) Briefly say what you can now tell.")
            } catch {
                print("Agent message failed: \(error)")
                awaitingReplyUntil = .distantPast
            }
        }
    }

    private func handleUserTranscript(_ text: String) {
        guard isRunning else { return }
        if KeywordMatcher.matches(text, in: endKeywords) {
            onEndRequested?()
            return
        }
        if KeywordMatcher.matches(text, in: rescanKeywords) {
            startVoiceRescan()
            return
        }
        onTranscript?(text)
    }

    private func agentStateChanged(_ state: ElevenLabs.AgentState) {
        let new = Status(state)
        print("Agent state: \(new)")
        rawState = new
        listeningSince = new == .listening ? (listeningSince ?? Date()) : nil
        if new == .speaking { heardAgent = true }
    }

    // The agent's reply text arrives ahead of its voice, so its length gives a lower bound on how long the
    // agent will keep talking, even if the state flickers.
    private func agentSaid(_ text: String) {
        heardAgent = true
        awaitingReplyUntil = .distantPast
        speakingUntil = max(speakingUntil, Date()) + Double(text.count) / charactersPerSecond + 0.1
    }

    // "Listening" only when the microphone is really open.
    private func displayedStatus() -> Status {
        if appliedMuted == false, !agentIsBusy, !holdingForReply { return .listening }
        if rawState == .thinking || (holdingForReply && heardAgent && !agentIsBusy) { return .thinking }
        return heardAgent ? .speaking : .connecting
    }

    // Logged only when it crosses the threshold: does the server hear the user's voice at all?
    private func voiceScoreChanged(_ score: Double) {
        let heard = score >= 0.5
        guard heard != voiceHeard else { return }
        voiceHeard = heard
        print(heard ? "Voice heard (score \(String(format: "%.2f", score)))" : "Voice stopped")
    }

    // While the agent is talking, thinking, or may still be talking, the microphone is muted, so no sound at all
    // reaches it. Side effect: the user can't interrupt the agent by voice.
    private func runMicPolicy(for conversation: Conversation) async {
        let began = Date()
        while !Task.isCancelled {
            let waitingForGreeting = !heardAgent && Date().timeIntervalSince(began) < greetingGrace
            requestMuted(agentIsBusy || holdingForReply || !listeningSteadily || waitingForGreeting, on: conversation)
            let shown = displayedStatus()
            if status != shown { status = shown }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // Changes are applied one at a time, always toward the latest request, so a quick mute-then-unmute can't
    // finish in the wrong order and leave the microphone open.
    private func requestMuted(_ muted: Bool, on conversation: Conversation) {
        desiredMuted = muted
        guard !isApplyingMute, appliedMuted != muted else { return }
        isApplyingMute = true
        Task {
            while appliedMuted != desiredMuted {
                let target = desiredMuted
                do {
                    try await conversation.setMuted(target)
                } catch {
                    print("Mic change failed: \(error)")
                }
                appliedMuted = target
                print("Mic \(target ? "muted" : "open") (SDK says muted: \(conversation.isMuted))")
            }
            isApplyingMute = false
        }
    }

    private func sendAfterGreeting(_ message: String, on conversation: Conversation) async {
        // Wait until the agent is completely quiet, or the greeting never comes, so the message can't cut it off.
        let giveUp = Date().addingTimeInterval(3)
        while !Task.isCancelled {
            if !agentIsBusy, listeningSteadily, heardAgent || Date() > giveUp { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, self.conversation === conversation else { return }
        initialMessagePending = false
        awaitingReplyUntil = Date().addingTimeInterval(10)
        do {
            try await conversation.sendMessage(message)
        } catch {
            print("Agent message failed: \(error)")
            awaitingReplyUntil = .distantPast
        }
    }

    private func handleDisconnect(_ reason: DisconnectionReason) {
        print("Agent disconnected: \(reason)")
        cancelBackgroundWork()
        conversation = nil
        // A refused override can also present as a connection that is accepted and then dropped, so a
        // disconnect before the agent has said a single word is treated as the same failure.
        if !isStopping, usedOverrides, !retriedWithoutOverrides, !heardAgent {
            print("Dropped before the agent spoke — retrying as it is configured")
            retriedWithoutOverrides = true
            resetForConnection()
            beginConnecting(withOverrides: false)
            return
        }
        status = .idle
        if !isStopping { onEnded?() }
    }
}
