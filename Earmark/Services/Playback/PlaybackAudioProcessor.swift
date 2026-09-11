import AVFoundation
import MediaToolbox
import Accelerate
import os

/// Real-time audio effects applied to the playing track via an `MTAudioProcessingTap`:
///   • Volume boost — amplifies quiet narration past the 1.0 ceiling `AVPlayer.volume` imposes,
///     with a hard limiter so it never clips harshly.
///   • Skip silence — measures loudness and, during sustained quiet, tells the engine to race the
///     playback rate up until speech returns (this is "Smart Speed").
///
/// Everything here must be robust: if a tap can't be built or the audio isn't 32-bit float, the
/// book plays normally with no effect. The process callback runs on a realtime audio thread, so it
/// only reads a lock-protected config and hops to the main actor to change the rate.
/// The skip-silence decision, factored out so it can be unit-tested without any audio plumbing.
/// Feed it the loudness of each buffer; it reports when to speed up (entered silence) or drop back
/// (speech returned), with hysteresis and a minimum silence duration so word gaps aren't clipped.
struct SilenceGate {
    var isSilent = false
    private var accum: Double = 0

    enum Change { case enteredSilence, endedSilence }

    mutating func step(rms: Float, seconds: Double,
                       enter: Float = PlaybackAudioProcessor.enterRMS,
                       exit: Float = PlaybackAudioProcessor.exitRMS,
                       minSeconds: Double = PlaybackAudioProcessor.enterSeconds) -> Change? {
        if rms < enter {
            accum += seconds
            if !isSilent && accum >= minSeconds { isSilent = true; return .enteredSilence }
        } else if rms > exit {
            accum = 0
            if isSilent { isSilent = false; return .endedSilence }
        }
        return nil
    }

    mutating func reset() { isSilent = false; accum = 0 }
}

final class PlaybackAudioProcessor {
    /// Loudness below this (linear RMS, ~-34 dBFS) counts as silence; above the exit value ends it.
    fileprivate static let enterRMS: Float = 0.02
    fileprivate static let exitRMS: Float = 0.035
    /// Silence must persist this long before we speed up (skip micro-gaps between words, keep sentences).
    fileprivate static let enterSeconds: Double = 0.12

    struct Config: Sendable {
        var gain: Float = 1
        var skipSilence = false
        var baseRate: Float = 1
        var boostQuiet = false          // upward compression: lift quiet narration, tame spikes
        var silenceRate: Float { min(max(baseRate, 1) * 3, 4.0) }
        var needsTap: Bool { gain != 1 || skipSilence || boostQuiet }
    }

    /// Called on the main actor when the rate should change (fast during silence, back to base after).
    var onRateChange: (@MainActor (Float) -> Void)?

    private let config = OSAllocatedUnfairLock(initialState: Config())
    private weak var activeContext: TapContext?

    func update(gain: Float, skipSilence: Bool, baseRate: Float, boostQuiet: Bool) {
        let wasSkipping = config.withLock { c -> Bool in
            let was = c.skipSilence
            c.gain = gain; c.skipSilence = skipSilence; c.baseRate = baseRate; c.boostQuiet = boostQuiet
            return was
        }
        activeContext?.setConfig(currentConfig())
        // If skip-silence was just turned off mid-gap, make sure we don't leave the rate stuck high.
        if wasSkipping && !skipSilence, let ctx = activeContext {
            ctx.forceBaseRate(baseRate)
        }
    }

    func currentConfig() -> Config { config.withLock { $0 } }

    /// Builds an audio mix that routes `track` through a fresh tap. Returns nil on any failure.
    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let context = TapContext(config: currentConfig(), onRateChange: onRateChange)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: tapUnprepare, process: tapProcess)

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            Logger.player.error("[audio] tap create failed: \(status)")
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        activeContext = context
        Logger.player.info("[audio] tap attached gain=\(self.currentConfig().gain) skipSilence=\(self.currentConfig().skipSilence)")
        return mix
    }
}

/// Audio-thread state behind the tap. Held alive by the tap's clientInfo (retained in `makeAudioMix`,
/// released in the finalize callback).
final class TapContext {
    private let config: OSAllocatedUnfairLock<PlaybackAudioProcessor.Config>
    private let onRateChange: (@MainActor (Float) -> Void)?
    var sampleRate: Double = 0
    var isFloat = false
    // silence state (touched only on the audio thread)
    private var gate = SilenceGate()
    var compEnv: Float = 0          // smoothed envelope for upward compression

