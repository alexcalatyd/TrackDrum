import AVFoundation
import QuartzCore
import os

final class UnfairLock {
    private let p: UnsafeMutablePointer<os_unfair_lock>
    init() {
        p = .allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
    }
    deinit { p.deallocate() }
    func lock() { os_unfair_lock_lock(p) }
    func unlock() { os_unfair_lock_unlock(p) }
    func with<T>(_ f: () -> T) -> T {
        lock(); defer { unlock() }
        return f()
    }
}

private struct Voice {
    var sample: Sample?
    var pos = 0
    var delay = 0
    var gain: Float = 0
    var choke = 0
    var fadeStep: Float = 0
    var fadeGain: Float = 1
}

private struct Hit {
    let slot: Int
    let velocity: Float
    let record: Bool
}

private struct RecEvent {
    let beat: Double      // posición dentro del loop (en negras)
    let slot: Int
    let velocity: Float
    let layer: Int
    let createdAt: Double // songBeat absoluto al grabarlo
}

/// Lo que la interfaz necesita saber del motor.
struct EngineSnapshot {
    var playing = false
    var recording = false
    var bpm = 100.0
    var bars = 2
    var quantize = true
    var metronome = false
    var metronomeSound = true
    var metronomeHaptic = true
    var songBeat = 0.0
    var countIn = 0
    var loopActive: [Bool] = []
    var loopPending: [Bool] = []
    var eventCount = 0
    var layers = 0
}

/// Sampler propio en el hilo de audio: voces, metrónomo, looper y loops a tempo,
/// todo con precisión de muestra.
final class AudioEngine {
    let sr: Double
    let loops: [LoopDef]

    /// (pulso dentro del loop, ¿primer pulso del compás?, retardo hasta que suena, ¿metrónomo háptico?)
    var onBeat: ((Int, Bool, Double, Bool) -> Void)?
    /// Un sonido del kit disparado por el looper o un loop (para iluminar el pad).
    var onSlotPlayed: ((Int, Float, Double) -> Void)?
    /// Momento (CACurrentMediaTime) en que empezó a sonar lo último: para no confundir
    /// la vibración de los altavoces con un golpe en el chasis.
    private(set) var lastSoundTime: Double = 0

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let lock = UnfairLock()
    private var latency: Double = 0.01

    // Estado compartido (protegido por `lock`).
    private var slots: [Sample]
    private var hits: [Hit] = []
    private var events: [RecEvent] = []
    private var layer = 0
    private var loopActive: [Bool]
    private var loopPending: [Bool]
    private var playing = false
    private var recording = false
    private var bpm = 100.0
    private var bars = 2
    private var quantize = true
    private var metronome = false
    private var metronomeSound = true
    private var metronomeHaptic = true
    private var songBeat = 0.0

    // Solo hilo de audio.
    private var voices = [Voice](repeating: Voice(), count: 64)
    private let click: Sample
    private let clickAccent: Sample
    private var beatNotes: [(Int, Bool, Int, Bool)] = []
    private var slotNotes: [(Int, Float, Int)] = []

    init() {
        let probe = AVAudioEngine()
        let rate = probe.outputNode.outputFormat(forBus: 0).sampleRate
        sr = rate > 0 ? rate : 48_000
        DSP.sr = sr

        slots = Kits.make(0).sounds
        loops = Loops.make()
        loopActive = Array(repeating: false, count: loops.count)
        loopPending = Array(repeating: false, count: loops.count)
        click = Drum.click(1500)
        clickAccent = Drum.click(2400)
        hits.reserveCapacity(128)
        beatNotes.reserveCapacity(16)
        slotNotes.reserveCapacity(64)
    }

