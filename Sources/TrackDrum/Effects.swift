import Foundation

/// Ajustes de los efectos generales (se guardan con el proyecto).
struct FXSettings: Codable, Equatable {
    /// Tamaño de la sala de la reverb (0..1).
    var revSize = 0.6
    /// Tiempo del delay en semicorcheas (2 = corchea, 3 = corchea con puntillo, 4 = negra).
    var dlyDiv = 3
    /// Realimentación del delay (0..0.85).
    var dlyFb = 0.35
    var comp = true
    /// Fuerza del compresor (0..1).
    var compAmt = 0.4
}

/// Reverb tipo Freeverb: 8 filtros peine + 4 pasatodo por canal.
final class Reverb {
    private final class Comb {
        let buf: UnsafeMutablePointer<Float>
        let size: Int
        var idx = 0
        var store: Float = 0
        init(_ n: Int) {
            size = max(1, n)
            buf = .allocate(capacity: size)
            buf.initialize(repeating: 0, count: size)
        }
        @inline(__always) func run(_ x: Float, fb: Float, damp: Float) -> Float {
            let y = buf[idx]
            store = y * (1 - damp) + store * damp
            buf[idx] = x + store * fb
            idx += 1
            if idx == size { idx = 0 }
            return y
        }
    }

    private final class AllPass {
        let buf: UnsafeMutablePointer<Float>
        let size: Int
        var idx = 0
        init(_ n: Int) {
            size = max(1, n)
            buf = .allocate(capacity: size)
            buf.initialize(repeating: 0, count: size)
        }
        @inline(__always) func run(_ x: Float) -> Float {
            let b = buf[idx]
            buf[idx] = x + b * 0.5
            idx += 1
            if idx == size { idx = 0 }
            return b - x
        }
    }

    private let combsL: [Comb], combsR: [Comb]
    private let apL: [AllPass], apR: [AllPass]
    private var fb: Float = 0.84
    private let damp: Float = 0.25

    init(sr: Double) {
        let k = sr / 44_100
        let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let aps = [556, 441, 341, 225]
        combsL = combs.map { Comb(Int(Double($0) * k)) }
        combsR = combs.map { Comb(Int(Double($0 + 23) * k)) }
        apL = aps.map { AllPass(Int(Double($0) * k)) }
        apR = aps.map { AllPass(Int(Double($0 + 23) * k)) }
    }

    func setSize(_ s: Double) { fb = Float(0.7 + 0.28 * min(1, max(0, s))) }

    @inline(__always) func process(_ x: Float) -> (Float, Float) {
        let input = x * 0.015
        var l: Float = 0, r: Float = 0
        for c in combsL { l += c.run(input, fb: fb, damp: damp) }
        for c in combsR { r += c.run(input, fb: fb, damp: damp) }
        for a in apL { l = a.run(l) }
        for a in apR { r = a.run(r) }
        return (l, r)
    }
}

/// Delay estéreo de ida y vuelta (izquierda → derecha → izquierda…), oscureciéndose en cada repetición.
final class PingPongDelay {
    private let cap: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var w = 0
    private var lpL: Float = 0, lpR: Float = 0
    var time = 1000
    var feedback: Float = 0.35

    init(sr: Double) {
        cap = Int(sr * 2.5)
        bufL = .allocate(capacity: cap)
        bufR = .allocate(capacity: cap)
        bufL.initialize(repeating: 0, count: cap)
        bufR.initialize(repeating: 0, count: cap)
    }

    @inline(__always) func process(_ x: Float) -> (Float, Float) {
        let t = min(cap - 1, max(1, time))
        var r = w - t
        if r < 0 { r += cap }
        let dl = bufL[r], dr = bufR[r]
        lpL += 0.45 * (dl - lpL)
        lpR += 0.45 * (dr - lpR)
        bufL[w] = x + lpR * feedback
        bufR[w] = lpL * feedback
        w += 1
        if w == cap { w = 0 }
        return (dl, dr)
    }
}

/// Compresor del máster (estéreo enlazado): pega la mezcla y la sube de volumen.
struct Compressor {
    private var env: Float = 0
    private let att: Float, rel: Float

    init(sr: Double) {
        att = Float(1 - exp(-1 / (0.008 * sr)))
        rel = Float(1 - exp(-1 / (0.15 * sr)))
    }

    /// Ganancia a aplicar para un nivel de pico dado.
    @inline(__always) mutating func gain(_ level: Float, amount: Float) -> Float {
        env += (level > env ? att : rel) * (level - env)
        let thr = -4 - 20 * amount       // dB
        let makeup = 0.45 * -thr * amount // dB
        let db = 20 * log10f(max(env, 1e-6))
        let over = db - thr
        let reduction = over > 0 ? over * 0.75 : 0 // ratio 4:1
        return powf(10, (makeup - reduction) / 20)
    }
}
