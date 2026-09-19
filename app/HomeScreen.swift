import SwiftUI

struct HomeScreen: View {
    @State private var showMainScreen = false

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
            .navigationDestination(isPresented: $showMainScreen) {
                MainScreen()
            }
        }
    }
}

#Preview {
    HomeScreen()
}
