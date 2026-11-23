import Foundation

/// Instrumentos melódicos para los loops (todo sintetizado).
enum Instrument {
    static func bass(_ midi: Int) -> Sample {
        let f = DSP.midiToHz(midi)
        var lp = OnePole(cutoff: 800)
        let v = DSP.render(0.45) { t in
            var saw = 0.0
            for k in 1...8 { saw += sin(2 * .pi * f * Double(k) * t) / Double(k) }
            lp.a = OnePole.coef(250 + 1600 * exp(-t * 14))
            let tone = lp.lowpass(saw) + 0.6 * sin(2 * .pi * f * t)
            return tone * min(1, t / 0.003) * exp(-t * 3.5)
        }
        return DSP.finish(v, peak: 0.8)
    }

    static func stab(_ chord: [Int]) -> Sample {
        var lp = OnePole(cutoff: 2000)
        let v = DSP.render(0.5) { t in
            var x = 0.0
            for m in chord {
                let f = DSP.midiToHz(m)
                x += DSP.saw(2 * .pi * f * 1.003 * t) + DSP.saw(2 * .pi * f * 0.997 * t)
            }
            lp.a = OnePole.coef(500 + 3000 * exp(-t * 7))
            return lp.lowpass(x) * min(1, t / 0.004) * exp(-t * 6)
        }
        return DSP.finish(v, peak: 0.7)
    }

    /// Cuerda pulsada (Karplus-Strong).
    static func pluck(_ midi: Int) -> Sample {
        let period = max(2, Int(DSP.sr / DSP.midiToHz(midi)))
        var ring = (0..<period).map { _ in DSP.noise() }
        var idx = 0
        let n = Int(0.6 * DSP.sr)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let next = (idx + 1) % period
            let v = 0.5 * (ring[idx] + ring[next]) * 0.996
            out[i] = ring[idx]
            ring[idx] = v
            idx = next
        }
        return DSP.finish(out, peak: 0.6)
    }

    static func pad(_ chord: [Int]) -> Sample {
        var lp = OnePole(cutoff: 1400)
        let v = DSP.render(2.8) { t in
            var x = 0.0
            for m in chord {
                let f = DSP.midiToHz(m)
                x += DSP.saw(2 * .pi * f * 1.004 * t) + DSP.saw(2 * .pi * f * 0.996 * t)
            }
            let attack = min(1, t / 0.5)
            let release = t > 2.0 ? max(0, 1 - (t - 2.0) / 0.8) : 1
            return lp.lowpass(x) * attack * release
        }
        return DSP.finish(v, peak: 0.6)
    }
}

/// Qué suena en un paso: un pad del kit actual o un sonido fijo.
enum LoopSound {
    case slot(Int)
    case sample(Sample)
}

struct LoopNote {
    let sound: LoopSound
    let gain: Float
}

/// Un loop es una secuencia de semicorcheas (16 pasos = 1 compás).
struct LoopDef {
    let name: String
    let steps: Int
    let byStep: [[LoopNote]]
}

enum Loops {
    // Progresión en La menor: Am – F – C – G (un compás cada uno).
    static let roots = [33, 29, 36, 31]
    static let chords = [[57, 60, 64], [53, 57, 60], [55, 60, 64], [55, 59, 62]]

    static func make() -> [LoopDef] {
        [
            drums("Beat", [
                (Slot.kick, "x.......x.x.....", 1.0),
                (Slot.snare, "....x.......x...", 0.9),
                (Slot.hat, "x.x.x.x.x.x.x.x.", 0.6),
            ]),
            drums("Break", [
                (Slot.kick, "x.x.......xx....", 1.0),
                (Slot.snare, "....x..x.x..x...", 0.85),
                (Slot.hat, "xxxxxxxxxxxxxxxx", 0.35),
            ]),
            drums("Charles", [
                (Slot.hat, "xxxxxxx.xxxxxxx.", 0.5),
                (Slot.openHat, ".......x.......x", 0.5),
            ]),
            drums("Percu", [
                (Slot.clap, "....x.......x...", 0.8),
                (Slot.cowbell, "x..x..x...x..x..", 0.45),
                (Slot.tomHi, "..........x.x...", 0.6),
                (Slot.tomLo, "...........x.x.x", 0.6),
            ]),
            bassLoop(),
            harmonic("Acordes", stepsInBar: [2, 6, 10, 14], gain: 0.4) { bar, _ in
                [Instrument.stab(chords[bar])]
            },
            arpLoop(),
            harmonic("Pad", stepsInBar: [0], gain: 0.4) { bar, _ in
                [Instrument.pad(chords[bar])]
            },
        ]
    }

    private static func drums(_ name: String, _ lanes: [(Int, String, Float)]) -> LoopDef {
        var byStep = [[LoopNote]](repeating: [], count: 16)
        for (slot, pattern, gain) in lanes {
            for (i, ch) in pattern.enumerated() where ch == "x" {
                byStep[i].append(LoopNote(sound: .slot(slot), gain: gain))
            }
        }
        return LoopDef(name: name, steps: 16, byStep: byStep)
    }

    /// 4 compases siguiendo la progresión.
    private static func harmonic(_ name: String, stepsInBar: [Int], gain: Float,
                                 _ make: (Int, Int) -> [Sample]) -> LoopDef {
        var byStep = [[LoopNote]](repeating: [], count: 64)
        for bar in 0..<4 {
            let samples = make(bar, 0) // mismo sonido para todo el compás
            for s in stepsInBar {
                for sample in samples {
                    byStep[bar * 16 + s].append(LoopNote(sound: .sample(sample), gain: gain))
                }
            }
        }
        return LoopDef(name: name, steps: 64, byStep: byStep)
    }

    private static func bassLoop() -> LoopDef {
        var byStep = [[LoopNote]](repeating: [], count: 64)
        let shape: [(Int, Int)] = [(0, 0), (3, 0), (6, 12), (8, 0), (11, 7), (14, 12)]
        var cache: [Int: Sample] = [:]
        for bar in 0..<4 {
            for (step, interval) in shape {
                let note = roots[bar] + interval
                let sample = cache[note] ?? Instrument.bass(note)
                cache[note] = sample
                byStep[bar * 16 + step].append(LoopNote(sound: .sample(sample), gain: 0.7))
            }
        }
        return LoopDef(name: "Bajo", steps: 64, byStep: byStep)
    }

    private static func arpLoop() -> LoopDef {
        var byStep = [[LoopNote]](repeating: [], count: 64)
        let order = [0, 1, 2, 1]
        var cache: [Int: Sample] = [:]
        for bar in 0..<4 {
            let chord = chords[bar].map { $0 + 12 }
            for step in 0..<16 {
                let octave = step >= 8 ? 12 : 0
                let note = chord[order[step % 4]] + octave
                let sample = cache[note] ?? Instrument.pluck(note)
                cache[note] = sample
                byStep[bar * 16 + step].append(LoopNote(sound: .sample(sample), gain: step % 4 == 0 ? 0.45 : 0.3))
            }
        }
        return LoopDef(name: "Arpegio", steps: 64, byStep: byStep)
    }
}
