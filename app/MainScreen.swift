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
        NavigationStack {
            VStack(spacing: 24) {
                Button(action: chooseFind) {
                    Text("A")
                        .font(.title)
                        .frame(width: 140, height: 60)
                        .foregroundColor(.white)
                        .background(Color.green)
                        .cornerRadius(12)
                }

                Button(action: chooseOption) {
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
            .navigationDestination(isPresented: $showFind) { ContentView() }
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
    }

    private func chooseOption() {
        optionChosen = true
        listener.stop()
        Speaker.shared.stop()
    }

    private func chooseFind() {
        chooseOption()
        showFind = true
    }

    private func listenForCommands() async {
        await Speaker.shared.waitUntilIdle()
        guard !Task.isCancelled, !optionChosen else { return }
        await listener.start(commands: commands) { command in
            switch command {
            case "find":
                chooseFind()
            case "understand":
                chooseOption()
            default:
                Speaker.shared.speak(question)
                listenTask = Task { await listenForCommands() }
            }
        }
    }
}

#Preview {
    MainScreen()
}
