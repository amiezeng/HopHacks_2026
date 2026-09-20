import SwiftUI
import UIKit

/// Builds what the screens need before the app shows any of them, while `LoadingScreen` is up.
///
/// Two things used to be built lazily on the main thread at the moment a screen appeared, and both
/// showed as a hitch: the Illustrator artwork (`HomeArt`/`MainArt` are Swift statics, so their paths
/// are built on first use — the home → main water pour landed on it) and the CoreML models (loaded
/// in the detectors' `init`, so tapping Find stalled the push into `ContentView`).
@MainActor
final class Preloader: ObservableObject {
    @Published private(set) var isReady = false
    /// True once the home screen has been on screen (under the loading screen) long enough to have drawn.
    @Published private(set) var isRevealed = false
    /// What `LoadingScreen` says it's doing.
    @Published private(set) var step = "Getting ready"

    /// Keeps the loading screen up long enough to be read rather than flashing past on a warm launch.
    private let minimumDuration = Duration.milliseconds(900)

    func warm() async {
        guard !isReady else { return }
        let started = ContinuousClock.now

        step = "Drawing the artwork"
        let display = Self.display()
        await Task.detached(priority: .userInitiated) {
            Self.buildArtwork()
            if let display { Self.rasterizeArtwork(screen: display.size, scale: display.scale) }
        }.value

        step = "Loading the vision models"
        await Task.detached(priority: .userInitiated) { Self.loadModels() }.value

        step = "Ready"
        let elapsed = ContinuousClock.now - started
        if elapsed < minimumDuration {
            try? await Task.sleep(for: minimumDuration - elapsed)
        }
        isReady = true
        // Let the home screen lay out and draw (and any layer not warmed above finish rasterizing)
        // while it is still covered.
        try? await Task.sleep(for: .milliseconds(400))
        isRevealed = true
    }

    /// Touching a layer builds its paths; `HomeArt.layers`/`MainArt.layers` list every one the home
    /// and main screens draw.
    private nonisolated static func buildArtwork() {
        for layer in HomeArt.layers + MainArt.layers {
            _ = layer.bounds
        }
        // Splitting "PROBE" into letters for the hop-in wave walks every subpath of the title.
        _ = HomeScreen.titleLetters
    }

    /// The window's size in points and the display's pixels per point, to rasterize the artwork at the
    /// size it will actually be drawn. Nil before there's a window, and the layers then rasterize
    /// themselves as they first appear instead.
    private static func display() -> (size: CGSize, scale: CGFloat)? {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            return (scene.screen.bounds.size, scene.screen.scale)
        }
        // The scene can still be connecting when the first task runs; fall back to the device screen.
        let screen = UIScreen.main
        return (screen.bounds.size, screen.scale)
    }

    /// Draws every layer into an image the size it will be laid out at (`ArtRaster`). Both screens fill
    /// the window with their artboard, which is what `Artboard` scales every layer's bounds by.
    private nonisolated static func rasterizeArtwork(screen: CGSize, scale: CGFloat) {
        func fill(_ artboard: CGRect) -> CGFloat {
            max(screen.width / artboard.width, screen.height / artboard.height)
        }
        func warm(_ layers: [ArtLayer], _ fill: CGFloat, oversample: CGFloat = 1) {
            for layer in layers {
                _ = ArtRaster.image(
                    of: layer,
                    size: CGSize(width: layer.bounds.width * fill, height: layer.bounds.height * fill),
                    scale: scale * oversample
                )
            }
        }
        warm(HomeArt.layers + HomeScreen.titleLetters, fill(HomeArt.artboard))
        warm(MainArt.layers, fill(MainArt.artboard))
        // The copy of the Analyze face under the lens is asked for at the lens' magnification.
        warm([MainArt.analyzeCard, MainArt.analyzeLabel], fill(MainArt.artboard), oversample: MainScreen.lensZoom)
    }

    private nonisolated static func loadModels() {
        do {
            if let segmentation = try ModelStore.model(names: [SegmentationDetector.defaultModelName]) {
                ModelStore.prime(segmentation)
            }
            // Bundled but disabled (`ObjectDetector.yoloEnabled`), so it isn't primed — just loaded,
            // so flipping it back on doesn't put the load back in the way of the navigation.
            _ = try ModelStore.model(names: ObjectDetector.objectModelNames)
        } catch {
            print("Preloader: model warmup failed: \(error)")
        }
    }
}
