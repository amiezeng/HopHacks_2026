import ARKit
import Combine
import Vision

/// Continuously reads text from the middle of the camera view. Each scan feeds a sliding window
/// (see `TextConsolidator`), and `lines` is the clean, de-duplicated result.
final class TextReader: ObservableObject {
    /// The part of the frame that is read, as fractions of the image. Symmetric, so it doesn't depend on rotation.
    static let region = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)

    @Published private(set) var lines: [String] = []
    @Published private(set) var uprightImageSize = CGSize(width: 1440, height: 1920)

    private let scanInterval: TimeInterval = 0.5
    private let minConfidence: Float = 0.3

    private let queue = DispatchQueue(label: "com.hophacks.textreader", qos: .userInitiated)
    // Touched only on the main thread (ARSession delivers frames there).
    private var isBusy = false
    private var lastScan: TimeInterval = 0
    private var knowsImageSize = false
    // Touched only on `queue`.
    private var consolidator = TextConsolidator()

    /// Forgets everything read so far, so a rescan starts from an empty window.
    func reset() {
        queue.async { [weak self] in self?.consolidator.reset() }
        lines = []
    }

    func process(frame: ARFrame) {
        if !knowsImageSize {
            knowsImageSize = true
            let resolution = frame.camera.imageResolution // landscape; the preview shows it rotated upright
            uprightImageSize = CGSize(width: resolution.height, height: resolution.width)
        }
        guard !isBusy, frame.timestamp - lastScan >= scanInterval else { return }
        isBusy = true
        lastScan = frame.timestamp
        // Keep only the pixel buffer, not the ARFrame, so ARKit's frame pool isn't starved.
        let pixelBuffer = frame.capturedImage
        queue.async { [weak self] in
            self?.scan(pixelBuffer)
            DispatchQueue.main.async { self?.isBusy = false }
        }
    }

    private func scan(_ pixelBuffer: CVPixelBuffer) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Correction can rewrite brand names and numbers; typos in ordinary words are easier to fix later.
        request.usesLanguageCorrection = false
        // Without this the recognizer may pick look-alike letters from other alphabets (a Cyrillic "м" in "mL").
        request.recognitionLanguages = ["en-US"]
        request.regionOfInterest = Self.region

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        do {
            try handler.perform([request])
        } catch {
            print("OCR error: \(error)")
            return
        }

        let readings: [TextReading] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3, text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return TextReading(text: text, midY: observation.boundingBox.midY, minX: observation.boundingBox.minX)
        }

        consolidator.add(readings)
        let consolidated = consolidator.consolidated()

        DispatchQueue.main.async { [weak self] in
            guard let self, consolidated != self.lines else { return }
            self.lines = consolidated
            if consolidated.isEmpty {
                print("OCR: no text")
            } else {
                print("OCR (\(consolidated.count) lines):")
                consolidated.forEach { print("  \($0)") }
            }
        }
    }
}
