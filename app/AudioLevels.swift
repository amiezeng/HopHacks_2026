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
        // Long: a ring that spreads slowly reads as water settling, where a quick one reads as a flash.
        life = .random(in: 2...3.2) * (0.6 + 0.4 * size)
        reach = size * .random(in: 0.7...1) * (0.5 + 0.5 * level)
        strength = level * (0.5 + 0.5 * size)
    }
}

/// Listens on the microphone and reports how loud three bands of what it hears are — bass, mids and
/// highs, each 0–1 and smoothed — plus the drops of water each band has shaken loose.
/// `WaterVisualizer` draws them.
///
/// Loudness is measured against the room rather than against a fixed scale: every band learns the quiet
/// it is sitting in (`floor`) and only what rises well over that counts, so a fan, a hum or a busy street
/// leaves the water still and only someone actually speaking breaks it.
///
/// It reads the microphone raw — see `Speaker.configureAudioSession`, which it shares with the voice
/// stack; iOS's own gain control would otherwise make a silent room read like speech.
@Observable
final class AudioLevels {
    /// Loudness of each band, 0–1, in the order of `bands`. Not observed: nothing outside this class
    /// reads it, and it is rewritten on every microphone buffer (~45 a second) — `@Observable`
    /// invalidates on the write rather than on the value changing, so leaving it observed redrew
    /// `WaterWell` 45 times a second even in a silent room.
    @ObservationIgnored private(set) var levels: [CGFloat] = [0, 0, 0]
    /// The drops still spreading, oldest first.
    private(set) var drops: [WaterDrop] = []

    /// The three bands, in Hz: bass, mids, highs.
    static let bands: [ClosedRange<Float>] = [40...250, 250...2000, 2000...8000]
    /// Roughly how often a band can shed drops; the higher bands patter faster. Each wait is jittered
    /// around this so the drops never fall in time with each other. Kept slow enough that a sentence
    /// reads as rain on open water rather than as a downpour — the rings have room to be seen.
    private static let dropGap: [TimeInterval] = [0.5, 0.42, 0.36]
    /// As many drops as the screen can usefully hold. Well under what a fast talker can shake loose:
    /// past a couple of dozen overlapping rings the surface is just texture.
    private static let mostDrops = 48
    /// How each band's noise floor learns the room it is in, per buffer (~45 of them a second): it drops
    /// onto a new quiet in a fraction of a second and creeps back up over about ten, so a fan or a hum
    /// sinks into it (a new one within a few seconds of starting) while a sentence never does — speech
    /// falls back to the room between phrases, and the floor snaps down with it.
    private static let floorFall: Float = 0.15, floorRise: Float = 0.0025
    /// Where the floor starts, and as high as it is ever allowed to learn: a loud room still has to leave
    /// headroom to be heard over, and starting up here keeps the water still while the room is found.
    private static let floorCeiling: Float = -28
    /// How far over the room, in dB, a sound has to be before the water feels it at all, and how much
    /// louder again reads as full strength. A voice a couple of feet away runs 20–35 dB over a quiet room.
    private static let overRoom: Float = 14, span: Float = 20
    /// Drops only fall while something is being said: a band has to reach `speaks` to set the water off,
    /// and every band has to fall back under `hushes` before it settles again.
    private static let speaks: CGFloat = 0.3, hushes: CGFloat = 0.12

