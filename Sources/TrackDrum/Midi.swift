import CoreMIDI
import Foundation

/// Salida MIDI virtual: aparece como «TrackDrum» en GarageBand, Logic, Ableton…
/// Canales: 1 guitarra, 2 bajo, 3 teclado, 4 sampler, 10 batería (mapa General MIDI).
final class MidiOut {
    enum Channel { static let guitar: UInt8 = 0, bass: UInt8 = 1, keys: UInt8 = 2, sampler: UInt8 = 3, drums: UInt8 = 9 }

    /// Nota General MIDI de cada hueco del kit (orden de `Slot`).
    static let drumNotes: [UInt8] = [42, 48, 45, 49, 36, 38, 39, 56, 46, 44, 41, 51]

    private let queue = DispatchQueue(label: "trackdrum.midi", qos: .userInteractive)
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private(set) var ready = false
    private(set) var failed = false

    var enabled = false {
        didSet { if enabled && !ready && !failed { queue.async { self.open() } } }
    }

    private func open() {
        guard !ready, !failed else { return }
        var c = MIDIClientRef()
        guard MIDIClientCreateWithBlock("TrackDrum" as CFString, &c, nil) == noErr else { failed = true; return }
        var s = MIDIEndpointRef()
        guard MIDISourceCreateWithProtocol(c, "TrackDrum" as CFString, ._1_0, &s) == noErr else { failed = true; return }
        client = c
        source = s
        ready = true
    }

    private func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        guard enabled else { return }
        queue.async { [self] in
            guard ready else { return }
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            // Mensaje MIDI 1.0 dentro de un paquete universal (UMP de 32 bits, tipo 2).
            var word = (UInt32(0x2) << 28) | (UInt32(status) << 16) | (UInt32(d1 & 0x7F) << 8) | UInt32(d2 & 0x7F)
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
            MIDIReceivedEventList(source, &list)
        }
    }

    func noteOn(_ ch: UInt8, _ note: Int, _ velocity: Float) {
        guard (0...127).contains(note) else { return }
        send(0x90 | ch, UInt8(note), UInt8(max(1, min(127, Int(velocity * 127)))))
    }

    func noteOff(_ ch: UInt8, _ note: Int) {
        guard (0...127).contains(note) else { return }
        send(0x80 | ch, UInt8(note), 0)
    }

    func cc(_ ch: UInt8, _ number: UInt8, _ value: Float) {
        send(0xB0 | ch, number, UInt8(max(0, min(127, Int(value * 127)))))
    }

    /// Nota con duración fija (golpes, pads del sampler).
    func short(_ ch: UInt8, _ note: Int, _ velocity: Float, length: Double = 0.08) {
        guard enabled else { return }
        noteOn(ch, note, velocity)
        queue.asyncAfter(deadline: .now() + length) { [weak self] in self?.noteOff(ch, note) }
    }

    /// Golpe de batería: nota corta en el canal 10.
    func drum(slot: Int, velocity: Float) {
        guard MidiOut.drumNotes.indices.contains(slot) else { return }
        short(Channel.drums, Int(MidiOut.drumNotes[slot]), velocity)
    }
}
