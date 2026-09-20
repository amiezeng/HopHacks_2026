import ARKit
import Combine
import Foundation

/// What happens once `DistanceBeepController` has run out of steps: the object is in the user's hand and
/// held close enough to read, so the label is read off it and handed to the conversational agent, which
/// says what they are holding and then answers questions about it.
///
/// This is bolted onto the *end* of the guidance pipeline rather than into it. Frames are dropped until
/// `begin` is called, so the three steps cost exactly what they cost before, and guidance is only torn
/// down (`onHandOff`) on the way into the conversation — never while it is still steering a hand.
///
/// It is also what makes the agent admissible on this screen at all, where it deliberately isn't during
/// guidance: LiveKit takes the audio hardware in its own mode, which costs the screen its tone. By the
/// time this connects there is no tone left to lose and nothing left to steer — the user is holding the
/// thing, and from here on the conversation *is* the screen, exactly as it is on Analyze.
@MainActor
final class ObjectConversation: ObservableObject {
    /// In order of how far the handoff has got. `reading` is also used for a rescan the agent asks for
    /// part way through the conversation, which is the same act: the pill and the water say "I'm
    /// looking at it" either way, and the stage it interrupted is put back afterwards.
    enum Stage { case idle, reading, talking, ended }

    @Published private(set) var stage: Stage = .idle
    /// Mirrored off `AgentSession` so a view observing this object sees both halves of the state:
    /// a nested `ObservableObject` publishes to nobody. Only meaningful while `stage` is `.talking`.
    @Published private(set) var agentStatus: AgentSession.Status = .idle

    /// The user asked to leave. Once the agent has the microphone it is the one that hears them, so
    /// this is the screen's "go back" for the whole of the conversation.
    var onBack: (() -> Void)?
    /// Called once, immediately before the agent connects: the screen's own listener has to let go of
    /// the microphone and guidance has to let go of the audio engine, or LiveKit takes the hardware out
    /// from under both of them.
    var onHandOff: (() -> Void)?
    /// The conversation is over and nothing else here will speak — the agent was refused, or dropped.
    /// The screen takes its listener back so "go back" still works.
    var onEnded: (() -> Void)?

    /// Reads the middle 60% of the frame (`TextReader.region`) — which is roughly the part
    /// `ConversationWater`'s rim leaves clear, so what is being read is what is not under water.
    private let reader = TextReader()
    private let agent = AgentSession()
    private var statusSink: AnyCancellable?
    private var task: Task<Void, Never>?
    private var objectName = "object"
    private var lines: [String] = []
    /// Frames are only read while this is set, which is what keeps the reader off the guidance pipeline.
    private var scanning = false
    /// When the object reached a readable distance, which is when `begin` was called. The picture is
    /// taken `readAfter` after this, not after the speech that starts at the same moment.
    private var readableAt = Date()

    /// The object is at a readable distance the moment `begin` is called, so that is where the clock
    /// starts: the label is read off the frames that arrive over the next `readAfter` seconds, and
    /// whatever has been read by then is what the agent is given. A picture taken at a fixed moment,
    /// in other words, rather than a read waited on until it stops changing.
    ///
    /// Waiting for it to stop changing is what this used to do, and it is why every handoff took the
    /// whole twelve-second timeout instead: `TextConsolidator` re-votes over a sliding window of the
    /// last eight scans, so on anything busier than a two-line label some cluster crosses or drops the
    /// three-appearance threshold every half second, and the read never holds still for two seconds
    /// together. The settle almost never fired. The timeout did, every time, with the user stood there
    /// holding a bottle up to the camera for it.
    private let readAfter: TimeInterval = 3
    /// Only spent when *nothing* has been read by then — an empty handoff is worth a few more seconds
    /// and a nudge to turn the label toward the camera, where one more line is not.
    private let readGrace: TimeInterval = 4
    /// A rescan starts from an empty window (`TextReader.reset`) and `TextConsolidator` won't report a
    /// line until it has seen it in three scans, so this can't go much below two seconds however close
    /// the object already is. The agent is holding its tool call open on it, hence the shorter grace.
    private let rescanAfter: TimeInterval = 2
    private let rescanGrace: TimeInterval = 3
    /// How long a read may go without producing anything before the user is nudged. Silence while
    /// holding something up is indistinguishable from the app having died.
    private let hintAfter: TimeInterval = 5

    init() {
        agent.onEndRequested = { [weak self] in self?.onBack?() }
        agent.onRescan = { [weak self] in await self?.rescan() ?? [] }
        agent.onEnded = { [weak self] in self?.agentWentAway() }
        statusSink = agent.$status.sink { [weak self] status in
            guard let self, self.agentStatus != status else { return }
            self.agentStatus = status
        }
    }

    /// Called from the AR frame callback for every frame, and ignores all of them until the label is
    /// being read. OCR is `.accurate` Vision text recognition on a background queue twice a second —
    /// worth having for the handoff, not worth running underneath the three steps of guidance.
    func process(frame: ARFrame) {
        guard scanning else { return }
        reader.process(frame: frame)
    }

    /// Starts the handoff. Latched on `stage`, because `DistanceBeepController.Phase.ready` can fall
    /// back to `.contact` and return — the object being taken out of the frame for a moment must not
    /// start a second conversation.
    func begin(objectName: String) {
        guard stage == .idle else { return }
        self.objectName = objectName
        stage = .reading
        scanning = true
        readableAt = Date()
        print("Conversation: reading the \(objectName)")
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        scanning = false
        agent.stop()
        stage = .idle
    }

