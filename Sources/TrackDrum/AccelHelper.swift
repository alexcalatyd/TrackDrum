import Foundation
import CMultitouch
import QuartzCore

/// El acelerómetro solo manda datos a root. Para no tener que abrir la app con sudo, un
/// ayudante (este mismo ejecutable con `--accel-daemon`) corre como LaunchDaemon y le pasa
/// las lecturas a la app por UDP local. La app le saluda cada segundo; si deja de saludar,
/// el ayudante apaga el sensor.
enum AccelHelper {
    static let port: UInt16 = 47321
    static let label = "com.trackdrum.accel"
    static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let hello = Array("TDHI".utf8)

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath) && FileManager.default.fileExists(atPath: installedBinary)
    }

    static func loopback(_ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return a
    }

    /// Copia el ejecutable y registra el LaunchDaemon. Pide la contraseña de administrador.
    /// Se llama fuera del hilo principal (el diálogo bloquea).
    static func install(completion: @escaping (Bool) -> Void) {
        guard let exe = Bundle.main.executablePath else { return completion(false) }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(installedBinary)</string><string>--accel-daemon</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ProcessType</key><string>Interactive</string>
        </dict></plist>
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        do { try plist.write(to: tmp, atomically: true, encoding: .utf8) } catch { return completion(false) }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let sh = [
            "launchctl bootout system/\(label) 2>/dev/null",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(q(exe)) \(q(installedBinary))",
            "chown root:wheel \(q(installedBinary))",
            "chmod 755 \(q(installedBinary))",
            "cp \(q(tmp.path)) \(q(plistPath))",
            "chown root:wheel \(q(plistPath))",
            "chmod 644 \(q(plistPath))",
            "launchctl bootstrap system \(q(plistPath))",
        ].joined(separator: "; ")
        completion(runAsAdmin(sh, prompt: L("TrackDrum quiere instalar un ayudante para leer el acelerómetro (golpe en el chasis = bombo).", "TrackDrum wants to install a helper to read the accelerometer (tap the chassis = kick).")))
    }

    static func uninstall(completion: @escaping (Bool) -> Void) {
        let sh = "launchctl bootout system/\(label) 2>/dev/null; rm -f '\(plistPath)' '\(installedBinary)'"
        completion(runAsAdmin(sh, prompt: L("TrackDrum quiere quitar el ayudante del acelerómetro.", "TrackDrum wants to remove the accelerometer helper.")))
    }

    private static func runAsAdmin(_ shell: String, prompt: String) -> Bool {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "do shell script \"\(esc(shell))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Lado del ayudante (root)

    private static var fd: Int32 = -1
    private static var client: sockaddr_in?
    private static var lastHello = 0.0
    private static var lastData = 0.0
    private static var running = false
    private static let lock = NSLock()

    /// Bucle del LaunchDaemon. No vuelve.
    static func runDaemon() -> Never {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = loopback(port)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard fd >= 0, bound == 0 else {
            FileHandle.standardError.write("trackdrum-accel: no puedo abrir el puerto \(port)\n".data(using: .utf8)!)
            exit(1)
        }

        // Saludos de la app.
        let rx = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        rx.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 16)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n == hello.count, Array(buf[0..<n]) == hello, from.sin_addr.s_addr == inet_addr("127.0.0.1") else { return }
            lock.lock(); client = from; lock.unlock()
            lastHello = CACurrentMediaTime()
            if !running { start() }
        }
        rx.resume()

        // Vigilante: apaga el sensor si la app se fue; lo despierta o reabre si se calla.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler {
            let now = CACurrentMediaTime()
            guard running else { return }
            if now - lastHello > 3 {
                accel_stop(); running = false
                lock.lock(); client = nil; lock.unlock()
                return
            }
            if now - lastData > 1 { accel_wake() }
            if now - lastData > 3 { start() }
        }
        t.resume()
        withExtendedLifetime((rx, t)) { dispatchMain() }
    }

    private static func start() {
        running = true
        lastData = CACurrentMediaTime()
        _ = accel_start { x, y, z in
            AccelHelper.lastData = CACurrentMediaTime()
            AccelHelper.lock.lock()
            guard var to = AccelHelper.client else { AccelHelper.lock.unlock(); return }
            AccelHelper.lock.unlock()
            var v = (x, y, z)
            withUnsafeBytes(of: &v) { raw in
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(AccelHelper.fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
}

/// Lado de la app: recibe las lecturas del ayudante.
final class AccelLink {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var onSample: ((Double, Double, Double) -> Void)?

    func start() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var addr = AccelHelper.loopback(0)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "trackdrum.accel", qos: .userInteractive))
        s.setEventHandler { [weak self] in
            guard let self else { return }
            var v = (0.0, 0.0, 0.0)
            let n = withUnsafeMutableBytes(of: &v) { recv(self.fd, $0.baseAddress, $0.count, 0) }
            if n == MemoryLayout.size(ofValue: v) { self.onSample?(v.0, v.1, v.2) }
        }
        s.resume()
        source = s
        sayHello()
    }

    /// Hay que llamarlo cada segundo o el ayudante apaga el sensor.
    func sayHello() {
        guard fd >= 0 else { return }
        var to = AccelHelper.loopback(AccelHelper.port)
        let msg = AccelHelper.hello
        _ = msg.withUnsafeBytes { raw in
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
