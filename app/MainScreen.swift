import SwiftUI

struct MainScreen: View {
    @State private var optionChosen = false
    @State private var showFind = false
    @State private var showAnalyze = false
    @State private var listenTask: Task<Void, Never>?
    @StateObject private var listener = VoiceListener()
    @StateObject private var agent = AgentSession()

    private let question = "Are you looking for something, or do you want help analyzing something?"
    private let commands: [String: [String]] = [
        "find": ["find", "locate", "position", "pinpoint", "looking for", "search"],
        "understand": ["understand", "analyze", "analyse", "analyzing", "interpret"],
        "repeat": ["repeat", "say that again", "one more time", "again", "pardon"]
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Button(action: chooseFind) {
                Image("FindButton")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 330, height: 180)
            }
            .buttonStyle(.plain)

            Button(action: chooseUnderstand) {
                Text("Analyze")
                    .font(.system(size: 52, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .scaleEffect(x: 1, y: -1)
                    .frame(width: 330, height: 180)
                    .foregroundColor(Color(red: 22 / 255, green: 133 / 255, blue: 184 / 255))
                    .background(Color.white)
                    .cornerRadius(12)
            }

            Spacer()
                .frame(height: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 43 / 255, green: 187 / 255, blue: 255 / 255))
        .overlay(alignment: .bottom) {
            if agent.isRunning {
                ListeningIndicator(status: agent.status)
            } else if listener.isListening {
                ListeningIndicator()
            }
        }
        .animation(.easeInOut, value: listener.isListening)
        .animation(.easeInOut, value: agent.status)
        .navigationDestination(isPresented: $showFind) { ContentView(onBack: { showFind = false }) }
        .navigationDestination(isPresented: $showAnalyze) { AnalyzeView(onBack: { showAnalyze = false }) }
        .onChange(of: showFind) { _, isShowing in
            if !isShowing { Speaker.shared.stop() }
        }
        .onChange(of: showAnalyze) { _, isShowing in
            if !isShowing { Speaker.shared.stop() }
        }
        .task {
            agent.onEndRequested = { endAgentConversation() }
            optionChosen = false
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, !optionChosen else { return }
            Speaker.shared.speak(question)
            await listenForCommands()
        }
        .onDisappear {
            listenTask?.cancel()
            listener.stop()
            agent.stop()
        }
    }

    private func choose(announcing message: String) {
        optionChosen = true
        agent.stop()
        listener.stop()
        Speaker.shared.stop()
        Speaker.shared.speak(message)
    }

    private func chooseFind() {
        choose(announcing: "Find object selected")
        showFind = true
    }

    private func chooseUnderstand() {
        choose(announcing: "Analyze object selected")
        showAnalyze = true
    }

    // Ends the conversation (by tap or by voice), then asks the question again before listening for a choice.
    private func endAgentConversation() {
        agent.stop()
        optionChosen = false
        listenTask?.cancel()
        listenTask = Task {
            await agent.waitUntilStopped()
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !optionChosen else { return }
            Speaker.shared.speak(question)
            await listenForCommands()
        }
    }

    private func listenForCommands() async {
        await Speaker.shared.waitUntilIdle()
        guard !Task.isCancelled, !optionChosen else { return }
        await listener.start(commands: commands) { command in
            switch command {
            case "find":
                chooseFind()
            case "understand":
                chooseUnderstand()
            default:
                Speaker.shared.speak(question)
                listenTask = Task { await listenForCommands() }
            }
        }
    }
}

#Preview {
    NavigationStack { MainScreen() }
}
