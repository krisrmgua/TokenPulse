import AppKit

enum StatusBarDesign: String, CaseIterable {
    // Keep the approved numbering stable, even though not every concept ships.
    case divider, rings, baseline, stack, focus, lanes, segments
    var number: Int { switch self { case .divider: return 1; case .rings: return 2; case .baseline: return 3; case .stack: return 4; case .focus: return 6; case .lanes: return 7; case .segments: return 9 } }
    var name: String { switch self { case .divider: return "Divider capsule"; case .rings: return "Twin gauges"; case .baseline: return "Baseline meters"; case .stack: return "Compact stack"; case .focus: return "Focus capsule"; case .lanes: return "Stacked tracks"; case .segments: return "Segmented lanes" } }
    var title: String { "\(number) · \(name)" }
    var stacked: Bool { self == .stack || self == .lanes || self == .segments }

    /// Work spend / OpenAI dollar blocks have no percent meters; only these
    /// layouts read cleanly without rings, baselines, or gauge tracks.
    static let spendCompatible: [StatusBarDesign] = [.divider, .stack]

    static func options(spendOnly: Bool) -> [StatusBarDesign] {
        spendOnly ? spendCompatible : Array(allCases)
    }

    /// Drop an unsupported personal-style pick down to Divider when the
    /// account flips to work spend (Compact stack stays).
    static func resolved(_ design: StatusBarDesign, spendOnly: Bool) -> StatusBarDesign {
        guard spendOnly else { return design }
        return spendCompatible.contains(design) ? design : .divider
    }
}

/// One menu-bar style slot per source. Account mode filters which designs
/// that slot may use; the stored rawValue stays the shared design id.
enum MenuBarProvider: String, CaseIterable {
    case chatGPT, cursor, claude, grokBot, openAI

    var isSpendOnly: Bool {
        switch self {
        case .openAI: return true
        case .grokBot: return false
        case .chatGPT: return !Prefs.chatGPTIsPersonal
        case .cursor: return !Prefs.cursorIsPersonal
        case .claude: return !Prefs.claudeIsPersonal
        }
    }

    static func from(blockProvider: String) -> MenuBarProvider? {
        switch blockProvider {
        case "ChatGPT", "ChatGPT work estimate": return .chatGPT
        case "Cursor": return .cursor
        case "Claude": return .claude
        case "Grok Bot": return .grokBot
        case "OpenAI API": return .openAI
        default: return nil
        }
    }
}

/// One value retains its unit and optional *remaining* percentage. Money has no
/// percentage, so dollar spend and prepaid balances never acquire quota gauges.
struct StatusBarMetric {
    let label: String
    let value: String
    var percent: Double? = nil
    var color: NSColor = MenuBarPalette.label
    var fraction: CGFloat? { percent.map { CGFloat(min(100, max(0, $0))) / 100 } }
}

struct StatusBarBlock {
    let provider: String
    let icon: NSImage?
    let metrics: [StatusBarMetric]
    var design: StatusBarDesign = .divider
    var stale = false
    var accessibilityLabel: String {
        provider + ": " + metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ") + (stale ? ", stale data" : "")
    }
    /// Any remaining-allowance meter at 0%, including a 5-hour window.
    var allowanceEmpty: Bool {
        metrics.contains { guard let percent = $0.percent else { return false }; return percent <= 0 }
    }
}

/// The same clean foreground marks in both modes: cyan on a navy tile when
/// themed, monochrome without a tile otherwise. App-icon packaging is removed.
enum ProviderArtwork {
    static let cyan = NSColor(srgbRed: 0.35, green: 0.83, blue: 0.93, alpha: 1)
    static let navy = NSColor(srgbRed: 0.055, green: 0.098, blue: 0.161, alpha: 1)
    private static var cache: [String: NSImage] = [:]

