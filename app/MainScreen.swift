import SwiftUI

struct MainScreen: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                NavigationLink(destination: ContentView()) {
                    Image("FindButton")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 330, height: 180)
                }

                Button(action: {}) {
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
        }
    }
}

#Preview {
    MainScreen()
}
