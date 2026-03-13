// GlyphAtlas.swift — Rasterises printable ASCII into a single r8Unorm MTLTexture.
//
// Layout: 16 columns × 6 rows = 96 slots; chars U+0020–U+007E (space … tilde, 95 glyphs).
// Each glyph slot is glyphW × glyphH pixels. The red channel stores coverage (1=glyph, 0=bg).

import Metal
import AppKit
import CoreText

final class GlyphAtlas {
    // MARK: – Public read-only state
    let texture:  MTLTexture
    let glyphW:   Int          // atlas cell width  in pixels
    let glyphH:   Int          // atlas cell height in pixels
    let baseline: Int          // pixels from cell bottom to text baseline

    // MARK: – Private atlas layout constants
    private static let firstCode  = 32    // U+0020 space
    private static let lastCode   = 126   // U+007E tilde
    private static let glyphCount = 95    // lastCode - firstCode + 1
    private static let atlasCols  = 16
    private static let atlasRows  = 6     // ceil(95 / 16)

    // MARK: – UV lookup

    /// Returns (u, v, width, height) in normalised atlas UV space for `char`.
    func uvRect(for char: Character) -> SIMD4<Float> {
        let code = Int(char.asciiValue ?? 32)
        let safe = max(GlyphAtlas.firstCode, min(code, GlyphAtlas.lastCode))
        let idx  = safe - GlyphAtlas.firstCode
        let col  = idx % GlyphAtlas.atlasCols
        let row  = idx / GlyphAtlas.atlasCols
        let aw   = Float(texture.width)
        let ah   = Float(texture.height)
        return SIMD4<Float>(
            Float(col) * Float(glyphW) / aw,
            Float(row) * Float(glyphH) / ah,
            Float(glyphW) / aw,
            Float(glyphH) / ah
        )
    }

    // MARK: – Init

    /// Rasterises all glyphs using CoreText and uploads to a Metal texture.
    /// Returns nil if Metal texture creation fails.
    init?(device: MTLDevice, fontName: String, pointSize: CGFloat) {
        let pt = max(6.0, pointSize)

        // ── 0. Resolve font first (needed for bounding-box measurement) ──────────
        let resolvedFont: CTFont = {
            let attempt = CTFontCreateWithName(fontName as CFString, pt, nil)
            // CTFontCreateWithName always returns something; verify by PostScript name.
            let psName = CTFontCopyPostScriptName(attempt) as String
            if psName.lowercased().contains("helvetica") && fontName != "Helvetica" {
                return CTFontCreateWithName("Menlo-Bold" as CFString, pt, nil)
            }
            return attempt
        }()

        // ── 1. Measure atlas cell size from the font's own bounding box ──────────
        // CTFontGetBoundingBox returns the union bounding box of all glyphs at `pt`.
        // This avoids hard-coded multipliers that break for wide fonts (e.g. Impact "W").
        let bbox      = CTFontGetBoundingBox(resolvedFont)
        let descender = abs(min(0, bbox.minY))   // pixels below baseline
        let ascender  = max(0, bbox.maxY)         // pixels above baseline
        let pad       = max(2, Int(pt * 0.06))    // small padding (~6 % of pt size)

        let gw = max(4, Int(ceil(bbox.width))  + pad * 2)
        let gh = max(4, Int(ceil(ascender + descender)) + pad * 2)
        let bl = Int(ceil(descender)) + pad       // baseline offset from cell bottom

        self.glyphW   = gw
        self.glyphH   = gh
        self.baseline = bl

        let atlasW = gw * GlyphAtlas.atlasCols
        let atlasH = gh * GlyphAtlas.atlasRows

        // ── 2. Rasterise to an RGBA8 CGContext (easier than single-channel) ──────
        let stride = atlasW * 4
        var rgba   = [UInt8](repeating: 0, count: atlasH * stride)

        guard let ctx = CGContext(
            data: &rgba,
            width: atlasW, height: atlasH,
            bitsPerComponent: 8, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Clear to black
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: atlasW, height: atlasH))

        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: resolvedFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)
        ]

        for code in GlyphAtlas.firstCode...GlyphAtlas.lastCode {
            let idx  = code - GlyphAtlas.firstCode
            let col  = idx % GlyphAtlas.atlasCols
            let row  = idx / GlyphAtlas.atlasCols

            let charStr = String(UnicodeScalar(code)!)
            let line    = CTLineCreateWithAttributedString(
                NSAttributedString(string: charStr, attributes: attrs))

            // CGContext origin is bottom-left; row 0 is at top of atlas image.
            let x = col * gw
            let y = atlasH - (row + 1) * gh + bl   // baseline from cell bottom = bl
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }

        // ── 3. Extract red channel → r8Unorm MTLTexture ──────────────────────────
        var r8 = [UInt8](repeating: 0, count: atlasW * atlasH)
        for i in 0..<(atlasW * atlasH) {
            r8[i] = rgba[i * 4]   // red == glyph coverage (white-on-black)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasW, height: atlasH,
            mipmapped: false)
        desc.usage = .shaderRead

        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(
            region:      MTLRegionMake2D(0, 0, atlasW, atlasH),
            mipmapLevel: 0,
            withBytes:   r8,
            bytesPerRow: atlasW)
        self.texture = tex
    }
}
