import SwiftUI

struct MainScreen: View {
    @State private var optionChosen = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                NavigationLink(destination: ContentView()) {
                    Text("A")
                        .font(.title)
                        .frame(width: 140, height: 60)
                        .foregroundColor(.white)
                        .background(Color.green)
                        .cornerRadius(12)
                }
                .simultaneousGesture(TapGesture().onEnded { chooseOption() })

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
            .task {
                optionChosen = false
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled, !optionChosen else { return }
                Speaker.shared.speak("Are you looking for something, or do you want help analyzing something?")
            }
        }
    }

    private func chooseOption() {
        optionChosen = true
        Speaker.shared.stop()
    }
}

#Preview {
    MainScreen()
}
