import Foundation
import CoreML
import Vision
import CoreGraphics

/// Loads the bundle's CoreML models once and keeps them.
///
/// Loading a compiled model reads its weights off disk, which was slow enough to stall the
/// navigation into `ContentView`: `ObjectDetector` and `SegmentationDetector` are `@StateObject`s
/// there, so their `init` ran on the main thread the moment the screen was pushed. `Preloader`
/// warms them at launch behind `LoadingScreen` instead, and the detectors take them from here.
enum ModelStore {
    private static let lock = NSLock()
    private static var models: [String: MLModel] = [:]

    /// The first of `names` present in the bundle, loaded once and then shared. `nil` means none of
    /// them is bundled; it throws only when a model is there but won't load.
    static func model(
        names: [String],
        extensions: [String] = ["mlmodelc", "mlpackage", "mlmodel"]
    ) throws -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        for name in names {
            if let cached = models[name] { return cached }
            for ext in extensions {
                guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { continue }
                let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
                models[name] = model
                return model
            }
        }
        return nil
    }

    /// One throwaway inference over a blank image, so the first camera frame doesn't pay for the
    /// model being compiled for the Neural Engine. This is only a warmup: a failure just means the
    /// first real frame is the slow one, so it's logged and ignored.
    static func prime(_ model: MLModel) {
        guard let blank = blankImage else { return }
        do {
            let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
            request.imageCropAndScaleOption = .scaleFit
            try VNImageRequestHandler(cgImage: blank).perform([request])
        } catch {
            print("ModelStore: warmup inference failed: \(error)")
        }
    }

    /// Mid-gray square; Vision scales it up to whatever the model's input wants.
    private static var blankImage: CGImage? {
        let size = 64
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}
