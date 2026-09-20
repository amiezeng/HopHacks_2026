import SwiftUI

struct ListeningIndicator: View {
    var text = "Listening…"
    var systemImage = "mic.fill"

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.45), in: Capsule())
            .padding(.bottom, 32)
            .transition(.opacity)
    }
}

extension ListeningIndicator {
    init(status: AgentSession.Status) {
        switch status {
        case .speaking: self.init(text: "Probe is speaking…", systemImage: "speaker.wave.2.fill")
        case .thinking: self.init(text: "Thinking…", systemImage: "ellipsis")
        case .connecting: self.init(text: "Connecting…", systemImage: "antenna.radiowaves.left.and.right")
        case .listening, .idle: self.init()
        }
    }
}
