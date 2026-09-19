import SwiftUI

struct ListeningIndicator: View {
    var body: some View {
        Label("Listening…", systemImage: "mic.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.45), in: Capsule())
            .padding(.bottom, 32)
            .transition(.opacity)
    }
}
