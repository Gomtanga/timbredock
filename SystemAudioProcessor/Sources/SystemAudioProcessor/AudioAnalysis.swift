import AppKit
import Accelerate
import AudioRingBufferC
import Combine
import Darwin
import Foundation
import Metal
import MetalKit
import SwiftUI

/// Signal Monitor lifecycle. The stopped value belongs to the app/analysis
/// lifecycle; every other value is produced by the analysis worker tick.
enum AnalysisState: String, Equatable, Sendable {
    case stopped
    case measuring
    case active
    case silence
    case waiting
    case interrupted
}

/// Fixed spectrum geometry shared by the analysis worker and its view. The
/// logarithmic band layout depends only on the analysis sample rate, never on
/// the signal level, so the display range stays relative and unnormalized.
enum SpectrumResolution {
    static let fftSize = 16_384
    static let halfSize = fftSize / 2
    static let bandCount = 128
    static let lowestFrequency: Float = 20
    static let highestFrequency: Float = 20_000
    static let displayFloorDb: Float = -96
    static let displayCeilingDb: Float = 0
    /// Exponential bar smoothing constant, in seconds.
    static let smoothingTauSeconds: Double = 0.0864
    static let powerFloor: Float = 1e-12
    /// Tick labels the view draws when they fall inside the shown range.
    static let tickFrequencies: [Float] = [20, 100, 1_000, 10_000, 20_000]
    /// Explanatory Bass/Midrange/Treble categories, not filter boundaries.
    static let categoryBoundaries: [Float] = [250, 4_000]

    static func nyquist(_ sampleRate: Float) -> Float {
        max(sampleRate, 2 * lowestFrequency) * 0.5
    }

    static func upperFrequency(_ sampleRate: Float) -> Float {
        min(highestFrequency, nyquist(sampleRate))
    }

    static func lowestResolvableFrequency(_ sampleRate: Float) -> Float {
        sampleRate / Float(fftSize)
    }

    /// Highest frequency the packed real FFT resolves. The Nyquist term shares
    /// bin 0 with DC, so the last ordinary bin is halfSize - 1.
    static func highestResolvableFrequency(_ sampleRate: Float) -> Float {
        Float(halfSize - 1) * sampleRate / Float(fftSize)
    }

    /// bandCount + 1 log-spaced edges from 20 Hz to min(20 kHz, Fs/2).
    static func bandEdges(sampleRate: Float) -> [Float] {
        let low = lowestFrequency
        let high = max(upperFrequency(sampleRate), low * 1.0001)
        let step = pow(high / low, 1 / Float(bandCount))
        var edges = [Float](repeating: low, count: bandCount + 1)
        var value = low
        for index in 1..<bandCount {
            value *= step
            edges[index] = value
        }
        edges[bandCount] = high
        return edges
    }

    /// Ordinary bins enclosed by one bar, or nil when the bar range lies
    /// outside the available resolution. Bin 0 packs DC and Nyquist, so the
    /// usable range is 1...(halfSize - 1); portions of a bar outside it are
    /// excluded rather than clamped onto a neighbour.
    static func bandBinRange(band: Int, sampleRate: Float) -> ClosedRange<Int>? {
        let edges = bandEdges(sampleRate: sampleRate)
        guard band >= 0, band + 1 < edges.count else { return nil }
        let rate = max(sampleRate, 1)
        let lowest = Int(ceil(edges[band] * Float(fftSize) / rate))
        let highest = Int(ceil(edges[band + 1] * Float(fftSize) / rate)) - 1
        let first = max(lowest, 1)
        let last = min(highest, halfSize - 1)
        guard first <= last else { return nil }
        return first...last
    }

    /// Bars that enclose at least one resolvable bin.
    static func availableBandCount(sampleRate: Float) -> Int {
        var count = 0
        for band in 0..<bandCount where bandBinRange(band: band, sampleRate: sampleRate) != nil {
            count += 1
        }
        return count
    }

    /// Power to dBFS. Band powers are amplitude squared, so this is a 10 log10
    /// conversion; the meter amplitudes use the 20 log10 form.
    static func powerToDb(_ power: Float) -> Float {
        guard power.isFinite, power > 0 else { return -120 }
        return max(10 * log10(power), -120)
    }

    static func normalized(_ db: Float) -> Float {
        clamp((db - displayFloorDb) / (displayCeilingDb - displayFloorDb), 0, 1)
    }
}

/// Monotonic analysis clock in seconds. Tests inject a deterministic source;
/// production uses the uptime clock so a wall-clock change can neither stall
/// nor prematurely expire the measurement window.
struct AnalysisClock: @unchecked Sendable {
    private let source: @Sendable () -> Double

    init(now: @escaping @Sendable () -> Double) {
        source = now
    }

    func now() -> Double {
        source()
    }

    static let monotonic = AnalysisClock {
        Double(DispatchTime.now().uptimeNanoseconds) * 1e-9
    }
}

/// Counters over the shared trailing stereo window.
struct DynamicsLevels: Sendable, Equatable {
    var peak: Float
    var rms: Float
    var crestFactor: Float
    /// The crest value is a number only when this is true. Silence keeps the
    /// finite 0 sentinel so the view can draw a dash.
    var crestAvailable: Bool = true

    static let floor = DynamicsLevels(peak: -100, rms: -100, crestFactor: 0, crestAvailable: false)
}

/// One worker reading applied as a single main-actor update so the state, the
/// analysis rate and the numbers can never be observed half-updated.
struct DynamicsReading: Sendable, Equatable {
    var state: AnalysisState
    var spectrumState: AnalysisState
    var sampleRate: Float
    var levels: DynamicsLevels
}

