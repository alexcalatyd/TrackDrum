import Foundation

/// Huecos de sonido de un kit. 0...7 son los pads del trackpad (4×2, fila de arriba primero).
enum Slot {
    static let hat = 0, tomHi = 1, tomLo = 2, cymbal = 3
    static let kick = 4, snare = 5, clap = 6, cowbell = 7
    static let openHat = 8, pedal = 9
    static let count = 10
    static let padNames = ["Charles", "Tom alto", "Tom bajo", "Platillo", "Bombo", "Caja", "Clap", "Cencerro"]
}

enum Wave { case sine, square, triangle }

struct Kit {
    let name: String
    let sounds: [Sample] // Slot.count sonidos
}

/// Generadores parametrizados: cada kit los llama con valores distintos.
enum Drum {
    static func osc(_ wave: Wave, _ phase: Double) -> Double {
        switch wave {
        case .sine: return sin(phase)
        case .square: return DSP.square(phase)
        case .triangle: return DSP.triangle(phase)
        }
    }

    static func kick(f0: Double, f1: Double, sweep: Double, decay: Double, click: Double,
                     drive: Double, dur: Double, wave: Wave = .sine) -> [Double] {
        var lp = OnePole(cutoff: 3000)
        let v = DSP.render(dur) { t in
            let body = osc(wave, DSP.sweepPhase(t, from: f0, to: f1, rate: sweep)) * exp(-decay * t)
            let c = lp.lowpass(DSP.noise()) * exp(-t * 250) * click * 3
            return body + c
        }
        return DSP.drive(v, drive)
    }

    static func snare(tone: Double, toneMix: Double, toneDecay: Double, noiseDecay: Double,
                      center: Double, dur: Double, drive: Double = 1, wave: Wave = .sine) -> [Double] {
        var bp = BandPass(center: center, q: 0.7)
        var hp = OnePole(cutoff: 600)
        let v = DSP.render(dur) { t in
            let body = (osc(wave, 2 * .pi * tone * t) + 0.5 * osc(wave, 2 * .pi * tone * 1.47 * t))
                * exp(-toneDecay * t) * toneMix
            let n = hp.highpass(bp.run(DSP.noise()) * 2.5) * exp(-noiseDecay * t) * (1 - toneMix)
            return body + n
        }
        return DSP.drive(v, drive)
    }

    static func hat(decay: Double, cutoff: Double, metal: Double, dur: Double, scale: Double = 1.7) -> [Double] {
        var hp1 = OnePole(cutoff: cutoff)
        var hp2 = OnePole(cutoff: cutoff)
        return DSP.render(dur) { t in
            let x = DSP.metallic(t, scale: scale) * metal + DSP.noise() * (1 - metal)
            let attack = min(1, t / 0.0008)
            return hp2.highpass(hp1.highpass(x)) * exp(-decay * t) * attack
        }
    }

    static func tom(f0: Double, f1: Double, decay: Double, noise: Double, dur: Double, wave: Wave = .sine) -> [Double] {
        var lp = OnePole(cutoff: 2500)
        return DSP.render(dur) { t in
            let body = osc(wave, DSP.sweepPhase(t, from: f0, to: f1, rate: 14)) * exp(-decay * t)
            let n = lp.lowpass(DSP.noise()) * exp(-t * 40) * noise
            return body + n
        }
    }

    static func cymbal(decay: Double, cutoff: Double, metal: Double, dur: Double) -> [Double] {
        var hp1 = OnePole(cutoff: cutoff)
        var hp2 = OnePole(cutoff: cutoff * 0.8)
        var bp = BandPass(center: 9000, q: 0.5)
        return DSP.render(dur) { t in
            let x = DSP.metallic(t, scale: 2.4) * metal + DSP.noise() * (1 - metal)
            let shaped = hp2.highpass(hp1.highpass(x)) + bp.run(x) * 0.3
            let env = exp(-decay * t) * min(1, t / 0.002)
            return shaped * env
        }
    }

    static func clap(center: Double, tail: Double, bursts: Int, dur: Double) -> [Double] {
        var bp = BandPass(center: center, q: 1.2)
        let spacing = 0.0105
        return DSP.render(dur) { t in
            var env = 0.0
            for b in 0..<bursts {
                let tb = Double(b) * spacing
                if t >= tb { env = max(env, exp(-(t - tb) * 190)) }
            }
            let tailStart = Double(bursts - 1) * spacing
            if t >= tailStart { env = max(env, 0.75 * exp(-(t - tailStart) * tail)) }
            return bp.run(DSP.noise()) * env
        }
    }

    static func cowbell(f1: Double, f2: Double, decay: Double, dur: Double) -> [Double] {
        var bp = BandPass(center: 2600, q: 0.9)
        return DSP.render(dur) { t in
            let x = DSP.square(2 * .pi * f1 * t) + DSP.square(2 * .pi * f2 * t)
            let env = 0.7 * exp(-t * 60) + 0.3 * exp(-t * decay)
            return (bp.run(x) * 2 + x * 0.15) * env
        }
    }

    static func click(_ freq: Double) -> Sample {
        DSP.finish(DSP.render(0.04) { t in sin(2 * .pi * freq * t) * exp(-t * 90) }, peak: 0.5)
    }
}

enum Kits {
    static let names = ["808", "Acústico", "Electro", "8-bit"]

    static func make(_ index: Int) -> Kit {
        switch index {
        case 1: return acoustic()
        case 2: return electro()
        case 3: return chip()
        default: return tr808()
        }
    }

