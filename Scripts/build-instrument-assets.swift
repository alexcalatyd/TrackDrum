import AppKit

// Run from the repository root: swift Scripts/build-instrument-assets.swift
// Generated studio textures plus deterministic touch-map geometry.
let source = URL(fileURLWithPath: "Art/InstrumentSources", isDirectory: true)
let output = URL(fileURLWithPath: "Sources/TrackDrum/Web/assets", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: UInt32) {
    color(c).setFill()
    NSRect(x: x, y: 1000-y-h, width: w, height: h).fill()
}
func line(_ x: CGFloat, _ y: CGFloat, _ xx: CGFloat, _ yy: CGFloat, _ width: CGFloat, _ c: UInt32) {
    color(c).setStroke()
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: 1000-y))
    p.line(to: NSPoint(x: xx, y: 1000-yy))
    p.lineWidth = width
    p.stroke()
}
func pearl(_ x: CGFloat, _ y: CGFloat) {
    let r = NSRect(x: x-12, y: 1000-y-12, width: 24, height: 24)
    color(0x504439).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)).fill()
    color(0xc8cec5).setFill(); NSBezierPath(ovalIn: r).fill()
    color(0xe5e8db).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 5, dy: 5)).fill()
}
func metal(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat, nut: Bool = false) {
    let w: CGFloat = nut ? 12 : 5
    line(x, top, x, bottom, w+2, nut ? 0x827969 : 0x444540)
    line(x, top, x, bottom, w, nut ? 0xd6cfbb : 0x999d99)
    line(x-1, top, x-1, bottom, nut ? 5 : 1.5, nut ? 0xf0ead8 : 0xdce0dc)
}
func string(_ y: CGFloat, _ end: CGFloat, _ width: CGFloat, wound: Bool) {
    line(0,y, end,y, width+1.5, 0x38342e)
    line(0,y, end,y, width, 0x9b998e)
    line(0,y-0.6, end,y-0.6, max(0.6,width*0.25), 0xe4dfcc)
    if wound {
        for x in stride(from: CGFloat(0), through: end, by: 2.4) {
            line(x,y-width*0.42, x+0.9,y+width*0.42, 0.55, 0x5b5a52)
        }
    }
}
func render(_ name: String, texture: String, width: Int = 2400, height: Int = 1500,
            overlay: () -> Void = {}) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(width)/1600, y: CGFloat(height)/1000)
    context.interpolationQuality = .high
    let image = NSImage(contentsOf: source.appendingPathComponent(texture))!
    image.draw(in: NSRect(x: 0,y: 0,width: 1600,height: 1000))
    overlay()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: output.appendingPathComponent(name+".jpg"))
    print("\(name).jpg: \(width)×\(height)")
}
try render("drums", texture: "drums.png")
try render("guitar", texture: "guitar.png") {
    metal(144, 160, 840, nut: true)
    for x: CGFloat in [329.6,489.6,630.4,755.2,864] { metal(x,160,840) }
    // Exact saddle extent for the deliberately expanded six-string touch map.
    rect(1417,180,10,640,0xded7c4)
    for i in 0..<6 {
        let y = CGFloat(200+i*120)
        string(y,1440,CGFloat(6)-CGFloat(i)*0.85,wound: i<3)
    }
}
try render("bass", texture: "rosewood.png") {
    let cell: CGFloat = 1600/13
    metal(cell,0,1000,nut: true)
    for i in 2...13 { metal(CGFloat(i)*cell,0,1000) }
    for i in [3,5,7,9] { pearl((CGFloat(i)+0.5)*cell,500) }
    pearl(12.5*cell,250); pearl(12.5*cell,750)
    for i in 0..<4 { string(CGFloat(125+i*250),1600,CGFloat(10)-CGFloat(i)*1.8,wound: true) }
}
try render("pad", texture: "pad.png",width: 600,height: 750)
try render("pad-pressed", texture: "pad-pressed.png",width: 600,height: 750)