@MainActor
final class DynamicsMeterModel: ObservableObject {
    typealias Levels = DynamicsLevels
    typealias Reading = DynamicsReading

    @Published private(set) var levels = DynamicsLevels.floor
    @Published private(set) var state: AnalysisState = .stopped
    @Published private(set) var spectrumState: AnalysisState = .stopped
    @Published private(set) var sampleRate: Float = 0

    func update(peak: Float, rms: Float, crestFactor: Float) {
        update(levels: DynamicsLevels(peak: peak, rms: rms, crestFactor: crestFactor,
                                      crestAvailable: true))
    }

    func update(levels: DynamicsLevels) {
        self.levels = levels
    }

    func apply(_ reading: Reading) {
        state = reading.state
        spectrumState = reading.spectrumState
        sampleRate = reading.sampleRate
        levels = reading.levels
    }

    func reset() {
        levels = .floor
        state = .stopped
        spectrumState = .stopped
        sampleRate = 0
    }
}

// The C snapshot provides concurrent publish/copy. Lifecycle callers stop the
// analyzer before clearing/destroying the snapshot.
final class SpectrumModel: @unchecked Sendable {
    static let binCount = Int(LC_SPECTRUM_BIN_COUNT)
    private let snapshot: OpaquePointer

    init() {
        guard let snapshot = lc_spectrum_snapshot_create() else {
            fatalError("Could not allocate spectrum snapshot.")
        }
        self.snapshot = snapshot
    }

    deinit {
        lc_spectrum_snapshot_destroy(snapshot)
    }

    func publish(_ values: [Float]) {
        values.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            lc_spectrum_snapshot_publish(snapshot, baseAddress, UInt32(pointer.count))
        }
    }

    func copySnapshot(
        into destination: UnsafeMutablePointer<Float>,
        after previousSequence: UInt64
    ) -> UInt64? {
        var newSequence: UInt64 = previousSequence
        let copied = lc_spectrum_snapshot_copy_if_new(
            snapshot,
            destination,
            UInt32(Self.binCount),
            previousSequence,
            &newSequence
        )
        return copied == UInt32(Self.binCount) ? newSequence : nil
    }

    func setAnalysisActive(_ active: Bool) {
        lc_spectrum_snapshot_set_active(snapshot, active ? 1 : 0)
    }

    var isAnalysisActive: Bool {
        lc_spectrum_snapshot_is_active(snapshot) != 0
    }

    func reset() {
        lc_spectrum_snapshot_clear(snapshot)
    }
}

private struct MetalSpectrumUniforms {
    var viewportAndCount = SIMD4<Float>(0, 0, Float(SpectrumModel.binCount), 0)
    var layout = SIMD4<Float>(42, 5, 1.5, 0)
}

/// CPU slots stay exclusively owned until their command buffer completes.
/// A slow GPU drops a render opportunity instead of blocking the main thread.
final class MetalSpectrumFrameSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [Bool]

    init(count: Int) { inFlight = Array(repeating: false, count: max(0, count)) }

    func acquire() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = inFlight.firstIndex(of: false) else { return nil }
        inFlight[index] = true
        return index
    }

    func release(_ index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight.indices.contains(index) else { return }
        inFlight[index] = false
    }

    func releaseAfterCompletion(_ index: Int, of commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [self] _ in release(index) }
    }
}


