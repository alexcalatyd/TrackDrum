import CoreAudio
import Foundation

/// Datos de la salida de audio actual (la que usa macOS por defecto).
struct OutputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let bluetooth: Bool
    /// Latencia que declara el dispositivo: hardware + margen de seguridad + stream + búfer.
    let reportedLatency: Double

    static func current() -> OutputDevice? {
        var id = AudioObjectID(0)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                  kAudioObjectPropertyScopeGlobal, &id), id != 0 else { return nil }

        var transport: UInt32 = 0
        _ = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        let bt = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE

        var rate: Float64 = 48_000
        _ = get(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
        var lat: UInt32 = 0, safety: UInt32 = 0, buffer: UInt32 = 0, streamLat: UInt32 = 0
        _ = get(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &lat)
        _ = get(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &safety)
        _ = get(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &buffer)
        if let stream = firstOutputStream(id) {
            _ = get(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &streamLat)
        }
        let frames = Double(lat) + Double(safety) + Double(buffer) + Double(streamLat)

        return OutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                            name: string(id, kAudioObjectPropertyName) ?? "Salida",
                            bluetooth: bt, reportedLatency: frames / max(1, rate))
    }

    private static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0.baseAddress!) == noErr
        }
    }

    private static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func firstOutputStream(_ id: AudioObjectID) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }
}
