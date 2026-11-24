import Foundation

/// Tonalidad compartida por el bajo, el teclado y el sampler.
enum Scales {
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let list: [(name: String, steps: [Int])] = [
        ("Mayor", [0, 2, 4, 5, 7, 9, 11]),
        ("Menor", [0, 2, 3, 5, 7, 8, 10]),
        ("Pentatónica", [0, 2, 4, 7, 9]),
        ("Pentatónica menor", [0, 3, 5, 7, 10]),
        ("Blues", [0, 3, 5, 6, 7, 10]),
        ("Dórica", [0, 2, 3, 5, 7, 9, 10]),
        ("Cromática", Array(0..<12)),
    ]

    static func steps(_ scale: Int) -> [Int] { list.indices.contains(scale) ? list[scale].steps : list[0].steps }

    /// Nota MIDI del grado `degree` (0 = tónica; puede pasar de octava).
    static func midi(degree: Int, root: Int, scale: Int, base: Int) -> Int {
        let st = steps(scale), n = st.count
        let oct = Int((Double(degree) / Double(n)).rounded(.down))
        let d = ((degree % n) + n) % n
        return base + root + oct * 12 + st[d]
    }

    static func name(_ midi: Int) -> String { noteNames[((midi % 12) + 12) % 12] }
}

/// Un dedo sobre el teclado: nota (en semitonos, admite decimales), brillo y vibrato.
struct SynthTouch {
    var id: Int32
    var pitch: Double
    var cutoff: Float   // 0..1
    var vib: Float      // 0..1
    var velocity: Float
}

/// Sinte polifónico: dos dientes de sierra desafinados + sub, filtro paso bajo resonante y envolventes.
final class PolySynth {
    struct Patch {
        let name: String
        let attack, decay, sustain, release: Double
        let fenv, fdecay: Double
        let reso: Float
        let glide: Double
        let detune: Double  // semitonos
        let saw2: Float
        let sub: Float
    }

    static let patches: [Patch] = [
        Patch(name: "Pad", attack: 0.35, decay: 1.2, sustain: 0.8, release: 1.4, fenv: 0.15, fdecay: 0.9,
              reso: 0.15, glide: 0.03, detune: 0.12, saw2: 1, sub: 0.2),
        Patch(name: "Lead", attack: 0.004, decay: 0.3, sustain: 0.85, release: 0.18, fenv: 0.35, fdecay: 0.25,
              reso: 0.42, glide: 0.06, detune: 0.06, saw2: 0.6, sub: 0.35),
        Patch(name: "Pluck", attack: 0.002, decay: 0.5, sustain: 0, release: 0.35, fenv: 0.9, fdecay: 0.18,
              reso: 0.3, glide: 0.01, detune: 0.08, saw2: 0.7, sub: 0.25),
    ]

    private struct Voice {
        var id: Int32 = 0
        var active = false
        var gate = false
        var pitch = 60.0, target = 60.0
        var cut: Float = 0.5, cutTarget: Float = 0.5
        var vib: Float = 0
        var vel: Float = 0.8
        var p1 = 0.0, p2 = 0.0, p3 = 0.0
        var env: Float = 0
        var attacking = false
        var fenv: Float = 0
        var ic1: Float = 0, ic2: Float = 0
        var age = 0
    }

    private let sr: Double
    private var voices = [Voice](repeating: Voice(), count: 12)
    private var patch = PolySynth.patches[0]
    private var vibPhase = 0.0
    private var clock = 0

    init(sr: Double) { self.sr = sr }

    func setPatch(_ i: Int) { if Self.patches.indices.contains(i) { patch = Self.patches[i] } }

    /// Estado de los dedos: los nuevos empiezan nota, los que ya no están la sueltan.
    func update(_ touches: [SynthTouch]) {
        for i in voices.indices where voices[i].gate && !touches.contains(where: { $0.id == voices[i].id }) {
            voices[i].gate = false
            voices[i].attacking = false
        }
        for t in touches {
            if let i = voices.firstIndex(where: { $0.gate && $0.id == t.id }) {
                voices[i].target = t.pitch
                voices[i].cutTarget = t.cutoff
                voices[i].vib = t.vib
                continue
            }
            // Voz libre o, si no hay, la que lleva más tiempo sonando.
            var idx = voices.firstIndex { !$0.active }
            if idx == nil { idx = voices.indices.filter { !voices[$0].gate }.min { voices[$0].age < voices[$1].age } }
            if idx == nil { idx = voices.indices.min { voices[$0].age < voices[$1].age } }
            guard let i = idx else { continue }
            clock += 1
            var v = voices[i]
            v.id = t.id; v.gate = true; v.active = true; v.attacking = true
            v.pitch = t.pitch; v.target = t.pitch
            v.cut = t.cutoff; v.cutTarget = t.cutoff
            v.vib = t.vib; v.vel = t.velocity
            v.fenv = 1
            v.age = clock
            if !voices[i].active { v.env = 0; v.ic1 = 0; v.ic2 = 0 }
            voices[i] = v
        }
    }