@available(macOS 14.4, *)
struct MetalSpectrumView: NSViewRepresentable {
    let model: SpectrumModel
    var isActive = true

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        model.setAnalysisActive(isActive && context.coordinator.isReady)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = !isActive || !context.coordinator.isReady
        view.presentsWithTransaction = false
        if !context.coordinator.isReady {
            let fallback = NSTextField(wrappingLabelWithString: L10n.string("analysis.unavailable"))
            fallback.textColor = .secondaryLabelColor
            fallback.alignment = .center
            fallback.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(fallback)
            NSLayoutConstraint.activate([
                fallback.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                fallback.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                fallback.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        model.setAnalysisActive(isActive && context.coordinator.isReady)
        nsView.isPaused = !isActive || !context.coordinator.isReady
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.setAnalysisActive(false)
        nsView.isPaused = true
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let model: SpectrumModel
        private let commandQueue: MTLCommandQueue?
        private let pipelineState: MTLRenderPipelineState?
        private let amplitudeBuffers: [MTLBuffer]
        private let uniformBuffers: [MTLBuffer]
        private let frameSlots = MetalSpectrumFrameSlots(count: 3)
        private var drawableSize = SIMD2<Float>(0, 0)
        private var lastSequence = UInt64.max

        var isReady: Bool {
            device != nil &&
                commandQueue != nil &&
                pipelineState != nil &&
                amplitudeBuffers.count == 3 &&
                uniformBuffers.count == 3
        }

        init(model: SpectrumModel) {
            self.model = model
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            self.pipelineState = Self.makePipeline(device: device)

            var amplitudes: [MTLBuffer] = []
            var uniforms: [MTLBuffer] = []
            if let device {
                let amplitudeLength = SpectrumModel.binCount * MemoryLayout<Float>.stride
                let uniformLength = MemoryLayout<MetalSpectrumUniforms>.stride
                for _ in 0..<3 {
                    if let amplitude = device.makeBuffer(length: amplitudeLength, options: .storageModeShared),
                       let uniform = device.makeBuffer(length: uniformLength, options: .storageModeShared) {
                        memset(amplitude.contents(), 0, amplitudeLength)
                        uniform.contents().bindMemory(to: MetalSpectrumUniforms.self, capacity: 1)
                            .initialize(to: MetalSpectrumUniforms())
                        amplitudes.append(amplitude)
                        uniforms.append(uniform)
                    }
                }
            }
            self.amplitudeBuffers = amplitudes
            self.uniformBuffers = uniforms
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            drawableSize = SIMD2(Float(size.width), Float(size.height))
            lastSequence = UInt64.max
        }

        func setAnalysisActive(_ active: Bool) {
            model.setAnalysisActive(active)
        }

        func draw(in view: MTKView) {
            guard isReady,
                  drawableSize.x > 0,
                  drawableSize.y > 0,
                  let commandQueue,
                  let pipelineState,
                  let index = frameSlots.acquire() else { return }
            var submitted = false
            defer { if !submitted { frameSlots.release(index) } }
            let amplitudeBuffer = amplitudeBuffers[index]
            let amplitudePointer = amplitudeBuffer.contents().bindMemory(
                to: Float.self,
                capacity: SpectrumModel.binCount
            )
            guard let sequence = model.copySnapshot(
                into: amplitudePointer,
                after: lastSequence
            ) else { return }
            let uniformBuffer = uniformBuffers[index]
            let uniformPointer = uniformBuffer.contents().bindMemory(
                to: MetalSpectrumUniforms.self,
                capacity: 1
            )
            var uniforms = MetalSpectrumUniforms()
            uniforms.viewportAndCount = SIMD4(
                drawableSize.x,
                drawableSize.y,
                Float(SpectrumModel.binCount),
                0
            )
            uniformPointer.pointee = uniforms

            guard let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(amplitudeBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: SpectrumModel.binCount
            )
            encoder.endEncoding()
            commandBuffer.present(drawable)
            frameSlots.releaseAfterCompletion(index, of: commandBuffer)
            submitted = true
            lastSequence = sequence
            commandBuffer.commit()
        }

        fileprivate static func packagedShaderURL() -> URL? {
            let moduleURL = Bundle.main.url(
                forResource: "SystemAudioProcessor_SystemAudioProcessor", withExtension: "bundle"
            ) ?? Bundle.main.bundleURL.appendingPathComponent("SystemAudioProcessor_SystemAudioProcessor.bundle")
            return Bundle(url: moduleURL)?.url(forResource: "SpectrumShaders", withExtension: "metal")
        }

        private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
            guard let device else { return nil }
            // The generated Bundle.module accessor traps for a missing bundle.
            // Optional resolution instead permits the unavailable-view fallback.
            let shaderURL = Bundle.main.url(forResource: "SpectrumShaders", withExtension: "metal")
                ?? packagedShaderURL()
            guard let shaderURL,
                  let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8),
                  let library = try? device.makeLibrary(source: shaderSource, options: nil),
                  let vertexFunction = library.makeFunction(name: "spectrumVertex"),
                  let fragmentFunction = library.makeFunction(name: "spectrumFragment") else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "TimbreDock Spectrum Bars"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
    }
}

private final class AnalysisPublicationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

/// Signal Monitor timing and thresholds. Cadence is capped at 30 Hz for the FFT
/// and 15 Hz for meter publication; every decision uses the analysis clock.
enum AnalysisLimits {
    static let fftRateHz: Double = 30
    static let fftIntervalSeconds: Double = 1 / fftRateHz
    static let meterRateHz: Double = 15
    static let meterIntervalSeconds: Double = 1 / meterRateHz
    /// One trailing stereo window serves Peak, RMS and Crest together.
    static let measurementWindowSeconds: Double = 0.3
    static let silenceThreshold: Float = 1e-5
    static let silenceFloorDb: Float = -100
    /// No new samples for this long means the input stopped instead of going quiet.
    static let staleTimeoutSeconds: Double = 0.25
}

/// Owns all analysis state on one serial queue. No audio callback work changes.
final class AudioSpectrumAnalyzer: NSObject, @unchecked Sendable {
    private let ringBuffer: LockFreeFloatRingBuffer
    private let dynamicsModel: DynamicsMeterModel
    private let spectrumModel: SpectrumModel
    private let clock: AnalysisClock
    private let analysisQueue = DispatchQueue(label: "lowend.spectrum.analysis", qos: .userInitiated)
    private let analysisQueueKey = DispatchSpecificKey<UInt8>()
    private let fftSize = SpectrumResolution.fftSize
    private let halfSize = SpectrumResolution.halfSize
    private let barCount = SpectrumResolution.bandCount
    private var sampleRate: Float
    private var timer: DispatchSourceTimer?
    private var publicationToken = AnalysisPublicationToken()
    private var fftSetup: FFTSetup?
    private var window = [Float](repeating: 0, count: SpectrumResolution.fftSize)
    private var windowSum: Float = 1
    private var drainBuffer = [Float](repeating: 0, count: 32_768)
    private var historyLeft = [Float](repeating: 0, count: SpectrumResolution.fftSize)
    private var historyRight = [Float](repeating: 0, count: SpectrumResolution.fftSize)
    private var historyIndex = 0
    private var filledSamples = 0
    private var windowed = [Float](repeating: 0, count: SpectrumResolution.fftSize)
    private var real = [Float](repeating: 0, count: SpectrumResolution.halfSize)
    private var imag = [Float](repeating: 0, count: SpectrumResolution.halfSize)
    private var leftPower = [Float](repeating: 0, count: SpectrumResolution.halfSize)
    private var meanPower = [Float](repeating: 0, count: SpectrumResolution.halfSize)
    private var magnitudes = [Float](repeating: 0, count: SpectrumResolution.bandCount)
    private var bandPowers = [Float](repeating: 0, count: SpectrumResolution.bandCount)
    private var edges = [Float]()
    private var peakHistory = [Float]()
    private var energyHistory = [Double]()
    private var measurementFrames = 0
    private var meterIndex = 0
    private var meterFilled = 0
    private var levels = DynamicsLevels.floor
    private var state: AnalysisState = .stopped
    private var spectrumState: AnalysisState = .stopped
    private var observedDroppedSamples: UInt64 = 0
    private var lastDataTime: Double?
    private var startedAt: Double = 0
    private var lastFftTime = -Double.greatestFiniteMagnitude
    private var lastMeterTime = -Double.greatestFiniteMagnitude
    private var lastSmoothingTime: Double?