    private func run() async {
        // Read *through* the line the guidance just queued ("That's close enough to read. Hold it
        // steady."), not after it: the reader has been scanning since `begin`, so those three seconds
        // are the three seconds it takes to say, and the label is in hand by the time it ends. Nothing
        // is said here at all any more — a second "hold it there while I read it" was another two
        // seconds of speech saying what had just been said, on the near side of the handoff where
        // every word still has to be checked against `ContentView.backKeywords`.
        lines = await scan(
            from: readableAt,
            after: readAfter,
            grace: readGrace,
            hint: "Still looking. Try turning it a little, so the label faces the camera."
        )
        guard !Task.isCancelled else { return }
        scanning = false
        print("Conversation: read \(lines.count) line(s) off the \(objectName)")

        // The handoff empties the speech queue (`onHandOff` → `beepController.shutdown`), so whatever
        // is mid-word when it lands is cut off. Normally there is nothing left to wait for by now.
        await Speaker.shared.waitUntilIdle()
        guard !Task.isCancelled else { return }

        stage = .talking
        // Both the microphone and the audio engine have to be free *before* this: LiveKit runs the
        // hardware in its own mode with echo cancellation, and it takes whatever it finds.
        onHandOff?()
        agent.start(
            initialMessage: Self.describeRequest(objectName: objectName, lines: lines),
            prompt: Self.persona(objectName: objectName),
            firstMessage: "Let me see what you're holding."
        )
    }

    /// The agent asked to read the label again. Same act as the first read, so it shows as one: the
    /// pill goes back to "Reading the label" and the water draws in again.
    private func rescan() async -> [String] {
        let interrupted = stage
        stage = .reading
        scanning = true
        reader.reset()
        let started = Date()
        print("Conversation: rescanning")
        let found = await scan(from: started, after: rescanAfter, grace: rescanGrace, hint: nil)
        scanning = false
        lines = found
        // Only if nothing else has moved on in the meantime — the screen may have been left mid-scan.
        if stage == .reading { stage = interrupted }
        print("Conversation: rescan read \(found.count) line(s)")
        return found
    }

    /// The read as of `delay` after `start` — the picture, taken at a fixed moment whether or not the
    /// reader has stopped finding new lines. The one thing worth waiting past it for is an *empty*
    /// read: it keeps looking for `grace` longer rather than handing the agent a label it never saw,
    /// and nudges the user once on the way. Coming back with nothing is still allowed, and the agent
    /// is told what to say when it happens.
    private func scan(from start: Date, after delay: TimeInterval, grace: TimeInterval, hint: String?) async -> [String] {
        var hinted = false
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            let lines = reader.lines
            if !lines.isEmpty, elapsed >= delay { return lines }
            if elapsed >= delay + grace { return lines }
            if let hint, !hinted, elapsed >= hintAfter, !Speaker.shared.isBusy {
                hinted = true
                Speaker.shared.speak(hint)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return []
    }

    /// The agent never connected, or the server dropped it. Everything audible on this screen was its
    /// job by then, so say what can be said without it and hand the microphone back to the screen.
    private func agentWentAway() {
        guard stage != .idle, stage != .ended else { return }
        stage = .ended
        scanning = false
        print("Conversation: agent went away, falling back to the label")
        Speaker.shared.speak(fallback)
        onEnded?()
    }

    /// Said in place of the conversation when there is no agent to have one with. Deliberately the
    /// label itself rather than an apology about a network: it is the thing the user picked the object
    /// up to find out.
    private var fallback: String {
        guard !lines.isEmpty else {
            return "I can tell it's a \(objectName), but I can't make out anything written on it."
        }
        return "I can't reach the assistant, but here's what it says. " + lines.prefix(6).joined(separator: ". ") + "."
    }

    private static func persona(objectName: String) -> String {
        """
        You are Probe, a voice guide for someone who cannot see. You have just walked them, step by \
        step, to a \(objectName) in front of them; they have picked it up and are holding it to the \
        camera, and you are given the text read off it.

        Tell them what they are holding and the one or two things on it that actually matter — what it \
        is, the brand, a flavour or a strength, a warning, a date — then stop and let them ask. Answer \
        in at most three short spoken sentences, plainly, with no lists and no markdown, and never read \
        the whole label out unless they ask you to. Never mention text, scanning, OCR or the camera: \
        just say what the thing is. If what you were given is garbled or empty, say so and offer to \
        look again — `rescan` is a tool you can call for that, and it takes a few seconds.
        """
    }

    private static func describeRequest(objectName: String, lines: [String]) -> String {
        guard !lines.isEmpty else {
            return """
            The user is holding a \(objectName) up to the camera, but nothing could be read off it. \
            Say that you can tell it's a \(objectName) but can't make out what's written on it, offer \
            to look again, and wait.
            """
        }
        let text = lines.map { "- \($0)" }.joined(separator: "\n")
        return """
        The user is holding a \(objectName) up to the camera. Read off it, in reading order (it may \
        contain misread characters):
        \(text)

        Say what they are holding in one or two short sentences, then wait.
        """
    }
}

extension ObjectConversation {
    /// What the water over the camera is doing, so the view doesn't have to piece it together from two
    /// published properties.
    var mood: WaterMood {
        switch stage {
        case .idle, .ended:
            return .still
        case .reading:
            return .drawingIn
        case .talking:
            switch agentStatus {
            case .speaking: return .speaking
            case .listening: return .listening
            case .thinking, .connecting, .idle: return .thinking
            }
        }
    }
}
