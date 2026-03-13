// MetalDisplayView.swift — Metal-accelerated grid renderer (replaces CellView grid)
//
// Architecture:
//   • One MTKView covers the entire display window.
//   • Per-frame: build a CellData buffer on CPU, upload, draw N×6 vertices (2 tris per cell).
//   • Vertex shader computes each cell quad from cell index + uniforms.
//   • Fragment shader: glyph atlas sample · colour tint · scanlines · glow · flash overlay.
//   • Shaders compiled at runtime from the embedded string (SPM-compatible, no .metal files needed).

import MetalKit
import Combine
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – GPU struct layout  (must mirror the Metal structs in shaderSrc below)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-cell data uploaded to the GPU each frame.
struct CellData {
    var atlasUV:    SIMD2<Float>   //  8 bytes – UV top-left of glyph in atlas
    var atlasSize:  SIMD2<Float>   //  8 bytes – UV width/height of glyph
    var color:      SIMD4<Float>   // 16 bytes – linear RGBA
    var flashAlpha: Float          //  4 bytes
    var flags:      UInt32         //  4 bytes – bit0 = show border, bit1 = blank
    // Total: 40 bytes
}

/// Frame-level constants.
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

struct CellData {
    float2 atlasUV;
    float2 atlasSize;
    float4 color;
    float  flashAlpha;
    uint   flags;
};

struct MetalUniforms {
    float2 viewportSize;
    uint   cols;
    uint   rows;
    float2 cellSize;
    float2 gridOrigin;
    float  cellSpacing;
    float  glowStrength;    // 0=off  1=full
    float  scanStrength;    // 0=off  1=full
    float  chromaStrength;  // 0=off  N=pixel-offset amount
    float  strobeAlpha;     // 0=off  >0=white flash overlay
    float  brightness;      // 1.0=normal  >1=over-bright
};

struct VertOut {
    float4 pos        [[position]];
    float2 atlasUV;
    float2 atlasSize;   // passed through for chromatic aberration calc
    float2 cellUV;      // 0..1 within the cell, for border edge detection
    float4 color;
    float  flashAlpha;
    uint   flags;
};

