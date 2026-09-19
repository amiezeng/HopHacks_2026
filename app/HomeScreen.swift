import SwiftUI

struct HomeScreen: View {
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
        }
    }
}

#Preview {
    HomeScreen()
}