    static func image(_ provider: String, original: NSImage?, themed: Bool = Prefs.themedProviderLogos,
                      plainColor: NSColor = MenuBarPalette.label) -> NSImage? {
        let cutout = provider == "ChatGPT" || provider == "Grok Bot"
        if !themed && !cutout { return original }
        let color = themed ? cyan : plainColor
        let key = provider + (themed ? ":themed" : ":plain:" + color.description)
        if let hit = cache[key] { return hit }
        let symbol = provider == "Cursor" ? "cube" : provider == "Claude" ? "asterisk" : provider == "OpenAI API" ? "brain.head.profile" : nil
        let mark: NSImage?
        if let symbol {
            mark = NSImage(systemSymbolName: symbol, accessibilityDescription: provider)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 21, weight: .medium).applying(.init(paletteColors: [color])))
        } else {
            let resource = provider == "Grok Bot" ? "icon-grokbot" : "icon-chatgpt"
            let source = Bundle.main.url(forResource: resource, withExtension: "png").flatMap { NSImage(contentsOf: $0) } ?? original
            mark = source.flatMap { foregroundMark($0, grok: provider == "Grok Bot", color: color) }
        }
        guard let mark else { return original }
        let result = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in
            if themed {
                navy.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            }
            let inset: CGFloat = themed ? 5 : 3
            mark.draw(in: bounds.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return true
        }
        result.isTemplate = false
        cache[key] = result
        return result
    }

    /// Extract only the ink, retaining antialiasing. Components touching the
    /// crop edge are app-tile borders/shadows, not part of the provider mark.
    private static func foregroundMark(_ source: NSImage, grok: Bool, color: NSColor) -> NSImage? {
        let n = 256
        guard let input = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        input.bitmapData?.initialize(repeating: 0, count: input.bytesPerRow * n)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: input)
        source.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        let x0 = grok ? 64 : 10, x1 = grok ? 230 : 246
        let y0 = grok ? 78 : 10, y1 = grok ? 202 : 246
        guard let inputBytes = input.bitmapData else { return nil }
        var alpha = [CGFloat](repeating: 0, count: n * n)
        for y in y0..<y1 { for x in x0..<x1 {
            let offset = y * input.bytesPerRow + x * 4
            let a = CGFloat(inputBytes[offset + 3]) / 255
            guard a > 0.05 else { continue }
            let luma = (CGFloat(inputBytes[offset]) * 0.2126 + CGFloat(inputBytes[offset + 1]) * 0.7152 + CGFloat(inputBytes[offset + 2]) * 0.0722) / (255 * a)
            alpha[y * n + x] = max(0, min(1, (0.63 - luma) / 0.25)) * a
        } }
        var seen = [Bool](repeating: false, count: n * n), kept: [Int] = []
        for y in y0..<y1 { for x in x0..<x1 {
            let start = y * n + x
            if seen[start] || alpha[start] < 0.03 { continue }
            var queue = [start], head = 0, edge = false
            seen[start] = true
            while head < queue.count {
                let p = queue[head]; head += 1
                let px = p % n, py = p / n
                if px == x0 || px == x1 - 1 || py == y0 || py == y1 - 1 { edge = true }
                for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
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
        } }
        guard !kept.isEmpty, let tint = color.usingColorSpace(.deviceRGB) else { return nil }
        let minX = kept.map { $0 % n }.min()!, maxX = kept.map { $0 % n }.max()!
        let minY = kept.map { $0 / n }.min()!, maxY = kept.map { $0 / n }.max()!
        let span = max(maxX - minX, maxY - minY) + 5
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: span, pixelsHigh: span, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 0, bitsPerPixel: 0), let outputBytes = output.bitmapData else { return nil }
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
        let mark = NSImage(size: output.size); mark.addRepresentation(output)
        return mark
    }
}

