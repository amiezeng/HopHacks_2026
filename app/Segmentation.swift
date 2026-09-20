import Foundation
import Combine
import Vision
import CoreML
import ARKit
import CoreGraphics

struct Segment: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect // normalized 0-1, Vision coords (origin bottom-left)
    let color: CGColor
}

// Union of all detected masks over the full upright image, at proto-grid resolution (row 0 = top).
struct ObjectMask {
    let width: Int
    let height: Int
    let pixels: [Bool]
    // Outer contour cell centers, normalized 0-1 Vision coords. Like cv2.RETR_EXTERNAL: holes are ignored.
    let edge: [CGPoint]
    // Centroid of the mask cells, normalized 0-1 Vision coords. Snapped to the nearest mask cell when the
    // centroid falls outside the mask (e.g. two objects side by side), so depth there is the object's.
    let center: CGPoint

    init?(width: Int, height: Int, pixels: [Bool]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels

        // Flood-fill the background from the border so hole boundaries don't count as edges.
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for x in 0..<width { stack += [x, (height - 1) * width + x] }
        for y in 0..<height { stack += [y * width, y * width + width - 1] }
        while let i = stack.popLast() {
            guard !pixels[i], !outside[i] else { continue }
            outside[i] = true
            let x = i % width, y = i / width
            if x > 0 { stack.append(i - 1) }
            if x < width - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - width) }
            if y < height - 1 { stack.append(i + width) }
        }

        // Edge = mask pixel on the image border or touching the outside background.
        var edge: [CGPoint] = []
        var sumX = 0, sumY = 0, count = 0
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] {
                sumX += x; sumY += y; count += 1
                let i = y * width + x
                let onEdge = x == 0 || y == 0 || x == width - 1 || y == height - 1
                    || outside[i - 1] || outside[i + 1] || outside[i - width] || outside[i + width]
                if onEdge {
                    edge.append(CGPoint(
                        x: (CGFloat(x) + 0.5) / CGFloat(width),
                        y: 1 - (CGFloat(y) + 0.5) / CGFloat(height)
                    ))
                }
            }
        }
        guard !edge.isEmpty else { return nil }
        self.edge = edge

        var cx = Int((Double(sumX) / Double(count)).rounded())
        var cy = Int((Double(sumY) / Double(count)).rounded())
        if !pixels[cy * width + cx] {
            var best = Int.max
            let (mx, my) = (cx, cy)
            for y in 0..<height {
                for x in 0..<width where pixels[y * width + x] {
                    let d = (x - mx) * (x - mx) + (y - my) * (y - my)
                    if d < best { best = d; cx = x; cy = y }
                }
            }
        }
        center = CGPoint(
            x: (CGFloat(cx) + 0.5) / CGFloat(width),
            y: 1 - (CGFloat(cy) + 0.5) / CGFloat(height)
        )
    }

    // point is normalized 0-1, Vision coords.
    func contains(_ point: CGPoint) -> Bool {
        let x = Int(point.x * CGFloat(width))
        let y = Int((1 - point.y) * CGFloat(height))
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return pixels[y * width + x]
    }

    // Nearest contour point in image pixels (not normalized units, which are stretched by the aspect ratio).
    // Brute force: with one query per hand per frame this is cheaper than building a k-d tree.
    func nearestEdgePoint(to point: CGPoint) -> CGPoint? {
        let w = CGFloat(width), h = CGFloat(height)
        func squaredDistance(_ p: CGPoint) -> CGFloat {
            let dx = (p.x - point.x) * w, dy = (p.y - point.y) * h
            return dx * dx + dy * dy
        }
        return edge.min { squaredDistance($0) < squaredDistance($1) }
    }
}

// Runs the YOLO26n-seg model on AR frames and produces boxes plus a combined mask image.
class SegmentationDetector: ObservableObject {
    @Published var segments: [Segment] = []
    @Published var maskImage: CGImage? = nil // covers the full upright camera image
    @Published var objectMask: ObjectMask? = nil // same pixels as maskImage, plus the outer contour
    @Published var status = "segmentation: loading" // debug line shown on screen

