"""engine.py — Core state machine and grid logic for Text Grid Display System."""

import random
import re
from PyQt6.QtCore import QObject, pyqtSignal, QTimer

# ─── Constants ────────────────────────────────────────────────────────────────

MAX_CELLS = 16

GRID_PROFILES: dict[str, tuple[int, int]] = {
    "1×1": (1, 1),
    "2×2": (2, 2),
    "3×3": (3, 3),
    "3×4": (3, 4),
    "4×4": (4, 4),
}

PRESET_NAMES = [
    "All",
    "3×3",
    "2×2 Center",
    "Corners",
    "X",
    "Cross +",
    "Diag ↘",
    "Diag ↗",
    "Both Diags",
    "Top Row",
    "Mid Row",
    "Bottom Row",
    "Left Col",
    "Right Col",
    "Outer Ring",
    "Center 1",
    "Custom",
]

# Backward compatibility for older control code and OSC payloads.
PRESETS: dict[str, list[int]] = {name: [] for name in PRESET_NAMES}
PRESETS["All 4×4"] = []

NEON_PALETTE = [
    "#ff6600", "#ff3300", "#ff9900", "#ffff00",
    "#00ff88", "#00ffcc", "#00ccff", "#0088ff",
    "#ff00ff", "#cc00ff", "#ffffff", "#ff0044",
]

FONTS = [
    "Impact", "Arial Black", "Courier New", "Consolas",
    "Bebas Neue", "Anton", "Oswald", "Teko",
    "Barlow Condensed", "Black Han Sans", "Rajdhani",
    "Share Tech Mono",
]

DEFAULT_TEXT = (
    "HELLO\nWORLD\nTEXT\nGRID\nFLASH\nBEAT\n"
    "SYNC\nRAVE\nLIVE\nNOW\nGO\nJET\n"
    "FIRE\nWAVE\nRUSH\nBLAST\nSHOW\nVIBE"
)

LEGACY_4X4_PRESETS: dict[str, list[int]] = {
    "All":         list(range(16)),
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
}

_PRESET_ALIASES = {
    "all4x4": "All",
    "all": "All",
    "all 4x4": "All",
    "all 4×4": "All",
}

_GRID_ALIASES = {
    "1x1": "1×1",
    "2x2": "2×2",
    "3x3": "3×3",
    "3x4": "3×4",
    "4x4": "4×4",
    "1×1": "1×1",
    "2×2": "2×2",
    "3×3": "3×3",
    "3×4": "3×4",
    "4×4": "4×4",
}


def normalize_preset_name(name: str) -> str:
    raw = (name or "").strip()
    if raw in PRESET_NAMES:
        return raw
    alias = _PRESET_ALIASES.get(raw.lower())
    return alias if alias in PRESET_NAMES else raw


def normalize_grid_profile_name(name: str) -> str | None:
    raw = (name or "").strip().lower().replace(" ", "")
    return _GRID_ALIASES.get(raw)


def _idx(r: int, c: int, cols: int) -> int:
    return r * cols + c


def _unique_in_order(values: list[int], cell_count: int) -> list[int]:
    seen: set[int] = set()
    out: list[int] = []
    for v in values:
        if 0 <= v < cell_count and v not in seen:
            seen.add(v)
            out.append(v)
    return out


