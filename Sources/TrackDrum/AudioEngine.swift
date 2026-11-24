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

/// A dónde va cada voz: lo que tocas en directo (se graba), los beats, el metrónomo
/// o el monitor (lo que tocas pero ya se ha escrito cuantizado en la pista, así que no se graba otra vez).
private enum Bus { static let live = 0, beats = 1, click = 2, mon = 3, count = 4 }

private struct Voice {
    var sample: Sample?
    var pos = 0
    var fpos = 0.0
    var rate = 1.0
    var delay = 0
    var gain: Float = 0
    var choke = 0
    var bus = 0
    var fadeStep: Float = 0
    var fadeGain: Float = 1
}

private struct Hit {
    let slot: Int
    let velocity: Float
    /// Sampler melódico: el sonido y a qué velocidad se reproduce (cambia la nota).
    let sample: Sample?
    let rate: Double
}

private struct Pluck {
    let string: Int
    let midi: Int      // < 0: apagar la cuerda
    let velocity: Float
    let bright: Float
    var delay: Int
    let bass: Bool
}

/// Mezclador de una pista (común a todas las escenas).
struct TrackMix: Codable, Equatable {
    var vol: Float = 0.85
    var pan: Float = 0     // -1 izquierda … 1 derecha
    var mute = false
    var solo = false
    var rev: Float = 0.12  // envío a la reverb
    var dly: Float = 0     // envío al delay
}

/// Lo que la interfaz necesita saber del motor.
struct EngineSnapshot {
    var playing = false
    var recording = false
    var bpm = 100.0
    var bars = 2
    var metronome = false
    var metronomeSound = true
    var metronomeHaptic = true
    var frame = 0
    var stepFrames = 1
    var countIn = 0
    var recTrack = 0
    var trackHas: [Bool] = []          // escena actual
    var mix: [TrackMix] = []
    var canUndo = false
    var beatsOn = true                 // escena actual
    var beatsVol: Float = 0.8
    var swing = 0.0
    var pattern: [[Float]] = []        // escena actual
    var scene = 0
    var queuedScene = -1
    var sceneHas: [Bool] = []          // escenas con algo (audio o ritmo)
    var song: [Int] = []
    var songMode = false
    var songPos = 0
    var fx = FXSettings()
    var quant = 0                      // 0 = no, 1 = semicorchea, 2 = corchea
    var quantStrength = 1.0
    var replace = false
    var hasAudio = false               // en cualquier escena
}

/// Todo lo que se guarda de un proyecto (menos el audio de las pistas).
struct EngineState {
    var bpm: Double
    var bars: Int
    var mix: [TrackMix]
    var patterns: [[[Float]]]
    var beatsOn: [Bool]
    var beatsVol: Float
    var swing: Double
    var scene: Int
    var song: [Int]
    var songMode: Bool
    var fx: FXSettings
    var quant: Int
    var quantStrength: Double
    var replace: Bool
}

/// Sampler + instrumentos + secuenciador + grabador multipista con escenas, todo en el hilo de audio
/// con precisión de muestra. El tiempo es un contador entero de muestras (`frame`);
/// cada semicorchea dura exactamente `stepFrames` muestras.
final class AudioEngine {
    static let trackCount = 6
    static let sceneCount = 4
    static let beatRows = [Slot.kick, Slot.snare, Slot.clap, Slot.hat, Slot.openHat, Slot.tomHi, Slot.tomLo, Slot.ride]
    static let beatSteps = 16
    static let beatsRevSend: Float = 0.1

    let sr: Double
    /// Muestras máximas por pista: 8 compases a 50 BPM.
    let maxFrames: Int

    /// (pulso dentro del loop, ¿primer pulso del compás?, retardo hasta que suena, ¿metrónomo háptico?)
    var onBeat: ((Int, Bool, Double, Bool) -> Void)?
    /// Un sonido del kit disparado por los beats (para iluminarlo).
    var onSlotPlayed: ((Int, Float, Double) -> Void)?
    /// Momento en que empezó a sonar lo último (para no confundir los altavoces con un golpe).
    private(set) var lastSoundTime: Double = 0
    /// Lo que tarda en oírse lo que sale del motor (salida actual).
    private(set) var latency: Double = 0.01
    /// La salida actual (nombre, si es Bluetooth…).
    private(set) var device: OutputDevice?
    /// Retraso medido a mano con la prueba de clics (por dispositivo). Si existe, manda al grabar.
    var calibratedLatency: Double? {
        get { lock.with { calLatency } }
        set { lock.with { calLatency = newValue } }
    }
    /// Retraso que se compensa al grabar.
    var recordLatency: Double { lock.with { calLatency ?? latency } }
    /// Se llama (en el hilo principal) cuando cambia la salida de audio.
    var onDeviceChange: (() -> Void)?
    /// Sube cada vez que cambia el audio grabado (para el autoguardado).
    private(set) var audioRevision = 0

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let lock = UnfairLock()

    // Estado compartido (protegido por `lock`).
    private var slots: [Sample]
    private var hits: [Hit] = []
    private var plucks: [Pluck] = []
    private var pendingTone: GuitarSynth.Tone?
    private var pendingBassTone: BassSynth.Tone?
    private var pendingPatch: Int?
    private var synthTouches: [SynthTouch] = []
    private var synthDirty = false
    private var playing = false
    private var recording = false
    private var bpm = 100.0
    private var bars = 2
    private var stepFrames = 1
    private var metronome = false
    private var metronomeSound = true
    private var metronomeHaptic = true
    private var frame = 0
    private var recTrack = 0
    private var mixer: [TrackMix]
    private var calLatency: Double?
    // Escenas: audio de cada pista y ritmo propios.
    private var bufs: [[UnsafeMutablePointer<Float>?]]
    private var has: [[Bool]]
    private var used: [[Int]]
    private var patterns: [[[Float]]]
    private var sceneBeatsOn: [Bool]
    private var scene = 0
    private var queuedScene = -1
    private var song: [Int] = []
    private var songMode = false
    private var songPos = 0
    // Deshacer la última toma.
    private var undoScene = 0
    private var undoTrack = -1
    private var undoHad = false
    private var undoUsed = 0
    // Prueba de latencia: clics a intervalos fijos y el momento exacto en que salió cada uno.
    private var calLeft = 0
    private var calCountdown = 0
    private var calInterval = 0
    private var calTimes: [Double] = []
    private var beatsVol: Float = 0.8
    private var swing = 0.0
    private var fx = FXSettings()
    private var quant = 0
    private var quantStrength = 1.0
    private var replace = false

