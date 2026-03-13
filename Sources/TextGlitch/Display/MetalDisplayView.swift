// MetalDisplayView.swift — Metal-accelerated grid renderer (replaces CellView grid)
//
// Architecture:
//   • One MTKView covers the entire display window.
//   • Per-frame: build a GlyphEntry buffer on CPU (one entry per glyph across all cells),
//     upload, draw totalGlyphs×6 vertices (2 tris per glyph).
//   • Each GlyphEntry carries per-pixel position/size inside its parent cell, so the
//     vertex shader can lay out multi-character tokens without extra draw calls.
//   • Font size is honoured as a visual size: glyphs are centred 1:1 at atlas resolution,
//     never stretched to fill the entire cell.

import MetalKit
import Combine
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – GPU struct layout  (must mirror the Metal structs in shaderSrc below)
// ─────────────────────────────────────────────────────────────────────────────

/// One entry per glyph in the frame buffer.
/// Multiple entries can share the same gridCellIdx for multi-char tokens.
struct GlyphEntry {                       // Swift / Metal offset
    var atlasUV:     SIMD2<Float>         //  0..7   UV top-left of glyph in atlas
    var atlasSize:   SIMD2<Float>         //  8..15  UV width/height of glyph
    var color:       SIMD4<Float>         // 16..31  linear RGBA
    var flashAlpha:  Float                // 32..35
    var flags:       UInt32               // 36..39  bit0=border
    var gridCellIdx: UInt32               // 40..43  which grid cell this glyph belongs to
    var _pad:        UInt32 = 0           // 44..47  padding for float2 alignment
    var glyphOffset: SIMD2<Float>         // 48..55  pixel offset from cell origin (top-left)
    var glyphSize:   SIMD2<Float>         // 56..63  rendered pixel size of this glyph quad
    // Total: 64 bytes  (stride = 64, aligns to 16 for float4)
}