    private let engine = AVAudioEngine()
    private let analyzer = BandAnalyzer(size: 1024)
    private var lastDrop: [TimeInterval] = [0, 0, 0]
    private var wait: [TimeInterval] = dropGap
    /// The quiet each band is sitting in, in dBFS — see `floorFall`.
    private var floor: [Float] = [floorCeiling, floorCeiling, floorCeiling]
    /// Whether the water is currently answering something; see `speaks`.
    private var speaking = false
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
        // The session isn't ours to end — `VoiceListener` is usually still on it.
        levels = [0, 0, 0]
        drops = []
        floor = [Self.floorCeiling, Self.floorCeiling, Self.floorCeiling]
        speaking = false
    }

    private func listen() {
        do {
            // The app's one session, the same one `Speaker` and `VoiceListener` ask for — it records in
            // `.measurement` so what arrives here is the raw microphone. Setting a second configuration
            // here is what used to make the water so jumpy: the voice stack set its own on top, and
            // whichever went last decided whether iOS was quietly amplifying the room.
            try Speaker.configureAudioSession()
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
            guard let self, let heard = analyzer.decibels(buffer, sampleRate: rate) else { return }
            DispatchQueue.main.async { self.publish(heard) }
        }
        do {
            try engine.start()
        } catch {
            Logger().error("AudioLevels: engine failed to start: \(error.localizedDescription)")
        }
    }

    /// Measures the new reading against the room, eases it into `levels` (quick to rise, slow to fall,
    /// like a VU meter), and — only while something is being said — shakes a few drops loose from any
    /// band that just jumped, a syllable or a beat, or that has stayed loud. How many fall, and how long
    /// until the band can shed more, are both random, so speaking scatters drops across the water
    /// instead of tapping out a rhythm.
    private func publish(_ heard: [Float]) {
        let now = Date.timeIntervalSinceReferenceDate
        var next = levels
        var rise = [CGFloat](repeating: 0, count: next.count)
        for band in heard.indices where band < next.count {
            // Learn this band's quiet, then read only what stands over it — a room's own noise sits at
            // its floor and so reads as nothing at all, however loud the room happens to be.
            let db = heard[band], pull = db < floor[band] ? Self.floorFall : Self.floorRise
            floor[band] = min(floor[band] + (db - floor[band]) * pull, Self.floorCeiling)
            let over = CGFloat(min(max((db - floor[band] - Self.overRoom) / Self.span, 0), 1))
            let jump = over - next[band]
            rise[band] = max(jump, 0)
            next[band] += jump * (jump > 0 ? 0.55 : 0.12)
        }
        // One band passing `speaks` sets all three going, and they all keep going until the loudest has
        // died back under `hushes`, so a sentence rains across the whole surface but a quiet room can't
        // trickle drops out by wandering over a threshold.
        let loudest = next.max() ?? 0
        speaking = loudest > (speaking ? Self.hushes : Self.speaks)

        if speaking {
            for band in next.indices {
                let level = next[band], since = now - lastDrop[band]
                let beat = rise[band] > 0.12 && level > Self.hushes
                let held = level > Self.speaks && since > wait[band] * 1.5
                guard since > wait[band], beat || held else { continue }
                lastDrop[band] = now
                wait[band] = Self.dropGap[band] * .random(in: 0.45...1.5)
                // A burst: one fat drop and at most a little spray around it, more of it the louder it
                // got. A handful at a time was what made the water look like static rather than rain.
                for drop in 0 ... Int.random(in: 0...1) + Int(level * 2) {
                    drops.append(WaterDrop(band: band, level: level,
                                           size: drop == 0 ? 1 : .random(in: 0.28...0.62)))
                }
            }
        }
        levels = next

        // `drops` is observed, and writing it redraws the water — so on a still surface it is worth
        // looking before touching, which costs a read-only pass over at most `mostDrops` of them.
        // (Don't gate this on the value instead: a band is only ever nudged a fraction of the way
        // towards what was heard, so a threshold on the change parks a decaying level short of zero,
        // and one parked at `hushes` would leave the water speaking forever.)
        if drops.count > Self.mostDrops || drops.contains(where: { now - $0.born > $0.life }) {
            drops.removeAll { now - $0.born > $0.life }
            if drops.count > Self.mostDrops { drops.removeFirst(drops.count - Self.mostDrops) }
        }
    }
}

/// The FFT behind `AudioLevels`: a buffer of samples in, the loudness of each band out in dBFS.
/// What counts as loud is `AudioLevels`' business, since that depends on the room.
/// Its own state is read-only, and it is only ever called from the microphone tap's thread.
private final class BandAnalyzer: @unchecked Sendable {
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

    /// How loud each of `AudioLevels.bands` is in this buffer, in dBFS, or nil if it can't be read.
    func decibels(_ buffer: AVAudioPCMBuffer, sampleRate: Float) -> [Float]? {
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
            guard low <= high else { return -140 }
            let bins = magnitudes[low...high]
            let rms = (bins.reduce(0) { $0 + $1 * $1 } / Float(bins.count)).squareRoot()
            // `vDSP_fft_zrip` scales its output by 2, so a full-scale tone lands around size / 2.
            return 20 * log10(max(rms / Float(half), 1e-7))
        }
    }
}