    init(ringBuffer: LockFreeFloatRingBuffer, sampleRate: Float,
         dynamicsModel: DynamicsMeterModel, spectrumModel: SpectrumModel,
         clock: AnalysisClock = .monotonic) {
        self.ringBuffer = ringBuffer
        self.sampleRate = sampleRate.isFinite && sampleRate >= 8_000 ? sampleRate : 48_000
        self.dynamicsModel = dynamicsModel
        self.spectrumModel = spectrumModel
        self.clock = clock
        super.init()
        analysisQueue.setSpecific(key: analysisQueueKey, value: 1)
        fftSetup = vDSP_create_fftsetup(vDSP_Length(14), FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        windowSum = window.reduce(0, +)
        rebuildBuffers()
    }

    deinit { stop(); if let fftSetup { vDSP_destroy_fftsetup(fftSetup) } }

    func start() {
        withAnalysisQueue {
            cancelTimer()
            ringBuffer.requestDiscard()
            _ = ringBuffer.consumeDiscardRequest()
            resetPaths()
            let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
            timer.schedule(deadline: .now(), repeating: AnalysisLimits.fftIntervalSeconds,
                           leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() { withAnalysisQueue { cancelTimer(); resetPaths(state: .stopped) } }

    func updateSampleRate(_ rate: Float) {
        guard rate.isFinite, rate >= 8_000, rate <= 768_000 else { return }
        analysisQueue.async { [weak self] in
            guard let self, self.sampleRate != rate else { return }
            self.ringBuffer.requestDiscard()
            _ = self.ringBuffer.consumeDiscardRequest()
            self.sampleRate = rate
            self.rebuildBuffers()
            self.resetPaths(state: self.timer == nil ? .stopped : .measuring)
        }
    }

    private func withAnalysisQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: analysisQueueKey) != nil { return try body() }
        return try analysisQueue.sync(execute: body)
    }

    private func cancelTimer() {
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
    }

    private func rebuildBuffers() {
        measurementFrames = max(1, Int((Double(sampleRate) * AnalysisLimits.measurementWindowSeconds).rounded()))
        peakHistory = [Float](repeating: 0, count: measurementFrames)
        energyHistory = [Double](repeating: 0, count: measurementFrames)
        edges = SpectrumResolution.bandEdges(sampleRate: sampleRate).map { $0 * Float(fftSize) / sampleRate }
    }

    private func resetPaths(state replacement: AnalysisState = .measuring) {
        publicationToken.invalidate()
        publicationToken = AnalysisPublicationToken()
        for i in peakHistory.indices { peakHistory[i] = 0; energyHistory[i] = 0 }
        for i in historyLeft.indices { historyLeft[i] = 0; historyRight[i] = 0 }
        for i in magnitudes.indices { magnitudes[i] = 0; bandPowers[i] = 0 }
        meterIndex = 0; meterFilled = 0
        historyIndex = 0; filledSamples = 0
        levels = .floor; state = replacement; spectrumState = replacement
        lastDataTime = nil; startedAt = clock.now()
        lastFftTime = -Double.greatestFiniteMagnitude
        lastMeterTime = -Double.greatestFiniteMagnitude
        lastSmoothingTime = nil
        observedDroppedSamples = ringBuffer.droppedWriteSamples()
        spectrumModel.reset()
        publishReading()
    }

    private func tick() {
        let now = clock.now()
        if drainAudio() {
            lastDataTime = now
            if now - lastMeterTime >= AnalysisLimits.meterIntervalSeconds - 1e-9 {
                measureWindow()
                lastMeterTime = now
            }
            if spectrumModel.isAnalysisActive, filledSamples == fftSize,
               now - lastFftTime >= AnalysisLimits.fftIntervalSeconds - 1e-9 {
                guard computeSpectrum(now: now) else { resetPaths(state: .interrupted); return }
                lastFftTime = now
                spectrumState = bandPowers.allSatisfy { $0 < 1e-10 } ? .silence : .active
                if spectrumState == .silence {
                    for i in magnitudes.indices { magnitudes[i] = 0 }
                }
                spectrumModel.publish(magnitudes)
            } else if !spectrumModel.isAnalysisActive {
                spectrumState = .stopped
            }
            // Publish meters at no more than 15 Hz; spectrum status uses the same reading.
            if lastMeterTime == now { publishReading() }
        } else if state != .stopped && state != .waiting,
                  now - (lastDataTime ?? startedAt) >= AnalysisLimits.staleTimeoutSeconds - 1e-9 {
            // Invalidate queued active readings and require fresh windows on resume.
            resetPaths(state: .waiting)
        }
    }

    private func drainAudio() -> Bool {
        if ringBuffer.consumeDiscardRequest() { resetPaths() }
        if ringBuffer.droppedWriteSamples() != observedDroppedSamples {
            // The gap lies after queued pre-drop samples. Discard that backlog
            // so the next window cannot straddle the missing part of the stream.
            ringBuffer.requestDiscard()
            _ = ringBuffer.consumeDiscardRequest()
            resetPaths(state: .interrupted)
            return false
        }
        var remaining = ringBuffer.availableSamples()
        remaining -= remaining % 2
        var received = false
        var invalid = false
        while remaining > 0 {
            let count = min(remaining, drainBuffer.count)
            drainBuffer.withUnsafeMutableBufferPointer { buffer in
                let samples = buffer.baseAddress!
                ringBuffer.popInterleaved(into: samples, count: count)
                // A corrupt chunk invalidates the complete finite snapshot, including earlier chunks.
                if !invalid {
                    for i in 0..<count where !samples[i].isFinite { invalid = true; break }
                }
                guard !invalid else { return }
                for i in stride(from: 0, to: count, by: 2) {
                    let left = samples[i], right = samples[i + 1]
                    let peak = max(abs(left), abs(right))
                    let energy = (Double(left) * Double(left) + Double(right) * Double(right)) * 0.5
                    energyHistory[meterIndex] = energy
                    peakHistory[meterIndex] = peak
                    meterIndex = (meterIndex + 1) % measurementFrames
                    meterFilled = min(meterFilled + 1, measurementFrames)
                    historyLeft[historyIndex] = left; historyRight[historyIndex] = right
                    historyIndex = (historyIndex + 1) % fftSize
                    filledSamples = min(filledSamples + 1, fftSize)
                }
                received = true
            }
            remaining -= count
        }
        if invalid { resetPaths(state: .interrupted); return false }
        return received
    }

    private func measureWindow() {
        guard meterFilled == measurementFrames else { levels = .floor; state = .measuring; return }
        var peak: Float = 0
        vDSP_maxv(peakHistory, 1, &peak, vDSP_Length(measurementFrames))
        if peak < AnalysisLimits.silenceThreshold {
            levels = .floor; state = .silence; return
        }
        var energySum: Double = 0
        vDSP_sveD(energyHistory, 1, &energySum, vDSP_Length(measurementFrames))
        let rms = Float(sqrt(max(energySum, 0) / Double(measurementFrames)))
        let peakDb = amplitudeToDb(peak), rmsDb = amplitudeToDb(rms)
        levels = DynamicsLevels(peak: peakDb, rms: rmsDb, crestFactor: peakDb - rmsDb, crestAvailable: true)
        state = .active
    }

    private func amplitudeToDb(_ amplitude: Float) -> Float {
        20 * log10(max(amplitude, Float.leastNonzeroMagnitude))
    }

    private func publishReading() {
        let reading = DynamicsReading(state: state, spectrumState: spectrumState,
                                      sampleRate: sampleRate, levels: levels)
        let token = publicationToken
        Task { @MainActor [dynamicsModel] in
            guard token.isValid else { return }
            dynamicsModel.apply(reading)
        }
    }

    private func transform(_ history: [Float], into powers: inout [Float]) {
        guard let fftSetup else { return }
        for i in 0..<fftSize { windowed[i] = history[(historyIndex + i) % fftSize] * window[i] }
        windowed.withUnsafeBufferPointer { input in
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(14), FFTDirection(FFT_FORWARD))
                    // Real forward vDSP has 2x scaling. A sine's positive-frequency
                    // coefficient is A*windowSum/2 before that scaling: divide by windowSum.
                    let scale = 1 / (windowSum * windowSum)
                    powers[0] = 0 // Packed DC/Nyquist are not ordinary frequency bins.
                    for i in 1..<halfSize {
                        powers[i] = (split.realp[i] * split.realp[i] + split.imagp[i] * split.imagp[i]) * scale
                    }
                }
            }
        }
    }

