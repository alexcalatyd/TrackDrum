import AppKit
import WebKit

/// WKWebView que deja soltar archivos de audio sobre los pads.
final class DropWebView: WKWebView {
    var onDragOver: ((CGPoint?) -> Void)?
    var onDrop: ((URL, CGPoint) -> Void)?

    private func webPoint(_ info: NSDraggingInfo) -> CGPoint {
        let p = convert(info.draggingLocation, from: nil)
        return CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    }

    private func fileURL(_ info: NSDraggingInfo) -> URL? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true])?.first as? URL
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileURL(sender) != nil else { return [] }
        onDragOver?(webPoint(sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragOver?(nil) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { fileURL(sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(sender) else { return false }
        onDragOver?(nil)
        onDrop?(url, webPoint(sender))
        return true
    }
}

/// Puente entre la interfaz web (Web/index.html) y la app.
final class WebUI: NSObject, WKScriptMessageHandler {
    let view: DropWebView
    var onMessage: ((String, [String: Any]) -> Void)?
    private(set) var ready = false

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        view = DropWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(self, name: "td")
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        if let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["a"] as? String else { return }
        if action == "ready" { ready = true }
        if action == "jsError" { FileHandle.standardError.write("TrackDrum JS: \(body)\n".data(using: .utf8)!) }
        onMessage?(action, body)
    }

    /// Envía un fotograma: estado + destellos de pads + dedos.
    func push(state: [String: Any]?, flashes: [[Any]], fingers: [[Float]]?) {
        guard ready else { return }
        func json(_ v: Any?) -> String {
            guard let v, let d = try? JSONSerialization.data(withJSONObject: v) else { return "null" }
            return String(data: d, encoding: .utf8) ?? "null"
        }
        view.evaluateJavaScript("TD.frame(\(json(state)),\(json(flashes)),\(json(fingers)))")
    }

    func padAt(_ p: CGPoint, _ done: @escaping (Int) -> Void) {
        view.evaluateJavaScript("TD.padAt(\(p.x),\(p.y))") { result, _ in
            done((result as? NSNumber)?.intValue ?? -1)
        }
    }

    func dragOver(_ p: CGPoint?) {
        guard ready else { return }
        let x = p?.x ?? -1, y = p?.y ?? -1
        view.evaluateJavaScript("TD.dragOver(\(x),\(y))")
    }
}
