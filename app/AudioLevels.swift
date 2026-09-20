import Accelerate
import AVFoundation
import os
import SwiftUI

/// A drop of water falling on one of `WaterVisualizer`'s three patches of water. Where it lands, how
/// big it is and how long it takes to fade are all picked at random, so no two sound the same.
struct WaterDrop: Identifiable {
    let id = UUID()
    /// Which of `AudioLevels.bands` set it off; it lands in that band's patch of water.
    let band: Int
    /// Where in the patch it lands, each 0–1 across the patch.
    let at: CGPoint
    /// `Date.timeIntervalSinceReferenceDate` when it hits — a moment after it was made, so a handful
    /// of drops scatter across the surface instead of landing together.
    let born: TimeInterval
    /// How long it takes to spread out and fade.
    let life: TimeInterval
    /// How far its rings spread, as a fraction of the patch.
    let reach: CGFloat
    /// How much ink it is drawn with, 0–1.
    let strength: CGFloat

    /// `size` is 1 for the fat drop at the head of a burst and less for the spray that follows it,
    /// which lands smaller, lighter and sooner gone.
    init(band: Int, level: CGFloat, size: CGFloat = 1) {
        self.band = band
        // Anywhere in the patch, spread evenly over it rather than bunched in the middle.
        let angle = Double.random(in: 0 ..< 2 * .pi), out = Double.random(in: 0...1).squareRoot() / 2
        at = CGPoint(x: 0.5 + cos(angle) * out, y: 0.5 + sin(angle) * out)
        born = Date.timeIntervalSinceReferenceDate + .random(in: 0...0.28)
        life = .random(in: 1.2...2.2) * (0.55 + 0.45 * size)
        reach = size * .random(in: 0.7...1) * (0.5 + 0.5 * level)
        strength = level * (0.5 + 0.5 * size)
    }
}

/// Listens on the microphone and reports how loud three bands of what it hears are — bass, mids and
/// highs, each 0–1 and smoothed — plus the drops of water each band has shaken loose.
/// `WaterVisualizer` draws them.
///
/// The session mixes with other audio, so music playing from another app drives it just as a voice does.
final class AudioLevels: ObservableObject {
    /// Loudness of each band, 0–1, in the order of `bands`.
    @Published private(set) var levels: [CGFloat] = [0, 0, 0]
    /// The drops still spreading, oldest first.
    @Published private(set) var drops: [WaterDrop] = []

    /// The three bands, in Hz: bass, mids, highs.
    static let bands: [ClosedRange<Float>] = [40...250, 250...2000, 2000...8000]
    /// Roughly how often a band can shed drops; the higher bands patter faster. Each wait is jittered
    /// around this so the drops never fall in time with each other.
    private static let dropGap: [TimeInterval] = [0.24, 0.17, 0.15]
    /// As many drops as the screen can usefully hold.
    private static let mostDrops = 140

    private let engine = AVAudioEngine()
    private let analyzer = BandAnalyzer(size: 1024)
    private var lastDrop: [TimeInterval] = [0, 0, 0]
    private var wait: [TimeInterval] = dropGap
    private var asking = false

    func start() {
        guard !engine.isRunning, !asking else { return }
        asking = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking = false
                guard granted else {
                    Logger().error("AudioLevels: microphone access denied")
                    return
                }
                self.listen()
            }
        }
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        levels = [0, 0, 0]
        drops = []
    }

    private func listen() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.measurement` keeps iOS's own processing off the signal; `.mixWithOthers` lets whatever
            // is already playing keep playing (and be heard by the mic).
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Logger().error("AudioLevels: audio session failed: \(error.localizedDescription)")
            return
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Logger().error("AudioLevels: no microphone input")
            return
        }
        let rate = Float(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let heard = analyzer.levels(buffer, sampleRate: rate) else { return }
            DispatchQueue.main.async { self.publish(heard) }
        }
        do {
            try engine.start()
        } catch {
            Logger().error("AudioLevels: engine failed to start: \(error.localizedDescription)")
        }
    }

    /// Eases the new reading into `levels` (quick to rise, slow to fall, like a VU meter) and shakes a
    /// few drops loose from any band that just jumped — a syllable, a beat — or that has stayed loud.
    /// How many fall, and how long until the band can shed more, are both random, so speaking scatters
    /// drops across the water instead of tapping out a rhythm.
    private func publish(_ heard: [CGFloat]) {
        let now = Date.timeIntervalSinceReferenceDate
        var next = levels
        for band in heard.indices where band < next.count {
            let jump = heard[band] - next[band]
            next[band] += jump * (jump > 0 ? 0.55 : 0.12)
            let level = next[band], since = now - lastDrop[band]
            let beat = jump > 0.02 && level > 0.06
            let held = level > 0.09 && since > wait[band] * 1.5
            guard since > wait[band], beat || held else { continue }
            lastDrop[band] = now
            wait[band] = Self.dropGap[band] * .random(in: 0.45...1.5)
            // A burst: one fat drop and a handful of spray around it, more of it the louder it got.
            for drop in 0 ... Int.random(in: 1...3) + Int(level * 4) {
                drops.append(WaterDrop(band: band, level: level,
                                       size: drop == 0 ? 1 : .random(in: 0.28...0.62)))
            }
        }
        levels = next
        drops.removeAll { now - $0.born > $0.life }
        if drops.count > Self.mostDrops { drops.removeFirst(drops.count - Self.mostDrops) }
    }
}

/// The FFT behind `AudioLevels`: a buffer of samples in, the loudness of each band out.
/// Its own state is read-only, and it is only ever called from the microphone tap's thread.
private final class BandAnalyzer: @unchecked Sendable {
    /// Level 0 and level 1 of the scale, in dBFS: a quiet room and a loud one.
    private static let quiet: Float = -60, loud: Float = -15

    private let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup?
    private let window: [Float]

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Float(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: size, isHalfWindow: false)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    /// How loud each of `AudioLevels.bands` is in this buffer, 0–1, or nil if it can't be read.
    func levels(_ buffer: AVAudioPCMBuffer, sampleRate: Float) -> [CGFloat]? {
        guard let setup, let samples = buffer.floatChannelData?[0],
              buffer.frameLength >= AVAudioFrameCount(size) else { return nil }
        let half = size / 2

        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        // Real FFT: the windowed samples go in as `half` complex pairs and `half` bins come out.
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
                        vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        let perBin = sampleRate / Float(size)
        return AudioLevels.bands.map { band in
            let low = max(1, Int(band.lowerBound / perBin))
            let high = min(half - 1, Int(band.upperBound / perBin))
            guard low <= high else { return 0 }
            let bins = magnitudes[low...high]
            let rms = (bins.reduce(0) { $0 + $1 * $1 } / Float(bins.count)).squareRoot()
            // `vDSP_fft_zrip` scales its output by 2, so a full-scale tone lands around size / 2.
            let db = 20 * log10(max(rms / Float(half), 1e-7))
            return CGFloat(min(max((db - Self.quiet) / (Self.loud - Self.quiet), 0), 1))
        }
    }
}
