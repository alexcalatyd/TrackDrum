import CMultitouch
import QuartzCore

struct Finger {
    let id: Int32
    let x: Float   // 0..1, izquierda → derecha
    let y: Float   // 0..1, abajo → arriba
    let size: Float
}

/// Lee el trackpad en bruto. Detecta golpes nuevos y calcula su fuerza
/// a partir del área de contacto en los primeros fotogramas.
final class TouchInput {
    /// Golpe (dedo, fuerza 0..1). Hilo del trackpad.
    var onHit: ((Finger, Float) -> Void)?
    /// Un dedo acaba de apoyarse (antes de calcular la fuerza).
    var onContact: (() -> Void)?
    /// Dedos actuales, para dibujarlos.
    var onFrame: (([Finger]) -> Void)?

    var useVelocity = true
    /// Respuesta inmediata: suena en el primer fotograma del toque en vez de esperar al segundo
    /// para medir la fuerza (≈ 8–12 ms menos). La fuerza se calcula con lo que hay en ese instante.
    var instant = false
    private(set) var lastSize: Float = 0
    private(set) var lastVelocity: Float = 0

    private struct Pending {
        var finger: Finger
        var frames: Int
        var maxSize: Float
        var fired: Bool
    }

    private var active: [Int32: Pending] = [:]
    private var peakSize: Float = 0.8 // se autocalibra con tus golpes más fuertes
    static var shared: TouchInput?

    func start() -> Bool {
        TouchInput.shared = self
        let callback: MTFrameCallback = { touches, count, _ in
            TouchInput.shared?.handle(touches, Int(count))
        }
        return mt_start(callback) > 0
    }

    func stop() { mt_stop() }

    private func handle(_ touches: UnsafePointer<MTTouch>?, _ count: Int) {
        var fingers: [Finger] = []
        var seen = Set<Int32>()

        for i in 0..<count {
            guard let t = touches?[i], t.state == 3 || t.state == 4 else { continue }
            let finger = Finger(id: t.identifier, x: t.normalized.position.x, y: t.normalized.position.y, size: t.size)
            fingers.append(finger)
            seen.insert(t.identifier)

            if var p = active[t.identifier] {
                if !p.fired {
                    p.frames += 1
                    p.maxSize = max(p.maxSize, t.size)
                    // Segundo fotograma: ya sabemos cuánto se ha aplastado el dedo.
                    if p.frames >= 2 { fire(&p) }
                }
                active[t.identifier] = p
            } else {
                onContact?()
                var p = Pending(finger: finger, frames: 1, maxSize: t.size, fired: false)
                // En el primer fotograma el dedo aún no está aplastado del todo: lo compensamos.
                if !useVelocity || instant { p.maxSize = t.size * 1.35; fire(&p) }
                active[t.identifier] = p
            }
        }

        // Toques tan cortos que solo duraron un fotograma.
        for (id, var p) in active where !seen.contains(id) {
            if !p.fired { fire(&p) }
        }
        active = active.filter { seen.contains($0.key) }
        onFrame?(fingers)
    }

    private func fire(_ p: inout Pending) {
        p.fired = true
        var velocity: Float = 0.85
        if useVelocity {
            peakSize = max(peakSize * 0.995, p.maxSize, 0.3)
            let r = min(1, p.maxSize / peakSize)
            velocity = max(0.15, min(1, powf(r, 1.1)))
        }
        lastSize = p.maxSize
        lastVelocity = velocity
        onHit?(p.finger, velocity)
    }
}
