import AppKit

// Dibuja el icono de TrackDrum (1024 px) en Art/AppIcon.png.
// Uso, desde la raíz: swift Scripts/make-icon.swift
// Plano: un trackpad oscuro con 4×2 pads y uno encendido con el naranja de la app.

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255,
            blue: CGFloat(h & 255) / 255, alpha: a)
}

// Placa del icono (rejilla de macOS: 824 px centrados, radio ~185).
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
hex(0x1a1a19).setFill()
NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185).fill()
ctx.restoreGState()
hex(0xffffff, 0.06).setStroke()
let rim = NSBezierPath(roundedRect: plate.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
rim.lineWidth = 3
rim.stroke()

// Trackpad (proporción ≈ 1,6:1).
let pad = NSRect(x: 192, y: 312, width: 640, height: 400)
hex(0x2a2a28).setFill()
NSBezierPath(roundedRect: pad, xRadius: 44, yRadius: 44).fill()

// 4×2 pads.
let cols = 4, rows = 2, gap: CGFloat = 18, inset: CGFloat = 30
let area = pad.insetBy(dx: inset, dy: inset)
let cw = (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
let ch = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
for r in 0..<rows {
    for c in 0..<cols {
        let cell = NSRect(x: area.minX + CGFloat(c) * (cw + gap), y: area.minY + CGFloat(r) * (ch + gap), width: cw, height: ch)
        let lit = r == 0 && c == 1
        (lit ? hex(0xff6b2c) : hex(0x3a3a37)).setFill()
        NSBezierPath(roundedRect: cell, xRadius: 16, yRadius: 16).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: "Art/AppIcon.png")
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("Art/AppIcon.png")