    private let undoBuf: UnsafeMutablePointer<Float>

    // Solo hilo de audio.
    private var voices = [Voice](repeating: Voice(), count: 96)
    private let guitar: GuitarSynth
    private let bass: BassSynth
    private let synth: PolySynth
    private let reverb: Reverb
    private let delay: PingPongDelay
    private var comp: Compressor
    private let click: Sample
    private let clickAccent: Sample
    private let bus: [UnsafeMutablePointer<Float>]
    private let mixL: UnsafeMutablePointer<Float>
    private let mixR: UnsafeMutablePointer<Float>
    private let revIn: UnsafeMutablePointer<Float>
    private let dlyIn: UnsafeMutablePointer<Float>
    private static let maxBlock = 4096
    private var beatNotes: [(Int, Bool, Int, Bool)] = []
    private var slotNotes: [(Int, Float, Int)] = []

    init() {
        let probe = AVAudioEngine()
        let rate = probe.outputNode.outputFormat(forBus: 0).sampleRate
        sr = rate > 0 ? rate : 48_000
        DSP.sr = sr
        let maxF = Int(sr * 8 * 4 * 60 / 50) + 1024
        maxFrames = maxF

        slots = Kits.make(0).sounds
        guitar = GuitarSynth(sr: sr)
        bass = BassSynth(sr: sr)
        synth = PolySynth(sr: sr)
        reverb = Reverb(sr: sr)
        delay = PingPongDelay(sr: sr)
        comp = Compressor(sr: sr)
        click = Drum.click(1500)
        clickAccent = Drum.click(2400)
        mixer = Array(repeating: TrackMix(), count: Self.trackCount)
        bufs = Array(repeating: Array(repeating: nil, count: Self.trackCount), count: Self.sceneCount)
        has = Array(repeating: Array(repeating: false, count: Self.trackCount), count: Self.sceneCount)
        used = Array(repeating: Array(repeating: 0, count: Self.trackCount), count: Self.sceneCount)
        patterns = Array(repeating: Beats.presets[1].pattern, count: Self.sceneCount)
        sceneBeatsOn = Array(repeating: true, count: Self.sceneCount)
        undoBuf = .allocate(capacity: maxF)
        undoBuf.initialize(repeating: 0, count: maxF)
        func block() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxBlock)
            p.initialize(repeating: 0, count: Self.maxBlock)
            return p
        }
        bus = (0..<Bus.count).map { _ in block() }
        mixL = block(); mixR = block(); revIn = block(); dlyIn = block()
        hits.reserveCapacity(128)
        plucks.reserveCapacity(128)
        beatNotes.reserveCapacity(16)
        calTimes.reserveCapacity(64)
        slotNotes.reserveCapacity(64)
        recomputeTiming()
        ensureScene(0)
    }

    /// Reserva el audio de una escena la primera vez que se usa (fuera del hilo de audio).
    private func ensureScene(_ s: Int) {
        guard (0..<Self.sceneCount).contains(s) else { return }
        guard lock.with({ bufs[s][0] == nil }) else { return }
        let maxF = maxFrames
        let fresh: [UnsafeMutablePointer<Float>?] = (0..<Self.trackCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxF)
            p.initialize(repeating: 0, count: maxF)
            return p
        }
        let usedFresh = lock.with { () -> Bool in
            guard bufs[s][0] == nil else { return false }
            bufs[s] = fresh
            return true
        }
        if !usedFresh { fresh.forEach { $0?.deallocate() } }
    }

    // MARK: - Salida de audio

    func start() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            var done = 0
            let total = Int(frameCount)
            while done < total {
                let n = min(Self.maxBlock, total - done)
                self.render(n)
                (l + done).update(from: self.mixL, count: n)
                if let r { (r + done).update(from: self.mixR, count: n) }
                done += n
            }
            return noErr
        }
        engine.attach(source)
        try connectAndRun()

        // Seguimos a la salida del sistema (cascos, AirPods, altavoces…) por tres vías:
        // 1) AVAudioEngine avisa de que su configuración ha cambiado.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in self?.restartAudio() }
        // 2) CoreAudio avisa de que ha cambiado la salida por defecto.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.restartAudio()
        }
        // 3) Vigilante: si el motor está parado o usa otro dispositivo, se vuelve a montar.
        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.restartAttempt == 0 else { return }
            let current = OutputDevice.current()?.id
            if !self.engine.isRunning || (current != nil && current != self.boundDevice) { self.restartAudio() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
    }

    private var boundDevice: AudioObjectID = 0
    private var restartAttempt = 0
    private var restartPending = false

    /// Vuelve a montar la salida. Al quitar unos cascos el sistema tarda un momento en
    /// cambiar de dispositivo, así que si falla se reintenta unas cuantas veces.
    private func restartAudio() {
        guard !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            do {
                try self.connectAndRun()
                self.restartAttempt = 0
            } catch {
                self.restartAttempt += 1
                if self.restartAttempt <= 20 { self.restartAudio() } else { self.restartAttempt = 0 }
            }
        }
    }

    private func connectAndRun() throws {
        engine.stop()
        if let dev = OutputDevice.current(), let au = engine.outputNode.audioUnit {
            var id = dev.id
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioObjectID>.size))
            boundDevice = dev.id
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        engine.disconnectNodeOutput(source)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        // Mezclador → salida con el formato del dispositivo nuevo (puede tener otra frecuencia).
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        // Búfer pequeño = menos latencia (128 muestras ≈ 2,7 ms).
        if let au = engine.outputNode.audioUnit {
            var frames: UInt32 = 128
            AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                 &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        engine.prepare()
        try engine.start()
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let presented = engine.outputNode.presentationLatency + 128 / (outRate > 0 ? outRate : sr)
        device = OutputDevice.current()
        // Nos quedamos con la cifra más alta: con Bluetooth la de AVAudioEngine suele quedarse corta.
        let lat = max(presented, device?.reportedLatency ?? 0)
        lock.with { latency = lat }
        onDeviceChange?()
    }

    /// Prueba de latencia: `count` clics separados `interval` segundos.
    func startCalibration(count: Int, interval: Double) {
        let count = min(60, count)
        lock.with {
            playing = false; recording = false
            calTimes.removeAll(keepingCapacity: true)
            calLeft = count
            calInterval = Int(interval * sr)
            calCountdown = Int(0.6 * sr)
        }
    }

    func stopCalibration() { lock.with { calLeft = 0 } }

    /// Momentos (CACurrentMediaTime) en que el motor soltó cada clic, sin contar la latencia.
    func calibrationClicks() -> [Double] { lock.with { calTimes } }
    var calibrating: Bool { lock.with { calLeft > 0 } }

    // MARK: - Tocar (cualquier hilo)

    func trigger(slot: Int, velocity: Float) {
        lock.with { hits.append(Hit(slot: slot, velocity: velocity, sample: nil, rate: 1)) }
    }

    /// Sampler melódico: `semitones` respecto a la nota original del sonido.
    func trigger(sample: Sample, semitones: Double, velocity: Float) {
        lock.with { hits.append(Hit(slot: -1, velocity: velocity, sample: sample, rate: pow(2, semitones / 12))) }
    }

    func pluck(string: Int, midi: Int, velocity: Float, bright: Float, delay: Double = 0) {
        lock.with {
            plucks.append(Pluck(string: string, midi: midi, velocity: velocity, bright: bright,
                                delay: Int(delay * sr), bass: false))
        }
    }

    func dampString(_ string: Int) { pluck(string: string, midi: -1, velocity: 0, bright: 0) }

    func pluckBass(string: Int, midi: Int, velocity: Float) {
        lock.with { plucks.append(Pluck(string: string, midi: midi, velocity: velocity, bright: 0, delay: 0, bass: true)) }
    }

    func dampBass(_ string: Int) {
        lock.with { plucks.append(Pluck(string: string, midi: -1, velocity: 0, bright: 0, delay: 0, bass: true)) }
    }

    func setSynthTouches(_ t: [SynthTouch]) { lock.with { synthTouches = t; synthDirty = true } }
    func setGuitarTone(_ t: GuitarSynth.Tone) { lock.with { pendingTone = t } }
    func setBassTone(_ t: BassSynth.Tone) { lock.with { pendingBassTone = t } }
    func setSynthPatch(_ i: Int) { lock.with { pendingPatch = i } }
    func setSlots(_ sounds: [Sample]) { lock.with { slots = sounds } }

    // MARK: - Transporte

    func togglePlay() {
        lock.with {
            if playing {
                playing = false
                recording = false
                queuedScene = -1
            } else {
                frame = 0
                startSongIfNeeded()
                playing = true
            }
        }
    }

    private func startSongIfNeeded() {
        if songMode, let first = song.first, bufs[first][0] != nil {
            songPos = 0
            scene = first
        }
        queuedScene = -1
    }

    func stop() { lock.with { playing = false; recording = false } }

    /// Graba (o deja de grabar) en la pista `track`. Si está parado, un compás de cuenta atrás.
    func toggleRecording(track: Int) {
        lock.with {
            if recording {
                recording = false
                return
            }
            guard (0..<Self.trackCount).contains(track), let buf = bufs[scene][track] else { return }
            recTrack = track
            // Copia para deshacer esta toma.
            let n = min(maxFrames, max(used[scene][track], loopFrames))
            undoBuf.update(from: buf, count: n)
            undoScene = scene
            undoTrack = track
            undoHad = has[scene][track]
            undoUsed = used[scene][track]
            // Reemplazar: la toma nueva sustituye a lo que había.
            if replace && has[scene][track] {
                buf.update(repeating: 0, count: n)
                has[scene][track] = false
                used[scene][track] = 0
                audioRevision += 1
            }
            recording = true
            if !playing {
                frame = -16 * stepFrames
                startSongIfNeeded()
                playing = true
            }
        }
    }

    func selectTrack(_ t: Int) { lock.with { if !recording, (0..<Self.trackCount).contains(t) { recTrack = t } } }

    func undo() {
        lock.with {
            guard undoTrack >= 0, !recording, let buf = bufs[undoScene][undoTrack] else { return }
            let n = min(maxFrames, max(undoUsed, used[undoScene][undoTrack], loopFrames))
            buf.update(from: undoBuf, count: n)
            has[undoScene][undoTrack] = undoHad
            used[undoScene][undoTrack] = undoUsed
            undoTrack = -1
            audioRevision += 1
        }
    }

    func clearTrack(_ t: Int) {
        lock.with {
            guard (0..<Self.trackCount).contains(t), let buf = bufs[scene][t] else { return }
            if recording && recTrack == t { recording = false }
            buf.update(repeating: 0, count: min(maxFrames, max(used[scene][t], 1)))
            has[scene][t] = false
            used[scene][t] = 0
            if undoTrack == t && undoScene == scene { undoTrack = -1 }
            audioRevision += 1
        }
    }

    /// Copia una pista en la primera libre (de la escena actual). Devuelve la pista nueva.
    func duplicateTrack(_ t: Int) -> Int? {
        lock.with {
            guard (0..<Self.trackCount).contains(t), has[scene][t], let src = bufs[scene][t] else { return nil }
            // Mejor una pista vacía en todas las escenas; si no hay, una vacía en esta.
            let free = (0..<Self.trackCount).first { d in d != t && (0..<Self.sceneCount).allSatisfy { !has[$0][d] } }
                ?? (0..<Self.trackCount).first { $0 != t && !has[scene][$0] }
            guard let d = free, let dst = bufs[scene][d] else { return nil }
            let n = min(maxFrames, max(used[scene][t], loopFrames))
            dst.update(from: src, count: n)
            has[scene][d] = true
            used[scene][d] = used[scene][t]
            mixer[d] = mixer[t]
            mixer[d].solo = false
            audioRevision += 1
            return d
        }
    }

    func setMix(_ t: Int, _ f: (inout TrackMix) -> Void) {
        lock.with {
            guard mixer.indices.contains(t) else { return }
            f(&mixer[t])
            mixer[t].vol = min(1.2, max(0, mixer[t].vol))
            mixer[t].pan = min(1, max(-1, mixer[t].pan))
            mixer[t].rev = min(1, max(0, mixer[t].rev))
            mixer[t].dly = min(1, max(0, mixer[t].dly))
        }
    }

    func setStep(row: Int, step: Int, value: Float) {
        lock.with {
            guard patterns[scene].indices.contains(row), (0..<Self.beatSteps).contains(step) else { return }
            patterns[scene][row][step] = value
        }
    }
    func setPattern(_ p: [[Float]]) { lock.with { patterns[scene] = p } }
    func setBeatsOn(_ on: Bool) { lock.with { sceneBeatsOn[scene] = on } }
    func setBeatsVolume(_ v: Float) { lock.with { beatsVol = min(1.2, max(0, v)) } }
    func setSwing(_ v: Double) { lock.with { swing = min(0.5, max(0, v)) } }
    func setFX(_ f: (inout FXSettings) -> Void) {
        lock.with {
            f(&fx)
            fx.revSize = min(1, max(0, fx.revSize))
            fx.dlyFb = min(0.85, max(0, fx.dlyFb))
            fx.compAmt = min(1, max(0, fx.compAmt))
            if ![2, 3, 4].contains(fx.dlyDiv) { fx.dlyDiv = 3 }
        }
    }
    func setQuantize(_ q: Int) { lock.with { quant = [0, 1, 2].contains(q) ? q : 0 } }
    func setQuantizeStrength(_ v: Double) { lock.with { quantStrength = min(1, max(0, v)) } }
    func setReplace(_ on: Bool) { lock.with { replace = on } }

    /// Cambia de escena. Sonando, el cambio espera al final del loop.
    func selectScene(_ s: Int) {
        guard (0..<Self.sceneCount).contains(s) else { return }
        ensureScene(s)
        lock.with {
            if playing && !(songMode && !song.isEmpty) {
                queuedScene = s == scene ? -1 : s
            } else if !playing {
                scene = s
                queuedScene = -1
            }
        }
    }

    func setSong(_ chain: [Int]) {
        let chain = Array(chain.filter { (0..<Self.sceneCount).contains($0) }.prefix(32))
        chain.forEach(ensureScene)
        lock.with {
            song = chain
            if songPos >= song.count { songPos = 0 }
        }
    }

    func setSongMode(_ on: Bool) { lock.with { songMode = on; if !on { songPos = 0 } } }

    /// Con audio grabado el tempo queda fijo: cambiarlo desincronizaría las pistas.
    func setBPM(_ value: Double) {
        lock.with {
            guard !anyAudio else { return }
            let old = stepFrames
            bpm = min(220, max(50, value))
            recomputeTiming()
            if playing { frame = Int(Double(frame) * Double(stepFrames) / Double(old)) }
        }
    }
    func setBars(_ n: Int) { lock.with { bars = [1, 2, 4, 8].contains(n) ? n : 2 } }
    func setMetronome(_ on: Bool) { lock.with { metronome = on } }
    func setMetronomeSound(_ on: Bool) { lock.with { metronomeSound = on } }
    func setMetronomeHaptic(_ on: Bool) { lock.with { metronomeHaptic = on } }

    func configure(bpm: Double, bars: Int, metronome: Bool, sound: Bool, haptic: Bool) {
        lock.with {
            self.bpm = min(220, max(50, bpm)); self.bars = [1, 2, 4, 8].contains(bars) ? bars : 2
            self.metronome = metronome; metronomeSound = sound; metronomeHaptic = haptic
            recomputeTiming()
        }
    }

    func configureBeats(pattern: [[Float]]?, on: Bool, volume: Float, swing: Double) {
        lock.with {
            if let pattern, Self.validPattern(pattern) { patterns[scene] = pattern }
            sceneBeatsOn[scene] = on; beatsVol = volume; self.swing = swing
        }
    }

    private static func validPattern(_ p: [[Float]]) -> Bool {
        p.count == beatRows.count && p.allSatisfy { $0.count == beatSteps }
    }

    private var anyAudio: Bool { has.contains { $0.contains(true) } }

    func snapshot() -> EngineSnapshot {
        lock.with {
            EngineSnapshot(playing: playing, recording: recording, bpm: bpm, bars: bars,
                           metronome: metronome, metronomeSound: metronomeSound, metronomeHaptic: metronomeHaptic,
                           frame: frame, stepFrames: stepFrames,
                           countIn: frame < 0 ? Int((Double(-frame) / Double(stepFrames * 4)).rounded(.up)) : 0,
                           recTrack: recTrack, trackHas: has[scene], mix: mixer,
                           canUndo: undoTrack >= 0 && !recording,
                           beatsOn: sceneBeatsOn[scene], beatsVol: beatsVol, swing: swing, pattern: patterns[scene],
                           scene: scene, queuedScene: queuedScene,
                           sceneHas: (0..<Self.sceneCount).map { s in
                               has[s].contains(true) || (sceneBeatsOn[s] && patterns[s].contains { $0.contains { $0 > 0 } })
                           },
                           song: song, songMode: songMode, songPos: songPos, fx: fx,
                           quant: quant, quantStrength: quantStrength, replace: replace, hasAudio: anyAudio)
        }
    }

    /// Picos de una pista (escena actual) para dibujar su forma de onda (0..1). Lee sin bloquear.
    func peaks(track t: Int, count: Int) -> [Float] {
        let (len, hasIt, buf) = lock.with { (loopFrames, has[scene][t], bufs[scene][t]) }
        guard hasIt, count > 0, let p = buf else { return [] }
        let per = max(1, len / count)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var m: Float = 0
            let start = i * per
            var j = start
            while j < min(len, start + per) { m = max(m, abs(p[j])); j += 4 }
            out[i] = min(1, m)
        }
        return out
    }

    // MARK: - Proyecto

    func state() -> EngineState {
        lock.with {
            EngineState(bpm: bpm, bars: bars, mix: mixer, patterns: patterns, beatsOn: sceneBeatsOn,
                        beatsVol: beatsVol, swing: swing, scene: scene, song: song, songMode: songMode, fx: fx,
                        quant: quant, quantStrength: quantStrength, replace: replace)
        }
    }

    func hasAudio(scene s: Int, track t: Int) -> Bool { lock.with { has[s][t] } }

    /// Audio de una pista (lo usado), o nil si está vacía.
    func trackAudio(scene s: Int, track t: Int) -> [Float]? {
        lock.with {
            guard has[s][t], let buf = bufs[s][t] else { return nil }
            let n = min(maxFrames, max(used[s][t], loopFrames))
            return Array(UnsafeBufferPointer(start: buf, count: n))
        }
    }

    /// Deja el motor vacío (proyecto nuevo) con estos ajustes.
    func load(_ st: EngineState, audio: [(scene: Int, track: Int, data: [Float])]) {
        for s in Set(audio.map(\.scene) + [st.scene] + st.song) { ensureScene(s) }
        lock.with {
            playing = false; recording = false
            frame = 0
            bpm = min(220, max(50, st.bpm))
            bars = [1, 2, 4, 8].contains(st.bars) ? st.bars : 2
            recomputeTiming()
            for t in 0..<Self.trackCount { mixer[t] = st.mix.indices.contains(t) ? st.mix[t] : TrackMix() }
            for s in 0..<Self.sceneCount {
                patterns[s] = st.patterns.indices.contains(s) && Self.validPattern(st.patterns[s]) ? st.patterns[s] : Beats.presets[0].pattern
                sceneBeatsOn[s] = st.beatsOn.indices.contains(s) ? st.beatsOn[s] : true
                for t in 0..<Self.trackCount {
                    if let b = bufs[s][t], has[s][t] || used[s][t] > 0 { b.update(repeating: 0, count: min(maxFrames, max(used[s][t], 1))) }
                    has[s][t] = false
                    used[s][t] = 0
                }
            }
            for a in audio {
                guard (0..<Self.sceneCount).contains(a.scene), (0..<Self.trackCount).contains(a.track),
                      let b = bufs[a.scene][a.track] else { continue }
                let n = min(maxFrames, a.data.count)
                a.data.withUnsafeBufferPointer { b.update(from: $0.baseAddress!, count: n) }
                has[a.scene][a.track] = true
                used[a.scene][a.track] = max(n, loopFrames)
            }
            beatsVol = st.beatsVol
            swing = min(0.5, max(0, st.swing))
            scene = (0..<Self.sceneCount).contains(st.scene) ? st.scene : 0
            queuedScene = -1
            song = st.song.filter { bufs.indices.contains($0) && bufs[$0][0] != nil }
            songMode = st.songMode
            songPos = 0
            fx = st.fx
            quant = st.quant
            quantStrength = st.quantStrength
            replace = st.replace
            undoTrack = -1
            recTrack = 0
            audioRevision += 1
        }
    }

    // MARK: - Exportar (render fuera de tiempo real)

    struct Bounce {
        var mix: [[Float]]                          // [L, R]
        var stems: [(track: Int, audio: [[Float]])] // pistas por separado, en seco
        var beats: [[Float]]?
    }

    /// Mezcla el loop (o la canción entera, en modo canción) con efectos. Con `stems`, también cada pista.
    func bounce(stems: Bool) -> Bounce {
        let (len, sf, mix, pats, bOn, kit, sw, bv, fxs, seq0, isSong, nBars, bufCopy, hasCopy) = lock.with {
            (loopFrames, stepFrames, mixer, patterns, sceneBeatsOn, slots, swing, beatsVol, fx,
             songMode && !song.isEmpty ? song : [scene], songMode && !song.isEmpty, bars, bufs, has)
        }
        // Un loop se renderiza dos veces y nos quedamos con la segunda: así las colas
        // (reverb, delay, platillos) del final suenan al principio y el loop empalma bien.
        let seq = isSong ? seq0 : [seq0[0], seq0[0]]
        let tail = isSong ? Int(sr * 3) : 0
        let total = seq.count * len + tail
        let keepFrom = isSong ? 0 : len

        var dryL = [Float](repeating: 0, count: total), dryR = dryL
        var rev = dryL, dly = dryL
        var stemL: [Int: [Float]] = [:], stemR: [Int: [Float]] = [:]
        var beatsMono: [Float]? = nil
        let anySolo = mix.contains { $0.solo }

        for (j, s) in seq.enumerated() {
            let off = j * len
            for t in 0..<Self.trackCount where hasCopy[s][t] {
                guard let p = bufCopy[s][t] else { continue }
                let m = mix[t]
                let audible = !m.mute && (!anySolo || m.solo)
                let gl = m.vol * min(1, 1 - m.pan), gr = m.vol * min(1, 1 + m.pan)
                if audible {
                    for i in 0..<len {
                        let x = p[i]
                        dryL[off + i] += x * gl; dryR[off + i] += x * gr
                        rev[off + i] += x * m.vol * m.rev; dly[off + i] += x * m.vol * m.dly
                    }
                }
                if stems {
                    if stemL[t] == nil { stemL[t] = [Float](repeating: 0, count: total); stemR[t] = stemL[t] }
                    for i in 0..<len { stemL[t]![off + i] += p[i] * gl; stemR[t]![off + i] += p[i] * gr }
                }
            }
            if bOn[s] && pats[s].contains(where: { $0.contains { $0 > 0 } }) {
                if beatsMono == nil { beatsMono = [Float](repeating: 0, count: total) }
                Self.renderBeats(at: off, sf: sf, pat: pats[s], swing: sw, kit: kit, bars: nBars, gain: bv,
                                 wrap: false, into: &beatsMono!)
            }
        }
        if let b = beatsMono {
            for i in 0..<total {
                dryL[i] += b[i]; dryR[i] += b[i]
                rev[i] += b[i] * Self.beatsRevSend
            }
        }

        // Efectos con instancias nuevas (no tocan las del directo).
        let rv = Reverb(sr: sr)
        rv.setSize(fxs.revSize)
        let dl = PingPongDelay(sr: sr)
        dl.time = sf * fxs.dlyDiv
        dl.feedback = Float(fxs.dlyFb)
        var cp = Compressor(sr: sr)
        var outL = [Float](repeating: 0, count: total - keepFrom), outR = outL
        for i in 0..<total {
            let (dlL, dlR) = dl.process(dly[i])
            let (rl, rr) = rv.process(rev[i] + (dlL + dlR) * 0.25)
            var l = dryL[i] + dlL + rl, r = dryR[i] + dlR + rr
            if fxs.comp {
                let g = cp.gain(max(abs(l), abs(r)), amount: Float(fxs.compAmt))
                l *= g; r *= g
            }
            if i >= keepFrom {
                outL[i - keepFrom] = tanhf(l * 0.85)
                outR[i - keepFrom] = tanhf(r * 0.85)
            }
        }

        var result = Bounce(mix: [outL, outR], stems: [], beats: nil)
        if stems {
            for t in stemL.keys.sorted() {
                result.stems.append((t, [Array(stemL[t]![keepFrom...]), Array(stemR[t]![keepFrom...])]))
            }
            if let b = beatsMono {
                let part = Array(b[keepFrom...])
                result.beats = [part, part]
            }
        }
        return result
    }

    /// Renderiza los beats de un loop a partir de `off`. Con `wrap`, lo que se sale da la vuelta al principio.
    private static func renderBeats(at off: Int, sf: Int, pat: [[Float]], swing sw: Double, kit: [Sample], bars nBars: Int,
                                    gain: Float, wrap: Bool, into mix: inout [Float]) {
        let count = mix.count
        let hatRow = beatRows.firstIndex(of: Slot.hat)!
        for s in 0..<(nBars * 16) {
            let col = s % beatSteps
            let start = off + s * sf + (col % 2 == 1 ? Int(sw * Double(sf)) : 0)
            for (r, slot) in beatRows.enumerated() where pat[r][col] > 0 && kit.indices.contains(slot) {
                // El charles cerrado corta al abierto, como en directo.
                var data = kit[slot].data[...]
                if slot == Slot.openHat {
                    var cut = data.count
                    for d in 1..<16 where pat[hatRow][(col + d) % beatSteps] > 0 { cut = d * sf; break }
                    data = data.prefix(cut)
                }
                let g = pat[r][col] * gain
                for (k, x) in data.enumerated() {
                    let i = start + k
                    if i < count { mix[i] += x * g } else if wrap { mix[i % count] += x * g } else { break }
                }
            }
        }
    }

    /// Pasa el ritmo actual a una pista de audio (y apaga los beats para que no suene doble).
    func bounceBeats(to t: Int) {
        guard (0..<Self.trackCount).contains(t) else { return }
        let (len, sf, pat, sw, kit, nBars) = lock.with { (loopFrames, stepFrames, patterns[scene], swing, slots, bars) }
        var mix = [Float](repeating: 0, count: len)
        Self.renderBeats(at: 0, sf: sf, pat: pat, swing: sw, kit: kit, bars: nBars, gain: 1, wrap: true, into: &mix)
        lock.with {
            guard len == loopFrames, let buf = bufs[scene][t] else { return }
            let n = min(maxFrames, max(used[scene][t], len))
            undoBuf.update(from: buf, count: n)
            undoScene = scene; undoTrack = t; undoHad = has[scene][t]; undoUsed = used[scene][t]
            buf.update(repeating: 0, count: n)
            mix.withUnsafeBufferPointer { buf.update(from: $0.baseAddress!, count: len) }
            has[scene][t] = true
            used[scene][t] = len
            mixer[t].vol = beatsVol
            mixer[t].rev = Self.beatsRevSend
            sceneBeatsOn[scene] = false
            audioRevision += 1
        }
    }

    // MARK: - Tiempo

    private var loopFrames: Int { stepFrames * bars * 16 }

    private func recomputeTiming() {
        stepFrames = max(1, Int((sr * 60 / bpm / 4).rounded()))
    }

    // MARK: - Hilo de audio

    /// Dónde cae un golpe dentro del loop al cuantizarlo (o nil si aún no toca grabarlo).
    private func quantizedPosition(_ f0: Int) -> Int? {
        let len = loopFrames
        let grid = stepFrames * quant
        let lat = Int((calLatency ?? latency) * sr)
        let raw = f0 - lat
        guard grid > 0, raw >= -grid / 2 else { return nil }
        let q = Int((Double(raw) / Double(grid)).rounded()) * grid
        let p = raw + Int(Double(q - raw) * quantStrength)
        return ((p % len) + len) % len
    }

    /// Escribe un golpe directamente en una pista (con cambio de nota si `rate` ≠ 1).
    private func write(_ s: Sample, gain: Float, rate: Double, into buf: UnsafeMutablePointer<Float>, at start: Int, len: Int) {
        s.data.withUnsafeBufferPointer { p in
            guard p.count > 1 else { return }
            let outLen = min(len, Int(Double(p.count - 1) / rate))
            var dst = start
            var f = 0.0
            for _ in 0..<outLen {
                let ip = Int(f)
                let fr = Float(f - Double(ip))
                buf[dst] += (p[ip] + (p[ip + 1] - p[ip]) * fr) * gain
                f += rate
                dst += 1
                if dst == len { dst = 0 }
            }
        }
    }

    private func render(_ n: Int) {
        for b in 0..<Bus.count { bus[b].update(repeating: 0, count: n) }
        mixL.update(repeating: 0, count: n)
        mixR.update(repeating: 0, count: n)
        revIn.update(repeating: 0, count: n)
        dlyIn.update(repeating: 0, count: n)
        let live = bus[Bus.live], beats = bus[Bus.beats], clk = bus[Bus.click], mon = bus[Bus.mon]
        beatNotes.removeAll(keepingCapacity: true)
        slotNotes.removeAll(keepingCapacity: true)

        lock.lock()
        if let t = pendingTone { guitar.setTone(t); pendingTone = nil }
        if let t = pendingBassTone { bass.setTone(t); pendingBassTone = nil }
        if let p = pendingPatch { synth.setPatch(p); pendingPatch = nil }
        if synthDirty {
            synth.update(synthTouches)
            synthDirty = false
            if !synthTouches.isEmpty { lastSoundTime = CACurrentMediaTime() + latency }
        }

        let f0 = frame
        // Golpes: con cuantización y grabando, se escriben ya en su sitio y aquí solo se escuchan.
        for h in hits {
            let s: Sample? = h.sample ?? (slots.indices.contains(h.slot) ? slots[h.slot] : nil)
            guard let s else { continue }
            if recording && playing && quant > 0, let buf = bufs[scene][recTrack], let at = quantizedPosition(f0) {
                write(s, gain: h.velocity, rate: h.rate, into: buf, at: at, len: loopFrames)
                has[scene][recTrack] = true
                used[scene][recTrack] = max(used[scene][recTrack], loopFrames)
                audioRevision += 1
                if h.sample == nil { play(slot: h.slot, gain: h.velocity, offset: 0, bus: Bus.mon) }
                else { start(s, gain: h.velocity, offset: 0, choke: 0, bus: Bus.mon, rate: h.rate) }
            } else if h.sample == nil {
                play(slot: h.slot, gain: h.velocity, offset: 0, bus: Bus.live)
            } else {
                start(s, gain: h.velocity, offset: 0, choke: 0, bus: Bus.live, rate: h.rate)
            }
        }
        hits.removeAll(keepingCapacity: true)

        var i = 0
        while i < plucks.count {
            if plucks[i].delay < n {
                let p = plucks[i]
                if p.bass {
                    if p.midi < 0 { bass.damp(string: p.string) } else { bass.pluck(string: p.string, midi: p.midi, velocity: p.velocity) }
                } else if p.midi < 0 {
                    guitar.damp(string: p.string)
                } else {
                    guitar.pluck(string: p.string, midi: p.midi, velocity: p.velocity, bright: p.bright)
                }
                if p.midi >= 0 { lastSoundTime = CACurrentMediaTime() + latency }
                plucks.remove(at: i)
            } else {
                plucks[i].delay -= n
                i += 1
            }
        }

        let now = CACurrentMediaTime()
        if calLeft > 0 {
            if calCountdown < n {
                let off = max(0, calCountdown)
                start(clickAccent, gain: 0.8, offset: off, choke: 0, bus: Bus.click)
                calTimes.append(now + Double(off) / sr)
                calLeft -= 1
                calCountdown += calInterval
            }
            calCountdown -= n
        }

        let oldScene = scene
        let recBefore = recording ? recTrack : -1
        var switchAt = n
        if playing { switchAt = schedule(n) }

        mix(n)
        guitar.render(live, n)
        bass.render(live, n)
        synth.render(live, n)

        // Pistas: reproducir y grabar lo que suena en directo.
        let len = loopFrames
        if playing && f0 + n > 0 && len > 0 {
            let i0 = max(0, -f0)
            let pos0 = (f0 + i0) % len
            // Tocas siguiendo lo que oyes, que llega `latency` tarde: grabamos ese tanto antes
            // para que la toma quede en su sitio (importa mucho con cascos Bluetooth).
            let lat = min(len - 1, Int((calLatency ?? latency) * sr))
            let anySolo = mixer.contains { $0.solo }
            let a = min(switchAt, n)
            var pos = pos0
            if i0 < a { playTracks(scene: oldScene, from: i0, to: a, pos: &pos, len: len, anySolo: anySolo) }
            if a < n { playTracks(scene: scene, from: max(a, i0), to: n, pos: &pos, len: len, anySolo: anySolo) }
            // Grabación (solo hasta el cambio de escena, si lo hay).
            if recBefore >= 0, let rb = bufs[oldScene][recBefore], i0 < a {
                var wpos = ((pos0 - lat) % len + len) % len
                var wrote = false
                for k in i0..<a {
                    let x = live[k]
                    rb[wpos] += x
                    if x != 0 { wrote = true }
                    wpos += 1
                    if wpos >= len { wpos = 0 }
                }
                if wrote && !has[oldScene][recBefore] { has[oldScene][recBefore] = true }
                if wrote { audioRevision += 1 }
                used[oldScene][recBefore] = max(used[oldScene][recBefore], len)
            }
        }

        // Directo: con los envíos de la pista seleccionada (lo que oyes es lo que vas a grabar).
        let liveMix = mixer[recTrack]
        let bv = beatsVol
        let fxs = fx
        delay.time = stepFrames * fxs.dlyDiv
        lock.unlock()

        reverb.setSize(fxs.revSize)
        delay.feedback = Float(fxs.dlyFb)
        let compAmt = Float(fxs.compAmt)
        let bRev = Self.beatsRevSend
        for k in 0..<n {
            let lv = live[k] + mon[k]
            let bt = beats[k] * bv
            var l = mixL[k] + lv + bt, r = mixR[k] + lv + bt
            let (dl, dr) = delay.process(dlyIn[k] + lv * liveMix.dly)
            let (rl, rr) = reverb.process(revIn[k] + lv * liveMix.rev + bt * bRev + (dl + dr) * 0.25)
            l += dl + rl
            r += dr + rr
            if fxs.comp {
                let g = comp.gain(max(abs(l), abs(r)), amount: compAmt)
                l *= g; r *= g
            }
            mixL[k] = tanhf((l + clk[k]) * 0.85)
            mixR[k] = tanhf((r + clk[k]) * 0.85)
        }

        // Avisos a la interfaz / háptica, compensando lo que tarda en salir el audio.
        for (beat, accent, offset, haptic) in beatNotes {
            onBeat?(beat, accent, Double(offset) / sr + latency, haptic)
        }
        for (slot, vel, offset) in slotNotes {
            onSlotPlayed?(slot, vel, Double(offset) / sr + latency)
        }
    }

    /// Suma las pistas de una escena al estéreo y a los envíos de efectos.
    private func playTracks(scene s: Int, from: Int, to: Int, pos: inout Int, len: Int, anySolo: Bool) {
        let start = pos
        for t in 0..<Self.trackCount where has[s][t] {
            let m = mixer[t]
            guard !m.mute, !anySolo || m.solo, let p = bufs[s][t] else { continue }
            let gl = m.vol * min(1, 1 - m.pan), gr = m.vol * min(1, 1 + m.pan)
            let sendRev = m.vol * m.rev, sendDly = m.vol * m.dly
            var q = start
            for i in from..<to {
                let x = p[q]
                mixL[i] += x * gl
                mixR[i] += x * gr
                revIn[i] += x * sendRev
                dlyIn[i] += x * sendDly
                q += 1
                if q >= len { q = 0 }
            }
        }
        pos = (start + (to - from)) % len
    }

    /// Semicorcheas de este bloque: cuenta atrás, cambio de escena, metrónomo y beats.
    /// Devuelve en qué muestra del bloque cambia de escena (o `n` si no cambia).
    private func schedule(_ n: Int) -> Int {
        let f0 = frame, f1 = frame + n
        let sf = stepFrames
        var switchAt = n
        var k = Int((Double(f0) / Double(sf)).rounded(.up))
        while k * sf < f1 {
            let off = k * sf - f0
            if k < 0 {
                if k % 4 == 0 {
                    // Cuenta atrás: siempre suena y vibra.
                    let accent = k == -16
                    start(accent ? clickAccent : click, gain: 0.7, offset: off, choke: 0, bus: Bus.click)
                    beatNotes.append((k / 4, accent, off, true))
                }
            } else {
                let loopSteps = bars * 16
                let inLoop = k % loopSteps
                // Final del loop: siguiente escena de la canción o la que se pidió.
                if inLoop == 0 && k > 0 {
                    var next = -1
                    if songMode && !song.isEmpty {
                        songPos = (songPos + 1) % song.count
                        next = song[songPos]
                    } else if queuedScene >= 0 {
                        next = queuedScene
                    }
                    queuedScene = -1
                    if next >= 0 && next != scene && bufs[next][0] != nil && switchAt == n {
                        switchAt = off
                        scene = next
                        recording = false
                    }
                }
                if inLoop % 4 == 0 {
                    let beat = inLoop / 4
                    let accent = beat % 4 == 0
                    if metronome && metronomeSound {
                        start(accent ? clickAccent : click, gain: 0.55, offset: off, choke: 0, bus: Bus.click)
                    }
                    beatNotes.append((beat, accent, off, metronome && metronomeHaptic))
                }
                if sceneBeatsOn[scene] {
                    let col = k % Self.beatSteps
                    let swingOff = col % 2 == 1 ? Int(swing * Double(sf)) : 0
                    let pat = patterns[scene]
                    for (r, slot) in Self.beatRows.enumerated() where pat[r][col] > 0 {
                        play(slot: slot, gain: pat[r][col], offset: off + swingOff, bus: Bus.beats)
                        slotNotes.append((slot, pat[r][col], off + swingOff))
                    }
                }
            }
            k += 1
        }
        frame = f1
        return switchAt
    }

    /// Dispara un hueco del kit, con el corte del charles abierto.
    private func play(slot: Int, gain: Float, offset: Int, bus: Int) {
        guard slots.indices.contains(slot) else { return }
        if slot == Slot.hat || slot == Slot.pedal { chokeOpenHat() }
        start(slots[slot], gain: gain, offset: offset, choke: slot == Slot.openHat ? 1 : 0, bus: bus)
    }

    private func chokeOpenHat() {
        for i in voices.indices where voices[i].sample != nil && voices[i].choke == 1 {
            voices[i].fadeStep = 1 / 240
        }
    }

    private func start(_ sample: Sample, gain: Float, offset: Int, choke: Int, bus: Int, rate: Double = 1) {
        var index = voices.firstIndex { $0.sample == nil }
        if index == nil {
            var best = 0
            for i in voices.indices where voices[i].pos > voices[best].pos { best = i }
            index = best
        }
        voices[index!] = Voice(sample: sample, pos: 0, fpos: 0, rate: rate, delay: offset, gain: gain, choke: choke, bus: bus)
        lastSoundTime = CACurrentMediaTime() + Double(offset) / sr + latency
    }

    private func mix(_ n: Int) {
        for vi in voices.indices {
            guard let sample = voices[vi].sample else { continue }
            var v = voices[vi]
            let out = bus[v.bus]
            sample.data.withUnsafeBufferPointer { p in
                var i = 0
                if v.delay > 0 {
                    let d = min(v.delay, n)
                    i = d
                    v.delay -= d
                }
                if v.rate == 1 {
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
                } else {
                    // Con cambio de nota: lectura fraccional con interpolación lineal.
                    let last = p.count - 1
                    while i < n {
                        let ip = Int(v.fpos)
                        if ip >= last { v.sample = nil; break }
                        let fr = Float(v.fpos - Double(ip))
                        out[i] += (p[ip] + (p[ip + 1] - p[ip]) * fr) * v.gain
                        v.fpos += v.rate
                        i += 1
                    }
                    v.pos = Int(v.fpos)
                }
            }
            voices[vi] = v
        }
    }
}

/// Carga un archivo de audio cualquiera y lo deja en mono a la frecuencia del motor.
enum SampleLoader {
    /// `maxSeconds` limita lo que se lee; `normalize` evita que un sample llegue saturado.
    static func load(_ url: URL, maxSeconds: Double? = 10, normalize: Bool = true) -> Sample? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        let limit = maxSeconds.map { Int64(inFormat.sampleRate * $0) } ?? file.length
        let frames = AVAudioFrameCount(min(file.length, limit))
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
        if normalize {
            let peak = data.map(abs).max() ?? 0
            if peak > 0.95 { data = data.map { $0 * 0.95 / peak } }
        }
        return Sample(data, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Guarda audio en WAV (32 bits float), mono o estéreo según cuántos canales lleguen.
    static func writeWAV(_ channels: [[Float]], sr: Double, to url: URL) throws {
        guard let first = channels.first, !first.isEmpty else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: AVAudioChannelCount(channels.count))!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(first.count)) else { return }
        buf.frameLength = AVAudioFrameCount(first.count)
        for (c, data) in channels.enumerated() {
            data.withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress!, count: min(first.count, data.count)) }
        }
        try file.write(from: buf)
    }
}
