import SwiftUI

struct MainScreen: View {
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

                Button(action: {}) {
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
        }
    }
}

#Preview {
    MainScreen()
}