    private func interpolatedPower(_ bin: Float) -> Float {
        let x = clamp(bin, 1, Float(halfSize - 1))
        let low = Int(x), high = min(low + 1, halfSize - 1)
        return meanPower[low] + (meanPower[high] - meanPower[low]) * (x - Float(low))
    }

    @discardableResult
    private func computeSpectrum(now: Double) -> Bool {
        guard fftSetup != nil else { return false }
        transform(historyLeft, into: &leftPower)
        transform(historyRight, into: &meanPower)
        for i in 1..<halfSize {
            meanPower[i] = leftPower[i] * 0.5 + meanPower[i] * 0.5
            if !meanPower[i].isFinite { return false }
        }
        let dt = max(0, now - (lastSmoothingTime ?? (now - AnalysisLimits.fftIntervalSeconds)))
        let alpha = Float(1 - exp(-dt / SpectrumResolution.smoothingTauSeconds))
        lastSmoothingTime = now
        for band in 0..<barCount {
            let low = max(edges[band], 1), high = min(edges[band + 1], Float(halfSize - 1))
            guard high >= low else { bandPowers[band] = 0; magnitudes[band] = 0; continue }
            var power = max(interpolatedPower(low), interpolatedPower(high))
            let first = Int(ceil(low)), last = Int(floor(high))
            if first <= last { for bin in first...last { power = max(power, meanPower[bin]) } }
            bandPowers[band] = power
            let target = SpectrumResolution.normalized(SpectrumResolution.powerToDb(power))
            magnitudes[band] += (target - magnitudes[band]) * alpha
            // Actual digital silence has no artificial one-pixel floor or smoothing tail.
            if power == 0 { magnitudes[band] = 0 }
        }
        return true
    }
}