/// Frame-level constants — unchanged at 56 bytes so existing trail/blit pipelines are unaffected.
struct MetalUniforms {
    var viewportSize:   SIMD2<Float>   //  8 bytes
    var cols:           UInt32         //  4 bytes
    var rows:           UInt32         //  4 bytes
    var cellSize:       SIMD2<Float>   //  8 bytes
    var gridOrigin:     SIMD2<Float>   //  8 bytes
    var cellSpacing:    Float          //  4 bytes
    var glowStrength:   Float          //  4 bytes  0=off  1=full glow
    var scanStrength:   Float          //  4 bytes  0=off  1=full scanlines
    var chromaStrength: Float          //  4 bytes  0=off  N=pixel offset
    var strobeAlpha:    Float          //  4 bytes  0=off  0.85=on
    var brightness:     Float          //  4 bytes  1.0=normal
    // Total: 56 bytes
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Embedded Metal shader source
// ─────────────────────────────────────────────────────────────────────────────

private let shaderSrc = """
#include <metal_stdlib>
using namespace metal;

// One entry per glyph; multiple per visual cell for multi-char tokens.
struct GlyphEntry {
    float2 atlasUV;
    float2 atlasSize;
    float4 color;
    float  flashAlpha;
    uint   flags;
    uint   gridCellIdx;
    uint   _pad;
    float2 glyphOffset;   // pixel offset from cell origin (top-left)
    float2 glyphSize;     // rendered pixel size of this glyph quad
};

struct MetalUniforms {
    float2 viewportSize;
    uint   cols;
    uint   rows;
    float2 cellSize;
    float2 gridOrigin;
    float  cellSpacing;
    float  glowStrength;
    float  scanStrength;
    float  chromaStrength;
    float  strobeAlpha;
    float  brightness;
};

struct VertOut {
    float4 pos        [[position]];
    float2 atlasUV;
    float2 atlasSize;
    float2 cellUV;        // 0..1 within the full cell (for border/scanline effects)
    float2 glyphPxSize;   // rendered pixel size of this glyph (for chroma calc)
    float4 color;
    float  flashAlpha;
    uint   flags      [[flat]];
};

// ── Vertex: 6 verts per glyph entry (2 triangles) ────────────────────────────
vertex VertOut vert_cell(
    uint                    vid     [[vertex_id]],
    constant GlyphEntry*    entries [[buffer(0)]],
    constant MetalUniforms& u       [[buffer(1)]]
) {
    uint   entryIdx = vid / 6u;
    uint   localVid = vid % 6u;

    // Two CCW triangles forming a quad: indices 0-1-2, 2-1-3
    const float2 corners[4] = { {0,0},{1,0},{0,1},{1,1} };
    const uint   tris[6]    = { 0,1,2, 2,1,3 };
    float2 corner = corners[tris[localVid]];

    GlyphEntry e = entries[entryIdx];

    uint col = e.gridCellIdx % u.cols;
    uint row = e.gridCellIdx / u.cols;

    // Top-left pixel of the grid cell
    float2 cellOrigin = u.gridOrigin + float2(
        float(col) * (u.cellSize.x + u.cellSpacing),
        float(row) * (u.cellSize.y + u.cellSpacing)
    );

    // Position the glyph quad inside the cell using per-entry offset + size
    float2 pixPos = cellOrigin + e.glyphOffset + corner * e.glyphSize;

    // Metal NDC: y+ = up, pixel y+ = down
    float2 ndc = float2(
         pixPos.x / u.viewportSize.x * 2.0 - 1.0,
        -pixPos.y / u.viewportSize.y * 2.0 + 1.0
    );

    VertOut out;
    out.pos         = float4(ndc, 0.0, 1.0);
    out.atlasUV     = e.atlasUV + corner * e.atlasSize;
    out.atlasSize   = e.atlasSize;
    // cellUV: normalised position within the full cell (not just the glyph quad)
    out.cellUV      = (e.glyphOffset + corner * e.glyphSize) / u.cellSize;
    out.glyphPxSize = e.glyphSize;
    out.color       = e.color;
    out.flashAlpha  = e.flashAlpha;
    out.flags       = e.flags;
    return out;
}

// ── Fragment: glyph · glow · chroma · scanlines · border · flash ─────────────
fragment float4 frag_cell(
    VertOut                              in    [[stage_in]],
    texture2d<float, access::sample>     atlas [[texture(0)]],
    constant MetalUniforms&              u     [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);

    // ── Chromatic aberration: R and B channels shifted ±N pixels horizontally.
    // atlas UV per screen pixel = atlasSize / glyphPxSize (1:1 pixel rendering).
    float2 atlasPerPx = in.atlasSize / max(in.glyphPxSize, float2(1.0));
    float2 chromaOff  = atlasPerPx * float2(u.chromaStrength, 0.0);
    float rCov    = atlas.sample(s, in.atlasUV + chromaOff).r;
    float glyphCov = atlas.sample(s, in.atlasUV).r;
    float bCov    = atlas.sample(s, in.atlasUV - chromaOff).r;

    // ── Soft glow: 8-neighbour samples at ~3 atlas pixels ────────────────────
    float2 px = 1.0 / float2(atlas.get_width(), atlas.get_height());
    float glow = 0.0;
    glow += atlas.sample(s, in.atlasUV + px * float2( 3,  0)).r;
    glow += atlas.sample(s, in.atlasUV + px * float2(-3,  0)).r;
    glow += atlas.sample(s, in.atlasUV + px * float2( 0,  3)).r;
    glow += atlas.sample(s, in.atlasUV + px * float2( 0, -3)).r;
    glow += atlas.sample(s, in.atlasUV + px * float2( 2,  2)).r;
    glow += atlas.sample(s, in.atlasUV + px * float2(-2,  2)).r;
    glow += atlas.sample(s, in.atlasUV + px * float2( 2, -2)).r;
    glow += atlas.sample(s, in.atlasUV + px * float2(-2, -2)).r;
    glow = saturate(glow / 5.0) * u.glowStrength;

    // ── Composite glyph + glow ────────────────────────────────────────────────
    float3 rgb = float3(in.color.r * rCov, in.color.g * glyphCov, in.color.b * bCov)
               + in.color.rgb * glow * 0.38;
    float  a   = saturate((rCov + glyphCov + bCov) / 3.0 + glow * 0.28);

    // ── Scanlines: dim every 4th row ─────────────────────────────────────────
    float scanDim = (uint(in.pos.y) % 4u == 0u) ? (1.0 - 0.72 * u.scanStrength) : 1.0;
    rgb *= scanDim;

    // ── Cell border: ~1.5 px dark ring at cell edge (not glyph quad edge) ────
    if ((in.flags & 1u) != 0u) {
        float2 bEdge = min(in.cellUV, 1.0 - in.cellUV);
        float2 bPx   = float2(1.5 / u.cellSize.x, 1.5 / u.cellSize.y);
        if (bEdge.x < bPx.x || bEdge.y < bPx.y) {
            rgb *= 0.35;
            a    = max(a, 0.28);
        }
    }

    // ── Flash: bright colour burst on tick ───────────────────────────────────
    if (in.flashAlpha > 0.001) {
        rgb = mix(rgb, in.color.rgb * 1.6, in.flashAlpha * 0.55);
        a   = max(a, in.flashAlpha * 0.42);
    }

    // ── Brightness multiplier ─────────────────────────────────────────────────
    rgb *= u.brightness;

    // ── Strobe: white pulse overlay on every other tick ──────────────────────
    if (u.strobeAlpha > 0.001) {
        rgb = mix(rgb, float3(1.0), u.strobeAlpha);
        a   = max(a, u.strobeAlpha * 0.9);
    }

    return float4(rgb, a);
}

// ─────────────────────────────────────────────────────────────────────────────
// Trail support: fade quad + blit quad
// ─────────────────────────────────────────────────────────────────────────────

vertex float4 vert_quad(uint vid [[vertex_id]]) {
    const float2 pos[6] = { {-1,-1},{1,-1},{-1,1}, {-1,1},{1,-1},{1,1} };
    return float4(pos[vid], 0.0, 1.0);
}

fragment float4 frag_fade(
    float4          fragCoord  [[position]],
    constant float& fadeAlpha  [[buffer(0)]]
) {
    return float4(0.0, 0.0, 0.0, fadeAlpha);
}

struct BlitOut { float4 pos [[position]]; float2 uv; };

vertex BlitOut vert_blit(uint vid [[vertex_id]]) {
    const float2 pos[6] = { {-1,-1},{1,-1},{-1,1}, {-1,1},{1,-1},{1,1} };
    const float2 uv[6]  = { {0,1},{1,1},{0,0}, {0,0},{1,1},{1,0} };
    BlitOut out;
    out.pos = float4(pos[vid], 0.0, 1.0);
    out.uv  = uv[vid];
    return out;
}

fragment float4 frag_blit(
    BlitOut                              in  [[stage_in]],
    texture2d<float, access::sample>     tex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}
"""

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – MetalDisplayView
// ─────────────────────────────────────────────────────────────────────────────

final class MetalDisplayView: MTKView, MTKViewDelegate {

