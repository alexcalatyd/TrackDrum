import Foundation

/// Un proyecto en disco es una carpeta `Nombre.trackdrum` con `proyecto.json`
/// y un WAV por cada pista con audio (`A-1.wav` = escena A, pista 1).
struct ProjectDoc: Codable {
    struct Track: Codable {
        var name: String
        var mix: TrackMix
    }
    struct Scene: Codable {
        var pattern: [[Float]]
        var beatsOn: Bool
        var tracks: [Int] // pistas con audio
    }

    var version = 1
    var sampleRate: Double
    var bpm: Double
    var bars: Int
    var beatsVol: Float
    var swing: Double
    var tracks: [Track]
    var scenes: [Scene]
    var scene: Int
    var song: [Int]
    var songMode: Bool
    var fx: FXSettings
    var quant: Int
    var quantStrength: Double
    var replace: Bool
    // Instrumentos.
    var kit: Int
    var padSamples: [String: String]
    var guitarTone: Int
    var bassTone: Int
    var synthPatch: Int
    var root: Int
    var scale: Int
    var octave: Int
    var samplerPath: String?
    var samplerTune: Int
}

enum ProjectFiles {
    static let sceneLetters = ["A", "B", "C", "D"]

    /// La app corre con sudo: los archivos van a la carpeta del usuario de verdad, no a la de root.
    static var userHome: URL {
        if let u = ProcessInfo.processInfo.environment["SUDO_USER"], let h = NSHomeDirectoryForUser(u) {
            return URL(fileURLWithPath: h)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var projectsFolder: URL {
        let music = userHome.appendingPathComponent("Music/TrackDrum")
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        giveToUser(music)
        return music
    }

    static var autosaveURL: URL {
        let dir = userHome.appendingPathComponent("Library/Application Support/TrackDrum")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        giveToUser(dir)
        return dir.appendingPathComponent("Autoguardado.trackdrum")
    }

    /// Si somos root (sudo), devuelve el archivo o carpeta al usuario para que pueda moverlo o borrarlo.
    static func giveToUser(_ url: URL) {
        let env = ProcessInfo.processInfo.environment
        guard getuid() == 0, let uid = env["SUDO_UID"].flatMap(UInt32.init), let gid = env["SUDO_GID"].flatMap(UInt32.init) else { return }
        chown(url.path, uid, gid)
        if let e = FileManager.default.enumerator(atPath: url.path) {
            for case let sub as String in e { chown(url.appendingPathComponent(sub).path, uid, gid) }
        }
    }

    static func wavName(scene: Int, track: Int) -> String { "\(sceneLetters[scene])-\(track + 1).wav" }

    static func save(_ doc: ProjectDoc, audio: [(scene: Int, track: Int, data: [Float])], to url: URL) throws {
        let fm = FileManager.default
        // Se escribe en una carpeta temporal al lado y luego se cambia por la buena: si algo falla, no se pierde nada.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(doc).write(to: tmp.appendingPathComponent("proyecto.json"))
        for a in audio {
            try SampleLoader.writeWAV([a.data], sr: doc.sampleRate, to: tmp.appendingPathComponent(wavName(scene: a.scene, track: a.track)))
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        giveToUser(url)
    }

    static func load(_ url: URL) -> (ProjectDoc, [(scene: Int, track: Int, data: [Float])])? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("proyecto.json")),
              let doc = try? JSONDecoder().decode(ProjectDoc.self, from: data) else { return nil }
        var audio: [(Int, Int, [Float])] = []
        for (s, scene) in doc.scenes.enumerated() where s < sceneLetters.count {
            for t in scene.tracks {
                let f = url.appendingPathComponent(wavName(scene: s, track: t))
                // Sin límite de duración ni normalizar: es el audio tal cual se grabó.
                if let smp = SampleLoader.load(f, maxSeconds: nil, normalize: false) { audio.append((s, t, smp.data)) }
            }
        }
        return (doc, audio.map { (scene: $0.0, track: $0.1, data: $0.2) })
    }
}