    private var request: VNCoreMLRequest?
    private let queue = DispatchQueue(label: "com.hophacks.segmentation", qos: .userInitiated)
    private let minInterval: TimeInterval = 0.1 
    private var lastTimestamp: TimeInterval = 0
    private var busy = false

    private var inputSize: CGFloat = 640 // read from the model's image input at load
    private let confidenceThreshold: Float = 0.02   
    private let maskThreshold: Float = 0.5
    @Published private(set) var uprightImageSize = CGSize(width: 1440, height: 1920)
    private var classNames: [String] = []

    // Only classes matching this filter are detected (COCO model: bottles only). Return true to allow every class.
    var classFilter: (String) -> Bool = { name in
        name == "bottle"
    } {
        didSet { updateAllowedIndices() }
    }
    private var allowedIndices: [Int] = []

    private func updateAllowedIndices() {
        allowedIndices = classNames.indices.filter { classFilter(classNames[$0]) }
        status = "\(classNames.count) classes, \(allowedIndices.count) allowed"
        if allowedIndices.isEmpty {
            print("Segmentation: no model classes match the filter; nothing will be detected")
        }
    }

    private static let palette: [(UInt8, UInt8, UInt8)] = [
        (255, 56, 56), (255, 157, 151), (255, 112, 31), (255, 178, 29), (207, 210, 49),
        (72, 249, 10), (146, 204, 23), (61, 219, 134), (26, 147, 52), (0, 212, 187),
        (44, 153, 168), (0, 194, 255), (52, 69, 147), (100, 115, 255), (0, 24, 236),
        (132, 56, 255), (82, 0, 133), (203, 56, 255), (255, 149, 200), (255, 55, 199)
    ]

