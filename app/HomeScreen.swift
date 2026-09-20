import SwiftUI

struct HomeScreen: View {
    @State private var hasIntroduced = false
    @State private var showMainScreen = false
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
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onEnded { value in
                        let isVerticalSwipe = abs(value.translation.height) > abs(value.translation.width)
                        if isVerticalSwipe && value.translation.height < -80 {
                            showMainScreen = true
                        }
                    }
            )
            .overlay(alignment: .bottom) {
                if listener.isListening {
                    ListeningIndicator()
                }
            }
            .animation(.easeInOut, value: listener.isListening)
            .navigationDestination(isPresented: $showMainScreen) {
                MainScreen()
            }
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
                ) { _ in showMainScreen = true }
            }
            .onDisappear { listener.stop() }
        }
        .background(VolumeHUDHider())
    }
}

#Preview {
    HomeScreen()
}