    // MARK: – Engine link
    private weak var engine: GridEngine?
    private var cancellables = Set<AnyCancellable>()

    // MARK: – Metal objects
    private var cmdQueue:     MTLCommandQueue!
    private var pipeline:     MTLRenderPipelineState!
    private var fadePipeline: MTLRenderPipelineState!
    private var blitPipeline: MTLRenderPipelineState!
    private var glyphBuf:     MTLBuffer?
    private var uniformBuf:   MTLBuffer?

    // MARK: – Trail
    private var trailTex:     MTLTexture?
    private var trailTexSize: CGSize = .zero

    // MARK: – Strobe
    private var strobePhase = false

    // MARK: – Glyph atlas
    private var atlas:       GlyphAtlas?
    private var atlasFont:   String  = ""
    private var atlasPtSize: CGFloat = 0

    // MARK: – Per-frame state
    private var entries:     [GlyphEntry] = []
    private var flashAlphas: [Float]      = []
    private var needsRebuild = true

    // MARK: – Configure

    func configure(engine: GridEngine) {
        self.engine = engine

        guard let dev = self.device else {
            print("[MetalDisplayView] No Metal device — display disabled.")
            return
        }

        self.delegate                 = self
        self.preferredFramesPerSecond = 60
        self.colorPixelFormat         = .bgra8Unorm
        self.clearColor               = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.framebufferOnly          = false
        self.isPaused                 = false
        self.enableSetNeedsDisplay    = false

        guard let q = dev.makeCommandQueue() else {
            print("[MetalDisplayView] Cannot create command queue.")
            return
        }
        cmdQueue = q
        buildPipeline(device: dev)
        subscribeEngine()
    }

    // MARK: – Pipeline

