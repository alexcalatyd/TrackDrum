import Foundation

/// Ritmos de partida para la caja de ritmos (16 semicorcheas = 1 compás).
/// Filas en el orden de `AudioEngine.beatRows`: bombo, caja, clap, charles, charles abierto, tom alto, tom bajo, ride.
/// "X" = acento, "x" = normal, "o" = suave.
enum Beats {
    struct Preset {
        let name: String
        let pattern: [[Float]]
    }

    static let rowNames = ["Bombo", "Caja", "Clap", "Charles", "Abierto", "Tom 1", "Tom 2", "Ride"]

    static let presets: [Preset] = [
        make("Vacío", [:]),
        make("Básico", [
            0: "X.......X.......",
            1: "....X.......X...",
            3: "x.x.x.x.x.x.x.x.",
        ]),
        make("Rock", [
            0: "X......xX.x.....",
            1: "....X.......X...",
            3: "x.x.x.x.x.x.x.x.",
            4: "..............x.",
        ]),
        make("Funk", [
            0: "X..x..x...X..x..",
            1: "....X..o.o..X..o",
            3: "xoxoxoxoxoxoxoxo",
        ]),
        make("House", [
            0: "X...X...X...X...",
            2: "....x.......x...",
            3: "x.x.x.x.x.x.x.x.",
            4: "..x...x...x...x.",
        ]),
        make("Hip-hop", [
            0: "X.....x...x.x...",
            1: "....X.......X...",
            3: "x.x.x.x.x.xxx.x.",
        ]),
        make("Reggaetón", [
            0: "X...X...X...X...",
            1: "...x..x....x..x.",
            3: "x.x.x.x.x.x.x.x.",
        ]),
        make("Bossa", [
            0: "X..xX..xX..xX..x",
            1: "x..x..x...x..x..",
            7: "x.xxx.xxx.xxx.xx",
        ]),
    ]

    private static func make(_ name: String, _ rows: [Int: String]) -> Preset {
        var p = [[Float]](repeating: [Float](repeating: 0, count: AudioEngine.beatSteps), count: rowNames.count)
        for (r, line) in rows {
            for (i, ch) in line.enumerated() where i < AudioEngine.beatSteps {
                switch ch {
                case "X": p[r][i] = 1
                case "x": p[r][i] = 0.72
                case "o": p[r][i] = 0.4
                default: break
                }
            }
        }
        return Preset(name: name, pattern: p)
    }
}