    // modelName: compiled model in the bundle. "yolo26n-seg" (COCO) or "yoloe-26n-seg" (YOLOE with text
    // prompts baked in at export, see model_trainig_code/scripts/export_yoloe.py; not bundled yet).
    init(modelName: String = "yolo26n-seg") {
        do {
            guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
                print("\(modelName) model not found in bundle")
                status = "segmentation: model not found in bundle"
                return
            }
            let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
            classNames = Self.parseClassNames(model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])
            updateAllowedIndices()
            if let image = model.modelDescription.inputDescriptionsByName.values.first(where: { $0.type == .image })?.imageConstraint {
                inputSize = CGFloat(image.pixelsWide)
            }
            let req = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
            req.imageCropAndScaleOption = .scaleFit
            request = req
        } catch {
            print("Failed to load segmentation model: \(error)")
            status = "segmentation: load failed"
        }
    }

    // Metadata "names" looks like "{0: 'person', 1: 'bicycle', ...}".
    private static func parseClassNames(_ metadata: [String: String]?) -> [String] {
        guard let raw = metadata?["names"] else { return [] }
        return raw.components(separatedBy: ", ").compactMap { entry in
            guard let start = entry.firstIndex(of: "'"), let end = entry.lastIndex(of: "'"), start < end else { return nil }
            return String(entry[entry.index(after: start)..<end])
        }
    }

    func process(frame: ARFrame) {
        let now = Date().timeIntervalSince1970
        guard !busy, now - lastTimestamp >= minInterval, let request else { return }
        lastTimestamp = now
        busy = true

        let pixelBuffer = frame.capturedImage
        queue.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.busy = false } }

            // .right rotates the landscape sensor buffer to portrait, so width/height swap.
            let imageSize = CGSize(
                width: CVPixelBufferGetHeight(pixelBuffer),
                height: CVPixelBufferGetWidth(pixelBuffer)
            )
            if imageSize != self.uprightImageSize {
                DispatchQueue.main.sync { self.uprightImageSize = imageSize }
            }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            do {
                try handler.perform([request])
            } catch {
                print("Segmentation failed: \(error)")
                return
            }

            let outputs = (request.results as? [VNCoreMLFeatureValueObservation]) ?? []
            let arrays = outputs.compactMap { $0.featureValue.multiArrayValue }
            guard let predictions = arrays.first(where: { $0.shape.count == 3 }),
                  let protos = arrays.first(where: { $0.shape.count == 4 }) else { return }

            let (segments, maskImage, objectMask) = self.decode(predictions: predictions, protos: protos)
            DispatchQueue.main.async {
                self.segments = segments
                self.maskImage = maskImage
                self.objectMask = objectMask
            }
        }
    }

    // predictions, either layout:
    //   raw:        [1, 4 + classes + 32, N]  (cx, cy, w, h, class scores, mask coeffs), NMS done here
    //   end-to-end: [1, N, 6 + 32]            (x1, y1, x2, y2, score, class, mask coeffs), NMS-free (YOLOE-26)
    // protos: [1, 32, 160, 160]
    private func decode(predictions: MLMultiArray, protos: MLMultiArray) -> ([Segment], CGImage?, ObjectMask?) {
        let maskDim = protos.shape[1].intValue
        let protoH = protos.shape[2].intValue
        let protoW = protos.shape[3].intValue
        let endToEnd = predictions.shape[2].intValue == 6 + maskDim
        let count = predictions.shape[endToEnd ? 1 : 2].intValue
        let classCount = endToEnd ? classNames.count : predictions.shape[1].intValue - 4 - maskDim
        guard classCount > 0,
              predictions.dataType == .float32, protos.dataType == .float32 else { return ([], nil, nil) }

        let pred = predictions.dataPointer.assumingMemoryBound(to: Float32.self)
        let proto = protos.dataPointer.assumingMemoryBound(to: Float32.self)
        // CoreML outputs can be padded, so index with the real strides instead of assuming packed rows.
        let ps = predictions.strides.map { $0.intValue }
        let qs = protos.strides.map { $0.intValue }
        // Channel ch of candidate i, in either layout.
        func p(_ ch: Int, _ i: Int) -> Float32 {
            endToEnd ? pred[i * ps[1] + ch * ps[2]] : pred[ch * ps[1] + i * ps[2]]
        }
        let coeffOffset = endToEnd ? 6 : 4 + classCount

        // Undo .scaleFit letterboxing: the image is centered inside the square model input.
        let scale = min(inputSize / uprightImageSize.width, inputSize / uprightImageSize.height)
        let scaledW = uprightImageSize.width * scale
        let scaledH = uprightImageSize.height * scale
        let padX = (inputSize - scaledW) / 2
        let padY = (inputSize - scaledH) / 2

        struct Candidate {
            let classIndex: Int
            let confidence: Float
            let box: CGRect // model input pixels, top-left origin
            let anchor: Int
        }

        var candidates: [Candidate] = []
        var topScore: Float = 0
        var topClass = 0
        for i in 0..<count {
            var best = 0
            var bestScore: Float = 0
            let box: CGRect
            if endToEnd {
                best = Int(p(5, i))
                guard allowedIndices.contains(best) else { continue }
                bestScore = p(4, i)
                box = CGRect(x: CGFloat(p(0, i)), y: CGFloat(p(1, i)),
                             width: CGFloat(p(2, i) - p(0, i)), height: CGFloat(p(3, i) - p(1, i)))
            } else {
                for c in allowedIndices where c < classCount {
                    let score = p(4 + c, i)
                    if score > bestScore { bestScore = score; best = c }
                }
                let cx = CGFloat(p(0, i)), cy = CGFloat(p(1, i))
                let w = CGFloat(p(2, i)), h = CGFloat(p(3, i))
                box = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            }
            if bestScore > topScore { topScore = bestScore; topClass = best }
            guard bestScore >= confidenceThreshold else { continue }
            candidates.append(Candidate(classIndex: best, confidence: bestScore, box: box, anchor: i))
        }

        // Per-class NMS (a no-op for end-to-end outputs, which are already deduplicated)
        candidates.sort { $0.confidence > $1.confidence }
        var kept: [Candidate] = []
        for candidate in candidates {
            let overlaps = kept.contains {
                $0.classIndex == candidate.classIndex && iou($0.box, candidate.box) > 0.45
            }
            if !overlaps { kept.append(candidate) }
            if kept.count >= 20 { break }
        }

        // Mask canvas covers only the non-padded region of the proto grid.
        let protoScale = CGFloat(protoW) / inputSize
        let x0 = Int((padX * protoScale).rounded()), x1 = protoW - x0
        let y0 = Int((padY * protoScale).rounded()), y1 = protoH - y0
        let canvasW = x1 - x0, canvasH = y1 - y0
        var largestMask = [Bool](repeating: false, count: canvasW * canvasH)
        var largestMaskArea = 0
        var largestMaskColor: (UInt8, UInt8, UInt8) = (255, 255, 255)

        var segments: [Segment] = []
        for candidate in kept {
            let rgb = Self.palette[candidate.classIndex % Self.palette.count]
            var candidateMask = [Bool](repeating: false, count: canvasW * canvasH)
            var coeffs = [Float](repeating: 0, count: maskDim)
            for k in 0..<maskDim { coeffs[k] = p(coeffOffset + k, candidate.anchor) }

            // Only evaluate the mask inside the box.
            let bx0 = max(x0, Int(candidate.box.minX * protoScale))
            let bx1 = min(x1, Int(candidate.box.maxX * protoScale))
            let by0 = max(y0, Int(candidate.box.minY * protoScale))
            let by1 = min(y1, Int(candidate.box.maxY * protoScale))
            if bx1 > bx0 && by1 > by0 {
                for y in by0..<by1 {
                    for x in bx0..<bx1 {
                        var logit: Float = 0
                        for k in 0..<maskDim {
                            logit += coeffs[k] * proto[k * qs[1] + y * qs[2] + x * qs[3]]
                        }
                        // sigmoid(logit) > maskThreshold
                        guard 1 / (1 + exp(-logit)) > maskThreshold else { continue }
                        let i = (y - y0) * canvasW + (x - x0)
                        candidateMask[i] = true
                    }
                }
            }

            let candidateArea = candidateMask.reduce(into: 0) { count, pixel in
                if pixel { count += 1 }
            }
            if candidateArea > largestMaskArea {
                largestMask = candidateMask
                largestMaskArea = candidateArea
                largestMaskColor = rgb
            }

            // Model pixels -> normalized upright image, then flip to Vision coords.
            let minX = max(0, (candidate.box.minX - padX) / scaledW)
            let maxX = min(1, (candidate.box.maxX - padX) / scaledW)
            let minY = max(0, (candidate.box.minY - padY) / scaledH)
            let maxY = min(1, (candidate.box.maxY - padY) / scaledH)
            guard maxX > minX, maxY > minY else { continue }

            let label = candidate.classIndex < classNames.count ? classNames[candidate.classIndex] : "class \(candidate.classIndex)"
            segments.append(Segment(
                label: label,
                confidence: candidate.confidence,
                boundingBox: CGRect(x: minX, y: 1 - maxY, width: maxX - minX, height: maxY - minY),
                color: CGColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
            ))
        }

        let topName = topClass < classNames.count ? classNames[topClass] : "?"
        let line = "\(classNames.count) classes, \(allowedIndices.count) allowed · top \(topName) \(String(format: "%.2f", topScore * 100))% (min \(Int(confidenceThreshold * 100))%)"
        DispatchQueue.main.async { self.status = line }

        var rgba = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
        for i in largestMask.indices where largestMask[i] {
            let pixel = i * 4
            rgba[pixel] = largestMaskColor.0
            rgba[pixel + 1] = largestMaskColor.1
            rgba[pixel + 2] = largestMaskColor.2
            rgba[pixel + 3] = 255
        }

        return (
            segments,
            makeImage(rgba: rgba, width: canvasW, height: canvasH),
            ObjectMask(width: canvasW, height: canvasH, pixels: largestMask)
        )
    }

    private func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
