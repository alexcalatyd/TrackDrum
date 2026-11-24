import AppKit
import QuartzCore
import UniformTypeIdentifiers

/// Pantallas de la app. Todas se tocan con el trackpad menos los beats, que van con el ratón.
enum Mode: String, CaseIterable {
    case pads, kit, guitar, bass, keys, sampler, beats
    var playable: Bool { self != .beats }
    var label: String {
        switch self {
        case .pads: return "Pads"
        case .kit: return "Batería"
        case .guitar: return "Guitarra"
        case .bass: return "Bajo"
        case .keys: return "Teclado"
        case .sampler: return "Sampler"
        case .beats: return "Beats"
        }
    }
}

/// Una pieza de la batería dibujada, en coordenadas 0..1 del dibujo (y hacia abajo).
private struct DrumZone {
    let slot: Int
    let x, y, rx, ry: Float
}

final class AppController: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let ui = WebUI()
    private let engine = AudioEngine()
    private let touch = TouchInput()
    private let lid = LidPedal()
    private let kick = AccelKick()
    private let midi = MidiOut()
    private let defaults = UserDefaults.standard

    private var mode = Mode.pads
    private var kitIndex = 0
    private var kits: [Int: Kit] = [:]
    private var custom: [Int: Sample] = [:]
    private var customPaths: [Int: String] = [:]

    // Pistas (metadatos; el audio vive en el motor).
    private var trackNames = [String](repeating: "", count: AudioEngine.trackCount)
    private var wavesDirty = Set<Int>()
    private var waveTick = 0
    private var shownScene = -1

    // Guitarra.
    private var chord = -1 // -1 = cuerdas al aire
    private var tone = GuitarSynth.Tone.acoustic
    private var holdChord = true

    // Tonalidad (bajo, teclado y sampler).
    private var root = 0
    private var scale = 0

    // Bajo.
    private var bassTone = BassSynth.Tone.finger
    private var bassMuteOnLift = false

    // Teclado.
    private var synthPatch = 0
    private var octave = 0

    // Sampler melódico.
    private var samplerSample = DefaultSamples.electricPiano()
    private var samplerPath: String?
    private var samplerTune = 0

    // Tocar: estado que comparten el hilo del trackpad y el principal (protegido por `playLock`).
    private let playLock = UnfairLock()
    private var guitarNotes = [Int?](repeating: nil, count: 6)
    private var bassNotes = [Int?](repeating: nil, count: 4)
    private var bassHeld: [Int32: Int] = [:]
    private struct KeyFinger { var col: Int; var midi: Int; var size: Float; var cut: Float }
    private var keyFingers: [Int32: KeyFinger] = [:]
    private var mouseKey: SynthTouch?
    private var mouseKeyNote = -1
    private var hapticPlay = true

    // Latencia / calibración.
    private var instantPref = false
    private var calTaps: [Double] = []
    private var calTotal = 16
    private var calResult: String? = nil
    private var calTimer: Timer?

    // Proyecto.
    private var projectURL: URL?
    private var savedSignature = ""
    private var autosaveSignature = ""
    private var notice: (text: String, until: Double)?
    private var helperBusy = false

    // Estado leído desde otros hilos (escrituras simples en el principal).
    private var appActive = true
    /// Modo tocar: el trackpad es el instrumento y el ratón queda bloqueado.
    private var playMode = false
    private var drumZones: [DrumZone] = []

    // Rasgueo (solo hilo del trackpad).
    private var strumY: [Int32: (y: Float, t: Double)] = [:]
    static let stringLines: [Float] = (0..<6).map { 0.2 + Float($0) * 0.12 } // 0 = Mi grave, arriba

    // Fotograma para la interfaz (solo hilo principal).
    private var pendingFlashes: [[Any]] = []
    private var latestFingers: [[Float]]? = nil
    private var frameTimer: Timer?

    // MARK: - Menú

    /// Menú nativo: los atajos funcionan aunque la interfaz web no tenga el foco.
    private func buildMenu() {
        let menu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu!.addItem($0) }
            menu.addItem(item)
        }
        func act(_ title: String, _ action: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.representedObject = action
            i.target = self
            return i
        }
        func sys(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        submenu("TrackDrum", [
            sys(L("Acerca de TrackDrum", "About TrackDrum"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            sys(L("Ocultar TrackDrum", "Hide TrackDrum"), #selector(NSApplication.hide(_:)), "h"),
            sys(L("Ocultar otros", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            sys(L("Salir de TrackDrum", "Quit TrackDrum"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu(L("Archivo", "File"), [
            act(L("Nuevo proyecto", "New Project"), "newProject", "n"),
            act(L("Abrir…", "Open…"), "open", "o"),
            .separator(),
            act(L("Guardar", "Save"), "save", "s"),
            act(L("Guardar como…", "Save As…"), "saveAs", "s", [.command, .shift]),
            .separator(),
            act(L("Exportar mezcla…", "Export Mix…"), "export", "e"),
            act(L("Exportar pistas por separado…", "Export Separate Tracks…"), "exportStems"),
        ])
        submenu(L("Edición", "Edit"), [
            act(L("Deshacer última toma", "Undo Last Take"), "undo", "z"),
            .separator(),
            sys(L("Cortar", "Cut"), #selector(NSText.cut(_:)), "x"),
            sys(L("Copiar", "Copy"), #selector(NSText.copy(_:)), "c"),
            sys(L("Pegar", "Paste"), #selector(NSText.paste(_:)), "v"),
            sys(L("Seleccionar todo", "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(L("Ventana", "Window"), [
            sys(L("Minimizar", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            sys(L("Pantalla completa", "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.last?.submenu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        handle(action, [:])
    }

    // MARK: - Arranque

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreSettings()
        // Lo último que había abierto (se guarda solo al salir y cada poco).
        if let (doc, audio) = ProjectFiles.load(ProjectFiles.autosaveURL) {
            apply(doc, audio)
            if let p = defaults.string(forKey: "projectPath"), FileManager.default.fileExists(atPath: p) {
                projectURL = URL(fileURLWithPath: p)
            }
        }
        // Al cerrar se apuntó si lo que había tenía cambios sin guardar.
        savedSignature = defaults.bool(forKey: "autosaveUnsaved") ? "" : signature()
        applySlots()
        autosaveSignature = signature()

        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "TrackDrum"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.067, green: 0.067, blue: 0.063, alpha: 1)
        window.contentView = ui.view
        window.contentMinSize = NSSize(width: 1040, height: 740)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(ui.view)

        ui.onMessage = { [unowned self] action, body in self.handle(action, body) }
        ui.view.onDragOver = { [unowned self] p in self.ui.dragOver(p) }
        ui.view.onDrop = { [unowned self] url, p in
            self.ui.padAt(p) { pad in
                if pad >= 0 { self.loadSample(url, into: pad) } else if pad == -2 { self.loadSamplerSample(url) }
            }
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
        engine.onDeviceChange = { [weak self] in self?.deviceChanged() }
        do { try engine.start() } catch {
            let alert = NSAlert()
            alert.messageText = L("No se pudo arrancar el audio", "Couldn't start audio")
            alert.informativeText = L("Comprueba la salida de sonido del Mac y vuelve a abrir TrackDrum.", "Check your Mac's sound output and open TrackDrum again.") + "\n\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
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
        RunLoop.main.add(frameTimer!, forMode: .common)

        // Autoguardado cada 20 s si ha cambiado algo (y no se está grabando).
        let autosave = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.autosave() }
        RunLoop.main.add(autosave, forMode: .common)
    }

    private func wireEngine() {
        engine.onBeat = { _, accent, delay, haptic in
            if haptic { Haptics.pulse(accent ? Haptics.strong : Haptics.weak, after: delay) }
        }
        engine.onSlotPlayed = { [weak self] slot, velocity, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.pendingFlashes.append([0, slot, velocity])
            }
        }
    }

    private func wireTouch() {
        touch.onContact = { [weak self, kick] in
            let t = CACurrentMediaTime()
            kick.lastOtherInput = t
            DispatchQueue.main.async { self?.calibrationTap(at: t) }
        }
        touch.onHit = { [weak self] finger, velocity in
            guard let self, self.appActive, self.playMode else { return }
            switch self.mode {
            case .pads:
                let col = min(3, max(0, Int(finger.x * 4)))
                var s = (finger.y >= 0.5 ? 0 : 4) + col
                if s == Slot.hat && self.lid.enabled && self.lid.available && self.lid.isOpen { s = Slot.openHat }
                self.hitSlot(s, velocity, fromTrackpad: true)
            case .kit:
                guard var s = self.drumSlot(x: finger.x, y: 1 - finger.y) else { return }
                if s == Slot.hat && self.lid.enabled && self.lid.available && self.lid.isOpen { s = Slot.openHat }
                self.hitSlot(s, velocity, fromTrackpad: true)
            case .sampler:
                let col = min(3, max(0, Int(finger.x * 4)))
                self.samplerHit((finger.y >= 0.5 ? 4 : 0) + col, velocity)
            case .bass:
                let string = min(3, max(0, Int((1 - finger.y) * 4)))
                let fret = min(BassSynth.frets, max(0, Int(finger.x * Float(BassSynth.frets + 1))))
                self.playLock.with { self.bassHeld[finger.id] = string }
                self.bassNote(string: string, fret: fret, velocity: velocity)
            case .guitar, .keys, .beats:
                return
            }
        }
        touch.onFrame = { [weak self] fingers in
            guard let self, self.playMode else { return }
            switch self.mode {
            case .guitar where self.appActive: self.strum(fingers)
            case .keys: self.keysFrame(fingers)
            case .bass: self.bassLifts(fingers)
            default: break
            }
            let list = fingers.map { [$0.x, $0.y, $0.size] }
            DispatchQueue.main.async { self.latestFingers = list }
        }
        if !touch.start() {
            let alert = NSAlert()
            alert.messageText = L("No se encontró ningún trackpad", "No trackpad found")
            alert.informativeText = L("No se pudo acceder a MultitouchSupport.", "Couldn't access MultitouchSupport.")
            alert.runModal()
        }
    }

    private func wireSensors() {
        lid.onClose = { [weak self] in
            guard let self, self.appActive, self.mode == .pads || self.mode == .kit else { return }
            self.hitSlot(Slot.pedal, 0.7)
        }
        lid.start()

        kick.lastSoundTime = { [engine] in engine.lastSoundTime }
        kick.onKick = { [weak self] velocity in
            guard let self, self.appActive, self.mode == .pads || self.mode == .kit else { return }
            self.hitSlot(Slot.kick, velocity)
        }
        kick.start()
    }

    private func hitSlot(_ slot: Int, _ velocity: Float, fromTrackpad: Bool = false) {
        engine.trigger(slot: slot, velocity: velocity)
        midi.drum(slot: slot, velocity: velocity)
        if fromTrackpad && hapticPlay { Haptics.pulse(Haptics.forVelocity(velocity)) }
        DispatchQueue.main.async { self.pendingFlashes.append([0, slot, velocity]) }
    }

    // MARK: - Batería: del trackpad a la pieza dibujada

    private func drumSlot(x: Float, y: Float) -> Int? {
        var best: (Int, Float)? = nil
        for z in drumZones {
            let dx = (x - z.x) / max(0.01, z.rx), dy = (y - z.y) / max(0.01, z.ry)
            // Dentro de la pieza cuenta como 0..1; fuera, la más cercana en proporción a su tamaño.
            let d = (dx * dx + dy * dy).squareRoot()
            if best == nil || d < best!.1 { best = (z.slot, d) }
        }
        return best?.0
    }

    // MARK: - Guitarra: rasgueo con el trackpad

    private func strum(_ fingers: [Finger]) {
        let now = CACurrentMediaTime()
        var seen = Set<Int32>()
        let lines = Self.stringLines
        for f in fingers {
            seen.insert(f.id)
            let y = 1 - f.y
            let bright = 0.25 + 0.7 * f.x
            if let prev = strumY[f.id] {
                let dy = y - prev.y
                let dt = max(0.004, now - prev.t)
                if abs(dy) > 0.0005 {
                    let speed = abs(dy) / Float(dt) // alturas de trackpad por segundo
                    let vel = min(1, max(0.22, 0.2 + speed * 0.16))
                    let crossed = lines.indices.filter { i in
                        let l = lines[i]
                        return dy > 0 ? (prev.y < l && l <= y) : (y <= l && l < prev.y)
                    }
                    let ordered = dy > 0 ? crossed : crossed.reversed()
                    for s in ordered {
                        let frac = (lines[s] - prev.y) / dy // 0..1 dentro de este fotograma
                        pluckString(s, velocity: vel, bright: bright, delay: Double(frac) * dt)
                    }
                }
            } else {
                // Dedo nuevo: si cae encima de una cuerda, la pulsa.
                if let s = lines.indices.min(by: { abs(lines[$0] - y) < abs(lines[$1] - y) }),
                   abs(lines[s] - y) < 0.035 {
                    pluckString(s, velocity: 0.55, bright: bright, delay: 0)
                }
            }
            strumY[f.id] = (y, now)
        }
        strumY = strumY.filter { seen.contains($0.key) }
    }

    /// Hilo cualquiera.
    private func pluckString(_ s: Int, velocity: Float, bright: Float, delay: Double) {
        let prev = playLock.with { guitarNotes[s] }
        if let prev { midi.noteOff(MidiOut.Channel.guitar, prev) }
        guard let note = Chords.note(string: s, chord: chord) else {
            engine.dampString(s)
            playLock.with { guitarNotes[s] = nil }
            return
        }
        engine.pluck(string: s, midi: note, velocity: velocity, bright: bright, delay: delay)
        midi.noteOn(MidiOut.Channel.guitar, note, velocity)
        playLock.with { guitarNotes[s] = note }
        if hapticPlay { Haptics.pulse(velocity > 0.6 ? Haptics.medium : Haptics.weak, after: delay) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + engine.latency) {
            self.pendingFlashes.append([1, s, velocity])
        }
    }

    private func setChord(_ c: Int) {
        let new = Chords.list.indices.contains(c) ? c : -1
        guard new != chord else { return }
        // Al cambiar de acorde, las cuerdas que cambian de nota se apagan (como al levantar los dedos).
        for s in 0..<6 where Chords.note(string: s, chord: chord) != Chords.note(string: s, chord: new) {
            engine.dampString(s)
            if let prev = playLock.with({ guitarNotes[s] }) { midi.noteOff(MidiOut.Channel.guitar, prev) }
            playLock.with { guitarNotes[s] = nil }
        }
        chord = new
    }

    // MARK: - Bajo: el trackpad es el mástil (4 cuerdas × 13 posiciones)

    /// Hilo cualquiera.
    private func bassNote(string: Int, fret: Int, velocity: Float) {
        let note = BassSynth.note(string: string, fret: fret)
        let prev = playLock.with { () -> Int? in
            let p = bassNotes[string]
            bassNotes[string] = note
            return p
        }
        if let prev { midi.noteOff(MidiOut.Channel.bass, prev) }
        engine.pluckBass(string: string, midi: note, velocity: velocity)
        midi.noteOn(MidiOut.Channel.bass, note, velocity)
        if hapticPlay { Haptics.pulse(Haptics.forVelocity(velocity)) }
        DispatchQueue.main.async { self.pendingFlashes.append([2, string, fret]) }
    }

    /// Dedos que se levantan del mástil: si está activado, apagan su cuerda.
    private func bassLifts(_ fingers: [Finger]) {
        let ids = Set(fingers.map(\.id))
        let lifted = playLock.with { () -> [Int] in
            let gone = bassHeld.filter { !ids.contains($0.key) }
            for id in gone.keys { bassHeld[id] = nil }
            // Si otro dedo sigue en esa cuerda, no se apaga.
            return gone.values.filter { s in !bassHeld.values.contains(s) }
        }
        guard bassMuteOnLift else { return }
        for s in Set(lifted) { muteBass(s) }
    }

    private func muteBass(_ s: Int) {
        engine.dampBass(s)
        if let prev = playLock.with({ () -> Int? in let p = bassNotes[s]; bassNotes[s] = nil; return p }) {
            midi.noteOff(MidiOut.Channel.bass, prev)
        }
    }

    // MARK: - Teclado: el trackpad como superficie continua

    private var keyColumns: Int { Scales.steps(scale).count * 2 + 1 }

    private func keyNote(x: Float) -> (col: Int, midi: Int) {
        let cols = keyColumns
        let col = min(cols - 1, max(0, Int(x * Float(cols))))
        return (col, Scales.midi(degree: col, root: root, scale: scale, base: 48 + octave * 12))
    }

    /// Hilo del trackpad: cada dedo es una nota; en vertical, el brillo; apretar más, vibrato.
    private func keysFrame(_ fingers: [Finger]) {
        var list: [SynthTouch] = []
        var events: [(on: Bool, midi: Int)] = []
        var ticks = 0
        var cutoffs: [Float] = []
        let mouse = playLock.with { () -> SynthTouch? in
            var seen = Set<Int32>()
            for f in fingers {
                seen.insert(f.id)
                let (col, note) = keyNote(x: f.x)
                let cut = 0.1 + 0.9 * min(1, max(0, f.y))
                if var k = keyFingers[f.id] {
                    if k.col != col {
                        events.append((false, k.midi)); events.append((true, note))
                        k.col = col; k.midi = note
                        ticks += 1
                    }
                    if abs(k.cut - cut) > 0.01 { k.cut = cut; cutoffs.append(cut) }
                    keyFingers[f.id] = k
                } else {
                    keyFingers[f.id] = KeyFinger(col: col, midi: note, size: max(0.05, f.size), cut: cut)
                    events.append((true, note))
                    ticks += 1
                }
                let k = keyFingers[f.id]!
                let vib = min(1, max(0, (f.size / k.size - 1) * 1.5))
                list.append(SynthTouch(id: f.id, pitch: Double(note), cutoff: cut, vib: vib, velocity: 0.85))
            }
            for (id, k) in keyFingers where !seen.contains(id) {
                events.append((false, k.midi))
                keyFingers[id] = nil
            }
            return mouseKey
        }
        engine.setSynthTouches(list + (mouse.map { [$0] } ?? []))
        for e in events {
            if e.on { midi.noteOn(MidiOut.Channel.keys, e.midi, 0.85) } else { midi.noteOff(MidiOut.Channel.keys, e.midi) }
        }
        if let c = cutoffs.last { midi.cc(MidiOut.Channel.keys, 74, c) }
        // Cada vez que el dedo entra en otra nota se nota un pequeño "clic" en el trackpad.
        if ticks > 0 && hapticPlay { Haptics.pulse(Haptics.weak) }
    }

    /// Clic y arrastre con el ratón sobre el teclado.
    private func keysMouse(x: Float, y: Float, down: Bool) {
        var events: [(Bool, Int)] = []
        let touches = playLock.with { () -> [SynthTouch] in
            if down {
                let (_, note) = keyNote(x: x)
                if note != mouseKeyNote {
                    if mouseKeyNote >= 0 { events.append((false, mouseKeyNote)) }
                    events.append((true, note))
                    mouseKeyNote = note
                }
                mouseKey = SynthTouch(id: -1, pitch: Double(note), cutoff: 0.1 + 0.9 * y, vib: 0, velocity: 0.85)
            } else {
                if mouseKeyNote >= 0 { events.append((false, mouseKeyNote)) }
                mouseKey = nil
                mouseKeyNote = -1
            }
            return keyFingers.map { id, k in SynthTouch(id: id, pitch: Double(k.midi), cutoff: k.cut, vib: 0, velocity: 0.85) }
                + (mouseKey.map { [$0] } ?? [])
        }
        engine.setSynthTouches(touches)
        for (on, n) in events { if on { midi.noteOn(MidiOut.Channel.keys, n, 0.85) } else { midi.noteOff(MidiOut.Channel.keys, n) } }
    }

    /// Suelta todas las notas del teclado (al salir del modo tocar o cambiar de pantalla).
    private func releaseKeys() {
        let notes = playLock.with { () -> [Int] in
            let n = keyFingers.values.map(\.midi) + (mouseKeyNote >= 0 ? [mouseKeyNote] : [])
            keyFingers.removeAll(); mouseKey = nil; mouseKeyNote = -1
            bassHeld.removeAll()
            return n
        }
        engine.setSynthTouches([])
        notes.forEach { midi.noteOff(MidiOut.Channel.keys, $0) }
    }

    // MARK: - Sampler melódico

    private func samplerNote(_ i: Int) -> Int { Scales.midi(degree: i, root: root, scale: scale, base: 60) }

    /// Hilo cualquiera.
    private func samplerHit(_ i: Int, _ velocity: Float) {
        let note = samplerNote(i)
        engine.trigger(sample: samplerSample, semitones: Double(note - 60 + samplerTune), velocity: velocity)
        midi.short(MidiOut.Channel.sampler, note, velocity, length: 0.3)
        if hapticPlay { Haptics.pulse(Haptics.forVelocity(velocity)) }
        DispatchQueue.main.async { self.pendingFlashes.append([3, i, velocity]) }
    }

    private func pickSamplerSample() {
        setPlayMode(false)
        let panel = NSOpenPanel()
        panel.title = L("Elige un sonido para el sampler", "Choose a sound for the sampler")
        panel.allowedContentTypes = [.audio]
        panel.directoryURL = ProjectFiles.userHome.appendingPathComponent("Music")
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.loadSamplerSample(url)
        }
    }

    private func loadSamplerSample(_ url: URL) {
        guard let s = SampleLoader.load(url) else { NSSound.beep(); return }
        samplerSample = s
        samplerPath = url.path
        pendingFlashes.append([3, 0, 1])
    }

    // MARK: - Latencia de la salida

    private func deviceChanged() {
        let d = engine.device
        let saved = d.flatMap { defaults.object(forKey: "latency.\($0.uid)") as? Double }
        engine.calibratedLatency = saved
        // Con Bluetooth cada milisegundo cuenta: sonamos en el primer contacto del dedo.
        touch.instant = instantPref || (d?.bluetooth ?? false)
    }

    private func startCalibration() {
        setPlayMode(false)
        calTaps = []
        calResult = nil
        let interval = 0.6
        engine.startCalibration(count: calTotal, interval: interval)
        calTimer?.invalidate()
        calTimer = Timer.scheduledTimer(withTimeInterval: 0.6 + Double(calTotal) * interval + 0.8, repeats: false) { [weak self] _ in
            self?.finishCalibration()
        }
    }

    /// Un toque del trackpad o la barra espaciadora durante la prueba.
    private func calibrationTap(at t: Double) {
        guard calTimer != nil else { return }
        calTaps.append(t)
    }

    private func finishCalibration() {
        calTimer = nil
        engine.stopCalibration()
        let clicks = engine.calibrationClicks()
        // Los 4 primeros clics son para coger el ritmo.
        let counted = clicks.dropFirst(4)
        var deltas: [Double] = []
        for c in counted {
            // El toque que corresponde a este clic: el primero entre 30 ms antes y 600 ms después.
            if let t = calTaps.first(where: { $0 - c > -0.03 && $0 - c < 0.6 }) { deltas.append(t - c) }
        }
        guard deltas.count >= 6, let d = engine.device else {
            calResult = L("No he pillado suficientes toques. Prueba otra vez siguiendo el clic.", "Not enough taps. Try again, following the click.")
            return
        }
        deltas.sort()
        let median = deltas[deltas.count / 2]
        let spread = deltas[deltas.count * 3 / 4] - deltas[deltas.count / 4]
        guard spread < 0.08 else {
            calResult = L("Los toques salieron muy irregulares. Prueba otra vez, con calma.", "The taps were too uneven. Try again, calmly.")
            return
        }
        let value = max(0, median)
        defaults.set(value, forKey: "latency.\(d.uid)")
        engine.calibratedLatency = value
        calResult = L("Listo: \(Int((value * 1000).rounded())) ms con \(d.name).", "Done: \(Int((value * 1000).rounded())) ms with \(d.name).")
    }

    // MARK: - Modo tocar / modo ratón

    private func setPlayMode(_ on: Bool) {
        guard on != playMode else { return }
        if on {
            guard appActive, window.isVisible, mode.playable else { return }
            // Llevamos el cursor al centro de la ventana y lo bloqueamos ahí, oculto.
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
        if !on { releaseKeys() }
    }

    // MARK: - Mensajes de la interfaz

    private func handle(_ action: String, _ body: [String: Any]) {
        kick.lastOtherInput = CACurrentMediaTime()
        let bool = body["v"] as? Bool ?? false
        let number = (body["v"] as? NSNumber)?.doubleValue ?? 0
        let int = Int(number)
        let pad = (body["pad"] as? NSNumber)?.intValue ?? -1
        let track = (body["t"] as? NSNumber)?.intValue ?? -1
        func num(_ k: String) -> Double { (body[k] as? NSNumber)?.doubleValue ?? 0 }

        switch action {
        case "ready", "key": wavesDirty = Set(0..<AudioEngine.trackCount); return
        case "jsError": return
        case "playMode": setPlayMode(bool); return
        case "mode":
            mode = Mode(rawValue: body["v"] as? String ?? "") ?? .pads
            releaseKeys()
            if !mode.playable { setPlayMode(false) }
        case "kit":
            kitIndex = min(3, max(0, int))
            applySlots()
        case "hit":
            // Clic con el ratón en un pad o en una pieza de la batería.
            let slot = (body["slot"] as? NSNumber)?.intValue ?? -1
            guard slot >= 0 else { return }
            hitSlot(slot, Float((body["vel"] as? NSNumber)?.doubleValue ?? 0.8))
            return
        case "drumLayout":
            let raw = body["v"] as? [[NSNumber]] ?? []
            drumZones = raw.compactMap { a in
                a.count == 5 ? DrumZone(slot: a[0].intValue, x: a[1].floatValue, y: a[2].floatValue,
                                        rx: a[3].floatValue, ry: a[4].floatValue) : nil
            }
            return
        case "pluck":
            let s = (body["s"] as? NSNumber)?.intValue ?? -1
            guard (0..<6).contains(s) else { return }
            pluckString(s, velocity: Float((body["vel"] as? NSNumber)?.doubleValue ?? 0.6),
                        bright: Float((body["b"] as? NSNumber)?.doubleValue ?? 0.6), delay: 0)
            return
        case "chord": setChord(int); return
        case "bassNote":
            let s = Int(num("s")), f = Int(num("f"))
            guard (0..<4).contains(s) else { return }
            bassNote(string: s, fret: min(BassSynth.frets, max(0, f)), velocity: 0.8)
            return
        case "bassMute": (0..<4).forEach(muteBass); return
        case "bassTone":
            bassTone = BassSynth.Tone(rawValue: int) ?? .finger
            engine.setBassTone(bassTone)
        case "bassLift": bassMuteOnLift = bool
        case "keysMouse": keysMouse(x: Float(num("x")), y: Float(num("y")), down: bool); return
        case "patch":
            synthPatch = min(PolySynth.patches.count - 1, max(0, int))
            engine.setSynthPatch(synthPatch)
        case "octave": octave = min(2, max(-2, int))
        case "root": releaseKeys(); root = min(11, max(0, int))
        case "scale": releaseKeys(); scale = min(Scales.list.count - 1, max(0, int))
        case "samplerHit":
            let i = (body["i"] as? NSNumber)?.intValue ?? -1
            guard (0..<8).contains(i) else { return }
            samplerHit(i, 0.85)
            return
        case "samplerPick": pickSamplerSample(); return
        case "samplerReset": samplerSample = DefaultSamples.electricPiano(); samplerPath = nil
        case "samplerTune": samplerTune = min(24, max(-24, int))
        case "calStart": startCalibration(); return
        case "calTap": calibrationTap(at: CACurrentMediaTime()); return
        case "calCancel":
            calTimer?.invalidate(); calTimer = nil; engine.stopCalibration(); calResult = nil
            return
        case "language":
            Lang.pref = ["auto", "en", "es"].contains(body["v"] as? String ?? "") ? body["v"] as! String : "auto"
            buildMenu()
            saveSettings()
            return
        case "kickInstall", "kickUninstall":
            guard !helperBusy else { return }
            helperBusy = true
            let install = action == "kickInstall"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let work = install ? AccelHelper.install : AccelHelper.uninstall
                work { ok in
                    DispatchQueue.main.async {
                        self?.helperBusy = false
                        if install { self?.say(ok ? L("Ayudante instalado", "Helper installed") : L("No se instaló el ayudante", "Helper not installed")) }
                        else { self?.say(ok ? L("Ayudante quitado", "Helper removed") : L("No se pudo quitar el ayudante", "Couldn't remove the helper")) }
                    }
                }
            }
            return
        case "calReset":
            if let d = engine.device { defaults.removeObject(forKey: "latency.\(d.uid)") }
            engine.calibratedLatency = nil
            calResult = nil
            return
        case "instant":
            instantPref = bool
            deviceChanged()
        case "tone":
            tone = GuitarSynth.Tone(rawValue: int) ?? .acoustic
            engine.setGuitarTone(tone)
        case "hold": holdChord = bool
        case "play": engine.togglePlay(); return
        case "rec": toggleRecording(); return
        case "undo": engine.undo(); wavesDirty = Set(0..<AudioEngine.trackCount); return
        case "selectTrack": engine.selectTrack(track); return
        case "clearTrack":
            engine.clearTrack(track)
            if trackNames.indices.contains(track) && !anySceneHas(track) { trackNames[track] = "" }
            wavesDirty.insert(track)
            return
        case "dupTrack":
            if let d = engine.duplicateTrack(track) {
                trackNames[d] = trackNames[track]
                engine.selectTrack(d)
                wavesDirty.insert(d)
            }
            return
        case "trackVol": engine.setMix(track) { $0.vol = Float(number) }; return
        case "trackPan": engine.setMix(track) { $0.pan = Float(number) }; return
        case "trackRev": engine.setMix(track) { $0.rev = Float(number) }; return
        case "trackDly": engine.setMix(track) { $0.dly = Float(number) }; return
        case "trackMute": engine.setMix(track) { $0.mute = bool }; return
        case "trackSolo": engine.setMix(track) { $0.solo = bool }; return
        case "scene": engine.selectScene(int); return
        case "songAdd":
            var s = engine.snapshot().song
            s.append(min(AudioEngine.sceneCount - 1, max(0, int)))
            engine.setSong(s)
            return
        case "songRemove":
            var s = engine.snapshot().song
            if s.indices.contains(int) { s.remove(at: int) }
            engine.setSong(s)
            return
        case "songMode": engine.setSongMode(bool); return
        case "quant": engine.setQuantize(int); return
        case "quantStrength": engine.setQuantizeStrength(number); return
        case "replace": engine.setReplace(bool); return
        case "fxRevSize": engine.setFX { $0.revSize = number }; return
        case "fxDlyDiv": engine.setFX { $0.dlyDiv = int }; return
        case "fxDlyFb": engine.setFX { $0.dlyFb = number }; return
        case "fxComp": engine.setFX { $0.comp = bool }; return
        case "fxCompAmt": engine.setFX { $0.compAmt = number }; return
        case "bounce": bounceBeats(); return
        case "export": exportMix(); return
        case "exportStems": exportStems(); return
        case "newProject": newProject(); return
        case "open": openProject(); return
        case "save": saveProject(as: false); return
        case "saveAs": saveProject(as: true); return
        case "step":
            let row = (body["row"] as? NSNumber)?.intValue ?? -1
            let step = (body["step"] as? NSNumber)?.intValue ?? -1
            engine.setStep(row: row, step: step, value: Float(number))
        case "preset":
            if Beats.presets.indices.contains(int) { engine.setPattern(Beats.presets[int].pattern) }
        case "beatsOn": engine.setBeatsOn(bool)
        case "beatsVol": engine.setBeatsVolume(Float(number))
        case "swing": engine.setSwing(number)
        case "bpm": engine.setBPM(number.rounded())
        case "bars": engine.setBars(int); wavesDirty = Set(0..<AudioEngine.trackCount)
        case "metro": engine.setMetronome(bool)
        case "metroSound": engine.setMetronomeSound(bool)
        case "metroHaptic": engine.setMetronomeHaptic(bool)
        case "hapticPlay": hapticPlay = bool
        case "midi": midi.enabled = bool
        case "velocity": touch.useVelocity = bool
        case "lid": lid.enabled = bool
        case "lidCalibrate": lid.calibrate()
        case "kick": kick.enabled = bool
        case "kickThreshold": kick.threshold = min(0.5, max(0.015, number))
        case "pickSample": pickSample(for: pad)
        case "removeSample": removeSample(pad)
        default: return
        }
        saveSettings()
    }

    private func anySceneHas(_ t: Int) -> Bool {
        (0..<AudioEngine.sceneCount).contains { engine.hasAudio(scene: $0, track: t) }
    }

    // MARK: - Pistas

    private func toggleRecording() {
        let s = engine.snapshot()
        if s.recording {
            engine.toggleRecording(track: s.recTrack)
            return
        }
        // Si la pista elegida ya tiene otro instrumento, buscamos una libre.
        var t = s.recTrack
        if s.trackHas[t] && trackNames[t] != mode.label,
           let free = s.trackHas.firstIndex(of: false) { t = free }
        if !s.trackHas[t] { trackNames[t] = mode.label }
        engine.toggleRecording(track: t)
    }

    private func bounceBeats() {
        let s = engine.snapshot()
        var t = s.recTrack
        if s.trackHas[t], let free = s.trackHas.firstIndex(of: false) { t = free }
        engine.bounceBeats(to: t)
        trackNames[t] = "Beats"
        engine.selectTrack(t)
        wavesDirty.insert(t)
        saveSettings()
    }

    private var projectName: String { projectURL?.deletingPathExtension().lastPathComponent ?? L("Sin título", "Untitled") }

    private func exportMix() {
        setPlayMode(false)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(projectName).wav"
        panel.directoryURL = ProjectFiles.projectsFolder
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            let b = self.engine.bounce(stems: false)
            do {
                try SampleLoader.writeWAV(b.mix, sr: self.engine.sr, to: url)
                ProjectFiles.giveToUser(url)
                self.say(L("Mezcla exportada", "Mix exported"))
            } catch { NSSound.beep() }
        }
    }

    /// Un WAV por pista (en seco, con su volumen y paneo), los beats y la mezcla, en una carpeta.
    private func exportStems() {
        setPlayMode(false)
        let panel = NSOpenPanel()
        panel.title = L("Elige dónde guardar las pistas", "Choose where to save the tracks")
        panel.prompt = L("Exportar aquí", "Export here")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = ProjectFiles.projectsFolder
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let base = panel.url else { return }
            let dir = base.appendingPathComponent("\(self.projectName) - pistas")
            let b = self.engine.bounce(stems: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (t, audio) in b.stems {
                    let name = self.trackNames[t].isEmpty ? "Audio" : self.trackNames[t]
                    try SampleLoader.writeWAV(audio, sr: self.engine.sr, to: dir.appendingPathComponent("\(t + 1) \(name).wav"))
                }
                if let beats = b.beats { try SampleLoader.writeWAV(beats, sr: self.engine.sr, to: dir.appendingPathComponent("Beats.wav")) }
                try SampleLoader.writeWAV(b.mix, sr: self.engine.sr, to: dir.appendingPathComponent("Mezcla.wav"))
                ProjectFiles.giveToUser(dir)
                self.say(L("Pistas exportadas en «\(dir.lastPathComponent)»", "Tracks exported to “\(dir.lastPathComponent)”"))
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            } catch { NSSound.beep() }
        }
    }

    // MARK: - Proyecto

    private func makeDoc(audio withAudio: Bool = true) -> (ProjectDoc, [(scene: Int, track: Int, data: [Float])]) {
        let st = engine.state()
        var audio: [(scene: Int, track: Int, data: [Float])] = []
        var scenes: [ProjectDoc.Scene] = []
        for s in 0..<AudioEngine.sceneCount {
            var tracks: [Int] = []
            for t in 0..<AudioEngine.trackCount where engine.hasAudio(scene: s, track: t) {
                tracks.append(t)
                if withAudio, let d = engine.trackAudio(scene: s, track: t) { audio.append((s, t, d)) }
            }
            scenes.append(.init(pattern: st.patterns[s], beatsOn: st.beatsOn[s], tracks: tracks))
        }
        let doc = ProjectDoc(
            sampleRate: engine.sr, bpm: st.bpm, bars: st.bars, beatsVol: st.beatsVol, swing: st.swing,
            tracks: (0..<AudioEngine.trackCount).map { .init(name: trackNames[$0], mix: st.mix[$0]) },
            scenes: scenes, scene: st.scene, song: st.song, songMode: st.songMode, fx: st.fx,
            quant: st.quant, quantStrength: st.quantStrength, replace: st.replace,
            kit: kitIndex, padSamples: Dictionary(uniqueKeysWithValues: customPaths.map { ("\($0.key)", $0.value) }),
            guitarTone: tone.rawValue, bassTone: bassTone.rawValue, synthPatch: synthPatch,
            root: root, scale: scale, octave: octave, samplerPath: samplerPath, samplerTune: samplerTune)
        return (doc, audio)
    }

    private func apply(_ doc: ProjectDoc, _ audio: [(scene: Int, track: Int, data: [Float])]) {
        releaseKeys()
        let st = EngineState(
            bpm: doc.bpm, bars: doc.bars, mix: doc.tracks.map(\.mix), patterns: doc.scenes.map(\.pattern),
            beatsOn: doc.scenes.map(\.beatsOn), beatsVol: doc.beatsVol, swing: doc.swing, scene: doc.scene,
            song: doc.song, songMode: doc.songMode, fx: doc.fx, quant: doc.quant,
            quantStrength: doc.quantStrength, replace: doc.replace)
        engine.load(st, audio: audio)
        trackNames = (0..<AudioEngine.trackCount).map { doc.tracks.indices.contains($0) ? doc.tracks[$0].name : "" }
        kitIndex = min(3, max(0, doc.kit))
        custom = [:]; customPaths = [:]
        for (key, path) in doc.padSamples {
            guard let pad = Int(key), let s = SampleLoader.load(URL(fileURLWithPath: path)) else { continue }
            custom[pad] = s; customPaths[pad] = path
        }
        applySlots()
        tone = GuitarSynth.Tone(rawValue: doc.guitarTone) ?? .acoustic
        engine.setGuitarTone(tone)
        bassTone = BassSynth.Tone(rawValue: doc.bassTone) ?? .finger
        engine.setBassTone(bassTone)
        synthPatch = min(PolySynth.patches.count - 1, max(0, doc.synthPatch))
        engine.setSynthPatch(synthPatch)
        root = min(11, max(0, doc.root)); scale = min(Scales.list.count - 1, max(0, doc.scale))
        octave = min(2, max(-2, doc.octave))
        samplerTune = doc.samplerTune
        samplerPath = nil
        samplerSample = DefaultSamples.electricPiano()
        if let p = doc.samplerPath, let s = SampleLoader.load(URL(fileURLWithPath: p)) { samplerSample = s; samplerPath = p }
        wavesDirty = Set(0..<AudioEngine.trackCount)
    }

    /// Huella de todo lo que se guarda: si cambia, hay algo sin guardar.
    private func signature() -> String {
        let (doc, _) = makeDoc(audio: false)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let json = (try? enc.encode(doc)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(engine.audioRevision)|\(json)"
    }

    private var unsaved: Bool { signature() != savedSignature && engine.snapshot().hasAudio }

    private func saveProject(as saveAs: Bool) {
        setPlayMode(false)
        if let url = projectURL, !saveAs {
            write(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.title = L("Guardar proyecto", "Save project")
        panel.nameFieldStringValue = projectURL == nil ? L("Mi canción", "My song") : projectName
        panel.directoryURL = ProjectFiles.projectsFolder
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, var url = panel.url else { return }
            if url.pathExtension != "trackdrum" { url = url.deletingPathExtension().appendingPathExtension("trackdrum") }
            self.write(to: url)
        }
    }

    private func write(to url: URL) {
        let (doc, audio) = makeDoc()
        do {
            try ProjectFiles.save(doc, audio: audio, to: url)
            projectURL = url
            savedSignature = signature()
            defaults.set(url.path, forKey: "projectPath")
            say(L("Guardado", "Saved"))
        } catch {
            let a = NSAlert()
            a.messageText = L("No se pudo guardar", "Couldn't save")
            a.informativeText = error.localizedDescription
            a.beginSheetModal(for: window)
        }
    }

    /// Pregunta antes de perder cambios. `then` se llama si se puede seguir.
    private func confirmDiscard(_ then: @escaping () -> Void) {
        guard unsaved else { then(); return }
        let a = NSAlert()
        a.messageText = L("¿Guardar los cambios de «\(projectName)»?", "Save changes to “\(projectName)”?")
        a.informativeText = L("Si no los guardas, se pierden.", "If you don't save them, they'll be lost.")
        a.addButton(withTitle: L("Guardar", "Save"))
        a.addButton(withTitle: L("Cancelar", "Cancel"))
        a.addButton(withTitle: L("No guardar", "Don't Save"))
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn:
                if let url = self.projectURL { self.write(to: url); then() } else { self.saveProject(as: true) }
            case .alertThirdButtonReturn: then()
            default: break
            }
        }
    }

    private func newProject() {
        setPlayMode(false)
        confirmDiscard { [weak self] in
            guard let self else { return }
            let st = self.engine.state()
            var empty = EngineState(bpm: st.bpm, bars: 2, mix: [], patterns: [Beats.presets[1].pattern],
                                    beatsOn: [true], beatsVol: 0.8, swing: 0, scene: 0, song: [], songMode: false,
                                    fx: FXSettings(), quant: 0, quantStrength: 1, replace: false)
            empty.patterns += Array(repeating: Beats.presets[0].pattern, count: AudioEngine.sceneCount - 1)
            empty.beatsOn += Array(repeating: true, count: AudioEngine.sceneCount - 1)
            self.engine.load(empty, audio: [])
            self.trackNames = Array(repeating: "", count: AudioEngine.trackCount)
            self.projectURL = nil
            self.defaults.removeObject(forKey: "projectPath")
            self.savedSignature = self.signature()
            self.wavesDirty = Set(0..<AudioEngine.trackCount)
        }
    }

    private func openProject() {
        setPlayMode(false)
        confirmDiscard { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.title = L("Abrir proyecto (carpeta .trackdrum)", "Open project (.trackdrum folder)")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.directoryURL = ProjectFiles.projectsFolder
            panel.beginSheetModal(for: self.window) { result in
                guard result == .OK, let url = panel.url else { return }
                guard let (doc, audio) = ProjectFiles.load(url) else {
                    let a = NSAlert()
                    a.messageText = L("Eso no es un proyecto de TrackDrum", "That's not a TrackDrum project")
                    a.informativeText = L("Elige una carpeta que termine en .trackdrum.", "Choose a folder ending in .trackdrum.")
                    a.beginSheetModal(for: self.window)
                    return
                }
                self.apply(doc, audio)
                self.projectURL = url
                self.savedSignature = self.signature()
                self.defaults.set(url.path, forKey: "projectPath")
            }
        }
    }

    /// Guarda el trabajo en curso para recuperarlo al abrir la app.
    func autosave(force: Bool = false) {
        let s = engine.snapshot()
        guard force || !s.recording else { return }
        let sig = signature()
        guard force || sig != autosaveSignature else { return }
        let (doc, audio) = makeDoc()
        try? ProjectFiles.save(doc, audio: audio, to: ProjectFiles.autosaveURL)
        autosaveSignature = sig
        defaults.set(sig != savedSignature && s.hasAudio, forKey: "autosaveUnsaved")
    }

    private func say(_ text: String) { notice = (text, CACurrentMediaTime() + 2.5) }

    // MARK: - Fotogramas

    private func pushFrame() {
        let flashes = pendingFlashes
        pendingFlashes.removeAll()
        let s = engine.snapshot()

        // Formas de onda: la pista que se graba se refresca a menudo; el resto, cuando cambia.
        waveTick += 1
        if s.scene != shownScene { shownScene = s.scene; wavesDirty = Set(0..<AudioEngine.trackCount) }
        if s.recording && waveTick % 6 == 0 { wavesDirty.insert(s.recTrack) }
        if s.recording && s.quant > 0 && waveTick % 6 == 0 { wavesDirty.insert(s.recTrack) }
        var waves: [String: Any]? = nil
        if !wavesDirty.isEmpty {
            var w: [String: Any] = [:]
            for t in wavesDirty { w["\(t)"] = engine.peaks(track: t, count: 300).map { ($0 * 100).rounded() / 100 } }
            waves = w
            wavesDirty.removeAll()
        }

        ui.push(state: state(s, waves: waves), flashes: flashes, fingers: latestFingers)
        latestFingers = nil
    }

    private var unsavedCache = (tick: -100, value: false)

    private func state(_ s: EngineSnapshot, waves: [String: Any]?) -> [String: Any] {
        let loopFrames = s.stepFrames * s.bars * 16
        // Lo que se oye va un poco por detrás del motor: compensamos la latencia para dibujar.
        let heard = s.frame - Int(engine.latency * engine.sr)
        let playingPos = s.playing && heard >= 0
        // Calcular si hay cambios sin guardar cuesta algo: dos veces por segundo basta.
        if waveTick - unsavedCache.tick >= 30 { unsavedCache = (waveTick, unsaved) }
        let now = CACurrentMediaTime()
        if let n = notice, n.until < now { notice = nil }
        var st: [String: Any] = [
            "mode": mode.rawValue,
            "kit": kitIndex,
            "kits": Kits.names,
            "playing": s.playing,
            "recording": s.recording,
            "bpm": s.bpm,
            "bars": s.bars,
            "tempoLocked": s.hasAudio,
            "metro": s.metronome,
            "metroSound": s.metronomeSound,
            "metroHaptic": s.metronomeHaptic,
            "pos": playingPos ? Double(heard % loopFrames) / Double(loopFrames) : -1,
            "step": playingPos ? (heard / s.stepFrames) % AudioEngine.beatSteps : -1,
            "beat": playingPos ? (heard / (s.stepFrames * 4)) % (s.bars * 4) : -1,
            "countIn": s.countIn,
            "recTrack": s.recTrack,
            "canUndo": s.canUndo,
            "tracks": (0..<AudioEngine.trackCount).map { t -> [String: Any] in
                let m = s.mix[t]
                return ["name": trackNames[t], "has": s.trackHas[t], "vol": m.vol, "pan": m.pan, "mute": m.mute,
                        "solo": m.solo, "rev": m.rev, "dly": m.dly]
            },
            "scene": s.scene,
            "queuedScene": s.queuedScene,
            "sceneHas": s.sceneHas,
            "song": s.song,
            "songMode": s.songMode,
            "songPos": s.songPos,
            "quant": s.quant,
            "quantStrength": s.quantStrength,
            "replace": s.replace,
            "fx": ["revSize": s.fx.revSize, "dlyDiv": s.fx.dlyDiv, "dlyFb": s.fx.dlyFb, "comp": s.fx.comp, "compAmt": s.fx.compAmt],
            "beatsOn": s.beatsOn,
            "beatsVol": s.beatsVol,
            "swing": s.swing,
            "pattern": s.pattern,
            "rows": Beats.rowNames,
            "presets": Beats.presets.map(\.name),
            "chords": Chords.list.map(\.name),
            "chordFrets": Chords.list.map(\.frets),
            "chord": chord,
            "tone": tone.rawValue,
            "hold": holdChord,
            "key": ["root": root, "scale": scale, "scales": Scales.list.map(\.name), "steps": Scales.steps(scale)],
            "bass": ["tone": bassTone.rawValue, "lift": bassMuteOnLift, "tuning": BassSynth.tuning, "frets": BassSynth.frets],
            "keys": ["patch": synthPatch, "patches": PolySynth.patches.map(\.name), "octave": octave,
                     "notes": (0..<keyColumns).map { Scales.midi(degree: $0, root: root, scale: scale, base: 48 + octave * 12) }],
            "sampler": ["name": samplerSample.name, "custom": samplerPath != nil, "tune": samplerTune,
                        "notes": (0..<8).map { samplerNote($0) }],
            "pads": (0..<8).map { ["sample": custom[$0]?.name ?? ""] },
            "vel": ["on": touch.useVelocity, "last": touch.lastVelocity],
            "lid": ["ok": lid.available, "on": lid.enabled, "open": lid.isOpen, "angle": lid.angle],
            "kick": ["ok": kick.available, "root": kick.needsRoot, "silent": kick.helperSilent,
                     "helper": AccelHelper.isInstalled, "installing": helperBusy, "on": kick.enabled, "th": kick.threshold, "level": kick.level],
            "hapticPlay": hapticPlay,
            "midi": ["on": midi.enabled, "failed": midi.failed],
            "playMode": playMode,
            "lang": Lang.code, "langPref": Lang.pref,
            "project": ["name": projectName, "unsaved": unsavedCache.value, "notice": notice?.text ?? ""],
            "audio": [
                "name": engine.device?.name ?? "",
                "bt": engine.device?.bluetooth ?? false,
                "lat": Int((engine.latency * 1000).rounded()),
                "cal": engine.calibratedLatency.map { Int(($0 * 1000).rounded()) } ?? -1,
                "calibrating": calTimer != nil,
                "clicks": engine.calibrationClicks().count,
                "total": calTotal,
                "taps": calTaps.count,
                "result": calResult ?? "",
                "instant": touch.instant,
                "instantPref": instantPref,
            ],
        ]
        if let waves { st["waves"] = waves }
        return st
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

    private func pickSample(for pad: Int) {
        guard (0..<8).contains(pad) else { return }
        setPlayMode(false)
        let panel = NSOpenPanel()
        panel.title = L("Elige un sonido para \(Slot.padNames[pad])", "Choose a sound for \(Slot.padNamesEN[pad])")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.directoryURL = ProjectFiles.userHome.appendingPathComponent("Music")
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
        pendingFlashes.append([0, pad, 1])
    }

    private func removeSample(_ pad: Int) {
        guard custom[pad] != nil else { return }
        custom[pad] = nil
        customPaths[pad] = nil
        applySlots()
        saveSettings()
    }

    // MARK: - Ajustes (preferencias de la app; la música va en el proyecto)

    private func restoreSettings() {
        Lang.pref = defaults.string(forKey: "language") ?? "auto"
        kitIndex = min(3, max(0, defaults.integer(forKey: "kit")))
        mode = Mode(rawValue: defaults.string(forKey: "screen") ?? "") ?? .pads
        engine.configure(bpm: defaults.object(forKey: "bpm") as? Double ?? 100,
                         bars: defaults.object(forKey: "bars") as? Int ?? 2,
                         metronome: defaults.object(forKey: "metro") as? Bool ?? false,
                         sound: defaults.object(forKey: "metroSound") as? Bool ?? true,
                         haptic: defaults.object(forKey: "metroHaptic") as? Bool ?? true)
        engine.configureBeats(pattern: defaults.array(forKey: "pattern") as? [[Float]],
                              on: defaults.object(forKey: "beatsOn") as? Bool ?? true,
                              volume: defaults.object(forKey: "beatsVol") as? Float ?? 0.8,
                              swing: defaults.object(forKey: "swing") as? Double ?? 0)
        tone = GuitarSynth.Tone(rawValue: defaults.integer(forKey: "tone")) ?? .acoustic
        engine.setGuitarTone(tone)
        holdChord = defaults.object(forKey: "holdChord") as? Bool ?? true
        bassMuteOnLift = defaults.bool(forKey: "bassLift")
        touch.useVelocity = defaults.object(forKey: "velocity") as? Bool ?? true
        instantPref = defaults.bool(forKey: "instant")
        hapticPlay = defaults.object(forKey: "hapticPlay") as? Bool ?? true
        midi.enabled = defaults.bool(forKey: "midi")
        lid.enabled = defaults.object(forKey: "lid") as? Bool ?? true
        kick.enabled = defaults.object(forKey: "kick") as? Bool ?? true
        kick.threshold = defaults.object(forKey: "threshold") as? Double ?? 0.12

        let paths = defaults.dictionary(forKey: "samples") as? [String: String] ?? [:]
        for (key, path) in paths {
            guard let pad = Int(key), let sample = SampleLoader.load(URL(fileURLWithPath: path)) else { continue }
            custom[pad] = sample
            customPaths[pad] = path
        }
    }

    private func saveSettings() {
        defaults.set(Lang.pref, forKey: "language")
        let s = engine.snapshot()
        defaults.set(kitIndex, forKey: "kit")
        defaults.set(mode.rawValue, forKey: "screen")
        defaults.set(s.bpm, forKey: "bpm")
        defaults.set(s.bars, forKey: "bars")
        defaults.set(s.metronome, forKey: "metro")
        defaults.set(s.metronomeSound, forKey: "metroSound")
        defaults.set(s.metronomeHaptic, forKey: "metroHaptic")
        defaults.set(s.pattern, forKey: "pattern")
        defaults.set(s.beatsOn, forKey: "beatsOn")
        defaults.set(s.beatsVol, forKey: "beatsVol")
        defaults.set(s.swing, forKey: "swing")
        defaults.set(tone.rawValue, forKey: "tone")
        defaults.set(holdChord, forKey: "holdChord")
        defaults.set(bassMuteOnLift, forKey: "bassLift")
        defaults.set(touch.useVelocity, forKey: "velocity")
        defaults.set(instantPref, forKey: "instant")
        defaults.set(hapticPlay, forKey: "hapticPlay")
        defaults.set(midi.enabled, forKey: "midi")
        defaults.set(lid.enabled, forKey: "lid")
        defaults.set(kick.enabled, forKey: "kick")
        defaults.set(kick.threshold, forKey: "threshold")
        defaults.set(Dictionary(uniqueKeysWithValues: customPaths.map { ("\($0.key)", $0.value) }), forKey: "samples")
    }

    func applicationWillTerminate(_ notification: Notification) {
        setPlayMode(false)
        touch.stop()
        autosave(force: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// `TrackDrum --accel-daemon`: ayudante con root que lee el acelerómetro (lo lanza launchd).
if CommandLine.arguments.contains("--accel-daemon") { AccelHelper.runDaemon() }

// `TrackDrum --selftest`: genera todos los sonidos y comprueba que están sanos.
if CommandLine.arguments.contains("--selftest") {
    DSP.sr = 48_000
    var ok = true
    func check(_ name: String, _ s: Sample) {
        let bad = s.data.contains { !$0.isFinite }
        let peak = s.data.map(abs).max() ?? 0
        let line = String(format: "%-26@ %7d muestras  pico %.2f", name as NSString, s.data.count, peak)
        print(line + (bad || peak < 0.05 || peak > 4 ? "  ✗" : ""))
        if bad || peak < 0.05 || peak > 4 { ok = false }
    }
    func capture(_ n: Int, _ f: (UnsafeMutablePointer<Float>, Int) -> Void) -> Sample {
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
        buf.initialize(repeating: 0, count: n)
        var done = 0
        while done < n { let k = min(512, n - done); f(buf + done, k); done += k }
        let data = Array(UnsafeBufferPointer(start: buf, count: n))
        buf.deallocate()
        return Sample(data)
    }
    let slotNames = Slot.padNames + ["Charles abierto", "Pedal", "Timbal base", "Ride"]
    for k in 0..<4 {
        let kit = Kits.make(k)
        for (i, s) in kit.sounds.enumerated() { check("\(kit.name)/\(slotNames[i])", s) }
    }
    // Guitarra: rasguea un Do y comprueba que suena y se apaga sin explotar.
    let g = GuitarSynth(sr: 48_000)
    for tone in [GuitarSynth.Tone.acoustic, .electric, .distortion] {
        g.setTone(tone)
        for s in 0..<6 { if let m = Chords.note(string: s, chord: 0) { g.pluck(string: s, midi: m, velocity: 0.8, bright: 0.6) } }
        check("Guitarra \(tone)", capture(48_000) { g.render($0, $1) })
    }
    // Bajo: cuerdas al aire y traste 12.
    let b = BassSynth(sr: 48_000)
    for tone in [BassSynth.Tone.finger, .pick, .sub] {
        b.setTone(tone)
        b.pluck(string: 0, midi: BassSynth.note(string: 0, fret: 0), velocity: 0.9)
        b.pluck(string: 3, midi: BassSynth.note(string: 3, fret: 12), velocity: 0.9)
        check("Bajo \(tone)", capture(48_000) { b.render($0, $1) })
    }
    // Teclado: un acorde de tres dedos en cada sonido.
    for (i, p) in PolySynth.patches.enumerated() {
        let syn = PolySynth(sr: 48_000)
        syn.setPatch(i)
        syn.update([60, 64, 67].enumerated().map { SynthTouch(id: Int32($0.offset), pitch: Double($0.element), cutoff: 0.7, vib: 0.3, velocity: 0.85) })
        let held = capture(24_000) { syn.render($0, $1) }
        syn.update([])
        check("Teclado \(p.name)", held)
        let tail = capture(96_000) { syn.render($0, $1) }
        if syn.isActive || tail.data.contains(where: { !$0.isFinite }) { print("Teclado \(p.name): no se apaga  ✗"); ok = false }
    }
    check("Sampler (piano eléctrico)", DefaultSamples.electricPiano())
    // Efectos: un impulso por la reverb y el delay.
    let rv = Reverb(sr: 48_000), dl = PingPongDelay(sr: 48_000)
    dl.time = 12_000
    var fxOut: [Float] = []
    for i in 0..<96_000 {
        let x: Float = i == 0 ? 1 : 0
        let (a, _) = rv.process(x)
        let (c, _) = dl.process(x)
        fxOut.append(a * 20 + c)
    }
    check("Reverb + delay", Sample(fxOut))

    // Motor: dos escenas con audio, canción A-B, exportación y proyecto de ida y vuelta.
    let eng = AudioEngine()
    let len = Int((eng.sr * 60 / 120 / 4).rounded()) * 2 * 16
    let tone = (0..<len).map { Float(sin(Double($0) * 0.05) * 0.3) }
    var st = EngineState(bpm: 120, bars: 2, mix: [], patterns: [Beats.presets[1].pattern, Beats.presets[0].pattern],
                         beatsOn: [true, false], beatsVol: 0.8, swing: 0, scene: 0, song: [0, 1], songMode: true,
                         fx: FXSettings(), quant: 1, quantStrength: 0.5, replace: false)
    st.mix = (0..<AudioEngine.trackCount).map { _ in TrackMix() }
    st.mix[2].pan = -1
    eng.load(st, audio: [(0, 0, tone), (1, 2, tone)])
    let loopB = eng.bounce(stems: true)
    let songOK = loopB.mix[0].count == 2 * len + Int(eng.sr * 3) && loopB.stems.count == 2 && loopB.beats != nil
    // La pista 3 va toda a la izquierda: en su pista suelta, el canal derecho queda en silencio.
    let panOK = loopB.stems.first { $0.track == 2 }.map { $0.audio[1].allSatisfy { $0 == 0 } && $0.audio[0].contains { $0 != 0 } } ?? false
    print("Motor: canción A-B \(songOK ? "bien" : "✗"), paneo \(panOK ? "bien" : "✗")")
    if !songOK || !panOK { ok = false }
    eng.setSongMode(false)
    let single = eng.bounce(stems: false)
    if single.mix[0].count != len || single.mix[0].contains(where: { !$0.isFinite }) { print("Motor: loop suelto ✗"); ok = false }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(getpid()).trackdrum")
    let doc = ProjectDoc(sampleRate: eng.sr, bpm: 120, bars: 2, beatsVol: 0.8, swing: 0,
                         tracks: st.mix.map { .init(name: "X", mix: $0) },
                         scenes: [.init(pattern: st.patterns[0], beatsOn: true, tracks: [0]),
                                  .init(pattern: st.patterns[1], beatsOn: false, tracks: [2])],
                         scene: 0, song: [0, 1], songMode: true, fx: FXSettings(), quant: 1, quantStrength: 0.5,
                         replace: false, kit: 0, padSamples: [:], guitarTone: 0, bassTone: 0, synthPatch: 0,
                         root: 0, scale: 0, octave: 0, samplerPath: nil, samplerTune: 0)
    do {
        try ProjectFiles.save(doc, audio: [(0, 0, tone), (1, 2, tone)], to: tmp)
        try ProjectFiles.save(doc, audio: [(0, 0, tone), (1, 2, tone)], to: tmp) // sobrescribir también
        if let (back, audio) = ProjectFiles.load(tmp), back.song == [0, 1], audio.count == 2,
           audio.allSatisfy({ zip($0.data, tone).allSatisfy { abs($0 - $1) < 1e-6 } }) {
            print("Proyecto: guardar y abrir bien")
        } else { print("Proyecto: guardar y abrir ✗"); ok = false }
    } catch { print("Proyecto: \(error) ✗"); ok = false }
    try? FileManager.default.removeItem(at: tmp)
    print(ok ? "OK" : "FALLOS")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.regular)

// Ctrl+C en el terminal (run.sh) también guarda antes de salir.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        delegate.autosave(force: true)
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

app.activate(ignoringOtherApps: true)
app.run()
