import Foundation

@MainActor
final class InteractionAnnouncer {
    private let threshold: Float = 0.7
    private let cooldown: TimeInterval = 3
    private var armed = true
    private var lastSpoken = Date.distantPast

    func update(confidence: Float) {
        guard confidence >= threshold else {
            armed = true
            return
        }
        guard armed else { return }
        armed = false

        // crossing threhold during cooldown just gets dropped
        let now = Date()
        guard now.timeIntervalSince(lastSpoken) >= cooldown else { return }
        lastSpoken = now
        Speaker.shared.speak("Interacting with object")
    }
}
