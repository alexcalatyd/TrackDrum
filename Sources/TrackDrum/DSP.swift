import Foundation

/// Un sonido listo para reproducir (mono, a la frecuencia del motor).
final class Sample {
    let data: [Float]
    let name: String
    init(_ data: [Float], name: String = "") {
        self.data = data
        self.name = name
    }
}

/// Utilidades de síntesis. `sr` se fija una vez con la frecuencia de salida real.
enum DSP {
    static var sr: Double = 48_000

    static func noise() -> Double { Double.random(in: -1...1) }

    static func square(_ phase: Double) -> Double { sin(phase) >= 0 ? 1 : -1 }

    static func saw(_ phase: Double) -> Double {
        let x = phase / (2 * .pi)
        return 2 * (x - floor(x + 0.5))
    }

    static func triangle(_ phase: Double) -> Double { 2 * abs(saw(phase)) - 1 }

    static func midiToHz(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12) }

    /// Seis cuadradas a ratios inarmónicos (receta clásica de la 808 para platos).
    static func metallic(_ t: Double, scale: Double) -> Double {
        let ratios = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]
        var v = 0.0
        for r in ratios { v += square(2 * .pi * r * scale * t) }
        return v / Double(ratios.count)
    }

    /// Fase integrada de un barrido exponencial f(t) = f1 + (f0 - f1)·e^(-k t).
    static func sweepPhase(_ t: Double, from f0: Double, to f1: Double, rate k: Double) -> Double {
        2 * .pi * (f1 * t + (f0 - f1) / k * (1 - exp(-k * t)))
    }

    static func render(_ duration: Double, _ f: (Double) -> Double) -> [Double] {
        let n = Int(duration * sr)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n { out[i] = f(Double(i) / sr) }
        return out
    }

    /// Normaliza, suaviza el final y lo convierte en Sample.
    static func finish(_ v: [Double], peak: Double = 0.9, name: String = "") -> Sample {
        var maxV = 0.0
        for x in v { maxV = max(maxV, abs(x)) }
        let gain = maxV > 0 ? peak / maxV : 1
        let fade = min(256, v.count)
        var out = [Float](repeating: 0, count: v.count)
        for i in 0..<v.count {
            var x = v[i] * gain
            let remaining = v.count - i
            if remaining < fade { x *= Double(remaining) / Double(fade) }
            out[i] = Float(x)
        }
        return Sample(out, name: name)
    }

    /// Reduce bits y frecuencia (sonido 8-bit).
    static func crush(_ v: [Double], bits: Int, hold: Int) -> [Double] {
        let levels = pow(2, Double(bits - 1))
        var out = v
        var held = 0.0
        for i in 0..<v.count {
            if i % hold == 0 { held = (v[i] * levels).rounded() / levels }
            out[i] = held
        }
        return out
    }

    static func drive(_ v: [Double], _ amount: Double) -> [Double] {
        guard amount > 1 else { return v }
        let norm = tanh(amount)
        return v.map { tanh($0 * amount) / norm }
    }
}

/// Filtro de un polo (paso bajo / paso alto).
struct OnePole {
    private var y = 0.0
    var a: Double

    init(cutoff: Double) { a = OnePole.coef(cutoff) }

    static func coef(_ cutoff: Double) -> Double { 1 - exp(-2 * .pi * cutoff / DSP.sr) }

    mutating func lowpass(_ x: Double) -> Double {
        y += a * (x - y)
        return y
    }

    mutating func highpass(_ x: Double) -> Double { x - lowpass(x) }
}

/// Biquad RBJ en modo paso banda.
struct BandPass {
    private var b0 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(center: Double, q: Double) {
        let w = 2 * .pi * center / DSP.sr
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b2 = -alpha / a0
        a1 = -2 * cos(w) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