    private func buildPipeline(device dev: MTLDevice) {
        let lib: MTLLibrary
        do {
            lib = try dev.makeLibrary(source: shaderSrc, options: nil)
        } catch {
            fatalError("[MetalDisplayView] Shader compile error: \(error)")
        }

        // ── Cell renderer (standard alpha blend) ─────────────────────────────
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction   = lib.makeFunction(name: "vert_cell")!
        pd.fragmentFunction = lib.makeFunction(name: "frag_cell")!
        pd.colorAttachments[0].pixelFormat                 = colorPixelFormat
        pd.colorAttachments[0].isBlendingEnabled           = true
        pd.colorAttachments[0].rgbBlendOperation           = .add
        pd.colorAttachments[0].alphaBlendOperation         = .add
        pd.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor      = .sourceAlpha
        pd.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // ── Fade quad (trail decay) ───────────────────────────────────────────
        let fpd = MTLRenderPipelineDescriptor()
        fpd.vertexFunction   = lib.makeFunction(name: "vert_quad")!
        fpd.fragmentFunction = lib.makeFunction(name: "frag_fade")!
        fpd.colorAttachments[0].pixelFormat                 = colorPixelFormat
        fpd.colorAttachments[0].isBlendingEnabled           = true
        fpd.colorAttachments[0].rgbBlendOperation           = .add
        fpd.colorAttachments[0].alphaBlendOperation         = .add
        fpd.colorAttachments[0].sourceRGBBlendFactor        = .zero
        fpd.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        fpd.colorAttachments[0].sourceAlphaBlendFactor      = .zero
        fpd.colorAttachments[0].destinationAlphaBlendFactor = .one

        // ── Blit quad (trail → drawable) ──────────────────────────────────────
        let bpd = MTLRenderPipelineDescriptor()
        bpd.vertexFunction   = lib.makeFunction(name: "vert_blit")!
        bpd.fragmentFunction = lib.makeFunction(name: "frag_blit")!
        bpd.colorAttachments[0].pixelFormat       = colorPixelFormat
        bpd.colorAttachments[0].isBlendingEnabled = false

        do {
            pipeline     = try dev.makeRenderPipelineState(descriptor: pd)
            fadePipeline = try dev.makeRenderPipelineState(descriptor: fpd)
            blitPipeline = try dev.makeRenderPipelineState(descriptor: bpd)
        } catch {
            fatalError("[MetalDisplayView] Pipeline error: \(error)")
        }
    }

    // MARK: – Engine subscriptions

    private func subscribeEngine() {
        guard let eng = engine else { return }

        eng.ticked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let eng = self.engine else { return }
                if eng.flashEnabled {
                    let activeSet = Set(eng.visibleIndices)
                    for i in 0..<self.flashAlphas.count where activeSet.contains(i) {
                        self.flashAlphas[i] = 0.88
                    }
                }
                self.strobePhase = eng.strobeEnabled ? !self.strobePhase : false
            }
            .store(in: &cancellables)

