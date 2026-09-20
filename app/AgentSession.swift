import Combine
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

    private let endKeywords = [
        "go back", "end conversation", "end the conversation", "end call", "end the call",
        "take me back", "goodbye", "bye", "exit", "quit", "i'm done", "i am done", "we're done",
        "stop the conversation", "stop conversation"
    ]

    @Published private(set) var status: Status = .idle
    var isRunning: Bool { status != .idle }

    private var conversation: Conversation?
    private var startTask: Task<Void, Never>?
    private var stateSubscription: AnyCancellable?
    private var stopTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        status = .connecting
        startTask = Task { [self] in
            defer { startTask = nil }
            do {
                try Speaker.configureAudioSession()
                let started = try await ElevenLabs.startConversation(
                    agentId: Secrets.elevenLabsAgentID,
                    config: ConversationConfig(
                        onError: { print("Agent error: \($0)") },
                        onAgentResponse: { text, _ in print("Agent: \(text)") },
                        onUserTranscript: { [weak self] text, _ in
                            print("You said: \(text)")
                            Task { @MainActor in self?.handleUserTranscript(text) }
                        }
                    ),
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
                    self?.status = Status(state)
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
        stateSubscription = nil
        status = .idle
        guard let conversation else { return }
        self.conversation = nil
        stopTask = Task { await conversation.endConversation() }
    }

    /// Returns once a conversation that is being ended has released the audio hardware.
    func waitUntilStopped() async {
        await stopTask?.value
    }

    private func handleUserTranscript(_ text: String) {
        guard isRunning, KeywordMatcher.matches(text, in: endKeywords) else { return }
        onEndRequested?()
    }

    private func handleDisconnect(_ reason: DisconnectionReason) {
        print("Agent disconnected: \(reason)")
        stateSubscription = nil
        conversation = nil
        status = .idle
    }
}
