// Constants.swift — Shared constants for Text Grid Display System

import Foundation

/// Must be ≥ the largest possible gridRows × gridCols (currently 32×24 = 768).
let maxCells = 4096

struct GridProfile {
    let name: String
    let rows: Int
    let cols: Int
}

let gridProfiles: [GridProfile] = [
    // ── Small / legacy ────────────────────────────────────────────
    GridProfile(name: "1×1",   rows: 1,  cols: 1),
    GridProfile(name: "2×2",   rows: 2,  cols: 2),
    GridProfile(name: "3×3",   rows: 3,  cols: 3),
    GridProfile(name: "3×4",   rows: 3,  cols: 4),
    GridProfile(name: "4×4",   rows: 4,  cols: 4),
    // ── Medium ────────────────────────────────────────────────────
    GridProfile(name: "5×4",   rows: 5,  cols: 4),
    GridProfile(name: "6×4",   rows: 6,  cols: 4),
    GridProfile(name: "6×6",   rows: 6,  cols: 6),
    GridProfile(name: "8×6",   rows: 8,  cols: 6),
    GridProfile(name: "8×8",   rows: 8,  cols: 8),
    GridProfile(name: "9×16",  rows: 9,  cols: 16),  // widescreen portrait
    // ── Large (Metal renderer shines here) ────────────────────────
    GridProfile(name: "12×9",  rows: 12, cols: 9),
    GridProfile(name: "16×9",  rows: 16, cols: 9),   // classic widescreen ratio
    GridProfile(name: "16×12", rows: 16, cols: 12),
    GridProfile(name: "24×18", rows: 24, cols: 18),
    GridProfile(name: "32×24", rows: 32, cols: 24),  // 768 cells
]

let gridProfileNames: [String] = gridProfiles.map { $0.name }

let presetNames: [String] = [
    "All", "3×3", "2×2 Center", "Corners", "X", "Cross +",
    "Diag ↘", "Diag ↗", "Both Diags",
    "Top Row", "Mid Row", "Bottom Row",
    "Left Col", "Right Col", "Outer Ring", "Center 1", "Custom",
]

let neonPalette: [String] = [
    "#ff6600", "#ff3300", "#ff9900", "#ffff00",
    "#00ff88", "#00ffcc", "#00ccff", "#0088ff",
    "#ff00ff", "#cc00ff", "#ffffff", "#ff0044",
]

let availableFonts: [String] = [
    "Impact", "Arial-BoldMT", "CourierNewPS-BoldMT", "Helvetica-Bold",
    "Georgia-Bold", "GillSans-Bold", "Futura-Bold", "Menlo-Bold",
    "AmericanTypewriter-Bold", "Rockwell-Bold", "TrebuchetMS-Bold",
    "ShareTechMono-Regular",
]

let defaultText = """
HELLO
WORLD
TEXT
GRID
FLASH
BEAT
SYNC
RAVE
LIVE
NOW
GO
JET
FIRE
WAVE
RUSH
BLAST
SHOW
VIBE
"""

let legacy4x4Presets: [String: [Int]] = [
    "All":         Array(0..<16),
    "3×3":         [0, 1, 2, 4, 5, 6, 8, 9, 10],
    "2×2 Center":  [5, 6, 9, 10],
    "Corners":     [0, 3, 12, 15],
    "X":           [0, 3, 5, 6, 9, 10, 12, 15],
    "Cross +":     [1, 2, 4, 7, 8, 11, 13, 14],
    "Diag ↘":     [0, 5, 10, 15],
    "Diag ↗":     [3, 6, 9, 12],
    "Both Diags":  [0, 3, 5, 6, 9, 10, 12, 15],
    "Top Row":     [0, 1, 2, 3],
    "Mid Row":     [4, 5, 6, 7],
    "Bottom Row":  [12, 13, 14, 15],
    "Left Col":    [0, 4, 8, 12],
    "Right Col":   [3, 7, 11, 15],
    "Outer Ring":  [0, 1, 2, 3, 4, 7, 8, 11, 12, 13, 14, 15],
    "Center 1":    [10],
]

let autoSwitchablePresets: [String] = presetNames.filter { $0 != "Custom" }
