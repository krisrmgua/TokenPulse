import AppKit
import Foundation

/// Headless tray PNG for Electron — same `StatusBarArtwork` path as the Swift app,
/// so SF Pro / monospaced-digit glyphs match the live menu bar.
enum StatusBarRender {
    struct Payload: Decodable {
        var dark: Bool?
        var themed: Bool?
        var blocks: [Block]
    }

    struct Block: Decodable {
        var id: String
        var design: String
        var stale: Bool?
        var metrics: [Metric]
    }

    struct Metric: Decodable {
        var label: String
        var value: String
        var percent: Double?
        var color: [Double]
    }

    private static let names: [String: String] = [
        "cursor": "Cursor",
        "claude": "Claude",
        "chatgpt": "ChatGPT",
        "openai": "OpenAI API",
        "grokbot": "Grok Bot",
    ]

    static func write(json: Data, to path: String) throws {
        _ = NSApplication.shared
        let payload = try JSONDecoder().decode(Payload.self, from: json)
        let dark = payload.dark ?? true
        let themed = payload.themed ?? Prefs.themedProviderLogos
        let blocks: [StatusBarBlock] = payload.blocks.map { block in
            let name = names[block.id] ?? block.id
            let design = StatusBarDesign(rawValue: block.design) ?? .divider
            let metrics = block.metrics.map { m -> StatusBarMetric in
                let rgb = m.color
                let color: NSColor
                if rgb.count >= 3 {
                    color = NSColor(
                        srgbRed: min(1, max(0, rgb[0] / 255)),
                        green: min(1, max(0, rgb[1] / 255)),
                        blue: min(1, max(0, rgb[2] / 255)),
                        alpha: 1
                    )
                } else {
                    color = MenuBarPalette.label
                }
                return StatusBarMetric(label: m.label, value: m.value, percent: m.percent, color: color)
            }
            let symbol = name == "Cursor" ? "cube"
                : name == "Claude" ? "asterisk"
                : name == "OpenAI API" ? "brain.head.profile"
                : nil
            let original = symbol.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: name)
            }
            let icon = ProviderArtwork.image(name, original: original, themed: themed)
            return StatusBarBlock(
                provider: name,
                icon: icon,
                metrics: metrics,
                design: design,
                stale: block.stale ?? false
            )
        }
        let image = StatusBarArtwork.image(blocks: blocks, dark: dark, enlarged: true)
        try writeRetinaPNG(image, to: path)
    }

    private static func writeRetinaPNG(_ image: NSImage, to path: String) throws {
        let size = image.size
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int((size.width * scale).rounded())),
            pixelsHigh: max(1, Int((size.height * scale).rounded())),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "TokenPulse.BarRender", code: 1)
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSNumber(value: Int(NSImageInterpolation.high.rawValue))]
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TokenPulse.BarRender", code: 2)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
