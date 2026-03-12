// CellView.swift — Individual grid cell with glow text, flash, scan-lines (port of display_window.py CellWidget)

import AppKit

final class CellView: NSView {
    let index: Int
    weak var engine: GridEngine?

    private var flashAlpha: CGFloat = 0
    private var fadeTimer: Timer?

    init(index: Int, engine: GridEngine) {
        self.index = index
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Flash

    func triggerFlash() {
        guard engine?.flashEnabled == true else {
            needsDisplay = true
            return
        }
        flashAlpha = 0.95
        needsDisplay = true
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 80.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.flashAlpha = max(0, self.flashAlpha - 0.2)
            self.needsDisplay = true
            if self.flashAlpha <= 0 { t.invalidate() }
        }
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let eng = engine else { return }

        let w = bounds.width
        let h = bounds.height
        let active = eng.activeIndices.contains(index)
        let visible = eng.isCellVisible(index)
        let colorHex = eng.getCellColor(index)
        let color = NSColor(hex: colorHex) ?? .orange

        // Background
        let bgColor = NSColor(hex: eng.bgColor) ?? .black
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        // Scan-line texture on visible cells
        if visible && eng.showBoxes {
            ctx.setFillColor(color.withAlphaComponent(0.06).cgColor)
            var y: CGFloat = 0
            while y < h {
                ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
                y += 4
            }
        }

        // Flash overlay
        if flashAlpha > 0 && visible {
            ctx.setFillColor(color.withAlphaComponent(flashAlpha).cgColor)
            ctx.fill(bounds)
        }

        // Border
        if eng.showBoxes {
            let borderColor: NSColor
            if visible {
                borderColor = color.withAlphaComponent(0.45)
            } else if active {
                borderColor = NSColor(white: 0.13, alpha: 1)
            } else {
                borderColor = NSColor(white: 0.09, alpha: 1)
            }
            ctx.setStrokeColor(borderColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        }

        // Text
        if visible {
            let text = eng.getCellText(index)
            if !text.isEmpty {
                drawText(text, color: color, in: bounds)
            }
        }

        // Custom-mode index badge
        if eng.presetName == "Custom" {
            let badgeColor = active
                ? color.withAlphaComponent(0.63)
                : NSColor(white: 0.16, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "CourierNewPS-BoldMT", size: 7) ?? NSFont.systemFont(ofSize: 7),
                .foregroundColor: badgeColor,
            ]
            NSString(string: "\(index)").draw(at: NSPoint(x: 4, y: 4), withAttributes: attrs)
        }
    }

    private func drawText(_ text: String, color: NSColor, in rect: NSRect) {
        guard let eng = engine else { return }
        let w = rect.width
        let h = rect.height

        var fontSize = CGFloat(max(8, Int(min(w, h) * CGFloat(eng.fontSizePct) / 100.0)))
        var font = NSFont(name: eng.fontFamily, size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)

        // Scale down for long text
        let measureAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let textW = (text as NSString).size(withAttributes: measureAttrs).width
        if textW > w * 0.88 {
            fontSize = max(6, fontSize * (w * 0.88) / max(1, textW))
            font = NSFont(name: eng.fontFamily, size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        }

        // Glow layers
        if eng.glowEnabled {
            for (alpha, spread): (CGFloat, CGFloat) in [(0.09, 7), (0.05, 4)] {
                let glowAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color.withAlphaComponent(alpha),
                ]
                let str = NSAttributedString(string: text, attributes: glowAttrs)
                let sz = str.size()
                let baseX = (w - sz.width) / 2
                let baseY = (h - sz.height) / 2
                for (dx, dy): (CGFloat, CGFloat) in [
                    (-spread, 0), (spread, 0), (0, -spread), (0, spread),
                    (-spread, -spread), (spread, spread),
                ] {
                    str.draw(at: NSPoint(x: baseX + dx, y: baseY + dy))
                }
            }
        }

        // Main text
        let mainAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: mainAttrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: (w - sz.width) / 2, y: (h - sz.height) / 2))
    }

    // MARK: - Mouse (custom mode toggle)

    override func mouseDown(with event: NSEvent) {
        guard engine?.presetName == "Custom" else { return }
        engine?.toggleCustomCell(index)
        needsDisplay = true
    }
}

// MARK: - NSColor hex convenience

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let val = UInt64(s, radix: 16) else { return nil }
        self.init(
            red:   CGFloat((val >> 16) & 0xFF) / 255,
            green: CGFloat((val >> 8)  & 0xFF) / 255,
            blue:  CGFloat(val & 0xFF)          / 255,
            alpha: 1
        )
    }
}