enum StatusBarArtwork {
    static let panel = NSColor(srgbRed: 0.075, green: 0.16, blue: 0.23, alpha: 0.95)
    /// Same capsule, shifted red, when that provider has a meter at 0%.
    static let exhausted = NSColor(srgbRed: 0.30, green: 0.075, blue: 0.08, alpha: 0.95)
    static let track = NSColor(srgbRed: 0.23, green: 0.32, blue: 0.39, alpha: 1)
    static func image(blocks: [StatusBarBlock],
                      dark: Bool = Prefs.darkBarBackground, enlarged: Bool = Prefs.increaseBarSize,
                      dimStale: Bool = false) -> NSImage {
        let iconSize: CGFloat = enlarged ? 14 : 13
        let height: CGFloat = blocks.contains(where: \.design.stacked) ? 24 : 22
        func fonts(for design: StatusBarDesign) -> (NSFont, NSFont) {
            let value = NSFont.monospacedDigitSystemFont(ofSize: design.stacked ? 11 : enlarged ? 12 : 11, weight: .semibold)
            let label = NSFont.systemFont(ofSize: design.stacked ? 10 : enlarged ? 11 : 10, weight: .semibold)
            return (value, label)
        }
        func width(_ text: String, _ f: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: f]).width) }
        func contentWidth(_ b: StatusBarBlock) -> CGFloat {
            let design = b.design
            let (font, labelFont) = fonts(for: design)
            if design.stacked {
                let labels = b.metrics.map { width($0.label, labelFont) }.max() ?? 0
                let values = b.metrics.map { width($0.value, font) }.max() ?? 0
                return labels + 5 + values + ((design == .lanes || design == .segments) && b.metrics.contains(where: { $0.fraction != nil }) ? 60 : 0)
            }
            func rowWidth(_ m: StatusBarMetric) -> CGFloat {
                width(m.label, labelFont) + 4 + width(m.value, font) + (design == .rings && m.fraction != nil ? 21 : 0)
            }
            return b.metrics.map(rowWidth).reduce(0, +) + CGFloat(max(0, b.metrics.count - 1)) * 13 + (design == .focus ? CGFloat(b.metrics.count) * 8 : 0)
        }
        let widths = blocks.map { 7 + iconSize + 7 + contentWidth($0) + 7 }
        let total = max(20, widths.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * 5)
        return NSImage(size: NSSize(width: total, height: height), flipped: true) { _ in
            func text(_ s: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
                (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
            }
            func capsule(_ r: NSRect, _ c: NSColor, radius: CGFloat = 3) {
                c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            }
            func meter(_ m: StatusBarMetric, x: CGFloat, y: CGFloat, width: CGFloat, design: StatusBarDesign) {
                guard let fraction = m.fraction else { return }
                capsule(NSRect(x: x, y: y, width: width, height: 4), track, radius: 2)
                if fraction > 0 { capsule(NSRect(x: x, y: y, width: width * fraction, height: 4), m.color, radius: 2) }
                if design == .segments {
                    for n in 1..<10 { panel.setFill(); NSRect(x: x + CGFloat(n) * width / 10 - 0.7, y: y, width: 1.4, height: 4).fill() }
                }
            }
            var x: CGFloat = 0
            for (index, block) in blocks.enumerated() {
                let design = block.design
                let (font, labelFont) = fonts(for: design)
                let blockHeight: CGFloat = design.stacked ? 24 : 22
                let y0 = (height - blockHeight) / 2
                NSGraphicsContext.saveGraphicsState()
                if block.stale && dimStale { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
                if dark { capsule(NSRect(x: x, y: y0, width: widths[index], height: blockHeight), block.allowanceEmpty ? exhausted : panel, radius: 6) }
                block.icon?.draw(in: NSRect(x: x + 7, y: y0 + (blockHeight - iconSize) / 2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                var cursor = x + 7 + iconSize + 7
                let labels = block.metrics.map { width($0.label, labelFont) }.max() ?? 0
                let values = block.metrics.map { width($0.value, font) }.max() ?? 0
                let minimum = block.metrics.compactMap(\.percent).min()
                for (i, metric) in block.metrics.enumerated() {
                    let rowY: CGFloat = y0 + (design.stacked ? (block.metrics.count == 1 ? 5 : CGFloat(i) * 11 + 1) : 4)
                    if design.stacked {
                        text(metric.label, x: cursor, y: rowY, font: labelFont, color: MenuBarPalette.secondaryLabel)
                        var valueX = cursor + labels + 5
                        if (design == .lanes || design == .segments) && metric.fraction != nil {
                            meter(metric, x: valueX, y: rowY + 4, width: 54, design: design)
                            valueX += 60
                        }
                        text(metric.value, x: valueX + values - width(metric.value, font), y: rowY - 1, font: font, color: metric.color)
                        continue
                    }
                    let rowWidth = width(metric.label, labelFont) + 4 + width(metric.value, font) + (design == .rings && metric.fraction != nil ? 21 : 0)
                    if design == .divider && i > 0 { track.setFill(); NSRect(x: cursor - 7, y: y0 + 5, width: 1, height: 12).fill() }
                    if design == .focus {
                        if metric.percent == minimum && minimum != nil {
                            capsule(NSRect(x: cursor - 3, y: y0 + 2, width: rowWidth + 6, height: 18), metric.color.withAlphaComponent(0.18))
                            capsule(NSRect(x: cursor - 3, y: y0 + 5, width: 2, height: 12), metric.color, radius: 1)
                        }
                        cursor += 3
                    }
                    if design == .rings, let fraction = metric.fraction {
                        let center = NSPoint(x: cursor + 8, y: y0 + 11)
                        let ring = NSBezierPath(ovalIn: NSRect(x: cursor, y: y0 + 3, width: 16, height: 16)); ring.lineWidth = 2.5
                        track.setStroke(); ring.stroke()
                        if fraction > 0 {
                            let arc = NSBezierPath(); arc.lineWidth = 2.5; arc.lineCapStyle = .round
                            arc.appendArc(withCenter: center, radius: 8, startAngle: -90, endAngle: -90 + 360 * fraction, clockwise: false)
                            metric.color.setStroke(); arc.stroke()
                        }
                        cursor += 21
                    }
                    let labelW = width(metric.label, labelFont)
                    text(metric.label, x: cursor, y: rowY + (design == .baseline ? -1 : 1), font: labelFont, color: MenuBarPalette.secondaryLabel)
                    text(metric.value, x: cursor + labelW + 4, y: rowY + (design == .baseline ? -2 : 0), font: font, color: metric.color)
                    if design == .baseline { meter(metric, x: cursor, y: y0 + 18, width: rowWidth, design: design) }
                    cursor += rowWidth - (design == .rings && metric.fraction != nil ? 21 : 0) + 13 + (design == .focus ? 5 : 0)
                }
                NSGraphicsContext.restoreGraphicsState()
                x += widths[index] + 5
            }
            return true
        }
    }
}
