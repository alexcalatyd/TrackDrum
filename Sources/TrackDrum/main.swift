import AppKit
import QuartzCore
import UniformTypeIdentifiers

enum Mode: String { case drums, loops }

final class AppController: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let ui = WebUI()
    private let engine = AudioEngine()
    private let touch = TouchInput()
    private let lid = LidPedal()
    private let kick = AccelKick()
    private let defaults = UserDefaults.standard

    private var mode = Mode.drums
    private var kitIndex = 0
    private var kits: [Int: Kit] = [:]
    private var custom: [Int: Sample] = [:]
    private var customPaths: [Int: String] = [:]
    private var onboarded = false

    // Estado leído desde otros hilos (escrituras simples en el principal).
    private var appActive = true
    /// Modo tocar: el trackpad es la batería y el ratón queda bloqueado.
    /// Fuera de él (modo ratón) el trackpad funciona normal y no suena nada.
    private var playMode = false

    // Fotograma para la interfaz (solo hilo principal).
    private var pendingFlashes: [[Any]] = []
    private var latestFingers: [[Float]]? = nil
    private var frameTimer: Timer?


    // MARK: - Arranque

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreSettings()
        applySlots()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "TrackDrum"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        window.contentView = ui.view
        window.contentMinSize = NSSize(width: 1080, height: 740)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(ui.view)

        ui.onMessage = { [unowned self] action, body in self.handle(action, body) }
        ui.view.onDragOver = { [unowned self] p in self.ui.dragOver(p) }
        ui.view.onDrop = { [unowned self] url, p in
            self.ui.padAt(p) { pad in if pad >= 0 { self.loadSample(url, into: pad) } }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            self.appActive = true
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            self.appActive = false
            self.setPlayMode(false)
        }

        wireEngine()
        do { try engine.start() } catch { fatalError("No se pudo arrancar el audio: \(error)") }
        wireTouch()
        wireSensors()

        // Esc siempre devuelve el ratón, aunque la interfaz web no tenga el foco.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            if event.keyCode == 53 && self.playMode {
                self.setPlayMode(false)
                return nil
            }
            return event
        }

        frameTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [unowned self] _ in
            self.pushFrame()
        }
    }

    private func wireEngine() {
        engine.onBeat = { _, accent, delay, haptic in
            if haptic { Haptics.pulse(accent ? Haptics.strong : Haptics.weak, after: delay) }
        }
        engine.onSlotPlayed = { [weak self] slot, velocity, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, self.mode == .drums else { return }
                self.pendingFlashes.append([self.pad(forSlot: slot), velocity, 1])
            }
        }
    }

    private func wireTouch() {
        touch.onContact = { [kick] in kick.lastOtherInput = CACurrentMediaTime() }
        touch.onHit = { [weak self] finger, velocity in
            guard let self, self.appActive, self.playMode else { return }
            let col = min(3, max(0, Int(finger.x * 4)))
            let index = (finger.y >= 0.5 ? 0 : 4) + col

            switch self.mode {
            case .drums:
                var slot = index
                if slot == Slot.hat && self.lid.enabled && self.lid.available && self.lid.isOpen { slot = Slot.openHat }
                self.engine.trigger(slot: slot, velocity: velocity, record: true)
                Haptics.pulse(Haptics.forVelocity(velocity))
            case .loops:
                self.engine.toggleLoop(index)
                Haptics.pulse(Haptics.medium)
            }
            DispatchQueue.main.async { self.pendingFlashes.append([index, velocity, 0]) }
        }
        touch.onFrame = { [weak self] fingers in
            guard let self, self.playMode else { return }
            let list = fingers.map { [$0.x, $0.y, $0.size] }
            DispatchQueue.main.async { self.latestFingers = list }
        }
        if !touch.start() {
            let alert = NSAlert()
            alert.messageText = "No se encontró ningún trackpad"
            alert.informativeText = "No se pudo acceder a MultitouchSupport."
            alert.runModal()
        }
    }

    private func wireSensors() {
        lid.onClose = { [weak self] in
            guard let self, self.appActive, self.mode == .drums else { return }
            self.engine.trigger(slot: Slot.pedal, velocity: 0.7, record: true)
            DispatchQueue.main.async { self.pendingFlashes.append([0, 0.5, 1]) }
        }
        lid.start()

        kick.lastSoundTime = { [engine] in engine.lastSoundTime }
        kick.onKick = { [weak self] velocity in
            guard let self, self.appActive, self.mode == .drums else { return }
            self.engine.trigger(slot: Slot.kick, velocity: velocity, record: true)
            DispatchQueue.main.async { self.pendingFlashes.append([4, velocity, 1]) }
        }
        kick.start()
    }

    // MARK: - Modo tocar / modo ratón

    private func setPlayMode(_ on: Bool) {
        guard on != playMode else { return }
        if on {
            guard appActive, window.isVisible else { return }
            // Llevamos el cursor al centro de la ventana y lo bloqueamos ahí, oculto:
            // los toques del trackpad ya no lo mueven ni hacen clic en nada útil.
            let f = window.frame
            let screenHeight = NSScreen.screens.first?.frame.height ?? f.maxY
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: screenHeight - f.midY))
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            latestFingers = []
        }
        playMode = on
    }

    // MARK: - Mensajes de la interfaz

    private func handle(_ action: String, _ body: [String: Any]) {
        kick.lastOtherInput = CACurrentMediaTime()
        let bool = body["v"] as? Bool ?? false
        let number = (body["v"] as? NSNumber)?.doubleValue ?? 0
        let pad = (body["pad"] as? NSNumber)?.intValue ?? -1

        switch action {
        case "ready", "jsError", "key": return
        case "playMode": setPlayMode(bool); return
        case "mode": mode = Mode(rawValue: body["v"] as? String ?? "") ?? .drums
        case "kit":
            kitIndex = min(3, max(0, Int(number)))
            applySlots()
        case "play": engine.togglePlay()
        case "rec": engine.toggleRecording()
        case "undo": engine.undoLayer()
        case "clear": engine.clearRecording()
        case "stopLoops": engine.stopAllLoops()
        case "bpm": engine.setBPM(number.rounded())
        case "bars": engine.setBars(Int(number))
        case "quantize": engine.setQuantize(bool)
        case "metro": engine.setMetronome(bool)
        case "metroSound": engine.setMetronomeSound(bool)
        case "metroHaptic": engine.setMetronomeHaptic(bool)
        case "velocity": touch.useVelocity = bool
        case "lid": lid.enabled = bool
        case "lidCalibrate": lid.calibrate()
        case "kick": kick.enabled = bool
        case "kickThreshold": kick.threshold = min(0.5, max(0.015, number))
        case "pickSample": pickSample(for: pad)
        case "removeSample": removeSample(pad)
        case "onboarded": onboarded = true
        default: return
        }
        saveSettings()
    }

    // MARK: - Fotogramas

    private func pushFrame() {
        let flashes = pendingFlashes
        pendingFlashes.removeAll()
        ui.push(state: state(), flashes: flashes, fingers: latestFingers)
        latestFingers = nil
    }

    private func state() -> [String: Any] {
        let s = engine.snapshot()
        return [
            "mode": mode.rawValue,
            "kit": kitIndex,
            "kits": Kits.names,
            "playing": s.playing,
            "recording": s.recording,
            "bpm": s.bpm,
            "bars": s.bars,
            "quantize": s.quantize,
            "metro": s.metronome,
            "metroSound": s.metronomeSound,
            "metroHaptic": s.metronomeHaptic,
            "beat": s.playing && s.songBeat >= 0 ? Int(floor(s.songBeat)) % (s.bars * 4) : -1,
            "beats": s.bars * 4,
            "countIn": s.countIn,
            "layers": s.layers,
            "pads": (0..<8).map { ["sample": custom[$0]?.name ?? ""] },
            "loops": engine.loops.enumerated().map { i, l in
                ["name": l.name, "on": s.loopActive[i], "pending": s.loopPending[i]]
            },
            "vel": ["on": touch.useVelocity, "last": touch.lastVelocity],
            "lid": ["ok": lid.available, "on": lid.enabled, "angle": lid.angle, "base": lid.baseline, "open": lid.isOpen],
            "kick": ["ok": kick.available, "on": kick.enabled, "th": kick.threshold, "level": kick.level],
            "onboarded": onboarded,
            "playMode": playMode,
        ]
    }

    // MARK: - Sonidos

    private func kit(_ i: Int) -> Kit {
        if let k = kits[i] { return k }
        let k = Kits.make(i)
        kits[i] = k
        return k
    }

    private func applySlots() {
        var sounds = kit(kitIndex).sounds
        for (slot, sample) in custom { sounds[slot] = sample }
        engine.setSlots(sounds)
    }

    private func pad(forSlot slot: Int) -> Int { slot == Slot.openHat || slot == Slot.pedal ? 0 : slot }

    private func pickSample(for pad: Int) {
        guard (0..<8).contains(pad) else { return }
        setPlayMode(false)
        let panel = NSOpenPanel()
        panel.title = "Elige un sonido para \(Slot.padNames[pad])"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.loadSample(url, into: pad)
        }
    }

    private func loadSample(_ url: URL, into pad: Int) {
        guard (0..<8).contains(pad) else { return }
        guard let sample = SampleLoader.load(url) else {
            NSSound.beep()
            return
        }
        custom[pad] = sample
        customPaths[pad] = url.path
        applySlots()
        saveSettings()
        pendingFlashes.append([pad, 1, 1])
    }

    private func removeSample(_ pad: Int) {
        guard custom[pad] != nil else { return }
        custom[pad] = nil
        customPaths[pad] = nil
        applySlots()
        saveSettings()
    }

    // MARK: - Ajustes

    private func restoreSettings() {
        kitIndex = min(3, max(0, defaults.integer(forKey: "kit")))
        engine.configure(bpm: defaults.object(forKey: "bpm") as? Double ?? 100,
                         bars: defaults.object(forKey: "bars") as? Int ?? 2,
                         quantize: defaults.object(forKey: "quantize") as? Bool ?? true,
                         metronome: defaults.object(forKey: "metro") as? Bool ?? false,
                         sound: defaults.object(forKey: "metroSound") as? Bool ?? true,
                         haptic: defaults.object(forKey: "metroHaptic") as? Bool ?? true)
        touch.useVelocity = defaults.object(forKey: "velocity") as? Bool ?? true
        lid.enabled = defaults.object(forKey: "lid") as? Bool ?? true
        kick.enabled = defaults.object(forKey: "kick") as? Bool ?? true
        kick.threshold = defaults.object(forKey: "threshold") as? Double ?? 0.12
        onboarded = defaults.bool(forKey: "onboarded")

        let paths = defaults.dictionary(forKey: "samples") as? [String: String] ?? [:]
        for (key, path) in paths {
            guard let pad = Int(key), let sample = SampleLoader.load(URL(fileURLWithPath: path)) else { continue }
            custom[pad] = sample
            customPaths[pad] = path
        }
    }

    private func saveSettings() {
        let s = engine.snapshot()
        defaults.set(kitIndex, forKey: "kit")
        defaults.set(s.bpm, forKey: "bpm")
        defaults.set(s.bars, forKey: "bars")
        defaults.set(s.quantize, forKey: "quantize")
        defaults.set(s.metronome, forKey: "metro")
        defaults.set(s.metronomeSound, forKey: "metroSound")
        defaults.set(s.metronomeHaptic, forKey: "metroHaptic")
        defaults.set(touch.useVelocity, forKey: "velocity")
        defaults.set(lid.enabled, forKey: "lid")
        defaults.set(kick.enabled, forKey: "kick")
        defaults.set(kick.threshold, forKey: "threshold")
        defaults.set(onboarded, forKey: "onboarded")
        defaults.set(Dictionary(uniqueKeysWithValues: customPaths.map { ("\($0.key)", $0.value) }), forKey: "samples")
    }

    func applicationWillTerminate(_ notification: Notification) {
        setPlayMode(false)
        touch.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// `TrackDrum --selftest`: genera todos los sonidos y comprueba que están sanos.
if CommandLine.arguments.contains("--selftest") {
    DSP.sr = 48_000
    var ok = true
    func check(_ name: String, _ s: Sample) {
        let bad = s.data.contains { !$0.isFinite }
        let peak = s.data.map(abs).max() ?? 0
        let line = String(format: "%-26@ %7d muestras  pico %.2f", name as NSString, s.data.count, peak)
        print(line + (bad || peak < 0.05 ? "  ✗" : ""))
        if bad || peak < 0.05 { ok = false }
    }
    let slotNames = Slot.padNames + ["Charles abierto", "Pedal"]
    for k in 0..<4 {
        let kit = Kits.make(k)
        for (i, s) in kit.sounds.enumerated() { check("\(kit.name)/\(slotNames[i])", s) }
    }
    for loop in Loops.make() {
        let notes = loop.byStep.flatMap { $0 }
        print("loop \(loop.name): \(loop.steps) pasos, \(notes.count) notas")
        for n in notes { if case .sample(let s) = n.sound { check("  \(loop.name)", s); break } }
    }
    print(ok ? "OK" : "FALLOS")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