// ── Vertex: 6 verts per cell (2 triangles) ───────────────────────────────────
vertex VertOut vert_cell(
    uint                    vid   [[vertex_id]],
    constant CellData*      cells [[buffer(0)]],
    constant MetalUniforms& u     [[buffer(1)]]
) {
    uint   cellIdx  = vid / 6u;
    uint   localVid = vid % 6u;

    // Two CCW triangles: 0-1-2, 2-1-3
    const float2 corners[4] = { {0,0},{1,0},{0,1},{1,1} };
    const uint   tris[6]    = { 0,1,2, 2,1,3 };
    float2 corner = corners[tris[localVid]];

    uint col = cellIdx % u.cols;
    uint row = cellIdx / u.cols;

    float2 origin = u.gridOrigin + float2(
        float(col) * (u.cellSize.x + u.cellSpacing),
        float(row) * (u.cellSize.y + u.cellSpacing)
    );
    float2 pixPos = origin + corner * u.cellSize;

    // Metal NDC: y+ = up, pixel y+ = down
    float2 ndc = float2(
         pixPos.x / u.viewportSize.x * 2.0 - 1.0,
        -pixPos.y / u.viewportSize.y * 2.0 + 1.0
    );

    CellData c = cells[cellIdx];

    VertOut out;
    out.pos        = float4(ndc, 0.0, 1.0);
    out.atlasUV    = c.atlasUV + corner * c.atlasSize;
    out.atlasSize  = c.atlasSize;
    out.cellUV     = corner;
    out.color      = c.color;
    out.flashAlpha = c.flashAlpha;
    out.flags      = c.flags;
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
    // When chromaStrength == 0 the offset is zero and all three equal glyphCov.
    float2 atlasPerPx = in.atlasSize / u.cellSize;
    float2 chromaOff  = atlasPerPx * float2(u.chromaStrength, 0.0);
    float rCov = atlas.sample(s, in.atlasUV + chromaOff).r;
    float glyphCov = atlas.sample(s, in.atlasUV).r;
    float bCov = atlas.sample(s, in.atlasUV - chromaOff).r;

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

    // ── Cell border: ~1.5 px dark ring (flags bit 0) ─────────────────────────
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

// vert_quad / frag_fade — draws a full-screen solid-colour quad.
// Used to darken the trail texture by trailDecay each frame via alpha blending.
vertex float4 vert_quad(uint vid [[vertex_id]]) {
    const float2 pos[6] = { {-1,-1},{1,-1},{-1,1}, {-1,1},{1,-1},{1,1} };
    return float4(pos[vid], 0.0, 1.0);
}

fragment float4 frag_fade(
    float4         fragCoord [[position]],
    constant float& fadeAlpha [[buffer(0)]]
) {
    // Black with alpha=(1-trailDecay): blending multiplies dst by trailDecay.
    return float4(0.0, 0.0, 0.0, fadeAlpha);
}

// vert_blit / frag_blit — copies a texture to the full screen.
struct BlitOut { float4 pos [[position]]; float2 uv; };

vertex BlitOut vert_blit(uint vid [[vertex_id]]) {
    const float2 pos[6] = { {-1,-1},{1,-1},{-1,1}, {-1,1},{1,-1},{1,1} };
    // UV: Metal texture origin is top-left; NDC y+ = up, so flip V.
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
    private var pipeline:     MTLRenderPipelineState!   // cell renderer
    private var fadePipeline: MTLRenderPipelineState!   // trail fade quad
    private var blitPipeline: MTLRenderPipelineState!   // trail → drawable blit
    private var cellBuf:      MTLBuffer?
    private var uniformBuf:   MTLBuffer?

    // MARK: – Trail
    private var trailTex:      MTLTexture?
    private var trailTexSize:  CGSize = .zero
    private var trailNeedsInit = false

    // MARK: – Strobe
    private var strobePhase = false

    // MARK: – Glyph atlas
    private var atlas:        GlyphAtlas?
    private var atlasFont:    String  = ""
    private var atlasPtSize:  CGFloat = 0

    // MARK: – Per-frame cell state
    private var cellData:    [CellData] = []
    private var flashAlphas: [Float]    = []
    private var needsRebuild = true

    // MARK: – Configure (call once after init)

    func configure(engine: GridEngine) {
        self.engine = engine

        guard let dev = self.device else {
            print("[MetalDisplayView] No Metal device — display disabled.")
            return
        }

        self.delegate                  = self
        self.preferredFramesPerSecond  = 60
        self.colorPixelFormat          = .bgra8Unorm
        self.clearColor                = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.framebufferOnly           = false
        self.isPaused                  = false
        self.enableSetNeedsDisplay     = false

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

        // ── Fade quad (trail decay): src=0, dst *= oneMinusSourceAlpha ────────
        // A black quad with alpha=(1-decay) multiplies the trail by `decay`.
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

        // ── Blit quad (trail → drawable, no blending) ─────────────────────────
        let bpd = MTLRenderPipelineDescriptor()
        bpd.vertexFunction   = lib.makeFunction(name: "vert_blit")!
        bpd.fragmentFunction = lib.makeFunction(name: "frag_blit")!
        bpd.colorAttachments[0].pixelFormat      = colorPixelFormat
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
                // Flash
                if eng.flashEnabled {
                    let activeSet = Set(eng.visibleIndices)
                    for i in 0..<self.flashAlphas.count where activeSet.contains(i) {
                        self.flashAlphas[i] = 0.88
                    }
                }
                // Strobe: flip phase on every tick
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
        trailTex     = nil      // force recreation at new drawable size
        trailNeedsInit = false
    }

    func draw(in view: MTKView) {
        guard
            let eng      = engine,
            let dev      = view.device,
            let drawable = view.currentDrawable,
            let rpd      = view.currentRenderPassDescriptor
        else { return }

        // ── 1. Atlas: rebuild if font or size changed ──────────────────────
        let ptSize = computeFontPointSize(engine: eng, viewHeight: view.bounds.height)
        if atlas == nil || eng.fontFamily != atlasFont || abs(ptSize - atlasPtSize) > 0.5 {
            atlas       = GlyphAtlas(device: dev, fontName: eng.fontFamily, pointSize: ptSize)
            atlasFont   = eng.fontFamily
            atlasPtSize = ptSize
            needsRebuild = true
        }

        // ── 2. Cell data: rebuild on grid/preset/text changes ─────────────
        let n = eng.cellCount
        if needsRebuild || cellData.count != n {
            cellData    = Array(repeating: .init(atlasUV: .zero, atlasSize: .zero,
                                                 color: .zero, flashAlpha: 0, flags: 0),
                                count: n)
            if flashAlphas.count != n { flashAlphas = Array(repeating: 0, count: n) }
            needsRebuild = false
        }

        // ── 3. Decay flash alphas (60 fps → ~0.88^60 ≈ fades in ~½ sec) ──
        for i in 0..<flashAlphas.count { flashAlphas[i] *= 0.88 }

        // ── 4. Fill cell buffer from engine state ─────────────────────────
        guard n > 0 else { return }

        let spaceUV = atlas?.uvRect(for: " ") ?? SIMD4<Float>(0, 0, 0.001, 0.001)
        let batch   = eng.batchCellDisplayData()     // O(n) batched fetch
        let blanked = eng.blankedCells
        let visible = Set(eng.visibleIndices)

        for i in 0..<n {
            let (text, hex) = batch[i]
            let isBlank     = blanked.contains(i) || !visible.contains(i)

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

            // Pick first printable ASCII char from the token (atlas supports ASCII only)
            let glyph = text.first(where: { $0.isASCII && $0.asciiValue ?? 0 >= 32 }) ?? " "
            let uv    = atlas?.uvRect(for: glyph) ?? spaceUV

            var flags: UInt32 = 0
            if eng.showBoxes && !isBlank { flags |= 1 }

            cellData[i] = CellData(
                atlasUV:    SIMD2(uv.x, uv.y),
                atlasSize:  SIMD2(uv.z, uv.w),
                color:      isBlank ? .zero : color,
                flashAlpha: isBlank ? 0 : flashAlphas[i],
                flags:      flags)
        }

        // ── 5. Upload cell buffer ─────────────────────────────────────────
        let cellBytes = n * MemoryLayout<CellData>.stride
        if cellBuf == nil || cellBuf!.length < cellBytes {
            cellBuf = dev.makeBuffer(length: cellBytes, options: .storageModeShared)
        }
        cellBuf?.contents().copyMemory(from: cellData, byteCount: cellBytes)

        // ── 6. Uniforms ───────────────────────────────────────────────────
        let vSize    = view.drawableSize
        let spacing: Float = eng.showBoxes ? 1 : 0
        let cols     = Float(eng.gridCols)
        let rows     = Float(eng.gridRows)
        let cellW    = (Float(vSize.width)  - spacing * (cols - 1)) / cols
        let cellH    = (Float(vSize.height) - spacing * (rows - 1)) / rows
        var uniforms = MetalUniforms(
            viewportSize:   SIMD2(Float(vSize.width), Float(vSize.height)),
            cols:           UInt32(eng.gridCols),
            rows:           UInt32(eng.gridRows),
            cellSize:       SIMD2(cellW, cellH),
            gridOrigin:     .zero,
            cellSpacing:    spacing,
            glowStrength:   eng.glowEnabled         ? 1.0 : 0.0,
            scanStrength:   eng.scanLinesEnabled     ? 1.0 : 0.0,
            chromaStrength: eng.chromaticAberration  ? 3.0 : 0.0,
            strobeAlpha:    (eng.strobeEnabled && strobePhase) ? 0.88 : 0.0,
            brightness:     eng.brightness)
        uniformBuf = dev.makeBuffer(bytes: &uniforms,
                                    length: MemoryLayout<MetalUniforms>.size,
                                    options: .storageModeShared)

        // ── 7. Background clear colour (applied to drawable in step 8) ───────
        let bgSRGB = (NSColor(hex: eng.bgColor) ?? .black).usingColorSpace(.sRGB) ?? .black
        let bgClear = MTLClearColor(
            red:   bgSRGB.redComponent,
            green: bgSRGB.greenComponent,
            blue:  bgSRGB.blueComponent,
            alpha: 1)

        // ── 8. Encode & present ───────────────────────────────────────────
        guard let cmdbuf = cmdQueue.makeCommandBuffer() else { return }

        if eng.trailEnabled {
            // ── 8a. Ensure trail texture exists and matches drawable size ──────
            ensureTrailTexture(device: dev, size: view.drawableSize)
            guard let trail = trailTex else { return }

            // ── 8b. Fade existing trail content ───────────────────────────────
            var fadeAlpha: Float = 1.0 - eng.trailDecay
            let fadeRPD = makeSingleTextureRPD(trail, load: .load)
            if let enc = cmdbuf.makeRenderCommandEncoder(descriptor: fadeRPD) {
                enc.setRenderPipelineState(fadePipeline)
                enc.setFragmentBytes(&fadeAlpha, length: MemoryLayout<Float>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }

            // ── 8c. Render cells onto the trail ───────────────────────────────
            let cellRPD = makeSingleTextureRPD(trail, load: .load)
            if let enc = cmdbuf.makeRenderCommandEncoder(descriptor: cellRPD) {
                encodeCells(enc, cellCount: n)
                enc.endEncoding()
            }

            // ── 8d. Blit trail to drawable ────────────────────────────────────
            rpd.colorAttachments[0].clearColor = bgClear
            if let enc = cmdbuf.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(blitPipeline)
                enc.setFragmentTexture(trail, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }
        } else {
            // ── Normal render (no trail) ──────────────────────────────────────
            rpd.colorAttachments[0].clearColor = bgClear
            if let enc = cmdbuf.makeRenderCommandEncoder(descriptor: rpd) {
                encodeCells(enc, cellCount: n)
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

    // ── Encode cell draw commands into an already-open encoder ───────────────
    private func encodeCells(_ enc: MTLRenderCommandEncoder, cellCount n: Int) {
        enc.setRenderPipelineState(pipeline)
        if let cb = cellBuf    { enc.setVertexBuffer(cb, offset: 0, index: 0) }
        if let ub = uniformBuf {
            enc.setVertexBuffer(ub, offset: 0, index: 1)
            enc.setFragmentBuffer(ub, offset: 0, index: 1)
        }
        if let atlasTex = atlas?.texture { enc.setFragmentTexture(atlasTex, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: n * 6)
    }

    // ── Build a render-pass descriptor targeting a single texture ─────────────
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

    // ── Create (or recreate) the persistent trail texture ────────────────────
    private func ensureTrailTexture(device dev: MTLDevice, size: CGSize) {
        guard trailTex == nil || trailTexSize != size else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat,
            width:       max(1, Int(size.width)),
            height:      max(1, Int(size.height)),
            mipmapped:   false)
        desc.usage       = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        trailTex      = dev.makeTexture(descriptor: desc)
        trailTexSize  = size
        trailNeedsInit = true

        // Clear the new texture to black immediately
        if let tex = trailTex,
           let cb  = cmdQueue.makeCommandBuffer() {
            let clearRPD = makeSingleTextureRPD(tex, load: .clear)
            if let enc = cb.makeRenderCommandEncoder(descriptor: clearRPD) { enc.endEncoding() }
            cb.commit()
            trailNeedsInit = false
        }
    }
}
