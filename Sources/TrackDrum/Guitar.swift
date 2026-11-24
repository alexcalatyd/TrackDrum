import Foundation

/// Acordes de guitarra: traste por cuerda (de la 6ª, Mi grave, a la 1ª). -1 = cuerda que no se toca.
enum Chords {
    static let tuning = [40, 45, 50, 55, 59, 64] // Mi La Re Sol Si Mi
    static let stringNames = ["E", "A", "D", "G", "B", "e"]
    static let open = [0, 0, 0, 0, 0, 0]

    static let list: [(name: String, frets: [Int])] = [
        ("C", [-1, 3, 2, 0, 1, 0]),
        ("G", [3, 2, 0, 0, 0, 3]),
        ("Am", [-1, 0, 2, 2, 1, 0]),
        ("F", [1, 3, 3, 2, 1, 1]),
        ("D", [-1, -1, 0, 2, 3, 2]),
        ("Em", [0, 2, 2, 0, 0, 0]),
        ("E", [0, 2, 2, 1, 0, 0]),
        ("A", [-1, 0, 2, 2, 2, 0]),
        ("Dm", [-1, -1, 0, 2, 3, 1]),
        ("Bm", [-1, 2, 4, 4, 3, 2]),
        ("G7", [3, 2, 0, 0, 0, 1]),
        ("A7", [-1, 0, 2, 0, 2, 0]),
        ("D7", [-1, -1, 0, 2, 1, 2]),
        ("E7", [0, 2, 0, 1, 0, 0]),
        ("B7", [-1, 2, 1, 2, 0, 2]),
        ("Cmaj7", [-1, 3, 2, 0, 0, 0]),
    ]

    static func frets(_ chord: Int) -> [Int] { list.indices.contains(chord) ? list[chord].frets : open }

    /// Nota MIDI de una cuerda con el acorde dado, o nil si esa cuerda no se toca.
    static func note(string: Int, chord: Int) -> Int? {
        let f = frets(chord)[string]
        return f < 0 ? nil : tuning[string] + f
    }
}