    init(config: PlaybackAudioProcessor.Config, onRateChange: (@MainActor (Float) -> Void)?) {
        self.config = OSAllocatedUnfairLock(initialState: config)
        self.onRateChange = onRateChange
    }

    func setConfig(_ new: PlaybackAudioProcessor.Config) { config.withLock { $0 = new } }
    func currentConfig() -> PlaybackAudioProcessor.Config { config.withLock { $0 } }

    func forceBaseRate(_ rate: Float) {
        gate.reset()
        dispatchRate(rate)
    }

    /// Called from the process callback with the measured loudness of this buffer.
    func handle(rms: Float, seconds: Double) {
        let cfg = currentConfig()
        guard cfg.skipSilence else {
            if gate.isSilent { forceBaseRate(cfg.baseRate) }
            return
        }
        switch gate.step(rms: rms, seconds: seconds) {
        case .enteredSilence: dispatchRate(cfg.silenceRate)
        case .endedSilence: dispatchRate(cfg.baseRate)
        case nil: break
        }
    }

    /// Upward compressor: boosts samples below a threshold so quiet narration is audible, with a
    /// slow release to avoid pumping, then soft-limits so nothing clips. Runs on the audio thread.
    func compress(_ ptr: UnsafeMutablePointer<Float>, count n: Int) {
        let sr = Float(sampleRate)
        let attack = 1 - exp(-1 / (0.003 * sr))   // ~3 ms
        let release = 1 - exp(-1 / (0.180 * sr))  // ~180 ms
        let threshold: Float = 0.12               // ~ -18 dBFS
        let maxGain: Float = 3.2                  // up to ~ +10 dB on the quietest parts
        var env = compEnv
        for i in 0..<n {
            let x = ptr[i]
            let ax = abs(x)
            env += (ax > env ? attack : release) * (ax - env)
            let e = max(env, 1e-4)
            var g: Float = 1
            if e < threshold { g = min(maxGain, sqrt(threshold / e)) }   // ratio ~2:1 upward
            var y = x * g
            if y > 0.98 { y = 0.98 } else if y < -0.98 { y = -0.98 }
            ptr[i] = y
        }
        compEnv = env
    }

    private func dispatchRate(_ rate: Float) {
        guard let onRateChange else { return }
        DispatchQueue.main.async { onRateChange(rate) }
    }
}

// MARK: - C tap callbacks

private func context(_ tap: MTAudioProcessingTap) -> TapContext {
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo  // hand our TapContext pointer to GetStorage
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let ctx = context(tap)
    ctx.sampleRate = format.pointee.mSampleRate
    ctx.isFloat = (format.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let ctx = context(tap)
    guard ctx.isFloat else { return }  // pass non-float audio through untouched
    let cfg = ctx.currentConfig()

    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    var sumSquares: Float = 0
    var sampleCount: Int = 0
    for buffer in abl {
        guard let base = buffer.mData else { continue }
        let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard n > 0 else { continue }
        let ptr = base.assumingMemoryBound(to: Float.self)
        if cfg.gain != 1 {
            var g = cfg.gain
            vDSP_vsmul(ptr, 1, &g, ptr, 1, vDSP_Length(n))
        }
        if cfg.boostQuiet, ctx.sampleRate > 0 {
            ctx.compress(ptr, count: n)   // upward compression + soft limit
        } else if cfg.gain != 1 {
            var lo: Float = -0.98, hi: Float = 0.98   // limiter — boosted peaks never clip harshly
            vDSP_vclip(ptr, 1, &lo, &hi, ptr, 1, vDSP_Length(n))
        }
        var meanSquare: Float = 0
        vDSP_measqv(ptr, 1, &meanSquare, vDSP_Length(n))
        sumSquares += meanSquare * Float(n)
        sampleCount += n
    }
    guard cfg.skipSilence, ctx.sampleRate > 0, sampleCount > 0 else { return }
    let rms = sqrt(sumSquares / Float(sampleCount))
    let seconds = Double(numberFrames) / ctx.sampleRate
    ctx.handle(rms: rms, seconds: seconds)
}
