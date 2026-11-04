#!/usr/bin/env swift
import AppKit
import Foundation

/// One-shot export of the same marks Mission Control / the menu bar use.
/// Writes 64×64 PNGs into menubar/Artwork/providers/ for Electron to ship.

let cyan = NSColor(srgbRed: 0.35, green: 0.83, blue: 0.93, alpha: 1)
let navy = NSColor(srgbRed: 0.055, green: 0.098, blue: 0.161, alpha: 1)
let plain = NSColor(srgbRed: 0.60, green: 0.68, blue: 0.78, alpha: 1)

func artworkURL(_ name: String) -> URL? {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return here.deletingLastPathComponent().appendingPathComponent("Artwork/\(name).png")
}

func foregroundMark(_ source: NSImage, grok: Bool, color: NSColor) -> NSImage? {
    let n = 256
    guard let input = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    input.bitmapData?.initialize(repeating: 0, count: input.bytesPerRow * n)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: input)
    source.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
    NSGraphicsContext.restoreGraphicsState()
    let x0 = grok ? 64 : 10, x1 = grok ? 230 : 246
    let y0 = grok ? 78 : 10, y1 = grok ? 202 : 246
    guard let inputBytes = input.bitmapData else { return nil }
    var alpha = [CGFloat](repeating: 0, count: n * n)
    for y in y0..<y1 {
        for x in x0..<x1 {
            let offset = y * input.bytesPerRow + x * 4
            let a = CGFloat(inputBytes[offset + 3]) / 255
            guard a > 0.05 else { continue }
            let luma = (CGFloat(inputBytes[offset]) * 0.2126
                + CGFloat(inputBytes[offset + 1]) * 0.7152
                + CGFloat(inputBytes[offset + 2]) * 0.0722) / (255 * a)
            alpha[y * n + x] = max(0, min(1, (0.63 - luma) / 0.25)) * a
        }
    }
    var seen = [Bool](repeating: false, count: n * n)
    var kept: [Int] = []
    for y in y0..<y1 {
        for x in x0..<x1 {
            let start = y * n + x
            if seen[start] || alpha[start] < 0.03 { continue }
            var queue = [start], head = 0, edge = false
            seen[start] = true
            while head < queue.count {
                let p = queue[head]; head += 1
                let px = p % n, py = p / n
                if px == x0 || px == x1 - 1 || py == y0 || py == y1 - 1 { edge = true }
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = px + dx, ny = py + dy
                    if nx < x0 || nx >= x1 || ny < y0 || ny >= y1 { continue }
                    let q = ny * n + nx
                    if !seen[q] && alpha[q] >= 0.03 { seen[q] = true; queue.append(q) }
                }
            }
            let componentWidth = (queue.map { $0 % n }.max() ?? 0) - (queue.map { $0 % n }.min() ?? 0)
            let componentHeight = (queue.map { $0 / n }.max() ?? 0) - (queue.map { $0 / n }.min() ?? 0)
            let packaging = !grok && (componentWidth > Int(Double(n) * 0.78) || componentHeight > Int(Double(n) * 0.78))
            if !edge && !packaging && queue.count > 20 { kept.append(contentsOf: queue) }
        }
    }
    guard !kept.isEmpty, let tint = color.usingColorSpace(.deviceRGB) else { return nil }
    let minX = kept.map { $0 % n }.min()!, maxX = kept.map { $0 % n }.max()!
    let minY = kept.map { $0 / n }.min()!, maxY = kept.map { $0 / n }.max()!
    let span = max(maxX - minX, maxY - minY) + 5
    guard let output = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: span, pixelsHigh: span,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let outputBytes = output.bitmapData else { return nil }
    output.bitmapData?.initialize(repeating: 0, count: output.bytesPerRow * span)
    for p in kept {
        let x = p % n - minX + (span - (maxX - minX + 1)) / 2
        let y = p / n - minY + (span - (maxY - minY + 1)) / 2
        let offset = y * output.bytesPerRow + x * 4
        outputBytes[offset] = UInt8(tint.redComponent * 255)
        outputBytes[offset + 1] = UInt8(tint.greenComponent * 255)
        outputBytes[offset + 2] = UInt8(tint.blueComponent * 255)
        outputBytes[offset + 3] = UInt8(alpha[p] * 255)
    }
    output.size = NSSize(width: 32, height: 32)
    let mark = NSImage(size: output.size)
    mark.addRepresentation(output)
    return mark
}

func providerImage(_ provider: String, themed: Bool) -> NSImage? {
    let color = themed ? cyan : plain
    let cutout = provider == "ChatGPT" || provider == "Grok Bot"
    let symbol = provider == "Cursor" ? "cube"
        : provider == "Claude" ? "asterisk"
        : provider == "OpenAI API" ? "brain.head.profile"
        : nil
    let mark: NSImage?
    if let symbol {
        mark = NSImage(systemSymbolName: symbol, accessibilityDescription: provider)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
                    .applying(.init(paletteColors: [color]))
            )
    } else {
        let resource = provider == "Grok Bot" ? "icon-grokbot" : "icon-chatgpt"
        let source = artworkURL(resource).flatMap { NSImage(contentsOf: $0) }
        mark = source.flatMap { foregroundMark($0, grok: provider == "Grok Bot", color: color) }
    }
    guard let mark else { return nil }
    let size = NSSize(width: 64, height: 64)
    let result = NSImage(size: size, flipped: false) { bounds in
        if themed {
            navy.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        }
        let inset: CGFloat = themed ? 10 : 6
        mark.draw(
            in: bounds.insetBy(dx: inset, dy: inset),
            from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: false, hints: nil
        )
        return true
    }
    result.isTemplate = false
    return result
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "export", code: 1)
    }
    try png.write(to: url)
}

_ = NSApplication.shared
let outDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Artwork/providers")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let providers: [(String, String)] = [
    ("ChatGPT", "chatgpt"),
    ("Cursor", "cursor"),
    ("Grok Bot", "grokbot"),
    ("OpenAI API", "openai"),
    ("Claude", "claude"),
]

for (name, slug) in providers {
    // Plain/monochrome — matches Mission Control sidebar (themedProviderLogos off).
    guard let plainImg = providerImage(name, themed: false) else {
        fputs("failed: \(name) plain\n", stderr)
        exit(1)
    }
    try writePNG(plainImg, to: outDir.appendingPathComponent("\(slug).png"))
    guard let themedImg = providerImage(name, themed: true) else {
        fputs("failed: \(name) themed\n", stderr)
        exit(1)
    }
    try writePNG(themedImg, to: outDir.appendingPathComponent("\(slug)-themed.png"))
    print("wrote \(slug).png + \(slug)-themed.png")
}
print("done → \(outDir.path)")