    private static func kit(_ name: String, _ raw: [[Double]], crush: Bool = false) -> Kit {
        let peaks: [Double] = [0.6, 0.85, 0.85, 0.55, 0.95, 0.85, 0.8, 0.6, 0.55, 0.45]
        let sounds = raw.enumerated().map { i, v -> Sample in
            let processed = crush ? DSP.crush(v, bits: 4, hold: 4) : v
            return DSP.finish(processed, peak: peaks[i])
        }
        return Kit(name: name, sounds: sounds)
    }

    static func tr808() -> Kit {
        kit("808", [
            Drum.hat(decay: 45, cutoff: 7000, metal: 0.75, dur: 0.12),
            Drum.tom(f0: 260, f1: 200, decay: 8, noise: 0.15, dur: 0.6),
            Drum.tom(f0: 170, f1: 125, decay: 6.5, noise: 0.15, dur: 0.75),
            Drum.cymbal(decay: 2.2, cutoff: 6000, metal: 0.7, dur: 1.8),
            Drum.kick(f0: 160, f1: 48, sweep: 28, decay: 4.2, click: 0.12, drive: 1.2, dur: 0.9),
            Drum.snare(tone: 190, toneMix: 0.45, toneDecay: 18, noiseDecay: 14, center: 5000, dur: 0.3),
            Drum.clap(center: 1100, tail: 9, bursts: 3, dur: 0.4),
            Drum.cowbell(f1: 540, f2: 800, decay: 9, dur: 0.45),
            Drum.hat(decay: 6, cutoff: 7000, metal: 0.75, dur: 0.6),
            Drum.hat(decay: 90, cutoff: 5000, metal: 0.6, dur: 0.05),
        ])
    }

    static func acoustic() -> Kit {
        kit("Acústico", [
            Drum.hat(decay: 55, cutoff: 6000, metal: 0.35, dur: 0.12, scale: 2.2),
            Drum.tom(f0: 230, f1: 165, decay: 7, noise: 0.35, dur: 0.6),
            Drum.tom(f0: 145, f1: 100, decay: 5.5, noise: 0.35, dur: 0.8),
            Drum.cymbal(decay: 1.3, cutoff: 4000, metal: 0.35, dur: 2.5),
            Drum.kick(f0: 120, f1: 55, sweep: 40, decay: 9, click: 0.6, drive: 1.8, dur: 0.45),
            Drum.snare(tone: 210, toneMix: 0.3, toneDecay: 25, noiseDecay: 10, center: 3500, dur: 0.4, drive: 1.5),
            Drum.clap(center: 1500, tail: 7, bursts: 4, dur: 0.45),
            Drum.cowbell(f1: 700, f2: 1050, decay: 14, dur: 0.35),
            Drum.hat(decay: 5, cutoff: 6000, metal: 0.35, dur: 0.7, scale: 2.2),
            Drum.hat(decay: 80, cutoff: 4000, metal: 0.3, dur: 0.06, scale: 2.2),
        ])
    }

    static func electro() -> Kit {
        kit("Electro", [
            Drum.hat(decay: 70, cutoff: 9000, metal: 0.9, dur: 0.09, scale: 2),
            Drum.tom(f0: 420, f1: 220, decay: 10, noise: 0.05, dur: 0.45, wave: .triangle),
            Drum.tom(f0: 300, f1: 140, decay: 8, noise: 0.05, dur: 0.55, wave: .triangle),
            Drum.cymbal(decay: 3, cutoff: 8000, metal: 0.85, dur: 1.4),
            Drum.kick(f0: 230, f1: 45, sweep: 55, decay: 6, click: 0.3, drive: 3, dur: 0.6),
            Drum.snare(tone: 240, toneMix: 0.5, toneDecay: 30, noiseDecay: 20, center: 6500, dur: 0.25, drive: 2),
            Drum.clap(center: 1800, tail: 14, bursts: 4, dur: 0.3),
            Drum.cowbell(f1: 600, f2: 900, decay: 14, dur: 0.35),
            Drum.hat(decay: 9, cutoff: 9000, metal: 0.9, dur: 0.45, scale: 2),
            Drum.hat(decay: 110, cutoff: 6000, metal: 0.8, dur: 0.04, scale: 2),
        ])
    }

    static func chip() -> Kit {
        kit("8-bit", [
            Drum.hat(decay: 50, cutoff: 5000, metal: 0, dur: 0.08),
            Drum.tom(f0: 330, f1: 220, decay: 9, noise: 0, dur: 0.35, wave: .square),
            Drum.tom(f0: 220, f1: 140, decay: 7, noise: 0, dur: 0.45, wave: .square),
            Drum.cymbal(decay: 3, cutoff: 3000, metal: 0, dur: 1),
            Drum.kick(f0: 200, f1: 50, sweep: 35, decay: 8, click: 0, drive: 1, dur: 0.35, wave: .square),
            Drum.snare(tone: 180, toneMix: 0.35, toneDecay: 25, noiseDecay: 16, center: 4000, dur: 0.25, wave: .square),
            Drum.clap(center: 2000, tail: 12, bursts: 2, dur: 0.25),
            Drum.cowbell(f1: 660, f2: 990, decay: 12, dur: 0.3),
            Drum.hat(decay: 8, cutoff: 5000, metal: 0, dur: 0.4),
            Drum.hat(decay: 100, cutoff: 3000, metal: 0, dur: 0.04),
        ], crush: true)
    }
}
