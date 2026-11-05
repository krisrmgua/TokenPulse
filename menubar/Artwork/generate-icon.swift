import AppKit
let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (AffineTransform(scale: CGFloat(pixels) / 1024) as NSAffineTransform).concat()
        NSColor(srgbRed: 0.055, green: 0.098, blue: 0.161, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
        let cyan = NSColor(srgbRed: 0.345, green: 0.824, blue: 0.925, alpha: 1)
        let track = NSBezierPath(ovalIn: NSRect(x: 236, y: 236, width: 552, height: 552))
        track.lineWidth = 58
        cyan.withAlphaComponent(0.22).setStroke(); track.stroke()
        let arc = NSBezierPath(); arc.lineWidth = 58; arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 276, startAngle: 40, endAngle: 310, clockwise: false)
        cyan.setStroke(); arc.stroke()
        let pulse = NSBezierPath(); pulse.lineWidth = 52; pulse.lineCapStyle = .round; pulse.lineJoinStyle = .round
        pulse.move(to: NSPoint(x: 245, y: 512))
        for point in [NSPoint(x: 385, y: 512), NSPoint(x: 448, y: 635), NSPoint(x: 545, y: 370), NSPoint(x: 610, y: 512), NSPoint(x: 780, y: 512)] { pulse.line(to: point) }
        cyan.setStroke(); pulse.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
