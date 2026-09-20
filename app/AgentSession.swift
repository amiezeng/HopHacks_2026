import Combine
import Foundation
import ElevenLabs

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

    private let endKeywords = [
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
    func start(initialMessage: String? = nil) {
        guard !isRunning else { return }
        rawState = .listening
        heardAgent = false
        initialMessagePending = initialMessage != nil
        holdingForTool = false
        rescanTask = nil
        lastRescan = nil
        handledToolCalls.removeAll()
        awaitingReplyUntil = .distantPast
        voiceHeard = false
        speakingUntil = .distantPast
        listeningSince = nil
        desiredMuted = true
        appliedMuted = nil
        isApplyingMute = false
        status = .connecting
        startTask = Task { [self] in
            defer { startTask = nil }
            do {
                try Speaker.configureAudioSession()
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
                if let initialMessage {
                    messageTask = Task { await sendAfterGreeting(initialMessage, on: started) }
                }
            } catch {
                print("Agent start failed: \(error)")
                status = .idle
            }
        }
    }

    func stop() {
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
        } else if KeywordMatcher.matches(text, in: rescanKeywords) {
            startVoiceRescan()
        }
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
        status = .idle
    }
}