    func start() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(out, Int(frameCount))
            for b in 1..<buffers.count {
                buffers[b].mData?.copyMemory(from: out, byteCount: Int(buffers[b].mDataByteSize))
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        // Búfer pequeño = menos latencia (128 muestras ≈ 2,7 ms).
        if let au = engine.outputNode.audioUnit {
            var frames: UInt32 = 128
            AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                 &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        engine.prepare()
        try engine.start()
        latency = engine.outputNode.presentationLatency + 128 / sr
    }

    // MARK: - API (cualquier hilo)

    func trigger(slot: Int, velocity: Float, record: Bool) {
        lock.with { hits.append(Hit(slot: slot, velocity: velocity, record: record)) }
    }

    func setSlots(_ sounds: [Sample]) { lock.with { slots = sounds } }

    func togglePlay() {
        lock.with {
            if playing {
                playing = false
                recording = false
            } else {
                songBeat = 0
                playing = true
            }
        }
    }

    func toggleRecording() {
        lock.with {
            if recording {
                recording = false
            } else {
                layer += 1
                recording = true
                if !playing {
                    songBeat = -4 // un compás de cuenta atrás
                    playing = true
                }
            }
        }
    }

    func undoLayer() {
        lock.with {
            guard let top = events.map(\.layer).max() else { return }
            events.removeAll { $0.layer == top }
        }
    }

    func clearRecording() { lock.with { events.removeAll() } }

    func toggleLoop(_ i: Int) {
        lock.with {
            guard loops.indices.contains(i) else { return }
            if !playing {
                // Parado: arranca ya con este loop.
                for j in loopPending.indices { loopPending[j] = false }
                loopActive[i].toggle()
                songBeat = 0
                playing = true
            } else {
                loopPending[i].toggle() // se aplica al empezar el siguiente compás
            }
        }
    }

    func stopAllLoops() {
        lock.with {
            for i in loopActive.indices { loopActive[i] = false; loopPending[i] = false }
        }
    }

    func setBPM(_ value: Double) { lock.with { bpm = min(220, max(50, value)) } }
    func cycleBars() { lock.with { bars = bars == 1 ? 2 : (bars == 2 ? 4 : 1) } }
    func setBars(_ n: Int) { lock.with { bars = [1, 2, 4].contains(n) ? n : 2 } }
    func setQuantize(_ on: Bool) { lock.with { quantize = on } }
    func setMetronome(_ on: Bool) { lock.with { metronome = on } }
    func setMetronomeSound(_ on: Bool) { lock.with { metronomeSound = on } }
    func setMetronomeHaptic(_ on: Bool) { lock.with { metronomeHaptic = on } }

    func configure(bpm: Double, bars: Int, quantize: Bool, metronome: Bool, sound: Bool, haptic: Bool) {
        lock.with {
            self.bpm = bpm; self.bars = bars; self.quantize = quantize
            self.metronome = metronome; metronomeSound = sound; metronomeHaptic = haptic
        }
    }

    func snapshot() -> EngineSnapshot {
        lock.with {
            EngineSnapshot(playing: playing, recording: recording, bpm: bpm, bars: bars, quantize: quantize,
                           metronome: metronome, metronomeSound: metronomeSound, metronomeHaptic: metronomeHaptic,
                           songBeat: songBeat, countIn: songBeat < 0 ? Int((-songBeat).rounded(.up)) : 0,
                           loopActive: loopActive, loopPending: loopPending, eventCount: events.count,
                           layers: Set(events.map(\.layer)).count)
        }
    }

    // MARK: - Hilo de audio

    private func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n { out[i] = 0 }
        beatNotes.removeAll(keepingCapacity: true)
        slotNotes.removeAll(keepingCapacity: true)

        lock.lock()
        for h in hits {
            play(slot: h.slot, gain: h.velocity, offset: 0)
            if h.record && playing && recording && songBeat >= 0 { record(h) }
        }
        hits.removeAll(keepingCapacity: true)
        if playing { advance(n) }
        lock.unlock()

        mix(out, n)

        // Avisos a la interfaz / háptica, compensando lo que tarda en salir el audio.
        for (beat, accent, offset, haptic) in beatNotes {
            onBeat?(beat, accent, Double(offset) / sr + latency, haptic)
        }
        for (slot, vel, offset) in slotNotes {
            onSlotPlayed?(slot, vel, Double(offset) / sr + latency)
        }
    }

    private func record(_ h: Hit) {
        let loopBeats = Double(bars * 4)
        var beat = songBeat.truncatingRemainder(dividingBy: loopBeats)
        if quantize { beat = ((beat * 4).rounded() / 4).truncatingRemainder(dividingBy: loopBeats) }
        events.append(RecEvent(beat: beat, slot: h.slot, velocity: h.velocity, layer: layer, createdAt: songBeat))
    }