extension AudioSpectrumAnalyzer {
    /// No Process Tap or audio device is opened. This exercises the actual
    /// worker's high-rate drain, history boundary and discard/rate reset paths.
    @MainActor
    static func runOfflineChecks() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "LowEndAudioAnalysisChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
#if SWIFT_PACKAGE
        if #available(macOS 14.4, *) {
            try require(MetalSpectrumView.Coordinator.packagedShaderURL() != nil,
                        "the delivered executable must resolve its packaged SwiftPM shader bundle")
        }
#endif
        let slots = MetalSpectrumFrameSlots(count: 3)
        let acquired = [slots.acquire(), slots.acquire(), slots.acquire()]
        try require(Set(acquired.compactMap { $0 }).count == 3, "in-flight GPU slots must be distinct")
        try require(slots.acquire() == nil, "a slow GPU must skip a frame without reusing its resources")
        slots.release(1)
        try require(slots.acquire() == 1, "only a completed GPU slot may become writable")
        let uniforms = MetalSpectrumUniforms()
        try require(uniforms.layout == SIMD4<Float>(42, 5, 1.5, 0), "all shader layout defaults must be initialized")
        try require(MemoryLayout<MetalSpectrumUniforms>.stride == 32, "shader uniforms must preserve the two-float4 layout")

        // Exercise actual Metal completion, not a manually released slot. A
        // shared-event wait keeps submitted work in flight while further CPU
        // frames try to acquire storage. This opens no audio device or tap.
        if let device = MTLCreateSystemDefaultDevice(),
           let commandQueue = device.makeCommandQueue(),
           let event = device.makeSharedEvent() {
            let delayedSlots = MetalSpectrumFrameSlots(count: 3)
            var skipped = 0
            for round in 1...12 {
                var commands: [MTLCommandBuffer] = []
                var sources: [MTLBuffer] = []
                var destinations: [MTLBuffer] = []
                let callbacks = DispatchSemaphore(value: 0)
                // Always unblock submitted GPU work if a check throws.
                defer { event.signaledValue = UInt64(round) }
                for frame in 0..<3 {
                    guard let slot = delayedSlots.acquire(),
                          let source = device.makeBuffer(length: 256, options: .storageModeShared),
                          let destination = device.makeBuffer(length: 256, options: .storageModeShared),
                          let command = commandQueue.makeCommandBuffer() else {
                        throw NSError(domain: "LowEndAudioAnalysisChecks", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Metal delayed-frame setup failed"])
                    }
                    let sentinel = UInt8(round * 3 + frame)
                    source.contents().initializeMemory(as: UInt8.self, repeating: sentinel, count: 256)
                    destination.contents().initializeMemory(as: UInt8.self, repeating: 0, count: 256)
                    command.encodeWaitForEvent(event, value: UInt64(round))
                    guard let blit = command.makeBlitCommandEncoder() else {
                        throw NSError(domain: "LowEndAudioAnalysisChecks", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "Metal blit encoder unavailable"])
                    }
                    blit.copy(from: source, sourceOffset: 0, to: destination, destinationOffset: 0, size: 256)
                    blit.endEncoding()
                    delayedSlots.releaseAfterCompletion(slot, of: command)
                    // Older SDKs do not annotate the Metal callback as Sendable.
                    // Do not inherit this check's MainActor on Metal's queue.
                    command.addCompletedHandler { @Sendable _ in callbacks.signal() }
                    commands.append(command); sources.append(source); destinations.append(destination)
                    command.commit()
                }
                Thread.sleep(forTimeInterval: 0.01)
                for _ in 0..<100 {
                    try require(delayedSlots.acquire() == nil,
                                "a pending Metal command exposed its CPU frame storage")
                    skipped += 1
                }
                event.signaledValue = UInt64(round)
                for _ in 0..<3 {
                    try require(callbacks.wait(timeout: .now() + 5) == .success,
                                "Metal completion handler did not return its slot")
                }
                for command in commands {
                    try require(command.status == .completed, "delayed Metal command failed")
                }
                for frame in 0..<3 {
                    let bytes = destinations[frame].contents().assumingMemoryBound(to: UInt8.self)
                    try require((0..<256).allSatisfy { bytes[$0] == UInt8(round * 3 + frame) },
                                "in-flight GPU resource contents changed before completion")
                }
                withExtendedLifetime(sources) {}
            }
            print("AudioAnalysisChecks: Metal delayed completion 36 commands, \(skipped) skipped acquisitions, 0 resource mismatches (\(device.name))")
        } else {
            print("AudioAnalysisChecks: SKIP real Metal delayed completion (device/queue/shared event unavailable)")
        }

        final class TestClock: @unchecked Sendable { var time: Double = 1 }
        func make(_ rate: Float = 48_000) throws -> (LockFreeFloatRingBuffer, AudioSpectrumAnalyzer, SpectrumModel, TestClock) {
            let ring = try LockFreeFloatRingBuffer(capacityFrames: Int(rate), channels: 2)
            let spectrum = SpectrumModel(); spectrum.setAnalysisActive(true)
            let time = TestClock()
            let analyzer = AudioSpectrumAnalyzer(ringBuffer: ring, sampleRate: rate,
                dynamicsModel: DynamicsMeterModel(), spectrumModel: spectrum,
                clock: AnalysisClock { time.time })
            analyzer.withAnalysisQueue { analyzer.resetPaths() }
            return (ring, analyzer, spectrum, time)
        }
        func tone(_ frames: Int, rate: Float = 48_000, frequency: Float = 1_000,
                  amplitude: Float = 0.5, rightGain: Float = 1) -> [Float] {
            var values = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let x = amplitude * Float(sin(2 * Double.pi * Double(frequency) * Double(i) / Double(rate)))
                values[2*i] = x; values[2*i+1] = x * rightGain
            }
            return values
        }
        func feed(_ values: [Float], _ setup: (LockFreeFloatRingBuffer, AudioSpectrumAnalyzer, SpectrumModel, TestClock),
                  block: Int = 1_600) {
            let (ring, analyzer, _, clock) = setup
            values.withUnsafeBufferPointer { samples in
                var offset = 0
                while offset < samples.count {
                    let count = min(block * 2, samples.count - offset)
                    ring.push(samples.baseAddress! + offset, count: count)
                    clock.time += Double(count / 2) / Double(analyzer.sampleRate)
                    analyzer.withAnalysisQueue { analyzer.tick() }
                    offset += count
                }
            }
            analyzer.withAnalysisQueue { analyzer.measureWindow() }
        }
        func near(_ actual: Float, _ expected: Float, _ name: String, tolerance: Float = 0.02) throws {
            try require(abs(actual - expected) <= tolerance, "\(name): \(actual), expected \(expected)")
        }
        let stereo = try make()
        feed(tone(24_000), stereo)
        try near(stereo.1.levels.peak, -6.0206, "stereo sine peak")
        try near(stereo.1.levels.rms, -9.0309, "stereo sine RMS")
        try near(stereo.1.levels.crestFactor, 3.0103, "stereo sine crest")
        let left = try make()
        feed(tone(24_000, rightGain: 0), left)
        try near(left.1.levels.rms, -12.0412, "left-only RMS")
        try near(left.1.levels.crestFactor, 6.0206, "left-only crest")
        let square = try make()
        feed((0..<48_000).map { $0 % 4 < 2 ? Float(0.5) : -0.5 }, square)
        try near(square.1.levels.rms, -6.0206, "square RMS")
        try near(square.1.levels.crestFactor, 0, "square crest")
        try require(square.1.levels.crestAvailable, "zero crest is valid for non-silent square wave")
        let silent = try make()
        feed([Float](repeating: 0, count: 48_000), silent)
        try require(silent.1.state == .silence && !silent.1.levels.crestAvailable, "digital silence state")
        try require(silent.1.magnitudes.allSatisfy { $0 == 0 }, "silence must produce zero-height bars")
        let half = try make()
        feed(tone(24_000, amplitude: 0.25), half)
        try near(half.1.levels.rms - stereo.1.levels.rms, -6.0206, "half amplitude RMS")
        let split = try make()
        feed(tone(24_000), split, block: 257)
        try near(split.1.levels.rms, stereo.1.levels.rms, "chunk partition RMS", tolerance: 0.0001)
        try near(split.1.levels.peak, stereo.1.levels.peak, "chunk partition peak", tolerance: 0.0001)
        let transient = try make()
        var impulse = [Float](repeating: 0, count: 14_400 * 2)
        impulse[0] = 1
        feed(impulse, transient, block: 20_000)
        try near(transient.1.levels.peak, 0, "first chunk transient retained")
        feed([0, 0], transient)
        try require(transient.1.state == .silence, "first frame expires exactly after trailing 300 ms")
        // Energy above full scale is measured rather than clipped to 0 dBFS.
        let over = try make(); feed([Float](repeating: 2, count: 28_800), over)
        try near(over.1.levels.rms, 6.0206, "over-full-scale RMS")

        let frequency = Float(341) * 48_000 / Float(SpectrumResolution.fftSize)
        let inPhase = try make(), antiphase = try make(), halfSpectrum = try make()
        feed(tone(32_768, frequency: frequency), inPhase)
        feed(tone(32_768, frequency: frequency, rightGain: -1), antiphase)
        feed(tone(32_768, frequency: frequency, amplitude: 0.25), halfSpectrum)
        try near(SpectrumResolution.powerToDb(inPhase.1.meanPower[341]), -6.0206, "FFT coherent gain", tolerance: 0.05)
        try near(SpectrumResolution.powerToDb(halfSpectrum.1.meanPower[341]) - SpectrumResolution.powerToDb(inPhase.1.meanPower[341]), -6.0206, "FFT half amplitude", tolerance: 0.05)
        for i in 0..<128 { try near(antiphase.1.bandPowers[i], inPhase.1.bandPowers[i], "antiphase spectral power", tolerance: 0.00001) }
        let offbin = try make()
        feed(tone(32_768, frequency: frequency + 48_000 / Float(SpectrumResolution.fftSize) * 0.5), offbin)
        try near(SpectrumResolution.powerToDb(offbin.1.bandPowers.max()!), -6.0206, "off-bin Hann tone", tolerance: 1.5)
        // Interpolation must serve bands narrower than one FFT bin too.
        try require(inPhase.1.bandPowers[0].isFinite, "narrow log band must be finite")

        let stale = try make(); feed(tone(24_000), stale)
        stale.3.time += 0.249; stale.1.withAnalysisQueue { stale.1.tick() }
        try require(stale.1.state == .active, "249ms should retain active samples")
        let oldToken = stale.1.publicationToken
        stale.3.time += 0.001; stale.1.withAnalysisQueue { stale.1.tick() }
        try require(stale.1.state == .waiting && stale.1.levels == .floor, "250ms clears stale values")
        try require(!oldToken.isValid && stale.1.magnitudes.allSatisfy { $0 == 0 }, "stale invalidates publications and bars")
        feed(tone(1_600), stale)
        try require(stale.1.state == .measuring, "resume requires a fresh 300ms window")
        let initial = try make(); initial.3.time += 0.25
        initial.1.withAnalysisQueue { initial.1.tick() }
        try require(initial.1.state == .waiting, "no initial input becomes waiting")
        let corrupt = try make(); feed(tone(24_000), corrupt)
        [Float.nan, 0].withUnsafeBufferPointer { corrupt.0.push($0.baseAddress!, count: $0.count) }
        corrupt.1.withAnalysisQueue { corrupt.1.tick() }
        try require(corrupt.1.state == .interrupted && corrupt.1.levels == .floor, "nonfinite clears measurement history")
        // feed's explicit measurement makes a short fresh history measuring; test raw invalid tick instead.

        corrupt.3.time += 0.25; corrupt.1.withAnalysisQueue { corrupt.1.tick() }
        try require(corrupt.1.state == .waiting, "interrupted input also becomes waiting at 250ms")
        let sparse = try make()
        var quietImpulse = [Float](repeating: 0, count: 28_800)
        quietImpulse[0] = 1e-4; quietImpulse[1] = 1e-4
        feed(quietImpulse, sparse, block: 14_400)
        try near(sparse.1.levels.rms, -121.5836, "sparse quiet impulse RMS")
        try near(sparse.1.levels.crestFactor, 41.5836, "sparse quiet impulse crest")
        let quietTail = try make(); feed(tone(32_768), quietTail)
        feed(tone(32_768, amplitude: 1e-6), quietTail)
        try require(quietTail.1.spectrumState == .silence && quietTail.1.magnitudes.allSatisfy { $0 == 0 },
                    "nonzero subthreshold silence clears smoothing tail")

        let ring = try LockFreeFloatRingBuffer(capacityFrames: 65_536, channels: 2)
        let analyzer = AudioSpectrumAnalyzer(ringBuffer: ring, sampleRate: 768_000,
            dynamicsModel: DynamicsMeterModel(), spectrumModel: SpectrumModel())
        let frames = 30_000
        var ramp = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { ramp[2*i] = Float(i) / Float(frames); ramp[2*i+1] = ramp[2*i] }
        ramp.withUnsafeBufferPointer { ring.push($0.baseAddress!, count: $0.count) }
        let completed = DispatchSemaphore(value: 0), offMain = AnalysisPublicationToken()
        analyzer.analysisQueue.async {
            if pthread_main_np() != 0 { offMain.invalidate() }
            analyzer.tick(); completed.signal()
        }
        try require(completed.wait(timeout: .now() + 5) == .success && offMain.isValid, "finite drain stays off main")
        try require(ring.availableSamples() == 0 && analyzer.filledSamples == analyzer.fftSize, "high-rate full snapshot drained")
        try near(analyzer.historyLeft[analyzer.historyIndex], Float(frames-analyzer.fftSize)/Float(frames), "newest FFT window begins correctly", tolerance: 0.000001)
        ring.requestDiscard(); analyzer.withAnalysisQueue { analyzer.tick() }
        try require(analyzer.filledSamples == 0 && analyzer.meterFilled == 0, "discard clears both histories")
        analyzer.updateSampleRate(48_000)
        analyzer.withAnalysisQueue {}
        try require(analyzer.sampleRate == 48_000 && analyzer.measurementFrames == 14_400, "rate rebuild uses actual analysis rate")
        let beforeStop = analyzer.publicationToken; analyzer.stop()
        try require(!beforeStop.isValid && analyzer.state == .stopped, "stop invalidates pending publication")
        let dropped = try make()
        var overflow = [Float](repeating: 0.5, count: 200_000)
        overflow.withUnsafeMutableBufferPointer { dropped.0.push($0.baseAddress!, count: $0.count) }
        dropped.1.withAnalysisQueue { dropped.1.tick() }
        try require(dropped.1.observedDroppedSamples > 0 && dropped.1.meterFilled == 0 && dropped.1.state == .interrupted, "dropped writes invalidate the pre-gap backlog")

        var timings = [Double]()
        for rate: Float in [44_100, 48_000, 96_000, 192_000, 384_000, 768_000] {
            let setup = try make(rate)
            let binTone = rate * 100 / Float(SpectrumResolution.fftSize)
            feed(tone(max(32_768, Int(rate * 0.35)), rate: rate, frequency: binTone), setup, block: Int(rate / 30))
            try near(SpectrumResolution.powerToDb(setup.1.meanPower[100]), -6.0206, "rate \(rate) FFT", tolerance: 0.05)
            try require(setup.1.edges.count == 129 && setup.1.magnitudes.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "rate geometry and bounded magnitudes")
            if rate >= 384_000 { try require(setup.1.bandPowers[0] == 0, "unresolvable low band excluded") }
            let chunk = tone(Int(rate / 30), rate: rate, frequency: binTone)
            for _ in 0..<30 {
                chunk.withUnsafeBufferPointer { setup.0.push($0.baseAddress!, count: $0.count) }
                setup.3.time += 1.0/30
                let start = DispatchTime.now().uptimeNanoseconds
                setup.1.withAnalysisQueue { setup.1.tick() }
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
        }
        timings.sort()
        print(String(format: "AudioAnalysisChecks: 300ms stereo/FFT/stale/reset fixtures passed; worker tick p95 %.3f ms, max %.3f ms", timings[Int(Double(timings.count-1)*0.95)], timings.last!))
    }
}
