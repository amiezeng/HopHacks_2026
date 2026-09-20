import SwiftUI

struct AnalyzeView: View {
    var onBack: () -> Void = {}
    @StateObject private var listener = VoiceListener()
    @StateObject private var arController = ARSessionController()
    @StateObject private var reader = TextReader()
    @StateObject private var agent = AgentSession()
    @State private var summaryStarted = false
    @State private var rescanning = false
    @State private var currentHold: TimeInterval = 5
    @State private var holdStartedAt: Date?
    @State private var secondsLeft = 0
    @State private var ringProgress: CGFloat = 0
    @State private var holdCount = 0

    private let backKeywords = ["go back", "back", "return", "previous", "exit", "leave", "quit", "cancel"]
    // Once text is found the user holds still for this long, then the agent starts with whatever was read.
    private let holdDuration: TimeInterval = 5
    // The countdown restarts if the text has been out of view for this long.
    private let textLostGrace: TimeInterval = 1
    // Hints when nothing readable is in view.
    private let firstHintAfter: TimeInterval = 12
    private let laterHintEvery: TimeInterval = 15
    private let maxHints = 2
    // A rescan is quicker than the first scan, because the agent is waiting for the result and gives up on a
    // slow tool. It reports what it has after the timeout even if it found nothing.
    private let rescanHold: TimeInterval = 2
    private let rescanTimeout: TimeInterval = 12

