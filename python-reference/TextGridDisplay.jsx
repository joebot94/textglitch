import { useState, useEffect, useRef, useCallback } from "react";

// ─── Font Imports ────────────────────────────────────────────────────────────
const FONT_IMPORTS = [
  "https://fonts.googleapis.com/css2?family=Bebas+Neue&display=swap",
  "https://fonts.googleapis.com/css2?family=Oswald:wght@700&display=swap",
  "https://fonts.googleapis.com/css2?family=Anton&display=swap",
  "https://fonts.googleapis.com/css2?family=Teko:wght@700&display=swap",
  "https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap",
  "https://fonts.googleapis.com/css2?family=Black+Han+Sans&display=swap",
  "https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@900&display=swap",
  "https://fonts.googleapis.com/css2?family=Rajdhani:wght@700&display=swap",
];

const FONTS = [
  "Impact", "Bebas Neue", "Anton", "Teko", "Oswald",
  "Barlow Condensed", "Black Han Sans", "Rajdhani",
  "Share Tech Mono", "Courier New",
];

// ─── Grid Layout Presets (4×4 = 16 cells, 0–15) ────────────────────────────
const PRESETS = {
  "All 4×4":      [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
  "3×3":          [0,1,2,4,5,6,8,9,10],
  "2×2 Center":   [5,6,9,10],
  "Corners":      [0,3,12,15],
  "X":            [0,3,5,6,9,10,12,15],
  "Cross +":      [1,2,4,7,8,11,13,14],
  "Diag ↘":      [0,5,10,15],
  "Diag ↗":      [3,6,9,12],
  "Both Diags":   [0,3,5,6,9,10,12,15],
  "Top Row":      [0,1,2,3],
  "Mid Row":      [4,5,6,7],
  "Bottom Row":   [12,13,14,15],
  "Left Col":     [0,4,8,12],
  "Right Col":    [3,7,11,15],
  "Outer Ring":   [0,1,2,3,4,7,8,11,12,13,14,15],
  "Center 1":     [10],
  "Custom":       [],
};

const NEON_PALETTE = [
  "#ff6600","#ff3300","#ff9900","#ffff00",
  "#00ff88","#00ffcc","#00ccff","#0088ff",
  "#ff00ff","#cc00ff","#ffffff","#ff0044",
];

const DEFAULT_TEXT =
  "HELLO\nWORLD\nTEXT\nGRID\nFLASH\nBEAT\nSYNC\nRAVE\nLIVE\nNOW\nGO\nJET\nFIRE\nWAVE\nRUSH\nBLAST\nSHOW\nVIBE";

export default function TextGridDisplay() {
  // ─── State ──────────────────────────────────────────────────────────────
  const [preset, setPreset]           = useState("Corners");
  const [customCells, setCustomCells] = useState([0,3,12,15]);
  const [showBoxes, setShowBoxes]     = useState(true);
  const [textMode, setTextMode]       = useState("word");
  const [distribution, setDist]       = useState("sequential");
  const [speed, setSpeed]             = useState(400);
  const [bpmSync, setBpmSync]         = useState(false);
  const [bpm, setBpm]                 = useState(128);
  const [beatDiv, setBeatDiv]         = useState(1);
  const [fontFamily, setFont]         = useState("Impact");
  const [fontSize, setFontSize]       = useState(9);
  const [globalColor, setGlobalColor] = useState("#ff6600");
  const [bgColor, setBgColor]         = useState("#000000");
  const [colorMode, setColorMode]     = useState("global");
  const [cellColors, setCellColors]   = useState(Array(16).fill("#ff6600"));
  const [textTransform, setTT]        = useState("uppercase");
  const [inputText, setInputText]     = useState(DEFAULT_TEXT);
  const [isPlaying, setIsPlaying]     = useState(false);
  const [pointer, setPointer]         = useState(0);
  const [randSnap, setRandSnap]       = useState(() => Array(16).fill(0).map(() => Math.floor(Math.random()*100)));
  const [activeTab, setActiveTab]     = useState("layout");
  const [isFullscreen, setIsFS]       = useState(false);
  const [flashKey, setFlashKey]       = useState(0);
  const [glowEnabled, setGlow]        = useState(true);
  const [flashEnabled, setFlash]      = useState(true);

  const intervalRef  = useRef(null);
  const displayRef   = useRef(null);
  const tapTimesRef  = useRef([]);
  const tickFnRef    = useRef(null);

  // Load Google Fonts
  useEffect(() => {
    FONT_IMPORTS.forEach(url => {
      if (!document.querySelector(`link[href="${url}"]`)) {
        const link = document.createElement("link");
        link.rel = "stylesheet";
        link.href = url;
        document.head.appendChild(link);
      }
    });
  }, []);

  // ─── Computed ───────────────────────────────────────────────────────────
  const activeIndices = preset === "Custom" ? customCells : (PRESETS[preset] || []);

  const getTokens = useCallback(() => {
    const t = inputText || "";
    if (textMode === "letter") return t.replace(/[\s\n]+/g, "").split("").filter(Boolean);
    if (textMode === "word")   return t.split(/[\s\n]+/).filter(w => w.trim());
    return t.split("\n").filter(l => l.trim());
  }, [inputText, textMode]);

  const applyTransform = (str) => {
    if (!str) return "";
    if (textTransform === "uppercase") return str.toUpperCase();
    if (textTransform === "lowercase") return str.toLowerCase();
    return str;
  };

  const getCellText = useCallback((cellIdx, cellOrder, ptr) => {
    const tokens = getTokens();
    if (!tokens.length || !activeIndices.includes(cellIdx)) return "";
    if (distribution === "all-same") return tokens[ptr % tokens.length];
    if (distribution === "random")   return tokens[randSnap[cellIdx] % tokens.length];
    return tokens[(ptr + cellOrder) % tokens.length];
  }, [getTokens, distribution, randSnap, activeIndices]);

  const getCellColor = useCallback((cellIdx, cellOrder) => {
    if (colorMode === "per-cell") return cellColors[cellIdx];
    if (colorMode === "random")   return NEON_PALETTE[randSnap[cellIdx] % NEON_PALETTE.length];
    if (colorMode === "cycle")    return NEON_PALETTE[(pointer + cellOrder) % NEON_PALETTE.length];
    return globalColor;
  }, [colorMode, cellColors, randSnap, globalColor, pointer]);

  // ─── Tick ───────────────────────────────────────────────────────────────
  const doTick = useCallback(() => {
    const tokens = getTokens();
    if (!tokens.length) return;
    setPointer(p => (p + 1) % Math.max(1, tokens.length));
    setFlashKey(k => k + 1);
    if (distribution === "random" || colorMode === "random") {
      setRandSnap(Array(16).fill(0).map(() => Math.floor(Math.random() * 10000)));
    }
  }, [getTokens, distribution, colorMode]);

  // Keep tickFnRef fresh
  tickFnRef.current = doTick;

  // Interval management
  useEffect(() => {
    clearInterval(intervalRef.current);
    if (isPlaying) {
      const ms = bpmSync ? Math.round((60000 / bpm) * beatDiv) : speed;
      intervalRef.current = setInterval(() => tickFnRef.current(), ms);
    }
    return () => clearInterval(intervalRef.current);
  }, [isPlaying, speed, bpmSync, bpm, beatDiv]);

  // ─── Tap Tempo ──────────────────────────────────────────────────────────
  const tapTempo = () => {
    const now = Date.now();
    const taps = tapTimesRef.current;
    taps.push(now);
    if (taps.length > 8) taps.shift();
    if (taps.length >= 2) {
      const diffs = taps.slice(1).map((t, i) => t - taps[i]);
      const avg = diffs.reduce((a, b) => a + b) / diffs.length;
      setBpm(Math.min(300, Math.max(40, Math.round(60000 / avg))));
      setBpmSync(true);
    }
  };

  // ─── Fullscreen ─────────────────────────────────────────────────────────
  const toggleFS = useCallback(() => {
    if (!document.fullscreenElement) {
      displayRef.current?.requestFullscreen?.();
    } else {
      document.exitFullscreen?.();
    }
  }, []);

  useEffect(() => {
    const h = () => setIsFS(!!document.fullscreenElement);
    document.addEventListener("fullscreenchange", h);
    return () => document.removeEventListener("fullscreenchange", h);
  }, []);

  // ─── Keyboard Shortcuts ─────────────────────────────────────────────────
  useEffect(() => {
    const h = (e) => {
      if (e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT") return;
      if (e.key === " ") { e.preventDefault(); setIsPlaying(p => !p); }
      if (e.key === "ArrowRight") { e.preventDefault(); tickFnRef.current(); }
      if (e.key === "ArrowLeft")  { e.preventDefault(); setPointer(p => Math.max(0, p - 1)); setFlashKey(k => k + 1); }
      if (e.key === "f" || e.key === "F") toggleFS();
      if (e.key === "r" || e.key === "R") setPointer(0);
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [toggleFS]);

  // ─── Toggle custom cell ──────────────────────────────────────────────────
  const toggleCustomCell = (idx) => {
    setPreset("Custom");
    setCustomCells(prev =>
      prev.includes(idx) ? prev.filter(i => i !== idx) : [...prev, idx].sort((a,b) => a-b)
    );
  };

  // ─── Render Cell ─────────────────────────────────────────────────────────
  const renderCell = (cellIdx) => {
    const order   = activeIndices.indexOf(cellIdx);
    const active  = order !== -1;
    const rawText = getCellText(cellIdx, order, pointer);
    const text    = applyTransform(rawText);
    const color   = active ? getCellColor(cellIdx, order) : "#333";
    const isCustom = preset === "Custom";

    const glow = glowEnabled && active
      ? `0 0 20px ${color}99, 0 0 50px ${color}44`
      : "none";

    return (
      <div
        key={cellIdx}
        onClick={() => isCustom && toggleCustomCell(cellIdx)}
        style={{
          backgroundColor: bgColor,
          border: showBoxes
            ? `1px solid ${active ? color + "33" : "#ffffff08"}`
            : "1px solid transparent",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          overflow: "hidden",
          cursor: isCustom ? "pointer" : "default",
          position: "relative",
          userSelect: "none",
          transition: "background-color 0.05s",
        }}
      >
        {/* Scan-line overlay for active cells */}
        {active && showBoxes && (
          <div style={{
            position: "absolute", inset: 0, pointerEvents: "none",
            background: `linear-gradient(180deg, transparent 50%, ${color}05 50%)`,
            backgroundSize: "100% 4px",
          }} />
        )}

        {/* Flash animation on tick */}
        {active && flashEnabled && (
          <div
            key={`flash-${flashKey}-${cellIdx}`}
            style={{
              position: "absolute", inset: 0, pointerEvents: "none",
              backgroundColor: color,
              opacity: 0,
              animation: "cellFlash 0.15s ease-out forwards",
            }}
          />
        )}

        {/* Text */}
        {active && (
          <span
            key={`text-${flashKey}-${cellIdx}`}
            style={{
              fontFamily: `"${fontFamily}", Impact, sans-serif`,
              fontSize: `${fontSize}vw`,
              color,
              fontWeight: 900,
              lineHeight: 0.9,
              textAlign: "center",
              wordBreak: "break-all",
              padding: "2%",
              textShadow: glow,
              animation: "textPop 0.1s ease-out",
              display: "block",
              width: "100%",
            }}
          >
            {text}
          </span>
        )}

        {/* Custom mode: cell index label */}
        {isCustom && (
          <div style={{
            position: "absolute", top: 3, left: 5,
            fontSize: 8, color: active ? color + "99" : "#333",
            fontFamily: "monospace", pointerEvents: "none",
          }}>
            {cellIdx}
          </div>
        )}
      </div>
    );
  };

  const currentMs = bpmSync ? Math.round((60000 / bpm) * beatDiv) : speed;
  const currentBPM = Math.round(60000 / currentMs);

  // ─── UI Helpers ──────────────────────────────────────────────────────────
  const Btn = ({ on, onClick, children, style = {} }) => (
    <button onClick={onClick} style={{
      border: `1px solid ${on ? "#444" : "#222"}`,
      padding: "7px 10px",
      fontSize: 9,
      letterSpacing: 1.5,
      cursor: "pointer",
      fontFamily: "'Share Tech Mono', monospace",
      backgroundColor: on ? globalColor : "#141414",
      color: on ? "#000" : "#666",
      transition: "all 0.1s",
      ...style,
    }}>
      {children}
    </button>
  );

  const Label = ({ children }) => (
    <div style={{ fontSize: 8, color: "#444", letterSpacing: 3, marginBottom: 6, fontFamily: "monospace" }}>
      {children}
    </div>
  );

  const Section = ({ children }) => (
    <div style={{ borderBottom: "1px solid #1a1a1a", paddingBottom: 14, marginBottom: 14 }}>
      {children}
    </div>
  );

  // ─── Render ──────────────────────────────────────────────────────────────
  return (
    <div style={{
      display: "flex", height: "100vh",
      backgroundColor: "#080808", color: "#aaa",
      fontFamily: "'Share Tech Mono', 'Courier New', monospace",
      overflow: "hidden",
    }}>
      <style>{`
        @keyframes cellFlash { 0% { opacity: 0.18; } 100% { opacity: 0; } }
        @keyframes textPop   { 0% { transform: scale(1.08); opacity: 0.7; } 100% { transform: scale(1); opacity: 1; } }
        input[type=range] {
          -webkit-appearance: none; width: 100%; height: 2px;
          background: #2a2a2a; outline: none; cursor: pointer;
        }
        input[type=range]::-webkit-slider-thumb {
          -webkit-appearance: none; width: 14px; height: 14px;
          background: ${globalColor}; border-radius: 0;
        }
        ::-webkit-scrollbar { width: 4px; }
        ::-webkit-scrollbar-track { background: #0a0a0a; }
        ::-webkit-scrollbar-thumb { background: #2a2a2a; }
      `}</style>

      {/* ── LEFT PANEL ─────────────────────────────────────────────────── */}
      {!isFullscreen && (
        <div style={{
          width: 268, minWidth: 268,
          backgroundColor: "#0a0a0a",
          borderRight: "1px solid #1a1a1a",
          display: "flex", flexDirection: "column",
          overflow: "hidden",
        }}>
          {/* Header */}
          <div style={{ padding: "14px 16px", borderBottom: "1px solid #1a1a1a" }}>
            <div style={{ fontSize: 13, color: globalColor, letterSpacing: 5, fontWeight: 700 }}>TEXT GRID</div>
            <div style={{ fontSize: 8, color: "#333", letterSpacing: 3, marginTop: 3 }}>DISPLAY SYSTEM v1.0</div>
          </div>

          {/* Tabs */}
          <div style={{ display: "flex", borderBottom: "1px solid #1a1a1a", flexShrink: 0 }}>
            {["LAYOUT","TEXT","STYLE","PLAY"].map(tab => {
              const t = tab.toLowerCase();
              const on = activeTab === t;
              return (
                <button key={tab} onClick={() => setActiveTab(t)} style={{
                  flex: 1, padding: "9px 0", fontSize: 8, letterSpacing: 1.5,
                  border: "none", cursor: "pointer",
                  backgroundColor: on ? "#141414" : "transparent",
                  color: on ? globalColor : "#383838",
                  borderBottom: on ? `2px solid ${globalColor}` : "2px solid transparent",
                  fontFamily: "monospace",
                }}>
                  {tab}
                </button>
              );
            })}
          </div>

          {/* Tab Content */}
          <div style={{ flex: 1, overflowY: "auto", padding: 14 }}>

            {/* ── LAYOUT TAB ─────────────────────────────────────────── */}
            {activeTab === "layout" && (
              <>
                <Section>
                  <Label>PRESET</Label>
                  <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 3 }}>
                    {Object.keys(PRESETS).map(p => (
                      <Btn key={p} on={preset === p} onClick={() => setPreset(p)}
                        style={{ fontSize: 8, padding: "6px 4px" }}>
                        {p}
                      </Btn>
                    ))}
                  </div>
                  {preset === "Custom" && (
                    <div style={{ marginTop: 8, fontSize: 8, color: "#444", lineHeight: 1.8 }}>
                      Click cells in the grid to toggle active positions
                    </div>
                  )}
                </Section>

                <Section>
                  <Label>BOXES</Label>
                  <div style={{ display: "flex", gap: 4 }}>
                    <Btn on={showBoxes} onClick={() => setShowBoxes(true)} style={{ flex: 1 }}>ON</Btn>
                    <Btn on={!showBoxes} onClick={() => setShowBoxes(false)} style={{ flex: 1 }}>OFF</Btn>
                  </div>
                </Section>

                <Section>
                  <Label>EFFECTS</Label>
                  <div style={{ display: "flex", gap: 4 }}>
                    <Btn on={glowEnabled} onClick={() => setGlow(g => !g)} style={{ flex: 1, fontSize: 8 }}>GLOW</Btn>
                    <Btn on={flashEnabled} onClick={() => setFlash(f => !f)} style={{ flex: 1, fontSize: 8 }}>FLASH</Btn>
                  </div>
                </Section>

                {/* Active cell count indicator */}
                <div style={{ fontSize: 9, color: "#333", textAlign: "center", marginTop: 8 }}>
                  <span style={{ color: globalColor }}>{activeIndices.length}</span> / 16 ACTIVE CELLS
                </div>
              </>
            )}

            {/* ── TEXT TAB ───────────────────────────────────────────── */}
            {activeTab === "text" && (
              <>
                <Section>
                  <Label>INPUT TEXT</Label>
                  <textarea
                    value={inputText}
                    onChange={e => setInputText(e.target.value)}
                    style={{
                      width: "100%", height: 130,
                      backgroundColor: "#111", border: "1px solid #222",
                      color: "#bbb", fontFamily: "monospace", fontSize: 10,
                      padding: 8, resize: "vertical", outline: "none",
                      boxSizing: "border-box", lineHeight: 1.6,
                    }}
                    placeholder="One entry per line for phrase mode..."
                  />
                  <div style={{ fontSize: 8, color: "#333", marginTop: 4 }}>
                    {getTokens().length} tokens parsed
                  </div>
                </Section>

                <Section>
                  <Label>TEXT MODE</Label>
                  <div style={{ display: "flex", gap: 3 }}>
                    {[["LETTER","letter"],["WORD","word"],["PHRASE","phrase"]].map(([l, v]) => (
                      <Btn key={v} on={textMode === v} onClick={() => setTextMode(v)}
                        style={{ flex: 1, fontSize: 7 }}>{l}</Btn>
                    ))}
                  </div>
                  <div style={{ fontSize: 8, color: "#333", marginTop: 6, lineHeight: 1.7 }}>
                    {textMode === "letter" && "Each cell gets 1 character"}
                    {textMode === "word"   && "Each cell gets 1 word"}
                    {textMode === "phrase" && "Each cell gets 1 line of text"}
                  </div>
                </Section>

                <Section>
                  <Label>CELL DISTRIBUTION</Label>
                  {[["SEQUENTIAL — cascade through text","sequential"],
                    ["ALL SAME — sync all cells","all-same"],
                    ["RANDOM — shuffle per cell","random"]].map(([l, v]) => (
                    <Btn key={v} on={distribution === v} onClick={() => setDist(v)}
                      style={{ display: "block", width: "100%", textAlign: "left", marginBottom: 3, fontSize: 8, lineHeight: 1.6 }}>
                      {l}
                    </Btn>
                  ))}
                </Section>

                <Section>
                  <Label>TEXT TRANSFORM</Label>
                  <div style={{ display: "flex", gap: 3 }}>
                    {[["UPPER","uppercase"],["lower","lowercase"],["As-Is","none"]].map(([l, v]) => (
                      <Btn key={v} on={textTransform === v} onClick={() => setTT(v)}
                        style={{ flex: 1, fontSize: 8 }}>{l}</Btn>
                    ))}
                  </div>
                </Section>
              </>
            )}

            {/* ── STYLE TAB ──────────────────────────────────────────── */}
            {activeTab === "style" && (
              <>
                <Section>
                  <Label>FONT</Label>
                  <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                    {FONTS.map(f => (
                      <Btn key={f} on={fontFamily === f} onClick={() => setFont(f)}
                        style={{ textAlign: "left", fontSize: 10, fontFamily: `"${f}", sans-serif`, padding: "6px 10px" }}>
                        {f}
                      </Btn>
                    ))}
                  </div>
                </Section>

                <Section>
                  <Label>FONT SIZE: {fontSize}vw</Label>
                  <input type="range" min={2} max={22} step={0.5} value={fontSize}
                    onChange={e => setFontSize(+e.target.value)} />
                </Section>

                <Section>
                  <Label>COLOR MODE</Label>
                  {[["GLOBAL — one color","global"],
                    ["PER CELL — custom per slot","per-cell"],
                    ["RANDOM — randomize on flash","random"],
                    ["CYCLE — rotate through palette","cycle"]].map(([l, v]) => (
                    <Btn key={v} on={colorMode === v} onClick={() => setColorMode(v)}
                      style={{ display: "block", width: "100%", textAlign: "left", marginBottom: 3, fontSize: 8, lineHeight: 1.6 }}>
                      {l}
                    </Btn>
                  ))}
                </Section>

                {(colorMode === "global" || colorMode === "cycle") && (
                  <Section>
                    <Label>TEXT COLOR</Label>
                    <div style={{ display: "flex", flexWrap: "wrap", gap: 5, marginBottom: 8 }}>
                      {NEON_PALETTE.map(c => (
                        <div key={c} onClick={() => setGlobalColor(c)} style={{
                          width: 26, height: 26, backgroundColor: c, cursor: "pointer",
                          border: globalColor === c ? "2px solid #fff" : "2px solid transparent",
                          boxShadow: globalColor === c ? `0 0 8px ${c}` : "none",
                        }} />
                      ))}
                    </div>
                    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                      <input type="color" value={globalColor} onChange={e => setGlobalColor(e.target.value)}
                        style={{ width: 32, height: 26, padding: 0, border: "1px solid #333", cursor: "pointer", backgroundColor: "#000" }} />
                      <span style={{ fontSize: 9, color: "#444" }}>{globalColor.toUpperCase()}</span>
                    </div>
                  </Section>
                )}

                {colorMode === "per-cell" && (
                  <Section>
                    <Label>CELL COLORS (4×4)</Label>
                    <div style={{ display: "grid", gridTemplateColumns: "repeat(4,1fr)", gap: 3 }}>
                      {Array.from({length: 16}, (_, i) => (
                        <div key={i} style={{ position: "relative" }}>
                          <input type="color" value={cellColors[i]}
                            onChange={e => {
                              const next = [...cellColors];
                              next[i] = e.target.value;
                              setCellColors(next);
                            }}
                            title={`Cell ${i}`}
                            style={{ width: "100%", height: 22, padding: 0, border: "1px solid #2a2a2a", cursor: "pointer",
                              opacity: activeIndices.includes(i) ? 1 : 0.3 }}
                          />
                          <div style={{ fontSize: 6, color: "#333", textAlign: "center", fontFamily: "monospace" }}>{i}</div>
                        </div>
                      ))}
                    </div>
                    <button onClick={() => setCellColors(Array(16).fill(0).map(() => NEON_PALETTE[Math.floor(Math.random()*NEON_PALETTE.length)]))}
                      style={{ marginTop: 8, width: "100%", padding: "6px", fontSize: 8, letterSpacing: 2,
                        backgroundColor: "#1a1a1a", border: "1px solid #333", color: "#666", cursor: "pointer", fontFamily: "monospace" }}>
                      RANDOMIZE
                    </button>
                  </Section>
                )}

                <Section>
                  <Label>BACKGROUND</Label>
                  <div style={{ display: "flex", flexWrap: "wrap", gap: 4, marginBottom: 6 }}>
                    {["#000000","#050505","#0a0000","#000a00","#00000a","#080008","#080800","#001010"].map(c => (
                      <div key={c} onClick={() => setBgColor(c)} style={{
                        width: 26, height: 26, backgroundColor: c, cursor: "pointer",
                        border: bgColor === c ? `2px solid ${globalColor}` : "2px solid #222",
                      }} />
                    ))}
                  </div>
                  <input type="color" value={bgColor} onChange={e => setBgColor(e.target.value)}
                    style={{ width: 32, height: 26, padding: 0, border: "1px solid #333", cursor: "pointer" }} />
                </Section>
              </>
            )}

            {/* ── PLAY TAB ───────────────────────────────────────────── */}
            {activeTab === "play" && (
              <>
                <Section>
                  <Label>TIMING MODE</Label>
                  <div style={{ display: "flex", gap: 3 }}>
                    <Btn on={!bpmSync} onClick={() => setBpmSync(false)} style={{ flex: 1, fontSize: 8 }}>MANUAL</Btn>
                    <Btn on={bpmSync} onClick={() => setBpmSync(true)} style={{ flex: 1, fontSize: 8 }}>BPM SYNC</Btn>
                  </div>
                </Section>

                {!bpmSync && (
                  <Section>
                    <Label>SPEED: {speed}ms ({currentBPM} BPM)</Label>
                    <input type="range" min={40} max={2000} step={10} value={speed}
                      onChange={e => setSpeed(+e.target.value)} />
                    <div style={{ display: "grid", gridTemplateColumns: "repeat(4,1fr)", gap: 3, marginTop: 10 }}>
                      {[[100,"FAST"],[200,"~"],[400,"MED"],[800,"SLOW"]].map(([ms, l]) => (
                        <Btn key={ms} on={speed === ms} onClick={() => setSpeed(ms)} style={{ fontSize: 7, padding: "5px 2px" }}>{l}<br/>{ms}ms</Btn>
                      ))}
                    </div>
                  </Section>
                )}

                {bpmSync && (
                  <>
                    <Section>
                      <Label>BPM: {bpm}</Label>
                      <input type="range" min={60} max={200} value={bpm} onChange={e => setBpm(+e.target.value)} />
                      <input type="number" value={bpm} onChange={e => setBpm(Math.min(300, Math.max(40, +e.target.value)))}
                        style={{ marginTop: 8, width: "100%", padding: "8px", fontSize: 22, textAlign: "center",
                          backgroundColor: "#111", border: "1px solid #2a2a2a", color: globalColor,
                          fontFamily: "monospace", outline: "none", boxSizing: "border-box" }} />
                    </Section>

                    <Section>
                      <Label>BEAT DIVISION</Label>
                      <div style={{ display: "grid", gridTemplateColumns: "repeat(4,1fr)", gap: 3 }}>
                        {[[2,"½"],[1,"¼"],[0.5,"⅛"],[0.25,"1/16"]].map(([v, l]) => (
                          <Btn key={v} on={beatDiv === v} onClick={() => setBeatDiv(v)} style={{ fontSize: 11, padding: "8px 2px" }}>{l}</Btn>
                        ))}
                      </div>
                      <div style={{ fontSize: 8, color: "#333", marginTop: 6, textAlign: "center" }}>
                        Interval: {Math.round((60000/bpm)*beatDiv)}ms
                      </div>
                    </Section>

                    <Section>
                      <button onMouseDown={tapTempo} style={{
                        width: "100%", padding: "20px 0", fontSize: 12, letterSpacing: 4,
                        backgroundColor: "#110800", border: `1px solid ${globalColor}44`,
                        color: globalColor, cursor: "pointer", fontFamily: "monospace",
                        userSelect: "none",
                      }}>
                        TAP TEMPO
                      </button>
                      <div style={{ fontSize: 8, color: "#333", textAlign: "center", marginTop: 4 }}>
                        Tap repeatedly to set BPM
                      </div>
                    </Section>
                  </>
                )}

                <Section>
                  <Label>TRANSPORT</Label>
                  <div style={{ display: "flex", gap: 4, marginBottom: 10 }}>
                    <button onClick={() => setIsPlaying(true)} style={{
                      flex: 2, padding: "14px 0", fontSize: 20,
                      backgroundColor: isPlaying ? globalColor : "#111",
                      border: `1px solid ${isPlaying ? globalColor : "#2a2a2a"}`,
                      color: isPlaying ? "#000" : "#555",
                      cursor: "pointer",
                      boxShadow: isPlaying ? `0 0 20px ${globalColor}66` : "none",
                    }}>▶</button>
                    <button onClick={() => { setIsPlaying(false); setPointer(0); }} style={{
                      flex: 1, padding: "14px 0", fontSize: 20,
                      backgroundColor: "#111", border: "1px solid #2a2a2a",
                      color: "#444", cursor: "pointer",
                    }}>■</button>
                    <button onClick={() => tickFnRef.current()} style={{
                      flex: 1, padding: "14px 0", fontSize: 16,
                      backgroundColor: "#111", border: "1px solid #2a2a2a",
                      color: "#555", cursor: "pointer",
                    }}>▶|</button>
                  </div>
                </Section>

                <div style={{ fontSize: 8, color: "#2a2a2a", lineHeight: 2.2, borderTop: "1px solid #141414", paddingTop: 10 }}>
                  <div>SPACE ───── play / pause</div>
                  <div>→ / ← ─── step forward / back</div>
                  <div>R ──────── reset to start</div>
                  <div>F ──────── fullscreen toggle</div>
                </div>
              </>
            )}
          </div>
        </div>
      )}

      {/* ── MAIN DISPLAY ─────────────────────────────────────────────────── */}
      <div ref={displayRef} style={{
        flex: 1, display: "flex", flexDirection: "column",
        backgroundColor: bgColor, position: "relative", overflow: "hidden",
      }}>
        {/* Status Bar */}
        {!isFullscreen && (
          <div style={{
            display: "flex", alignItems: "center", justifyContent: "space-between",
            padding: "7px 14px",
            borderBottom: `1px solid ${globalColor}18`,
            backgroundColor: bgColor,
            flexShrink: 0,
          }}>
            <div style={{ display: "flex", gap: 16, fontSize: 8, color: "#2a2a2a", fontFamily: "monospace" }}>
              <span style={{ color: isPlaying ? globalColor : "#333" }}>
                {isPlaying ? `▶ ${currentBPM}BPM` : "■ STOPPED"}
              </span>
              <span>{preset.toUpperCase()}</span>
              <span>{textMode.toUpperCase()}</span>
              <span>{distribution.toUpperCase()}</span>
              <span style={{ color: "#1f1f1f" }}>PTR:{pointer}</span>
            </div>
            <div style={{ display: "flex", gap: 6 }}>
              <button onClick={() => { setPointer(0); }} style={{
                padding: "4px 10px", fontSize: 8, letterSpacing: 2,
                backgroundColor: "#111", border: "1px solid #222",
                color: "#444", cursor: "pointer", fontFamily: "monospace",
              }}>RESET</button>
              <button onClick={toggleFS} style={{
                padding: "4px 10px", fontSize: 8, letterSpacing: 2,
                backgroundColor: "#111", border: `1px solid ${globalColor}44`,
                color: globalColor, cursor: "pointer", fontFamily: "monospace",
              }}>⛶ FULLSCREEN</button>
            </div>
          </div>
        )}

        {/* Grid */}
        <div style={{
          flex: 1,
          display: "grid",
          gridTemplateColumns: "repeat(4, 1fr)",
          gridTemplateRows: "repeat(4, 1fr)",
          gap: showBoxes ? 1 : 0,
          backgroundColor: showBoxes ? `${globalColor}0a` : bgColor,
          padding: showBoxes ? 1 : 0,
        }}>
          {Array.from({ length: 16 }, (_, i) => renderCell(i))}
        </div>

        {/* Fullscreen Overlay Controls */}
        {isFullscreen && (
          <div
            style={{
              position: "absolute", bottom: 20, right: 20,
              display: "flex", gap: 8, opacity: 0,
              transition: "opacity 0.3s",
            }}
            onMouseEnter={e => (e.currentTarget.style.opacity = "1")}
            onMouseLeave={e => (e.currentTarget.style.opacity = "0")}
          >
            <button onClick={() => setIsPlaying(p => !p)} style={{
              padding: "10px 16px", fontSize: 16,
              backgroundColor: "#000000cc",
              border: `1px solid ${globalColor}66`,
              color: globalColor, cursor: "pointer", fontFamily: "monospace",
            }}>
              {isPlaying ? "■" : "▶"}
            </button>
            <button onClick={() => tickFnRef.current()} style={{
              padding: "10px 16px", fontSize: 12,
              backgroundColor: "#000000cc", border: "1px solid #333",
              color: "#666", cursor: "pointer", fontFamily: "monospace",
            }}>STEP</button>
            <button onClick={toggleFS} style={{
              padding: "10px 16px", fontSize: 10, letterSpacing: 2,
              backgroundColor: "#000000cc", border: "1px solid #444",
              color: "#888", cursor: "pointer", fontFamily: "monospace",
            }}>EXIT</button>
          </div>
        )}
      </div>
    </div>
  );
}
