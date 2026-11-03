import AppKit

/// Offline proof sheet built by the exact renderer used by NSStatusBarButton.
enum StatusBarPreview {
    static func writeIcons(to path: String) throws {
        _ = NSApplication.shared
        let width = 700, height = 210
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.098, green: 0.173, blue: 0.251, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let plain = NSColor(srgbRed: 0.60, green: 0.68, blue: 0.78, alpha: 1)
        for (row, themed) in [true, false].enumerated() {
            let y = CGFloat(135 - row * 90)
            ((themed ? "Themed" : "Monochrome") as NSString).draw(at: NSPoint(x: 20, y: y + 8), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: plain])
            for (i, provider) in ["ChatGPT", "Cursor", "Grok Bot", "OpenAI API", "Claude"].enumerated() {
                let resource = provider == "Grok Bot" ? "icon-grokbot" : "icon-chatgpt"
                let symbol = provider == "Cursor" ? "cube" : provider == "Claude" ? "asterisk" : provider == "OpenAI API" ? "brain.head.profile" : nil
                let original = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [plain])) } ?? Bundle.main.url(forResource: resource, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
                let x = CGFloat(145 + i * 110)
                ProviderArtwork.image(provider, original: original, themed: themed, plainColor: plain)?.draw(in: NSRect(x: x, y: y, width: 32, height: 32))
                (provider as NSString).draw(at: NSPoint(x: x - 12, y: y - 24), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: plain])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "TokenPulse.Preview", code: 2) }
        try png.write(to: URL(fileURLWithPath: path))
    }

    static func write(to path: String) throws {
        _ = NSApplication.shared
        let logo = Bundle.main.url(forResource: "icon-chatgpt", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        let icon = ProviderArtwork.image("ChatGPT", original: logo)
        let cyan = ProviderArtwork.cyan
        let samples: [(String, [StatusBarMetric])] = [
            ("Mixed · remaining", [.init(label: "5H", value: "64%", percent: 64, color: SpendPalette.green), .init(label: "W", value: "29%", percent: 29, color: SpendPalette.yellow)]),
            ("Low · remaining", [.init(label: "5H", value: "1%", percent: 1, color: SpendPalette.red), .init(label: "W", value: "29%", percent: 29, color: SpendPalette.yellow)]),
            ("Exhausted / reset", [.init(label: "5H", value: "0% Nov 6", percent: 0, color: SpendPalette.red), .init(label: "W", value: "100%", percent: 100, color: SpendPalette.green)]),
            ("Work · pending day", [.init(label: "D", value: "—"), .init(label: "M", value: "$212", color: SpendPalette.green)])
        ]
        let width = 1280, height = 610
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ProviderArtwork.navy.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 12, _ color: NSColor = .white) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
        }
        text("TokenPulse · native menu-bar styles", 24, 575, 18, cyan)
        for (column, sample) in samples.enumerated() { text(sample.0, CGFloat(column) * 275 + 180, 540, 12, cyan) }
        for (row, design) in StatusBarDesign.allCases.enumerated() {
            let y = CGFloat(height - 115 - row * 55)
            text(design.title, 24, y + 5)
            for (column, sample) in samples.enumerated() {
                let image = StatusBarArtwork.image(blocks: [.init(provider: "ChatGPT", icon: icon, metrics: sample.1, design: design)], dark: true, enlarged: true)
                image.draw(in: NSRect(x: CGFloat(column) * 275 + 180, y: y, width: image.size.width, height: image.size.height))
            }
        }
        let labels = ["ChatGPT", "Cursor", "Grok Bot", "OpenAI API", "Claude"]
        for (i, provider) in labels.enumerated() {
            let resource = provider == "Grok Bot" ? "icon-grokbot" : "icon-chatgpt"
            let original = Bundle.main.url(forResource: resource, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ProviderArtwork.image(provider, original: original)?.draw(in: NSRect(x: 180 + i * 160, y: 42, width: 32, height: 32))
            text(provider, CGFloat(220 + i * 160), 50, 11)
        }
        text("Bars and arcs encode allowance remaining. Money stays numeric. Sample data; no provider calls.", 24, 15, 11, cyan)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "TokenPulse.Preview", code: 1) }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