    var body: some View {
        GeometryReader { geo in
            ARCameraPreview(session: arController.session)
                .overlay {
                    ScanAreaOutline(
                        imageSize: reader.uprightImageSize,
                        viewSize: geo.size,
                        foundText: !reader.lines.isEmpty,
                        progress: ringProgress
                    )
                }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { statusPill }
        .animation(.easeInOut, value: agent.status)
        .animation(.easeInOut, value: holdStartedAt != nil)
        .animation(.easeInOut, value: summaryStarted)
        .sensoryFeedback(.impact(weight: .light), trigger: holdCount)
        .sensoryFeedback(.success, trigger: summaryStarted) { _, started in started }
        .sensoryFeedback(.impact(weight: .light), trigger: agent.status) { old, new in new == .listening && old != .listening }
        .onAppear {
            arController.onFrame = { frame in reader.process(frame: frame) }
            arController.start()
            agent.onEndRequested = { onBack() }
            agent.onRescan = { await performRescan() }
        }
        .task {
            await Speaker.shared.waitUntilIdle()
            guard !Task.isCancelled else { return }
            Speaker.shared.speak("Hold the item in front of the camera so I can read it.")
            await Speaker.shared.waitUntilIdle()
            guard !Task.isCancelled else { return }
            await listener.start(commands: ["back": backKeywords]) { _ in onBack() }
            if let lines = await scanForText(hold: holdDuration, hints: true, timeout: nil) {
                beginSummary(with: lines)
            }
        }
        .onDisappear {
            listener.stop()
            agent.stop()
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if !rescanning, agent.isRunning {
            ListeningIndicator(status: agent.status)
        } else if !rescanning, summaryStarted {
            ListeningIndicator(text: "Text detected", systemImage: "checkmark.circle.fill")
        } else if holdStartedAt != nil {
            ListeningIndicator(text: "Hold steady… \(secondsLeft)", systemImage: "timer")
        } else {
            ListeningIndicator(text: "Looking for text…", systemImage: "text.viewfinder")
        }
    }

    // Waits for text, runs the countdown once it is found, and returns what was read. With `hints`, it also nudges
    // the user if nothing readable shows up. With a `timeout`, it gives up and returns whatever there is.
    // Returns nil if the screen went away.
    private func scanForText(hold: TimeInterval, hints: Bool, timeout: TimeInterval?) async -> [String]? {
        currentHold = hold
        let began = Date()
        var lastTextSeen = Date()
        var emptySince = Date()
        var hintsGiven = 0

        while !Task.isCancelled {
            let now = Date()
            if !reader.lines.isEmpty {
                lastTextSeen = now
                emptySince = now
            }

            if let holdBegan = holdStartedAt {
                if now.timeIntervalSince(lastTextSeen) >= textLostGrace {
                    resetHold()
                } else {
                    let elapsed = now.timeIntervalSince(holdBegan)
                    secondsLeft = max(0, Int((hold - elapsed).rounded(.up)))
                    if elapsed >= hold { return reader.lines }
                }
            } else if !reader.lines.isEmpty {
                startHold(at: now)
            } else if hints {
                let wait = hintsGiven == 0 ? firstHintAfter : laterHintEvery
                if hintsGiven < maxHints, now.timeIntervalSince(emptySince) >= wait {
                    hintsGiven += 1
                    emptySince = now
                    await speakHint("I can't read any text yet. Try holding the label closer, or say go back.")
                }
            }

            if let timeout, now.timeIntervalSince(began) >= timeout { return reader.lines }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // The agent asked for another scan: clear what was read, show the countdown again, and return the new text.
    private func performRescan() async -> [String] {
        let began = Date()
        print("Rescan started")
        rescanning = true
        reader.reset()
        resetHold()
        let lines = await scanForText(hold: rescanHold, hints: false, timeout: rescanTimeout) ?? []
        resetHold()
        rescanning = false
        print("Rescan finished: \(lines.count) lines in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        return lines
    }

    private func startHold(at date: Date) {
        holdStartedAt = date
        secondsLeft = Int(currentHold)
        holdCount += 1
        withAnimation(.linear(duration: currentHold)) { ringProgress = 1 }
    }

    private func resetHold() {
        holdStartedAt = nil
        withAnimation(.easeOut(duration: 0.2)) { ringProgress = 0 }
    }

    // The hint mentions "go back", so the microphone must be off while it plays or the listener would hear it.
    private func speakHint(_ text: String) async {
        listener.stop()
        Speaker.shared.speak(text)
        await Speaker.shared.waitUntilIdle()
        guard !Task.isCancelled else { return }
        await listener.start(commands: ["back": backKeywords]) { _ in onBack() }
    }

    // The agent takes over the microphone, so our own listener stops first. Connecting takes a moment anyway, so
    // it starts right away instead of waiting for "Text detected." to finish.
    private func beginSummary(with lines: [String]) {
        summaryStarted = true
        holdStartedAt = nil
        withAnimation(.easeOut(duration: 0.3)) { ringProgress = 0 }
        listener.stop()
        Speaker.shared.speak("Text detected.")
        agent.start(initialMessage: Self.summaryRequest(for: lines))
    }

    private static func summaryRequest(for lines: [String]) -> String {
        let text = lines.map { "- \($0)" }.joined(separator: "\n")
        return """
        Scanned label text, in reading order (may contain misread characters):
        \(text)

        Summarize this item in one or two short sentences, then wait.
        """
    }
}

/// Outlines the part of the picture that is being read, and fills in green during the countdown. The camera image
/// fills the screen and is cropped to fit, so the outline is computed the same way (see SegmentationOverlay in
/// ContentView).
private struct ScanAreaOutline: View {
    let imageSize: CGSize
    let viewSize: CGSize
    let foundText: Bool
    let progress: CGFloat

    private var rect: CGRect {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let content = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let region = TextReader.region
        return CGRect(
            x: region.minX * content.width - (content.width - viewSize.width) / 2,
            y: (1 - region.maxY) * content.height - (content.height - viewSize.height) / 2,
            width: region.width * content.width,
            height: region.height * content.height
        )
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(foundText ? Color.green.opacity(0.4) : Color.white.opacity(0.8), lineWidth: 3)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeInOut, value: foundText)
            .allowsHitTesting(false)
    }
}

#Preview {
    AnalyzeView()
}
