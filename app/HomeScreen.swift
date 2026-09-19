import SwiftUI

struct HomeScreen: View {
    @State private var hasIntroduced = false
    @State private var showOptions = false
    @StateObject private var listener = VoiceListener()

    var body: some View {
        NavigationStack {
            ZStack {
                Image("homeImage")
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()

                Color.black.opacity(0.15)
                    .ignoresSafeArea()

                Button(action: { showOptions = true }) {
                    Text("Click Me")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.18))
                        .cornerRadius(14)
                }
            }
            .overlay(alignment: .bottom) {
                if listener.isListening {
                    ListeningIndicator()
                }
            }
            .animation(.easeInOut, value: listener.isListening)
            .navigationDestination(isPresented: $showOptions) { MainScreen() }
            .task {
                if !hasIntroduced {
                    try? await Task.sleep(for: .seconds(0.25))
                    guard !Task.isCancelled else { return }
                    hasIntroduced = true
                    Speaker.shared.speak("Hello, this is Probe. I can help you find things around you, or help you understand an item you're holding!")
                }
                await Speaker.shared.waitUntilIdle()
                guard !Task.isCancelled else { return }
                await listener.start(
                    commands: ["continue": ["continue", "okay", "next", "start", "begin", "go", "yes", "ready"]]
                ) { _ in showOptions = true }
            }
            .onDisappear { listener.stop() }
        }
    }
}

#Preview {
    HomeScreen()
}