/// Biquad RBJ en Float para el hilo de audio.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func lowpass(_ f: Double, q: Double = 0.707, sr: Double) -> Biquad {
        let w = 2 * .pi * f / sr, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        var b = Biquad()
        b.b0 = Float((1 - c) / 2 / a0); b.b1 = Float((1 - c) / a0); b.b2 = b.b0
        b.a1 = Float(-2 * c / a0); b.a2 = Float((1 - alpha) / a0)
        return b
    }

    static func highpass(_ f: Double, q: Double = 0.707, sr: Double) -> Biquad {
        let w = 2 * .pi * f / sr, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        var b = Biquad()
        b.b0 = Float((1 + c) / 2 / a0); b.b1 = Float(-(1 + c) / a0); b.b2 = b.b0
        b.a1 = Float(-2 * c / a0); b.a2 = Float((1 - alpha) / a0)
        return b
    }

    static func peak(_ f: Double, q: Double, db: Double, sr: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * .pi * f / sr, alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha / A
        var b = Biquad()
        b.b0 = Float((1 + alpha * A) / a0); b.b1 = Float(-2 * c / a0); b.b2 = Float((1 - alpha * A) / a0)
        b.a1 = Float(-2 * c / a0); b.a2 = Float((1 - alpha / A) / a0)
        return b
    }

    @inline(__always) mutating func run(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Una cuerda Karplus-Strong con afinación fina (paso todo fraccional).
final class KSString {
    static let capacity = 8192
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: KSString.capacity)
    let exc = UnsafeMutablePointer<Float>.allocate(capacity: KSString.capacity)
    var len = 100, idx = 0
    var c: Float = 0, apX: Float = 0, apY: Float = 0
    var loss: Float = 0.996
    var mute: Float = 1
    var energy: Float = 0
    var active = false
    var rng: UInt32

    init(seed: UInt32) {
        rng = seed
        buf.initialize(repeating: 0, count: KSString.capacity)
        exc.initialize(repeating: 0, count: KSString.capacity)
    }

    @inline(__always) func noise() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng) / Float(UInt32.max) * 2 - 1
    }

    func pluck(freq: Double, sr: Double, velocity: Float, bright: Float, sustain: Double) {
        let period = sr / freq
        // Retardo del bucle = len - 0.5 (promedio) + frac (paso todo).
        var n = Int(period + 0.5)
        var frac = period + 0.5 - Double(n)
        if frac < 0.15 { n -= 1; frac += 1 }
        let newLen = max(4, min(KSString.capacity - 1, n))

        // Lo que aún sonaba se apaga casi del todo (el dedo/púa la para al volver a tocarla).
        let keep: Float = active ? 0.15 : 0
        // Excitación: ruido filtrado (más claro = más agudo) y peine de posición de púa.
        var y: Float = 0
        let a = 0.12 + 0.85 * bright
        var mean: Float = 0
        for i in 0..<newLen {
            y += a * (noise() - y)
            exc[i] = y
            mean += y
        }
        mean /= Float(newLen)
        let pick = max(1, Int(Float(newLen) * (0.08 + 0.12 * (1 - bright))))
        var peakV: Float = 0.0001
        for i in 0..<newLen {
            let v = (exc[i] - mean) - 0.7 * (exc[(i - pick + newLen) % newLen] - mean)
            exc[i] = v
            peakV = max(peakV, abs(v))
        }
        let g = velocity / peakV * 0.6
        for i in 0..<newLen {
            exc[i] = exc[i] * g + (keep > 0 ? buf[(idx + i) % len] * keep : 0)
        }
        for i in 0..<newLen { buf[i] = exc[i] }
        len = newLen
        idx = 0
        c = Float((1 - frac) / (1 + frac))
        apX = 0; apY = 0
        loss = Float(pow(10, -3 * period / (sr * sustain)))
        mute = 1
        energy = velocity
        active = true
    }

    func damp(_ amount: Float) { if active { mute = amount } }

    @inline(__always) func tick() -> Float {
        let next = idx + 1 == len ? 0 : idx + 1
        let y = buf[idx]
        let avg = 0.5 * (y + buf[next]) * loss * mute
        let ap = c * avg + apX - c * apY
        apX = avg; apY = ap
        buf[idx] = ap
        idx = next
        energy = energy * 0.9995 + abs(y) * 0.0005
        return y
    }
}

/// Guitarra de seis cuerdas sintetizada en el hilo de audio.
final class GuitarSynth {
    enum Tone: Int { case acoustic = 0, electric = 1, distortion = 2 }

    private let sr: Double
    private let strings: [KSString]
    private var tone = Tone.acoustic
    private var body1: Biquad, body2: Biquad, top: Biquad, hp: Biquad, cab: Biquad, mid: Biquad

    init(sr: Double) {
        self.sr = sr
        strings = (0..<6).map { KSString(seed: UInt32(0x9E3779B9 &+ $0 &* 7919)) }
        body1 = .peak(105, q: 1.4, db: 7, sr: sr)
        body2 = .peak(230, q: 1.6, db: 4, sr: sr)
        top = .lowpass(8500, sr: sr)
        hp = .highpass(70, sr: sr)
        cab = .lowpass(3400, q: 0.9, sr: sr)
        mid = .peak(750, q: 0.8, db: -4, sr: sr)
    }

    func setTone(_ t: Tone) {
        tone = t
        switch t {
        case .acoustic: top = .lowpass(8500, sr: sr)
        case .electric: top = .lowpass(4800, q: 1.1, sr: sr)
        case .distortion: top = .lowpass(5200, sr: sr)
        }
    }

    private var sustain: Double {
        switch tone {
        case .acoustic: return 3.2
        case .electric: return 5.5
        case .distortion: return 7
        }
    }