    private func advance(_ n: Int) {
        let beatsPerFrame = bpm / 60 / sr
        let b0 = songBeat
        let b1 = b0 + Double(n) * beatsPerFrame
        let loopBeats = Double(bars * 4)
        func offset(_ beat: Double) -> Int { min(n - 1, max(0, Int((beat - b0) / beatsPerFrame))) }

        // Pasos de semicorchea: compases, metrónomo y loops.
        var s = Int((b0 * 4 - 1e-9).rounded(.up))
        while Double(s) / 4 < b1 {
            let off = offset(Double(s) / 4)
            if s % 16 == 0 && s >= 0 {
                for i in loopPending.indices where loopPending[i] {
                    loopActive[i].toggle()
                    loopPending[i] = false
                }
            }
            if s % 4 == 0 && s < 0 {
                // Cuenta atrás: siempre suena y vibra, aunque el metrónomo esté apagado.
                let accent = s == -16
                start(accent ? clickAccent : click, gain: 0.7, offset: off, choke: 0)
                beatNotes.append((s / 4, accent, off, true))
            } else if s % 4 == 0 {
                let beatInLoop = (s / 4) % (bars * 4)
                let accent = beatInLoop % 4 == 0
                if metronome && metronomeSound { start(accent ? clickAccent : click, gain: 0.6, offset: off, choke: 0) }
                beatNotes.append((beatInLoop, accent, off, metronome && metronomeHaptic))
            }
            for (i, loop) in loops.enumerated() where loopActive[i] && s >= 0 {
                for note in loop.byStep[s % loop.steps] {
                    switch note.sound {
                    case .slot(let slot):
                        play(slot: slot, gain: note.gain, offset: off)
                        slotNotes.append((slot, note.gain, off))
                    case .sample(let sample):
                        start(sample, gain: note.gain, offset: off, choke: 0)
                    }
                }
            }
            s += 1
        }

        // Golpes grabados.
        for e in events where e.beat < loopBeats && b1 > 0 {
            let m = ((b0 - e.beat) / loopBeats).rounded(.up)
            let t = m * loopBeats + e.beat
            guard t >= b0, t >= 0, t < b1, t - e.createdAt > loopBeats * 0.5 else { continue }
            let off = offset(t)
            play(slot: e.slot, gain: e.velocity, offset: off)
            slotNotes.append((e.slot, e.velocity, off))
        }

        songBeat = b1
    }

    /// Dispara un hueco del kit, con el corte del charles abierto.
    private func play(slot: Int, gain: Float, offset: Int) {
        guard slots.indices.contains(slot) else { return }
        if slot == Slot.hat || slot == Slot.pedal { chokeOpenHat(offset: offset) }
        start(slots[slot], gain: gain, offset: offset, choke: slot == Slot.openHat ? 1 : 0)
    }

    private func chokeOpenHat(offset: Int) {
        for i in voices.indices where voices[i].sample != nil && voices[i].choke == 1 {
            voices[i].fadeStep = 1 / 240
        }
    }

    private func start(_ sample: Sample, gain: Float, offset: Int, choke: Int) {
        var index = voices.firstIndex { $0.sample == nil }
        if index == nil {
            // Sin voces libres: robamos la más avanzada.
            var best = 0
            for i in voices.indices where voices[i].pos > voices[best].pos { best = i }
            index = best
        }
        voices[index!] = Voice(sample: sample, pos: 0, delay: offset, gain: gain, choke: choke)
        lastSoundTime = CACurrentMediaTime() + Double(offset) / sr + latency
    }

    private func mix(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        for vi in voices.indices {
            guard let sample = voices[vi].sample else { continue }
            var v = voices[vi]
            sample.data.withUnsafeBufferPointer { p in
                var i = 0
                if v.delay > 0 {
                    let d = min(v.delay, n)
                    i = d
                    v.delay -= d
                }
                while i < n && v.pos < p.count {
                    var g = v.gain
                    if v.fadeStep > 0 {
                        v.fadeGain -= v.fadeStep
                        if v.fadeGain <= 0 { v.pos = p.count; break }
                        g *= v.fadeGain
                    }
                    out[i] += p[v.pos] * g
                    v.pos += 1
                    i += 1
                }
                if v.pos >= p.count { v.sample = nil }
            }
            voices[vi] = v
        }
        for i in 0..<n { out[i] = tanhf(out[i] * 0.85) }
    }
}

/// Carga un archivo de audio cualquiera y lo deja en mono a la frecuencia del motor.
enum SampleLoader {
    static func load(_ url: URL) -> Sample? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(min(file.length, Int64(inFormat.sampleRate * 10)))
        guard frames > 0, let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames),
              (try? file.read(into: inBuffer, frameCount: frames)) != nil else { return nil }

        let outFormat = AVAudioFormat(standardFormatWithSampleRate: DSP.sr, channels: 1)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(frames) * DSP.sr / inFormat.sampleRate) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, let channel = outBuffer.floatChannelData?[0] else { return nil }
        var data = Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
        let peak = data.map(abs).max() ?? 0
        if peak > 0.95 { data = data.map { $0 * 0.95 / peak } }
        return Sample(data, name: url.deletingPathExtension().lastPathComponent)
    }
}
