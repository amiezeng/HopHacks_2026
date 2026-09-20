import SwiftUI
import UIKit

/// `ArtLayer`s drawn into bitmaps once, at the pixel size they're laid out at, and drawn as those
/// images from then on.
///
/// The layers are big paths — the monster is most of a screen of bezier curves, the ANALYZE lettering
/// is glyph outlines — and a path is transformed and filled again every time the view holding it
/// redraws. The Analyze face pays it twice over, once plain and once magnified under the lens. As
/// images those redraws are the GPU moving a texture instead, which is what keeps a screen at 60 fps
/// while it animates.
///
/// `Preloader` fills this at launch, off the main thread, at the sizes the two screens lay their layers
/// out at. Anything it misses (a size it couldn't work out up front) is rendered off the main thread on
/// first use, with the paths drawn until it's ready — so a layer never stalls a frame to rasterize.
enum ArtRaster {
    /// Worth it only past a few dozen path elements: a flat background rectangle is cheaper to fill
    /// every frame than a screen-sized texture is to hold.
    static let leastElements = 24
    /// Cap on what's held, in pixels (4 bytes each). Past it, layers keep drawing as paths.
    private static let mostPixels = 20_000_000

    private struct Key: Hashable {
        let layer: Int
        let width: Int
        let height: Int
    }

    private static let lock = NSLock()
    private static var images: [Key: CGImage] = [:]
    private static var pixels = 0

    /// The layer as an image `size` points across at `scale` pixels per point, rendering it if this is
    /// the first ask. Nil for a layer that isn't worth rasterizing, or once the cache is full.
    static func image(of layer: ArtLayer, size: CGSize, scale: CGFloat) -> CGImage? {
        guard layer.elements >= leastElements, scale > 0 else { return nil }
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, layer.bounds.width > 0, layer.bounds.height > 0 else { return nil }
        let key = Key(layer: layer.id, width: width, height: height)

        lock.lock()
        if let hit = images[key] {
            lock.unlock()
            return hit
        }
        let full = pixels + width * height > mostPixels
        lock.unlock()
        guard !full, let image = render(layer, width: width, height: height) else { return nil }

        lock.lock()
        // Another thread may have rendered the same layer meanwhile; either image will do.
        if images[key] == nil {
            images[key] = image
            pixels += width * height
        }
        lock.unlock()
        return image
    }

    private static func render(_ layer: ArtLayer, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // A bitmap's y runs up the image and the artwork's runs down, so the y scale is negated from
        // the top. Within that, the layer's own bounds are mapped onto the whole image — the same
        // mapping `ArtShape` makes onto the rect it is drawn in.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / layer.bounds.width, y: -CGFloat(height) / layer.bounds.height)
        context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        for fill in layer.fills {
            context.addPath(fill.path.cgPath)
            context.setFillColor(UIColor(fill.color).cgColor)
            context.fillPath(using: fill.evenOdd ? .evenOdd : .winding)
        }
        return context.makeImage()
    }
}

private struct ArtOversampleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Extra resolution for the artwork in here, for layers that are then scaled up — the copy of the
    /// Analyze face magnified under the lens, which would otherwise be a screen-resolution image
    /// blown up past its own pixels.
    var artOversample: CGFloat {
        get { self[ArtOversampleKey.self] }
        set { self[ArtOversampleKey.self] = newValue }
    }
}
