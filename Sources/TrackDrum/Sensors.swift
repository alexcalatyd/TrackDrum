import AppKit
import CMultitouch
import QuartzCore

/// Motor háptico del trackpad a bajo nivel (más fuerte y rápido que NSHapticFeedbackManager).
enum Haptics {
    static let strong: Int32 = 6
    static let medium: Int32 = 4
    static let weak: Int32 = 3

    private static let queue = DispatchQueue(label: "trackdrum.haptics", qos: .userInteractive)
    /// Última vibración (para que el acelerómetro no la confunda con un golpe).
    private(set) static var lastTime: Double = 0

    static func pulse(_ strength: Int32, after delay: Double = 0) {
        let fire = {
            lastTime = CACurrentMediaTime()
            if mt_haptic(strength) != 0 {
                DispatchQueue.main.async {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        }
        if delay > 0.001 {
            queue.asyncAfter(deadline: .now() + delay, execute: fire)
        } else {
            queue.async(execute: fire)
        }
    }

    static func forVelocity(_ v: Float) -> Int32 { v > 0.66 ? strong : (v > 0.33 ? medium : weak) }
}

/// La tapa como pedal del charles: echarla hacia atrás lo abre, volver lo cierra.
final class LidPedal {
    private(set) var available = false
    private(set) var angle = 0
    private(set) var baseline = 0
    private(set) var isOpen = false
    var enabled = true
    /// El pedal se ha "pisado" (charles abierto → cerrado).
    var onClose: (() -> Void)?

    private let openDelta = 6
    private let closeDelta = 3
    private var timer: DispatchSourceTimer?

    func start() {
        let a = Int(lid_angle())
        available = a >= 0
        guard available else { return }
        angle = a
        baseline = a
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "trackdrum.lid", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func calibrate() {
        baseline = angle
        isOpen = false
    }

    private func poll() {
        let a = Int(lid_angle())
        guard a >= 0 else { return }
        angle = a
        if !isOpen && a >= baseline + openDelta {
            isOpen = true
        } else if isOpen && a <= baseline + closeDelta {
            isOpen = false
            if enabled { onClose?() }
        }
    }
}

/// Golpes en el chasis (reposamuñecas) con el acelerómetro oculto → bombo.
final class AccelKick {
    private(set) var available = false
    var enabled = true
    var threshold = 0.12 // en g
    /// Fuerza del golpe (0..1). Hilo del sensor.
    var onKick: ((Float) -> Void)?
    /// Momento del último toque en el trackpad o tecla pulsada (eso también mueve el chasis).
    var lastOtherInput: Double = 0
    /// Momento en que empezó a sonar lo último (la vibración de los altavoces).
    var lastSoundTime: () -> Double = { 0 }
    /// Nivel reciente para mostrarlo en pantalla.
    private(set) var level = 0.0

    private var avg = (0.0, 0.0, 0.0)
    private var pending: (time: Double, peak: Double)?
    private var refractoryUntil = 0.0
    static var shared: AccelKick?

    func start() {
        AccelKick.shared = self
        available = accel_start { x, y, z in AccelKick.shared?.process(x, y, z) } == 1
    }

    private func process(_ x: Double, _ y: Double, _ z: Double) {
        let now = CACurrentMediaTime()
        // Paso alto: quitamos la gravedad y la inclinación.
        avg.0 += 0.02 * (x - avg.0)
        avg.1 += 0.02 * (y - avg.1)
        avg.2 += 0.02 * (z - avg.2)
        let hx = x - avg.0, hy = y - avg.1, hz = z - avg.2
        let m = (hx * hx + hy * hy + hz * hz).squareRoot()
        level = max(level * 0.997, m)

        if let p = pending {
            pending!.peak = max(p.peak, m)
            // Esperamos 20 ms por si era un toque del trackpad que aún no ha llegado.
            if now >= p.time + 0.02 {
                let done = pending!
                pending = nil
                decide(done)
            }
            return
        }
        guard enabled, now > refractoryUntil, m > threshold else { return }
        pending = (now, m)
    }

    private func decide(_ p: (time: Double, peak: Double)) {
        refractoryUntil = p.time + 0.12
        // Era un toque del trackpad o una tecla.
        if abs(lastOtherInput - p.time) < 0.09 { return }
        // Nuestra propia vibración o sonido: solo cuenta si es un golpe claro.
        let sinceSound = p.time - lastSoundTime()
        let sinceHaptic = p.time - Haptics.lastTime
        let selfNoise = (sinceSound > -0.01 && sinceSound < 0.08) || (sinceHaptic > -0.005 && sinceHaptic < 0.06)
        if selfNoise && p.peak < threshold * 2.5 { return }
        let velocity = Float(max(0.3, min(1, p.peak / (threshold * 4))))
        onKick?(velocity)
    }
}
