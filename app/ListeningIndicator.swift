import SwiftUI

/// "Listening…" pill: a mic that breathes, on a frosted capsule with a hairline edge.
struct ListeningIndicator: View {
    var text = "Listening…"
    var systemImage = "mic.fill"
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(breathing ? 1.15 : 0.9)
            Text(text)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.25), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .padding(.bottom, 32)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
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
