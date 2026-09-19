import SwiftUI

struct MainScreen: View {
    @State private var optionChosen = false
    @State private var showFind = false
    @State private var listenTask: Task<Void, Never>?
    @StateObject private var listener = VoiceListener()

    private let question = "Are you looking for something, or do you want help analyzing something?"
    private let commands: [String: [String]] = [
        "find": ["find", "locate", "position", "pinpoint", "looking for", "search"],
        "understand": ["understand", "analyze", "analyse", "analyzing", "interpret"],
        "repeat": ["repeat", "say that again", "one more time", "again", "pardon"]
    ]

    var body: some View {
        VStack(spacing: 24) {
            Button(action: chooseFind) {
                Text("A")
                    .font(.title)
                    .frame(width: 140, height: 60)
                    .foregroundColor(.white)
                    .background(Color.green)
                    .cornerRadius(12)
            }

            Button(action: chooseUnderstand) {
                Text("B")
                    .font(.title)
                    .frame(width: 140, height: 60)
                    .foregroundColor(.white)
                    .background(Color.orange)
                    .cornerRadius(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.15))
        .overlay(alignment: .bottom) {
            if listener.isListening {
                ListeningIndicator()
            }
        }
        .animation(.easeInOut, value: listener.isListening)
        .navigationDestination(isPresented: $showFind) { ContentView(onBack: { showFind = false }) }
        .onChange(of: showFind) { _, isShowing in
            if !isShowing { Speaker.shared.stop() }
        }
        .task {
            optionChosen = false
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, !optionChosen else { return }
            Speaker.shared.speak(question)
            await listenForCommands()
        }
        .onDisappear {
            listenTask?.cancel()
            listener.stop()
        }
    }

    private func choose(announcing message: String) {
        optionChosen = true
        listener.stop()
        Speaker.shared.stop()
        Speaker.shared.speak(message)
    }

    private func chooseFind() {
        choose(announcing: "Find object selected")
        showFind = true
    }

    private func chooseUnderstand() {
        choose(announcing: "Understand object selected")
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
