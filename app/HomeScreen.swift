import SwiftUI

struct HomeScreen: View {
    @State private var hasIntroduced = false

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

                NavigationLink(destination: MainScreen()) {
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
            .task {
                guard !hasIntroduced else { return }
                try? await Task.sleep(for: .seconds(0.25))
                guard !Task.isCancelled else { return }
                hasIntroduced = true
                Speaker.shared.speak("Hello, this is Probe. I can help you find things around you, or help you understand an item you're holding!")
            }
        }
    }
}

#Preview {
    HomeScreen()
}