def _center_window(length: int, size: int) -> tuple[int, int]:
    if length <= size:
        return 0, length
    start = max(0, (length - size) // 2)
    return start, min(length, start + size)


def _diag_down(rows: int, cols: int) -> list[int]:
    n = min(rows, cols)
    return [_idx(i, i, cols) for i in range(n)]


def _diag_up(rows: int, cols: int) -> list[int]:
    n = min(rows, cols)
    out: list[int] = []
    for i in range(n):
        c = cols - 1 - i
        if 0 <= c < cols:
            out.append(_idx(i, c, cols))
    return out


def compute_preset_indices(preset_name: str, rows: int, cols: int) -> list[int]:
    cell_count = rows * cols
    if cell_count <= 0:
        return []

    preset = normalize_preset_name(preset_name)

    if rows == 4 and cols == 4 and preset in LEGACY_4X4_PRESETS:
        return list(LEGACY_4X4_PRESETS[preset])

    if preset == "All":
        return list(range(cell_count))

    if preset == "3×3":
        if rows < 3 or cols < 3:
            return list(range(cell_count))
        r0, r1 = _center_window(rows, 3)
        c0, c1 = _center_window(cols, 3)
        return [_idx(r, c, cols) for r in range(r0, r1) for c in range(c0, c1)]

    if preset == "2×2 Center":
        if rows < 2 or cols < 2:
            return list(range(cell_count))
        r0, r1 = _center_window(rows, 2)
        c0, c1 = _center_window(cols, 2)
        return [_idx(r, c, cols) for r in range(r0, r1) for c in range(c0, c1)]

    if preset == "Corners":
        return _unique_in_order(
            [0, cols - 1, _idx(rows - 1, 0, cols), _idx(rows - 1, cols - 1, cols)],
            cell_count
        )

    if preset == "Diag ↘":
        return _unique_in_order(_diag_down(rows, cols), cell_count)

    if preset == "Diag ↗":
        return _unique_in_order(_diag_up(rows, cols), cell_count)

    if preset in ("X", "Both Diags"):
        return _unique_in_order(_diag_down(rows, cols) + _diag_up(rows, cols), cell_count)

    if preset == "Cross +":
        center_rows = [rows // 2] if rows % 2 else [rows // 2 - 1, rows // 2]
        center_cols = [cols // 2] if cols % 2 else [cols // 2 - 1, cols // 2]
        out = []
        for r in center_rows:
            out.extend(_idx(r, c, cols) for c in range(cols))
        for c in center_cols:
            out.extend(_idx(r, c, cols) for r in range(rows))
        return _unique_in_order(out, cell_count)

    if preset == "Top Row":
        return [_idx(0, c, cols) for c in range(cols)]

    if preset == "Mid Row":
        r = rows // 2
        return [_idx(r, c, cols) for c in range(cols)]

    if preset == "Bottom Row":
        return [_idx(rows - 1, c, cols) for c in range(cols)]

    if preset == "Left Col":
        return [_idx(r, 0, cols) for r in range(rows)]

    if preset == "Right Col":
        return [_idx(r, cols - 1, cols) for r in range(rows)]

    if preset == "Outer Ring":
        out = []
        out.extend(_idx(0, c, cols) for c in range(cols))
        if rows > 1:
            out.extend(_idx(rows - 1, c, cols) for c in range(cols))
        for r in range(1, max(1, rows - 1)):
            out.append(_idx(r, 0, cols))
            if cols > 1:
                out.append(_idx(r, cols - 1, cols))
        return _unique_in_order(out, cell_count)

    if preset == "Center 1":
        r = (rows - 1) // 2
        c = (cols - 1) // 2
        return [_idx(r, c, cols)]

    return list(range(cell_count))


# ─── Engine ───────────────────────────────────────────────────────────────────

class GridEngine(QObject):
    """Central state object. All UI and sync handlers read/write this."""

    ticked          = pyqtSignal(int)   # pointer value after tick
    tokens_updated  = pyqtSignal(int)   # new token count
    playing_changed = pyqtSignal(bool)
    display_changed = pyqtSignal()      # visual-only prop changed
    preset_changed  = pyqtSignal(str)

    def __init__(self, parent=None):
        super().__init__(parent)

        # Grid layout
        self.grid_profile = "4×4"
        self.grid_rows, self.grid_cols = GRID_PROFILES[self.grid_profile]
        self.preset_name = "Corners"
        self.custom_cells: list[int] = [0, 3, 12, 15]
        self.blanked_cells: set[int] = set()

        # Text
        self.raw_text       = DEFAULT_TEXT
        self.text_mode      = "word"        # letter | word | phrase | chunk
        self.chunk_size     = 4             # chars per token in chunk mode
        self.distribution   = "sequential"  # sequential | all-same | random
        self.text_transform = "upper"       # upper | lower | none
        self._tokens: list[str] = []
        self._rand_snap = [0] * MAX_CELLS

        # Color
        self.color_mode   = "global"        # global | per-cell | random | cycle
        self.global_color = "#ff6600"
        self.cell_colors  = ["#ff6600"] * MAX_CELLS
        self.bg_color     = "#000000"

        # Style
        self.font_family   = "Impact"
        self.font_size_pct = 35             # % of cell min-dimension
        self.glow_enabled  = True
        self.flash_enabled = True
        self.show_boxes    = True

        # Playback
        self.pointer       = 0
        self.speed_ms      = 400
        self.bpm           = 128.0
        self.bpm_sync      = False
        self.beat_division = 1.0            # 2=half, 1=quarter, 0.5=eighth, 0.25=16th
        self._playing      = False

        self._timer = QTimer(self)
        self._timer.timeout.connect(self._do_tick)

        self._normalize_custom_cells()
        self._parse_tokens()

    # ── Properties ────────────────────────────────────────────────────────────

    @property
    def playing(self) -> bool:
        return self._playing

    @property
    def cell_count(self) -> int:
        return self.grid_rows * self.grid_cols

    @property
    def active_indices(self) -> list[int]:
        if self.preset_name == "Custom":
            return _unique_in_order(list(self.custom_cells), self.cell_count)
        return compute_preset_indices(self.preset_name, self.grid_rows, self.grid_cols)

    @property
    def visible_indices(self) -> list[int]:
        return [i for i in self.active_indices if i not in self.blanked_cells]

    @property
    def effective_ms(self) -> int:
        if self.bpm_sync and self.bpm > 0:
            return max(16, int(round((60_000.0 / self.bpm) * self.beat_division)))
        return max(16, self.speed_ms)

    # ── Grid helpers ──────────────────────────────────────────────────────────

    def set_grid_profile(self, profile_name: str) -> bool:
        canonical = normalize_grid_profile_name(profile_name)
        if not canonical or canonical not in GRID_PROFILES:
            return False
        if canonical == self.grid_profile:
            return True

        self.grid_profile = canonical
        self.grid_rows, self.grid_cols = GRID_PROFILES[canonical]
        self._normalize_custom_cells()
        self._normalize_blanks()
        self.display_changed.emit()
        return True

    def set_preset(self, preset_name: str, *, emit_display: bool = True) -> bool:
        canonical = normalize_preset_name(preset_name)
        if canonical not in PRESET_NAMES:
            return False

        changed = canonical != self.preset_name
        self.preset_name = canonical
        if emit_display:
            self.display_changed.emit()
        if changed:
            self.preset_changed.emit(canonical)
        return True

    def _normalize_custom_cells(self):
        self.custom_cells = _unique_in_order(self.custom_cells, self.cell_count)
        if not self.custom_cells and self.cell_count > 0:
            self.custom_cells = compute_preset_indices("Corners", self.grid_rows, self.grid_cols)

    def _normalize_blanks(self):
        self.blanked_cells = {i for i in self.blanked_cells if 0 <= i < self.cell_count}

    # ── Text ──────────────────────────────────────────────────────────────────

    def set_text(self, text: str):
        self.raw_text = text
        self._parse_tokens()

    def set_text_mode(self, mode: str):
        mode = (mode or "").strip().lower()
        if mode not in {"letter", "word", "phrase", "chunk"}:
            mode = "word"
        self.text_mode = mode
        self._parse_tokens()

    def set_chunk_size(self, size: int):
        self.chunk_size = max(1, min(64, int(size)))
        if self.text_mode == "chunk":
            self._parse_tokens()

    def _parse_tokens(self):
        t = self.raw_text or ""
        if self.text_mode == "letter":
            self._tokens = [c for c in re.sub(r"\s+", "", t) if c]
        elif self.text_mode == "word":
            self._tokens = [w for w in re.split(r"[\s\n]+", t) if w.strip()]
        elif self.text_mode == "chunk":
            cleaned = re.sub(r"\s+", "", t)
            size = max(1, self.chunk_size)
            self._tokens = [cleaned[i:i + size] for i in range(0, len(cleaned), size)] if cleaned else []
        else:  # phrase
            self._tokens = [ln for ln in t.split("\n") if ln.strip()]
        if self.pointer >= max(1, len(self._tokens)):
            self.pointer = 0
        self.tokens_updated.emit(len(self._tokens))

    def _apply_transform(self, s: str) -> str:
        if self.text_transform == "upper":
            return s.upper()
        if self.text_transform == "lower":
            return s.lower()
        return s

    # ── Cell accessors ────────────────────────────────────────────────────────

    def is_cell_blanked(self, cell_idx: int) -> bool:
        return cell_idx in self.blanked_cells

    def is_cell_visible(self, cell_idx: int) -> bool:
        return cell_idx in self.active_indices and cell_idx not in self.blanked_cells

    def get_cell_text(self, cell_idx: int) -> str:
        active = self.visible_indices
        if not self._tokens or cell_idx not in active:
            return ""
        order = active.index(cell_idx)
        n = len(self._tokens)
        if self.distribution == "all-same":
            tok = self._tokens[self.pointer % n]
        elif self.distribution == "random":
            tok = self._tokens[self._rand_snap[cell_idx % MAX_CELLS] % n]
        else:
            tok = self._tokens[(self.pointer + order) % n]
        return self._apply_transform(tok)

    def get_cell_color(self, cell_idx: int) -> str:
        active = self.visible_indices
        order = active.index(cell_idx) if cell_idx in active else 0
        if self.color_mode == "per-cell":
            return self.cell_colors[cell_idx % MAX_CELLS]
        if self.color_mode == "random":
            return NEON_PALETTE[self._rand_snap[cell_idx % MAX_CELLS] % len(NEON_PALETTE)]
        if self.color_mode == "cycle":
            return NEON_PALETTE[(self.pointer + order) % len(NEON_PALETTE)]
        return self.global_color

    # ── Playback ──────────────────────────────────────────────────────────────

    def play(self):
        self._playing = True
        self._timer.start(self.effective_ms)
        self.playing_changed.emit(True)

    def stop(self):
        self._playing = False
        self._timer.stop()
        self.playing_changed.emit(False)

    def toggle_play(self):
        self.stop() if self._playing else self.play()

    def reset(self):
        self.pointer = 0
        self.ticked.emit(0)

    def step(self, direction: int = 1):
        if not self._tokens:
            return
        self.pointer = (self.pointer + direction) % max(1, len(self._tokens))
        if self.distribution == "random" or self.color_mode == "random":
            self._rand_snap = [random.randint(0, 99999) for _ in range(MAX_CELLS)]
        self.ticked.emit(self.pointer)

    def external_tick(self):
        """Thread-safe tick entry point for MIDI/audio/OSC handlers."""
        self._do_tick()

    def update_speed(self):
        """Recalculate timer interval from current BPM/speed settings."""
        if self._playing:
            self._timer.start(self.effective_ms)

    def _do_tick(self):
        if not self._tokens:
            return
        self.pointer = (self.pointer + 1) % max(1, len(self._tokens))
        if self.distribution == "random" or self.color_mode == "random":
            self._rand_snap = [random.randint(0, 99999) for _ in range(MAX_CELLS)]
        self.ticked.emit(self.pointer)

    # ── Layout helpers ────────────────────────────────────────────────────────

    def toggle_custom_cell(self, idx: int):
        if idx < 0 or idx >= self.cell_count:
            return
        if idx in self.custom_cells:
            self.custom_cells.remove(idx)
        else:
            self.custom_cells.append(idx)
            self.custom_cells.sort()
        self.set_preset("Custom", emit_display=True)

    # ── Blanking helpers ──────────────────────────────────────────────────────

    def set_cell_blank(self, idx: int, blank: bool = True):
        if idx < 0 or idx >= self.cell_count:
            return
        changed = False
        if blank and idx not in self.blanked_cells:
            self.blanked_cells.add(idx)
            changed = True
        if not blank and idx in self.blanked_cells:
            self.blanked_cells.remove(idx)
            changed = True
        if changed:
            self.display_changed.emit()

    def set_cells_blank(self, indices: list[int], blank: bool = True):
        before = set(self.blanked_cells)
        for idx in indices:
            if 0 <= idx < self.cell_count:
                if blank:
                    self.blanked_cells.add(idx)
                else:
                    self.blanked_cells.discard(idx)
        if self.blanked_cells != before:
            self.display_changed.emit()

    def clear_blanks(self):
        if self.blanked_cells:
            self.blanked_cells.clear()
            self.display_changed.emit()
