import SwiftUI

@main
struct hophacks_prepApp: App {
    /// Builds the artwork and the vision models up front, so no screen has to do it as it appears.
    @StateObject private var preloader = Preloader()
    /// Whether the loading screen is still in the tree. It has nothing left to draw once it has handed over.
    @State private var showsLoading = true

    var body: some Scene {
        WindowGroup {
            // The home screen is mounted as soon as the warmup is done, but the loading screen stays
            // over it until it has had time to lay out and draw its first frames. Then the loading screen
            // hands over: its title is the home screen's, in the same place, and rises to the top while the
            // monster slides up from below (`HomeScreen.introStarted`).
            ZStack {
                if preloader.isReady {
                    HomeScreen(introStarted: preloader.isRevealed)
                }
                if showsLoading {
                    LoadingScreen(step: preloader.step, handedOver: preloader.isRevealed)
                }
            }
            .task { await preloader.warm() }
            .task(id: preloader.isRevealed) {
                guard preloader.isRevealed else { return }
                // Long enough for the spinner to have faded.
                try? await Task.sleep(for: .milliseconds(300))
                showsLoading = false
            }
        }
    }
}