    func pluck(string: Int, midi: Int, velocity: Float, bright: Float) {
        guard strings.indices.contains(string) else { return }
        let b = tone == .acoustic ? bright : min(1, bright * 0.7 + 0.3)
        strings[string].pluck(freq: DSP.midiToHz(midi), sr: sr, velocity: velocity, bright: b, sustain: sustain)
    }

    /// Apaga cuerdas (cambio de acorde o palma). `amount` es la pérdida extra por periodo.
    func damp(string: Int, amount: Float = 0.94) {
        guard strings.indices.contains(string) else { return }
        strings[string].damp(amount)
    }

    var isActive: Bool { strings.contains { $0.active } }

    /// Suma la guitarra en `out` (no lo borra).
    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        guard isActive else { return }
        for s in strings where s.active && s.energy < 0.00002 { s.active = false }
        for i in 0..<n {
            var x: Float = 0
            for s in strings where s.active { x += s.tick() }
            var y: Float
            switch tone {
            case .acoustic:
                y = top.run(body2.run(body1.run(hp.run(x))))
                y *= 0.42
            case .electric:
                y = top.run(hp.run(x))
                y = tanhf(y * 1.6) * 0.42
            case .distortion:
                let pre = hp.run(x) * 9
                y = tanhf(pre) + 0.3 * tanhf(pre * 3)
                y = mid.run(cab.run(y)) * 0.26
            }
            out[i] += y
        }
    }
}

/// Bajo de cuatro cuerdas (Mi La Re Sol), también con Karplus-Strong.
final class BassSynth {
    enum Tone: Int { case finger = 0, pick = 1, sub = 2 }
    static let tuning = [28, 33, 38, 43] // 0 = Mi grave (arriba, como la guitarra)
    static let frets = 12

    private let sr: Double
    private let strings: [KSString]
    private var tone = Tone.finger
    private var lp: Biquad, hp: Biquad, mid: Biquad

    init(sr: Double) {
        self.sr = sr
        strings = (0..<4).map { KSString(seed: UInt32(0x51ED27 &+ $0 &* 104_729)) }
        lp = .lowpass(1100, sr: sr)
        hp = .highpass(32, sr: sr)
        mid = .peak(900, q: 0.9, db: 0, sr: sr)
        setTone(.finger)
    }

    func setTone(_ t: Tone) {
        tone = t
        switch t {
        case .finger: lp = .lowpass(1100, q: 0.8, sr: sr); mid = .peak(700, q: 0.9, db: 1, sr: sr)
        case .pick: lp = .lowpass(3400, q: 0.9, sr: sr); mid = .peak(1100, q: 0.9, db: 4, sr: sr)
        case .sub: lp = .lowpass(280, q: 0.7, sr: sr); mid = .peak(90, q: 0.8, db: 3, sr: sr)
        }
    }

    static func note(string: Int, fret: Int) -> Int { tuning[min(3, max(0, string))] + min(frets, max(0, fret)) }

    func pluck(string: Int, midi: Int, velocity: Float) {
        guard strings.indices.contains(string) else { return }
        let bright: Float
        let sustain: Double
        switch tone {
        case .finger: bright = 0.1 + 0.25 * velocity; sustain = 4.5
        case .pick: bright = 0.5 + 0.3 * velocity; sustain = 4
        case .sub: bright = 0.04; sustain = 3
        }
        strings[string].pluck(freq: DSP.midiToHz(midi), sr: sr, velocity: velocity, bright: bright, sustain: sustain)
    }

    func damp(string: Int) {
        guard strings.indices.contains(string) else { return }
        strings[string].damp(0.9)
    }

    var isActive: Bool { strings.contains { $0.active } }

    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        guard isActive else { return }
        for s in strings where s.active && s.energy < 0.00002 { s.active = false }
        let gain: Float = tone == .sub ? 1.4 : 0.9
        for i in 0..<n {
            var x: Float = 0
            for s in strings where s.active { x += s.tick() }
            let y = mid.run(lp.run(hp.run(x))) * gain
            out[i] += tanhf(y * 1.6) * 0.8
        }
    }
}