    func allOff() { for i in voices.indices { voices[i].gate = false; voices[i].attacking = false } }

    var isActive: Bool { voices.contains { $0.active } }

    @inline(__always) private static func blepSaw(_ ph: Double, _ dt: Double) -> Float {
        var v = 2 * ph - 1
        if ph < dt {
            let t = ph / dt
            v -= t + t - t * t - 1
        } else if ph > 1 - dt {
            let t = (ph - 1) / dt
            v -= t * t + t + t + 1
        }
        return Float(v)
    }

    /// Suma el sinte en `out`.
    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        guard isActive else { return }
        let p = patch
        let aC = Float(1 - exp(-1 / (max(0.001, p.attack) * sr)))
        // Decay y release: tiempo hasta caer ~60 dB.
        let dC = Float(1 - exp(-4.6 / (p.decay * sr)))
        let rC = Float(1 - exp(-6.9 / (p.release * sr)))
        let fC = Float(exp(-1 / (p.fdecay * sr)))
        let chunk = 16
        let gC = 1 - exp(-Double(chunk) / (max(0.001, p.glide) * sr))
        let k = 2 - 1.96 * p.reso
        let vibInc = 5.5 / sr * Double(chunk)

        var start = 0
        while start < n {
            let end = min(n, start + chunk)
            vibPhase += vibInc
            if vibPhase > 1 { vibPhase -= 1 }
            let vibS = sin(2 * .pi * vibPhase)
            for vi in voices.indices where voices[vi].active {
                var v = voices[vi]
                v.pitch += (v.target - v.pitch) * gC
                v.cut += (v.cutTarget - v.cut) * 0.2
                let pitch = v.pitch + Double(v.vib) * 0.45 * vibS
                let f = 440 * pow(2, (pitch - 69) / 12)
                let dt1 = f * pow(2, p.detune / 12) / sr, dt2 = f * pow(2, -p.detune / 12) / sr, dt3 = f * 0.5 / sr
                // Corte del filtro: de 120 Hz a ~9,6 kHz según la altura del dedo, más la envolvente.
                let fc = min(0.45 * sr, 120 * pow(80, Double(v.cut)) * (1 + Double(v.fenv) * p.fenv * 6))
                let g = Float(tan(.pi * fc / sr))
                let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
                for i in start..<end {
                    // Envolvente de amplitud.
                    if v.gate {
                        if v.attacking {
                            v.env += aC * (1.15 - v.env)
                            if v.env >= 1 { v.env = 1; v.attacking = false }
                        } else {
                            v.env += dC * (Float(p.sustain) - v.env)
                        }
                    } else {
                        v.env -= rC * v.env
                        if v.env < 0.0004 { v.active = false; break }
                    }
                    v.fenv *= fC
                    let x = Self.blepSaw(v.p1, dt1) + p.saw2 * Self.blepSaw(v.p2, dt2) + p.sub * Float(sin(2 * .pi * v.p3))
                    v.p1 += dt1; if v.p1 >= 1 { v.p1 -= 1 }
                    v.p2 += dt2; if v.p2 >= 1 { v.p2 -= 1 }
                    v.p3 += dt3; if v.p3 >= 1 { v.p3 -= 1 }
                    // Filtro de estado variable (TPT).
                    let v3 = x - v.ic2
                    let v1 = a1 * v.ic1 + a2 * v3
                    let v2 = v.ic2 + a2 * v.ic1 + a3 * v3
                    v.ic1 = 2 * v1 - v.ic1
                    v.ic2 = 2 * v2 - v.ic2
                    out[i] += v2 * v.env * v.vel * 0.16
                }
                voices[vi] = v
            }
            start = end
        }
    }
}

/// Sonido de partida del sampler: un piano eléctrico FM en Do central (MIDI 60).
enum DefaultSamples {
    static func electricPiano() -> Sample {
        let f = DSP.midiToHz(60)
        let v = DSP.render(2.4) { t in
            let index = 2.2 * exp(-t * 5) + 0.25
            let mod = sin(2 * .pi * f * t) * index
            let tine = sin(2 * .pi * f * 7 * t) * exp(-t * 30) * 0.12
            let body = sin(2 * .pi * f * t + mod)
            return (body + tine) * exp(-t * 1.4) * min(1, t / 0.002)
        }
        return DSP.finish(v, peak: 0.8, name: "Piano eléctrico")
    }
}