        eng.displayChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.needsRebuild = true }
            .store(in: &cancellables)
    }

    // MARK: – MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRebuild = true
        trailTex     = nil
    }

    func draw(in view: MTKView) {
        guard
            let eng      = engine,
            let dev      = view.device,
            let drawable = view.currentDrawable,
            let rpd      = view.currentRenderPassDescriptor
        else { return }

        // ── 1. Atlas: rebuild if font or size changed ─────────────────────────
        let ptSize = computeFontPointSize(engine: eng, viewHeight: view.drawableSize.height)
        if atlas == nil || eng.fontFamily != atlasFont || abs(ptSize - atlasPtSize) > 0.5 {
            atlas       = GlyphAtlas(device: dev, fontName: eng.fontFamily, pointSize: ptSize)
            atlasFont   = eng.fontFamily
            atlasPtSize = ptSize
            needsRebuild = true
        }

        // ── 2. Resize flash-alpha array if cell count changed ─────────────────
        let n = eng.cellCount
        if flashAlphas.count != n { flashAlphas = Array(repeating: 0, count: n) }

        // ── 3. Decay flash alphas (60 fps, fades in ~½ sec) ──────────────────
        for i in 0..<flashAlphas.count { flashAlphas[i] *= 0.88 }

        guard n > 0 else { return }

        // ── 4. Build per-glyph entry buffer ───────────────────────────────────
        //
        // Each visible cell contributes one GlyphEntry per printable character in
        // its token, laid out horizontally inside the cell at natural atlas size
        // (font size percentage controls the visual size of the glyphs).
        //
        let vSize   = view.drawableSize
        let spacing = Float(eng.showBoxes ? 1 : 0)
        let cols    = Float(eng.gridCols)
        let rows    = Float(eng.gridRows)
        let cellW   = (Float(vSize.width)  - spacing * (cols - 1)) / cols
        let cellH   = (Float(vSize.height) - spacing * (rows - 1)) / rows

        let atW = Float(atlas?.glyphW ?? 16)    // atlas cell pixel width
        let atH = Float(atlas?.glyphH ?? 24)    // atlas cell pixel height

        let spaceUV = atlas?.uvRect(for: " ") ?? SIMD4<Float>(0, 0, 0.001, 0.001)
        let batch   = eng.batchCellDisplayData()
        let blanked = eng.blankedCells
        let visible = Set(eng.visibleIndices)

        entries.removeAll(keepingCapacity: true)

        for i in 0..<n {
            let (text, hex) = batch[i]
            let isBlank     = blanked.contains(i) || !visible.contains(i)

            // Color
            let color: SIMD4<Float>
            if isBlank {
                color = .zero
            } else {
                let nsColor = (NSColor(hex: hex) ?? .orange).usingColorSpace(.sRGB) ?? .orange
                color = SIMD4<Float>(
                    Float(nsColor.redComponent),
                    Float(nsColor.greenComponent),
                    Float(nsColor.blueComponent),
                    1)
            }

            // Collect printable ASCII glyphs from the token
            let glyphs: [Character] = isBlank
                ? [" "]
                : Array(text.filter { $0.isASCII && ($0.asciiValue ?? 0) >= 32 }.prefix(16))
            let glyphList = glyphs.isEmpty ? [Character(" ")] : glyphs
            let nGlyphs   = glyphList.count

            // Horizontal glyph layout within the cell.
            // Each glyph occupies slotW × cellH pixels; scaled down to fit, no upscaling.
            let slotW  = cellW / Float(nGlyphs)
            let scaleX = slotW  < atW ? slotW / atW : 1.0
            let scaleY = cellH  < atH ? cellH / atH : 1.0
            let scale  = min(scaleX, scaleY)
            let rendW  = atW * scale
            let rendH  = atH * scale

            var flags: UInt32 = 0
            if eng.showBoxes && !isBlank { flags |= 1 }

            for (j, ch) in glyphList.enumerated() {
                let uv       = atlas?.uvRect(for: ch) ?? spaceUV
                let slotX    = Float(j) * slotW
                let offsetX  = slotX  + (slotW - rendW) / 2   // centre in slot
                let offsetY  = (cellH - rendH) / 2             // centre vertically

                entries.append(GlyphEntry(
                    atlasUV:     SIMD2(uv.x, uv.y),
                    atlasSize:   SIMD2(uv.z, uv.w),
                    color:       isBlank ? .zero : color,
                    flashAlpha:  isBlank ? 0 : flashAlphas[i],
                    flags:       flags,
                    gridCellIdx: UInt32(i),
                    _pad:        0,
                    glyphOffset: SIMD2(offsetX, offsetY),
                    glyphSize:   SIMD2(rendW,   rendH)
                ))
            }
        }

        // ── 5. Upload glyph buffer ────────────────────────────────────────────
        let entryBytes = entries.count * MemoryLayout<GlyphEntry>.stride
        if glyphBuf == nil || glyphBuf!.length < entryBytes {
            glyphBuf = dev.makeBuffer(length: max(entryBytes, 64), options: .storageModeShared)
        }
        if entryBytes > 0 {
            glyphBuf?.contents().copyMemory(from: entries, byteCount: entryBytes)
        }

        // ── 6. Uniforms ───────────────────────────────────────────────────────
        var uniforms = MetalUniforms(
            viewportSize:   SIMD2(Float(vSize.width), Float(vSize.height)),
            cols:           UInt32(eng.gridCols),
            rows:           UInt32(eng.gridRows),
            cellSize:       SIMD2(cellW, cellH),
            gridOrigin:     .zero,
            cellSpacing:    spacing,
            glowStrength:   eng.glowEnabled        ? 1.0 : 0.0,
            scanStrength:   eng.scanLinesEnabled   ? 1.0 : 0.0,
            chromaStrength: eng.chromaticAberration ? 3.0 : 0.0,
            strobeAlpha:    (eng.strobeEnabled && strobePhase) ? 0.88 : 0.0,
            brightness:     eng.brightness)
        uniformBuf = dev.makeBuffer(bytes: &uniforms,
                                    length: MemoryLayout<MetalUniforms>.size,
                                    options: .storageModeShared)

        // ── 7. Background clear colour ────────────────────────────────────────
        let bgSRGB = (NSColor(hex: eng.bgColor) ?? .black).usingColorSpace(.sRGB) ?? .black
        let bgClear = MTLClearColor(
            red:   bgSRGB.redComponent,
            green: bgSRGB.greenComponent,
            blue:  bgSRGB.blueComponent,
            alpha: 1)

        // ── 8. Encode & present ───────────────────────────────────────────────
        guard let cmdbuf = cmdQueue.makeCommandBuffer() else { return }

        if eng.trailEnabled {
            ensureTrailTexture(device: dev, size: view.drawableSize)
            guard let trail = trailTex else { return }

            var fadeAlpha: Float = 1.0 - eng.trailDecay
            let fadeRPD = makeSingleTextureRPD(trail, load: .load)
            if let enc = cmdbuf.makeRenderCommandEncoder(descriptor: fadeRPD) {
                enc.setRenderPipelineState(fadePipeline)
                enc.setFragmentBytes(&fadeAlpha, length: MemoryLayout<Float>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }

            let cellRPD = makeSingleTextureRPD(trail, load: .load)
            if let enc = cmdbuf.makeRenderCommandEncoder(descriptor: cellRPD) {
                encodeGlyphs(enc)
                enc.endEncoding()
            }

            rpd.colorAttachments[0].clearColor = bgClear
            if let enc = cmdbuf.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(blitPipeline)
                enc.setFragmentTexture(trail, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }
        } else {
            rpd.colorAttachments[0].clearColor = bgClear
            if let enc = cmdbuf.makeRenderCommandEncoder(descriptor: rpd) {
                encodeGlyphs(enc)
                enc.endEncoding()
            }
        }

        cmdbuf.present(drawable)
        cmdbuf.commit()
    }

    // MARK: – Helpers

    private func computeFontPointSize(engine eng: GridEngine, viewHeight: CGFloat) -> CGFloat {
        let cellH = (viewHeight - CGFloat(eng.gridRows - 1)) / CGFloat(max(1, eng.gridRows))
        return max(6, cellH * CGFloat(eng.fontSizePct) / 100.0)
    }

    private func encodeGlyphs(_ enc: MTLRenderCommandEncoder) {
        guard !entries.isEmpty else { return }
        enc.setRenderPipelineState(pipeline)
        if let gb = glyphBuf  { enc.setVertexBuffer(gb,  offset: 0, index: 0) }
        if let ub = uniformBuf {
            enc.setVertexBuffer(ub, offset: 0, index: 1)
            enc.setFragmentBuffer(ub, offset: 0, index: 1)
        }
        if let atlasTex = atlas?.texture { enc.setFragmentTexture(atlasTex, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: entries.count * 6)
    }

    private func makeSingleTextureRPD(_ tex: MTLTexture,
                                       load: MTLLoadAction) -> MTLRenderPassDescriptor {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture     = tex
        rpd.colorAttachments[0].loadAction  = load
        rpd.colorAttachments[0].storeAction = .store
        if load == .clear {
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return rpd
    }

    private func ensureTrailTexture(device dev: MTLDevice, size: CGSize) {
        guard trailTex == nil || trailTexSize != size else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat,
            width:       max(1, Int(size.width)),
            height:      max(1, Int(size.height)),
            mipmapped:   false)
        desc.usage       = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        trailTex     = dev.makeTexture(descriptor: desc)
        trailTexSize = size

        if let tex = trailTex,
           let cb  = cmdQueue.makeCommandBuffer() {
            let clearRPD = makeSingleTextureRPD(tex, load: .clear)
            if let enc = cb.makeRenderCommandEncoder(descriptor: clearRPD) { enc.endEncoding() }
            cb.commit()
        }
    }
}
