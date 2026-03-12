"""control_window.py — Main control panel: all tabs, settings, transport, sync."""

import time
from PyQt6.QtWidgets import (
    QMainWindow, QWidget, QTabWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QLabel, QPushButton, QSlider, QComboBox, QTextEdit, QSpinBox, QDoubleSpinBox,
    QGroupBox, QCheckBox, QScrollArea, QStatusBar, QApplication, QFileDialog,
    QSizePolicy, QButtonGroup, QFrame,
)
from PyQt6.QtCore  import Qt, QTimer
from PyQt6.QtGui   import QFont, QColor, QKeySequence, QShortcut, QIcon

from engine        import (
    GridEngine, PRESET_NAMES, GRID_PROFILES, NEON_PALETTE, FONTS, DEFAULT_TEXT
)
from display_window import DisplayWindow
from preset_auto_switcher import AutoPresetSwitcher, AUTO_SWITCHABLE_PRESETS
from midi_handler  import MidiHandler
from audio_handler import AudioHandler
from osc_handler   import OscHandler
from file_watcher  import FileWatcher


# ─── Dark stylesheet ──────────────────────────────────────────────────────────

def _build_style(accent: str) -> str:
    return f"""
QMainWindow, QWidget {{
    background-color: #0a0a0a;
    color: #888888;
    font-family: "Courier New", monospace;
    font-size: 10px;
}}
QTabWidget::pane {{
    border: 1px solid #1a1a1a;
    background-color: #0a0a0a;
}}
QTabBar::tab {{
    background-color: #080808;
    color: #383838;
    padding: 9px 14px;
    font-size: 9px;
    letter-spacing: 2px;
    border: none;
    border-bottom: 2px solid transparent;
    min-width: 54px;
}}
QTabBar::tab:selected {{
    background-color: #141414;
    color: {accent};
    border-bottom: 2px solid {accent};
}}
QPushButton {{
    background-color: #141414;
    border: 1px solid #222222;
    color: #555555;
    padding: 7px 12px;
    font-family: "Courier New", monospace;
    font-size: 9px;
    letter-spacing: 1px;
}}
QPushButton:hover    {{ background-color: #1a1a1a; border: 1px solid #333333; }}
QPushButton:checked  {{ background-color: {accent}; color: #000000; border: 1px solid #555; }}
QPushButton:pressed  {{ background-color: {accent}; color: #000000; }}
QPushButton:disabled {{ color: #282828; border: 1px solid #181818; }}
QSlider::groove:horizontal {{ height: 2px; background: #2a2a2a; border: none; }}
QSlider::handle:horizontal {{
    background: {accent}; width: 13px; height: 13px;
    margin: -6px 0; border-radius: 0;
}}
QTextEdit, QSpinBox, QDoubleSpinBox, QComboBox, QLineEdit {{
    background-color: #111111;
    border: 1px solid #222222;
    color: #bbbbbb;
    font-family: "Courier New", monospace;
    font-size: 10px;
    padding: 4px;
    selection-background-color: {accent};
    selection-color: #000000;
}}
QComboBox::drop-down {{ border: none; width: 20px; }}
QComboBox QAbstractItemView {{
    background: #111; border: 1px solid #333;
    selection-background-color: {accent}; selection-color: #000;
}}
QGroupBox {{
    border: 1px solid #1a1a1a;
    margin-top: 18px;
    font-size: 8px;
    letter-spacing: 3px;
    color: #333333;
}}
QGroupBox::title {{
    subcontrol-origin: margin;
    left: 8px;
    padding: 0 6px;
    color: #444444;
}}
QCheckBox {{ color: #555555; spacing: 8px; }}
QCheckBox::indicator {{
    width: 13px; height: 13px;
    border: 1px solid #333333; background: #111111;
}}
QCheckBox::indicator:checked {{
    background: {accent}; border: 1px solid {accent};
}}
QScrollBar:vertical   {{ width: 4px;  background: #0a0a0a; }}
QScrollBar:horizontal {{ height: 4px; background: #0a0a0a; }}
QScrollBar::handle:vertical, QScrollBar::handle:horizontal {{
    background: #252525;
}}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
QStatusBar {{
    background: #070707;
    color: #2e2e2e;
    border-top: 1px solid #151515;
    font-size: 8px;
    letter-spacing: 1px;
}}
QLabel#sectionLabel {{
    font-size: 8px;
    letter-spacing: 3px;
    color: #383838;
}}
"""


# ─── Helper widgets ───────────────────────────────────────────────────────────

def _section_label(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setObjectName("sectionLabel")
    return lbl


def _divider() -> QFrame:
    f = QFrame()
    f.setFrameShape(QFrame.Shape.HLine)
    f.setStyleSheet("color: #1a1a1a;")
    return f


def _color_swatch(color_hex: str, selected: bool, callback) -> QPushButton:
    btn = QPushButton()
    btn.setFixedSize(26, 26)
    border = "2px solid #ffffff" if selected else "2px solid transparent"
    shadow = f"0 0 6px {color_hex}" if selected else "none"
    btn.setStyleSheet(
        f"background-color: {color_hex}; border: {border};"
    )
    btn.clicked.connect(callback)
    return btn


# ─── Control Window ───────────────────────────────────────────────────────────

class ControlWindow(QMainWindow):
    def __init__(
        self,
        engine: GridEngine,
        display: DisplayWindow,
        preset_switcher: AutoPresetSwitcher,
        midi: MidiHandler,
        audio: AudioHandler,
        osc: OscHandler,
        watcher: FileWatcher,
    ):
        super().__init__()
        self.engine  = engine
        self.display = display
        self.preset_switcher = preset_switcher
        self.midi    = midi
        self.audio   = audio
        self.osc     = osc
        self.watcher = watcher

        self._tap_times: list[float] = []
        self._auto_countdown_ms = 0
        self._bpm_flash_timer = QTimer(self)
        self._bpm_flash_timer.setSingleShot(True)

        self.setWindowTitle("TEXT GRID — Control")
        self.setMinimumSize(320, 600)
        self.resize(340, 700)
        self.setStyleSheet(_build_style(engine.global_color))

        self._build_ui()
        self._build_shortcuts()
        self._connect_signals()
        self._sync_auto_controls()
        self._sync_layout_controls()
        self._on_tokens(len(self.engine._tokens))

        # Initial status
        self._update_status()

    # ── UI construction ───────────────────────────────────────────────────────

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        root = QVBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Header
        header = QWidget()
        header.setStyleSheet("background-color: #070707; border-bottom: 1px solid #1a1a1a;")
        hl = QHBoxLayout(header)
        hl.setContentsMargins(14, 10, 14, 10)
        title = QLabel("TEXT GRID")
        title.setStyleSheet(f"font-size: 14px; color: {self.engine.global_color}; letter-spacing: 6px; font-weight: bold;")
        sub = QLabel("DISPLAY SYSTEM v1.0")
        sub.setStyleSheet("font-size: 8px; color: #252525; letter-spacing: 3px;")
        hl.addWidget(title)
        hl.addStretch()
        hl.addWidget(sub)
        root.addWidget(header)

        # Tabs
        self.tabs = QTabWidget()
        self.tabs.addTab(self._tab_layout(),    "LAYOUT")
        self.tabs.addTab(self._tab_text(),      "TEXT")
        self.tabs.addTab(self._tab_style(),     "STYLE")
        self.tabs.addTab(self._tab_play(),      "PLAY")
        self.tabs.addTab(self._tab_midi(),      "MIDI")
        self.tabs.addTab(self._tab_audio(),     "AUDIO")
        self.tabs.addTab(self._tab_osc(),       "OSC")
        self.tabs.addTab(self._tab_files(),     "FILES")
        root.addWidget(self.tabs)

        # Transport bar
        root.addWidget(self._transport_bar())

        # Status bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)

    def _scrollable(self, inner: QWidget) -> QWidget:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(inner)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        return scroll

    def _tab_layout(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 12, 12, 12)
        lay.setSpacing(10)

        lay.addWidget(_section_label("GRID PROFILE"))
        self.grid_profile_combo = QComboBox()
        self.grid_profile_combo.addItems(GRID_PROFILES.keys())
        self.grid_profile_combo.setCurrentText(self.engine.grid_profile)
        self.grid_profile_combo.currentTextChanged.connect(self._set_grid_profile)
        lay.addWidget(self.grid_profile_combo)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("PRESET"))
        preset_grid = QGridLayout()
        preset_grid.setSpacing(3)
        self._preset_btns = {}
        for i, name in enumerate(PRESET_NAMES):
            btn = QPushButton(name)
            btn.setCheckable(True)
            btn.setChecked(name == self.engine.preset_name)
            btn.clicked.connect(lambda _, n=name: self._set_preset(n))
            self._preset_btns[name] = btn
            preset_grid.addWidget(btn, i // 2, i % 2)
        lay.addLayout(preset_grid)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("AUTO SWITCH PRESETS"))
        auto_row = QHBoxLayout()
        self.auto_enable_btn = QPushButton("AUTO")
        self.auto_enable_btn.setCheckable(True)
        self.auto_enable_btn.setChecked(self.preset_switcher.enabled)
        self.auto_enable_btn.clicked.connect(self._toggle_auto_switch)
        auto_row.addWidget(self.auto_enable_btn)

        self.auto_seq_btn = QPushButton("SEQ")
        self.auto_seq_btn.setCheckable(True)
        self.auto_seq_btn.clicked.connect(lambda: self._set_auto_mode("sequential"))
        auto_row.addWidget(self.auto_seq_btn)

        self.auto_rand_btn = QPushButton("RND")
        self.auto_rand_btn.setCheckable(True)
        self.auto_rand_btn.clicked.connect(lambda: self._set_auto_mode("random"))
        auto_row.addWidget(self.auto_rand_btn)
        lay.addLayout(auto_row)

        interval_row = QHBoxLayout()
        interval_row.addWidget(QLabel("INTERVAL"))
        self.auto_interval_spin = QSpinBox()
        self.auto_interval_spin.setRange(80, 600000)
        self.auto_interval_spin.setSingleStep(50)
        self.auto_interval_spin.setValue(self.preset_switcher.interval_ms)
        self.auto_interval_spin.setSuffix(" ms")
        self.auto_interval_spin.valueChanged.connect(self._set_auto_interval)
        interval_row.addWidget(self.auto_interval_spin)
        for ms, label in [(250, "250"), (500, "500"), (1000, "1000"), (2000, "2000")]:
            btn = QPushButton(label)
            btn.clicked.connect(lambda _, v=ms: self.auto_interval_spin.setValue(v))
            interval_row.addWidget(btn)
        lay.addLayout(interval_row)

        self.auto_status_lbl = QLabel("")
        self.auto_status_lbl.setStyleSheet("font-size: 8px; color: #2e2e2e;")
        lay.addWidget(self.auto_status_lbl)
        note = QLabel("Manual preset choice restarts auto timer from now.")
        note.setStyleSheet("font-size: 8px; color: #242424;")
        lay.addWidget(note)

        lay.addWidget(_section_label("AUTO PRESET POOL"))
        pool_grid = QGridLayout()
        pool_grid.setSpacing(4)
        self._auto_pool_checks = {}
        enabled_pool = set(self.preset_switcher.enabled_presets)
        for i, name in enumerate(AUTO_SWITCHABLE_PRESETS):
            cb = QCheckBox(name)
            cb.setChecked(name in enabled_pool)
            cb.toggled.connect(lambda on, n=name: self._toggle_auto_pool_preset(n, on))
            self._auto_pool_checks[name] = cb
            pool_grid.addWidget(cb, i // 2, i % 2)
        lay.addLayout(pool_grid)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("BOXES / BORDER"))
        row = QHBoxLayout()
        self.boxes_on  = QPushButton("ON");  self.boxes_on.setCheckable(True)
        self.boxes_off = QPushButton("OFF"); self.boxes_off.setCheckable(True)
        self.boxes_on.setChecked(self.engine.show_boxes)
        self.boxes_off.setChecked(not self.engine.show_boxes)
        self.boxes_on.clicked.connect(lambda: self._set_boxes(True))
        self.boxes_off.clicked.connect(lambda: self._set_boxes(False))
        row.addWidget(self.boxes_on); row.addWidget(self.boxes_off)
        lay.addLayout(row)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("EFFECTS"))
        row2 = QHBoxLayout()
        self.glow_cb  = QCheckBox("GLOW");  self.glow_cb.setChecked(self.engine.glow_enabled)
        self.flash_cb = QCheckBox("FLASH"); self.flash_cb.setChecked(self.engine.flash_enabled)
        self.glow_cb.toggled.connect(lambda v: self._toggle("glow_enabled", v))
        self.flash_cb.toggled.connect(lambda v: self._toggle("flash_enabled", v))
        row2.addWidget(self.glow_cb); row2.addWidget(self.flash_cb)
        lay.addLayout(row2)

        self._sync_auto_controls()
        lay.addStretch()
        return self._scrollable(w)

    def _tab_text(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 12, 12, 12)
        lay.setSpacing(10)

        lay.addWidget(_section_label("INPUT TEXT"))
        self.text_edit = QTextEdit()
        self.text_edit.setPlainText(self.engine.raw_text)
        self.text_edit.setMinimumHeight(120)
        self.text_edit.textChanged.connect(
            lambda: self.engine.set_text(self.text_edit.toPlainText())
        )
        lay.addWidget(self.text_edit)
        self.token_label = QLabel("0 tokens")
        self.token_label.setStyleSheet("font-size: 8px; color: #2e2e2e;")
        lay.addWidget(self.token_label)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("TEXT MODE"))
        row = QHBoxLayout()
        self._text_mode_btns = {}
        for label, val in [
            ("LETTER", "letter"),
            ("WORD", "word"),
            ("PHRASE", "phrase"),
            ("CHUNK", "chunk"),
        ]:
            btn = QPushButton(label); btn.setCheckable(True)
            btn.setChecked(self.engine.text_mode == val)
            btn.clicked.connect(lambda _, v=val: self._set_text_mode(v))
            self._text_mode_btns[val] = btn
            row.addWidget(btn)
        lay.addLayout(row)

        lay.addWidget(_section_label("CHUNK SIZE (CHUNK MODE)"))
        c_row = QHBoxLayout()
        self.chunk_spin = QSpinBox()
        self.chunk_spin.setRange(1, 64)
        self.chunk_spin.setValue(self.engine.chunk_size)
        self.chunk_spin.valueChanged.connect(self._set_chunk_size)
        self.chunk_lbl = QLabel(f"{self.engine.chunk_size} chars/tile")
        self.chunk_lbl.setStyleSheet("font-size: 8px; color: #2e2e2e;")
        c_row.addWidget(self.chunk_spin)
        c_row.addWidget(self.chunk_lbl)
        c_row.addStretch()
        lay.addLayout(c_row)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("CELL DISTRIBUTION"))
        self._dist_btns = {}
        for label, val in [
            ("SEQUENTIAL — cascade", "sequential"),
            ("ALL SAME — lock cells", "all-same"),
            ("RANDOM — shuffle", "random"),
        ]:
            btn = QPushButton(label); btn.setCheckable(True)
            btn.setChecked(self.engine.distribution == val)
            btn.setStyleSheet(btn.styleSheet() + "text-align: left; padding-left: 8px;")
            btn.clicked.connect(lambda _, v=val: self._set_dist(v))
            self._dist_btns[val] = btn
            lay.addWidget(btn)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("TRANSFORM"))
        row2 = QHBoxLayout()
        self._tt_btns = {}
        for label, val in [("UPPER", "upper"), ("lower", "lower"), ("As-Is", "none")]:
            btn = QPushButton(label); btn.setCheckable(True)
            btn.setChecked(self.engine.text_transform == val)
            btn.clicked.connect(lambda _, v=val: self._set_transform(v))
            self._tt_btns[val] = btn
            row2.addWidget(btn)
        lay.addLayout(row2)

        self._update_chunk_controls()
        lay.addStretch()
        return self._scrollable(w)

    def _tab_style(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 12, 12, 12)
        lay.setSpacing(10)

        lay.addWidget(_section_label("FONT"))
        self.font_combo = QComboBox()
        self.font_combo.addItems(FONTS)
        idx = FONTS.index(self.engine.font_family) if self.engine.font_family in FONTS else 0
        self.font_combo.setCurrentIndex(idx)
        self.font_combo.currentTextChanged.connect(self._set_font)
        lay.addWidget(self.font_combo)

        lay.addWidget(_section_label("FONT SIZE"))
        self.font_slider = QSlider(Qt.Orientation.Horizontal)
        self.font_slider.setRange(5, 80)
        self.font_slider.setValue(self.engine.font_size_pct)
        self.font_size_lbl = QLabel(f"{self.engine.font_size_pct}%")
        self.font_slider.valueChanged.connect(self._set_font_size)
        row = QHBoxLayout(); row.addWidget(self.font_slider); row.addWidget(self.font_size_lbl)
        lay.addLayout(row)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("COLOR MODE"))
        self._color_mode_btns = {}
        for label, val in [
            ("GLOBAL — one color", "global"),
            ("PER CELL — custom per slot", "per-cell"),
            ("RANDOM — flash shuffle", "random"),
            ("CYCLE — rotate palette", "cycle"),
        ]:
            btn = QPushButton(label); btn.setCheckable(True)
            btn.setChecked(self.engine.color_mode == val)
            btn.setStyleSheet(btn.styleSheet() + "text-align: left; padding-left: 8px;")
            btn.clicked.connect(lambda _, v=val: self._set_color_mode(v))
            self._color_mode_btns[val] = btn
            lay.addWidget(btn)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("TEXT COLOR (GLOBAL / CYCLE)"))
        swatch_grid = QGridLayout(); swatch_grid.setSpacing(4)
        self._swatches = []
        for i, c in enumerate(NEON_PALETTE):
            sel = (c == self.engine.global_color)
            btn = _color_swatch(c, sel, lambda _, col=c: self._set_global_color(col))
            swatch_grid.addWidget(btn, i // 6, i % 6)
            self._swatches.append((btn, c))
        lay.addLayout(swatch_grid)

        lay.addWidget(_section_label("BACKGROUND"))
        bg_row = QHBoxLayout()
        for c in ["#000000", "#050505", "#0a0000", "#000a00", "#00000a", "#080808"]:
            btn = QPushButton()
            btn.setFixedSize(26, 26)
            sel = (c == self.engine.bg_color)
            btn.setStyleSheet(f"background:{c}; border: {'2px solid #888' if sel else '1px solid #222'};")
            btn.clicked.connect(lambda _, col=c: self._set_bg(col))
            bg_row.addWidget(btn)
        bg_row.addStretch()
        lay.addLayout(bg_row)

        lay.addStretch()
        return self._scrollable(w)

    def _tab_play(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 12, 12, 12)
        lay.setSpacing(10)

        lay.addWidget(_section_label("TIMING MODE"))
        row = QHBoxLayout()
        self.manual_btn = QPushButton("MANUAL");  self.manual_btn.setCheckable(True)
        self.bpm_btn    = QPushButton("BPM SYNC"); self.bpm_btn.setCheckable(True)
        self.manual_btn.setChecked(not self.engine.bpm_sync)
        self.bpm_btn.setChecked(self.engine.bpm_sync)
        self.manual_btn.clicked.connect(lambda: self._set_timing(False))
        self.bpm_btn.clicked.connect(lambda: self._set_timing(True))
        row.addWidget(self.manual_btn); row.addWidget(self.bpm_btn)
        lay.addLayout(row)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("SPEED (MANUAL)"))
        self.speed_slider = QSlider(Qt.Orientation.Horizontal)
        self.speed_slider.setRange(20, 2000)
        self.speed_slider.setValue(self.engine.speed_ms)
        self.speed_lbl = QLabel(f"{self.engine.speed_ms} ms")
        self.speed_slider.valueChanged.connect(self._set_speed)
        sr = QHBoxLayout(); sr.addWidget(self.speed_slider); sr.addWidget(self.speed_lbl)
        lay.addLayout(sr)

        quick = QHBoxLayout()
        for ms, label in [(80, "80ms"), (200, "200ms"), (400, "400ms"), (800, "800ms")]:
            btn = QPushButton(label)
            btn.clicked.connect(lambda _, v=ms: self._quick_speed(v))
            quick.addWidget(btn)
        lay.addLayout(quick)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("BPM"))
        self.bpm_spin = QDoubleSpinBox()
        self.bpm_spin.setRange(40.0, 300.0)
        self.bpm_spin.setValue(self.engine.bpm)
        self.bpm_spin.setDecimals(1)
        self.bpm_spin.setSingleStep(1.0)
        self.bpm_spin.setStyleSheet("font-size: 18px; text-align: center;")
        self.bpm_spin.valueChanged.connect(self._set_bpm)
        lay.addWidget(self.bpm_spin)

        self.tap_btn = QPushButton("TAP TEMPO")
        self.tap_btn.setFixedHeight(50)
        self.tap_btn.setStyleSheet(self.tap_btn.styleSheet() + "font-size: 12px; letter-spacing: 4px;")
        self.tap_btn.pressed.connect(self._tap_tempo)
        lay.addWidget(self.tap_btn)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("BEAT DIVISION"))
        div_row = QHBoxLayout()
        self._div_btns = {}
        for label, val in [("½", 2.0), ("¼", 1.0), ("⅛", 0.5), ("1/16", 0.25)]:
            btn = QPushButton(label); btn.setCheckable(True)
            btn.setChecked(self.engine.beat_division == val)
            btn.setStyleSheet(btn.styleSheet() + "font-size: 14px;")
            btn.clicked.connect(lambda _, v=val: self._set_div(v))
            self._div_btns[val] = btn
            div_row.addWidget(btn)
        lay.addLayout(div_row)

        self.interval_lbl = QLabel()
        self.interval_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.interval_lbl.setStyleSheet("font-size: 8px; color: #2a2a2a; margin: 4px;")
        lay.addWidget(self.interval_lbl)
        self._update_interval_label()

        lay.addWidget(_divider())
        lay.addWidget(_section_label("DISPLAY OUTPUT"))
        screen_row = QHBoxLayout()
        screens = QApplication.screens()
        for i, scr in enumerate(screens):
            name = scr.name() or f"Screen {i}"
            btn = QPushButton(f"→ {name[:12]}")
            btn.setToolTip(f"{scr.geometry().width()}×{scr.geometry().height()}")
            btn.clicked.connect(lambda _, idx=i: self.display.move_to_screen(idx))
            screen_row.addWidget(btn)
        lay.addLayout(screen_row)

        btn_fs = QPushButton("⛶  FULLSCREEN (F)")
        btn_fs.clicked.connect(self.display.toggle_fullscreen)
        lay.addWidget(btn_fs)

        lay.addStretch()
        return self._scrollable(w)

    def _tab_midi(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 12, 12, 12)
        lay.setSpacing(10)

        lay.addWidget(_section_label("MIDI INPUT (CLOCK IN)"))
        self.midi_in_combo = QComboBox()
        self.midi_in_combo.addItem("— select port —")
        self.midi_in_combo.addItems(MidiHandler.available_inputs())
        lay.addWidget(self.midi_in_combo)

        row = QHBoxLayout()
        self.midi_in_open  = QPushButton("OPEN")
        self.midi_in_close = QPushButton("CLOSE")
        self.midi_enabled_cb = QCheckBox("ENABLED")
        self.midi_enabled_cb.setChecked(self.midi.enabled)
        self.midi_in_open.clicked.connect(self._open_midi_in)
        self.midi_in_close.clicked.connect(self.midi.close_input)
        self.midi_enabled_cb.toggled.connect(lambda v: setattr(self.midi, "enabled", v))
        row.addWidget(self.midi_in_open); row.addWidget(self.midi_in_close)
        row.addWidget(self.midi_enabled_cb)
        lay.addLayout(row)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("MIDI OUTPUT (CLOCK OUT)"))
        self.midi_out_combo = QComboBox()
        self.midi_out_combo.addItem("— select port —")
        self.midi_out_combo.addItems(MidiHandler.available_outputs())
        lay.addWidget(self.midi_out_combo)

        row2 = QHBoxLayout()
        self.midi_out_open  = QPushButton("OPEN")
        self.midi_out_close = QPushButton("CLOSE")
        self.midi_send_cb   = QCheckBox("SEND")
        self.midi_send_cb.setChecked(self.midi.send_enabled)
        self.midi_out_open.clicked.connect(self._open_midi_out)
        self.midi_out_close.clicked.connect(self.midi.close_output)
        self.midi_send_cb.toggled.connect(lambda v: setattr(self.midi, "send_enabled", v))
        row2.addWidget(self.midi_out_open); row2.addWidget(self.midi_out_close)
        row2.addWidget(self.midi_send_cb)
        lay.addLayout(row2)

        self.midi_status_lbl = QLabel("No MIDI port open")
        self.midi_status_lbl.setStyleSheet("font-size: 8px; color: #2a2a2a; margin-top: 6px;")
        lay.addWidget(self.midi_status_lbl)

        lay.addStretch()
        return self._scrollable(w)

    def _tab_audio(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 12, 12, 12)
        lay.setSpacing(10)

        lay.addWidget(_section_label("AUDIO INPUT DEVICE"))
        self.audio_combo = QComboBox()
        self.audio_combo.addItem("— system default —")
        for idx, name in AudioHandler.available_devices():
            self.audio_combo.addItem(f"{idx}: {name}", idx)
        lay.addWidget(self.audio_combo)

        row = QHBoxLayout()
        self.audio_start_btn = QPushButton("START")
        self.audio_stop_btn  = QPushButton("STOP")
        self.audio_cb        = QCheckBox("ENABLED")
        self.audio_cb.setChecked(self.audio.enabled)
        self.audio_start_btn.clicked.connect(self._start_audio)
        self.audio_stop_btn.clicked.connect(self.audio.stop)
        self.audio_cb.toggled.connect(lambda v: setattr(self.audio, "enabled", v))
        row.addWidget(self.audio_start_btn); row.addWidget(self.audio_stop_btn)
        row.addWidget(self.audio_cb)
        lay.addLayout(row)

        # VU meter
        lay.addWidget(_section_label("LEVEL"))
        self.vu_bar = QLabel()
        self.vu_bar.setFixedHeight(8)
        self.vu_bar.setStyleSheet(f"background: #1a1a1a; border: 1px solid #222;")
        lay.addWidget(self.vu_bar)
        self.audio.level.connect(self._update_vu)

        self.audio_bpm_lbl = QLabel("BPM: —")
        self.audio_bpm_lbl.setStyleSheet(f"font-size: 22px; color: {self.engine.global_color}; text-align: center;")
        self.audio_bpm_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lay.addWidget(self.audio_bpm_lbl)

        self.audio_status_lbl = QLabel("Audio not started")
        self.audio_status_lbl.setStyleSheet("font-size: 8px; color: #2a2a2a;")
        lay.addWidget(self.audio_status_lbl)

        lay.addStretch()
        return self._scrollable(w)

    def _tab_osc(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 12, 12, 12)
        lay.setSpacing(10)

        lay.addWidget(_section_label("RECEIVE (SERVER)"))
        from PyQt6.QtWidgets import QLineEdit
        self.osc_rx_ip   = QLineEdit("0.0.0.0")
        self.osc_rx_port = QSpinBox(); self.osc_rx_port.setRange(1, 65535); self.osc_rx_port.setValue(8000)
        row = QHBoxLayout()
        row.addWidget(QLabel("IP")); row.addWidget(self.osc_rx_ip)
        row.addWidget(QLabel("Port")); row.addWidget(self.osc_rx_port)
        lay.addLayout(row)

        row2 = QHBoxLayout()
        self.osc_start_btn = QPushButton("START SERVER")
        self.osc_stop_btn  = QPushButton("STOP")
        self.osc_rx_cb     = QCheckBox("ENABLED")
        self.osc_rx_cb.setChecked(self.osc.receive_enabled)
        self.osc_start_btn.clicked.connect(self._start_osc_server)
        self.osc_stop_btn.clicked.connect(self.osc.stop_server)
        self.osc_rx_cb.toggled.connect(lambda v: setattr(self.osc, "receive_enabled", v))
        row2.addWidget(self.osc_start_btn); row2.addWidget(self.osc_stop_btn); row2.addWidget(self.osc_rx_cb)
        lay.addLayout(row2)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("SEND (CLIENT — EXTRON / QLAB / ETC)"))
        self.osc_tx_ip   = QLineEdit("192.168.1.1")
        self.osc_tx_port = QSpinBox(); self.osc_tx_port.setRange(1, 65535); self.osc_tx_port.setValue(8001)
        row3 = QHBoxLayout()
        row3.addWidget(QLabel("IP")); row3.addWidget(self.osc_tx_ip)
        row3.addWidget(QLabel("Port")); row3.addWidget(self.osc_tx_port)
        lay.addLayout(row3)

        row4 = QHBoxLayout()
        self.osc_open_btn  = QPushButton("OPEN CLIENT")
        self.osc_close_btn = QPushButton("CLOSE")
        self.osc_tx_cb     = QCheckBox("SEND")
        self.osc_tx_cb.setChecked(self.osc.send_enabled)
        self.osc_open_btn.clicked.connect(self._open_osc_client)
        self.osc_close_btn.clicked.connect(self.osc.close_client)
        self.osc_tx_cb.toggled.connect(lambda v: setattr(self.osc, "send_enabled", v))
        row4.addWidget(self.osc_open_btn); row4.addWidget(self.osc_close_btn); row4.addWidget(self.osc_tx_cb)
        lay.addLayout(row4)

        self.osc_status_lbl = QLabel("OSC not configured")
        self.osc_status_lbl.setStyleSheet("font-size: 8px; color: #2a2a2a; margin-top: 6px;")
        self.osc.status_changed.connect(self.osc_status_lbl.setText)
        lay.addWidget(self.osc_status_lbl)

        lay.addWidget(_divider())
        lay.addWidget(_section_label("ADDRESS MAP"))
        map_text = (
            "RECEIVE:\n"
            "  /textgrid/play\n"
            "  /textgrid/stop\n"
            "  /textgrid/tick\n"
            "  /textgrid/reset\n"
            "  /textgrid/bpm  <float>\n"
            "  /textgrid/preset <str>\n"
            "  /textgrid/grid <str>   e.g. 3x4\n"
            "  /textgrid/pointer <int>\n"
            "  /textgrid/speed <int ms>\n\n"
            "  /textgrid/blank <int|csv>\n"
            "  /textgrid/unblank <int|csv>\n"
            "  /textgrid/clear_blanks\n\n"
            "SEND:\n"
            "  /textgrid/beat <int>\n"
            "  /textgrid/state playing|stopped"
        )
        map_lbl = QLabel(map_text)
        map_lbl.setStyleSheet("font-size: 9px; color: #2a2a2a; font-family: 'Courier New';")
        lay.addWidget(map_lbl)

        lay.addStretch()
        return self._scrollable(w)

    def _tab_files(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 12, 12, 12)
        lay.setSpacing(10)

        lay.addWidget(_section_label("TEXT FILE"))
        from PyQt6.QtWidgets import QLineEdit
        self.file_path_edit = QLineEdit()
        self.file_path_edit.setReadOnly(True)
        self.file_path_edit.setPlaceholderText("No file selected…")
        lay.addWidget(self.file_path_edit)

        row = QHBoxLayout()
        browse_btn = QPushButton("BROWSE…")
        reload_btn = QPushButton("RELOAD")
        stop_btn   = QPushButton("UNWATCH")
        browse_btn.clicked.connect(self._browse_file)
        reload_btn.clicked.connect(self.watcher.reload)
        stop_btn.clicked.connect(self.watcher.stop)
        row.addWidget(browse_btn); row.addWidget(reload_btn); row.addWidget(stop_btn)
        lay.addLayout(row)

        self.file_status_lbl = QLabel("No file loaded")
        self.file_status_lbl.setStyleSheet("font-size: 8px; color: #2a2a2a; margin-top: 4px;")
        self.watcher.status.connect(self.file_status_lbl.setText)
        self.watcher.file_error.connect(self.file_status_lbl.setText)
        lay.addWidget(self.file_status_lbl)

        lay.addWidget(_divider())
        info = QLabel(
            "File is hot-reloaded on save.\n"
            "One entry per line → phrase mode.\n"
            "UTF-8 encoding supported."
        )
        info.setStyleSheet("font-size: 9px; color: #252525; line-height: 180%;")
        lay.addWidget(info)

        lay.addStretch()
        return self._scrollable(w)

    def _transport_bar(self) -> QWidget:
        bar = QWidget()
        bar.setStyleSheet("background: #070707; border-top: 1px solid #181818;")
        lay = QHBoxLayout(bar)
        lay.setContentsMargins(10, 8, 10, 8)
        lay.setSpacing(6)

        self.play_btn = QPushButton("▶")
        self.stop_btn = QPushButton("■")
        self.step_btn = QPushButton("▶|")
        self.play_btn.setFixedSize(48, 40)
        self.stop_btn.setFixedSize(38, 40)
        self.step_btn.setFixedSize(38, 40)
        self.play_btn.setStyleSheet(
            self.play_btn.styleSheet() + "font-size: 18px;"
        )
        self.play_btn.setCheckable(True)
        self.play_btn.clicked.connect(self.engine.toggle_play)
        self.stop_btn.clicked.connect(lambda: (self.engine.stop(), self.engine.reset()))
        self.step_btn.clicked.connect(lambda: self.engine.step(1))

        self.ptr_lbl = QLabel("PTR: 0")
        self.ptr_lbl.setStyleSheet(f"font-size: 10px; color: {self.engine.global_color}; min-width: 60px;")

        lay.addWidget(self.play_btn)
        lay.addWidget(self.stop_btn)
        lay.addWidget(self.step_btn)
        lay.addStretch()
        lay.addWidget(self.ptr_lbl)

        return bar

    # ── Keyboard shortcuts ────────────────────────────────────────────────────

    def _build_shortcuts(self):
        QShortcut(QKeySequence("Space"),       self, self.engine.toggle_play)
        QShortcut(QKeySequence("Right"),       self, lambda: self.engine.step(1))
        QShortcut(QKeySequence("Left"),        self, lambda: self.engine.step(-1))
        QShortcut(QKeySequence("R"),           self, self.engine.reset)
        QShortcut(QKeySequence("F"),           self, self.display.toggle_fullscreen)
        QShortcut(QKeySequence("Ctrl+Return"), self, self.display.show)
        QShortcut(QKeySequence("A"),           self, self.preset_switcher.toggle_enabled)
        QShortcut(QKeySequence("]"),           self, self.preset_switcher.switch_next)
        QShortcut(QKeySequence("["),           self, self.preset_switcher.switch_previous)

    # ── Signal connections ────────────────────────────────────────────────────

    def _connect_signals(self):
        eng = self.engine
        eng.ticked.connect(self._on_tick)
        eng.tokens_updated.connect(self._on_tokens)
        eng.playing_changed.connect(self._on_playing)
        eng.display_changed.connect(self._on_display_changed)
        self.preset_switcher.auto_changed.connect(self._on_auto_changed)
        self.preset_switcher.config_changed.connect(self._sync_auto_controls)
        self.preset_switcher.switched.connect(self._on_auto_switched)
        self.preset_switcher.countdown_changed.connect(self._on_auto_countdown)
        self.preset_switcher.status_message.connect(self._on_auto_message)
        self.midi.port_error.connect(lambda s: self.midi_status_lbl.setText(s))
        self.midi.bpm_detected.connect(self._on_midi_bpm)
        self.audio.bpm_detected.connect(self._on_audio_bpm)
        self.audio.error.connect(lambda s: self.audio_status_lbl.setText(s))

    # ── Slots ─────────────────────────────────────────────────────────────────

    def _on_tick(self, ptr: int):
        self.ptr_lbl.setText(f"PTR: {ptr}")
        self._update_status()

    def _on_tokens(self, count: int):
        self.token_label.setText(f"{count} tokens")
        self._update_status()

    def _on_playing(self, playing: bool):
        self.play_btn.setChecked(playing)
        self.play_btn.setText("■■" if playing else "▶")
        self._update_status()

    def _on_display_changed(self):
        self._sync_layout_controls()
        self._update_status()

    def _on_auto_changed(self, _enabled: bool):
        self._sync_auto_controls()
        self._update_status()

    def _on_auto_switched(self, _preset: str, _source: str):
        self._sync_layout_controls()
        self._update_status()

    def _on_auto_countdown(self, ms: int):
        self._auto_countdown_ms = max(0, int(ms))
        self._update_auto_status_label()
        self._update_status()

    def _on_auto_message(self, msg: str):
        if msg:
            self.auto_status_lbl.setText(msg)

    def _on_midi_bpm(self, bpm: float):
        self.midi_status_lbl.setText(f"MIDI clock detected — {bpm:.1f} BPM")
        if self.engine.bpm_sync:
            self.engine.bpm = bpm
            self.bpm_spin.blockSignals(True)
            self.bpm_spin.setValue(bpm)
            self.bpm_spin.blockSignals(False)
            self.engine.update_speed()

    def _on_audio_bpm(self, bpm: float):
        self.audio_bpm_lbl.setText(f"BPM: {bpm:.1f}")
        self.audio_status_lbl.setText(f"Beat detected — {bpm:.1f} BPM")
        if self.engine.bpm_sync:
            self.engine.bpm = bpm
            self.bpm_spin.blockSignals(True)
            self.bpm_spin.setValue(bpm)
            self.bpm_spin.blockSignals(False)
            self.engine.update_speed()

    def _update_vu(self, level: float):
        w = int(self.vu_bar.width() * level)
        hue = int(120 - level * 120)   # green → red
        self.vu_bar.setStyleSheet(
            f"background: qlineargradient(x1:0, y1:0, x2:1, y2:0, "
            f"stop:0 hsl({hue}, 100%, 50%), stop:{min(0.99, level):.2f} hsl({hue}, 100%, 50%), "
            f"stop:{min(1.0, level + 0.01):.2f} #1a1a1a, stop:1 #1a1a1a);"
        )

    def _update_status(self):
        eng = self.engine
        state = "▶ PLAYING" if eng.playing else "■ STOPPED"
        mode  = f"{eng.text_mode.upper()} / {eng.distribution}"
        ms    = eng.effective_ms
        bpm   = round(60000 / ms, 1) if ms > 0 else 0
        active = len(eng.active_indices)
        visible = len(eng.visible_indices)
        blanked = len(eng.blanked_cells)
        blanked_text = f" / {blanked} blanked" if blanked else ""
        auto_state = "AUTO ON" if self.preset_switcher.enabled else "AUTO OFF"
        auto_mode = self.preset_switcher.mode.upper()
        next_s = self._auto_countdown_ms / 1000.0
        self.status_bar.showMessage(
            f"  {state}   ·   {eng.grid_profile}   ·   {eng.preset_name}   ·   {mode}   ·   "
            f"{ms}ms / {bpm}BPM   ·   {visible}/{active} visible{blanked_text}   ·   "
            f"{auto_state} {auto_mode} ({next_s:.1f}s)"
        )

    def _update_interval_label(self):
        ms  = self.engine.effective_ms
        bpm = round(60000 / ms, 1) if ms > 0 else 0
        self.interval_lbl.setText(f"Interval: {ms}ms  (~{bpm} BPM)")

    # ── Control callbacks ─────────────────────────────────────────────────────

    def _update_auto_status_label(self):
        if not self.preset_switcher.enabled:
            self.auto_status_lbl.setText("Auto switch is OFF")
            return
        pool = self.preset_switcher.scene_cycle or self.preset_switcher.enabled_presets
        self.auto_status_lbl.setText(
            f"AUTO {self.preset_switcher.mode.upper()} · {len(pool)} presets · "
            f"next in {self._auto_countdown_ms / 1000.0:.1f}s"
        )

    def _sync_auto_controls(self):
        enabled = self.preset_switcher.enabled
        self.auto_enable_btn.blockSignals(True)
        self.auto_enable_btn.setChecked(enabled)
        self.auto_enable_btn.setText("AUTO ON" if enabled else "AUTO OFF")
        self.auto_enable_btn.blockSignals(False)

        mode = self.preset_switcher.mode
        self.auto_seq_btn.setChecked(mode == "sequential")
        self.auto_rand_btn.setChecked(mode == "random")

        self.auto_interval_spin.blockSignals(True)
        self.auto_interval_spin.setValue(self.preset_switcher.interval_ms)
        self.auto_interval_spin.blockSignals(False)

        selected = set(self.preset_switcher.enabled_presets)
        for name, cb in self._auto_pool_checks.items():
            cb.blockSignals(True)
            cb.setChecked(name in selected)
            cb.blockSignals(False)

        self._update_auto_status_label()

    def _toggle_auto_switch(self, on: bool):
        self.preset_switcher.set_enabled(on)

    def _set_auto_mode(self, mode: str):
        self.preset_switcher.set_mode(mode)
        self._sync_auto_controls()

    def _set_auto_interval(self, ms: int):
        self.preset_switcher.set_interval_ms(ms)
        self._sync_auto_controls()

    def _toggle_auto_pool_preset(self, preset: str, enabled: bool):
        current = list(self.preset_switcher.enabled_presets)
        if enabled and preset not in current:
            current.append(preset)
        if not enabled and preset in current:
            current.remove(preset)
        self.preset_switcher.set_enabled_presets(current)
        self._sync_auto_controls()

    def _sync_layout_controls(self):
        self.grid_profile_combo.blockSignals(True)
        self.grid_profile_combo.setCurrentText(self.engine.grid_profile)
        self.grid_profile_combo.blockSignals(False)
        for n, btn in self._preset_btns.items():
            btn.setChecked(n == self.engine.preset_name)

    def _update_chunk_controls(self):
        is_chunk = self.engine.text_mode == "chunk"
        self.chunk_spin.setEnabled(is_chunk)
        self.chunk_lbl.setEnabled(is_chunk)
        self.chunk_lbl.setText(f"{self.engine.chunk_size} chars/tile")

    def _set_grid_profile(self, profile: str):
        if self.engine.set_grid_profile(profile):
            self._update_status()

    def _set_preset(self, name: str):
        self.preset_switcher.apply_manual_preset(name, source="ui")
        for n, btn in self._preset_btns.items():
            btn.setChecked(n == self.engine.preset_name)
        self._update_status()

    def _set_boxes(self, on: bool):
        self.engine.show_boxes = on
        self.boxes_on.setChecked(on); self.boxes_off.setChecked(not on)
        self.engine.display_changed.emit()

    def _toggle(self, attr: str, value: bool):
        setattr(self.engine, attr, value)
        self.engine.display_changed.emit()

    def _set_text_mode(self, mode: str):
        self.engine.set_text_mode(mode)
        for k, btn in self._text_mode_btns.items():
            btn.setChecked(k == mode)
        self._update_chunk_controls()

    def _set_chunk_size(self, size: int):
        self.engine.set_chunk_size(size)
        self._update_chunk_controls()

    def _set_dist(self, dist: str):
        self.engine.distribution = dist
        for k, btn in self._dist_btns.items():
            btn.setChecked(k == dist)

    def _set_transform(self, tt: str):
        self.engine.text_transform = tt
        for k, btn in self._tt_btns.items():
            btn.setChecked(k == tt)
        self.engine.display_changed.emit()

    def _set_font(self, family: str):
        self.engine.font_family = family
        self.engine.display_changed.emit()

    def _set_font_size(self, val: int):
        self.engine.font_size_pct = val
        self.font_size_lbl.setText(f"{val}%")
        self.engine.display_changed.emit()

    def _set_color_mode(self, mode: str):
        self.engine.color_mode = mode
        for k, btn in self._color_mode_btns.items():
            btn.setChecked(k == mode)
        self.engine.display_changed.emit()

    def _set_global_color(self, color: str):
        self.engine.global_color = color
        self.setStyleSheet(_build_style(color))
        for btn, c in self._swatches:
            sel = (c == color)
            btn.setStyleSheet(
                f"background-color: {c}; border: {'2px solid #fff' if sel else '2px solid transparent'};"
            )
        self.engine.display_changed.emit()

    def _set_bg(self, color: str):
        self.engine.bg_color = color
        self.engine.display_changed.emit()

    def _set_timing(self, bpm_sync: bool):
        self.engine.bpm_sync = bpm_sync
        self.manual_btn.setChecked(not bpm_sync)
        self.bpm_btn.setChecked(bpm_sync)
        self.engine.update_speed()
        self._update_interval_label()

    def _set_speed(self, ms: int):
        self.engine.speed_ms = ms
        self.speed_lbl.setText(f"{ms} ms")
        self.engine.update_speed()
        self._update_interval_label()

    def _quick_speed(self, ms: int):
        self.speed_slider.setValue(ms)

    def _set_bpm(self, bpm: float):
        self.engine.bpm = bpm
        self.engine.update_speed()
        self._update_interval_label()

    def _set_div(self, div: float):
        self.engine.beat_division = div
        for k, btn in self._div_btns.items():
            btn.setChecked(k == div)
        self.midi.set_beat_division(div)
        self.engine.update_speed()
        self._update_interval_label()

    def _tap_tempo(self):
        now = time.perf_counter()
        self._tap_times.append(now)
        if len(self._tap_times) > 8:
            self._tap_times.pop(0)
        if len(self._tap_times) >= 2:
            diffs = [self._tap_times[i+1] - self._tap_times[i]
                     for i in range(len(self._tap_times) - 1)]
            avg  = sum(diffs) / len(diffs)
            bpm  = min(300.0, max(40.0, 60.0 / avg))
            self.engine.bpm = round(bpm, 1)
            self.engine.bpm_sync = True
            self.bpm_btn.setChecked(True); self.manual_btn.setChecked(False)
            self.bpm_spin.blockSignals(True)
            self.bpm_spin.setValue(self.engine.bpm)
            self.bpm_spin.blockSignals(False)
            self.engine.update_speed()
            self._update_interval_label()

    def _open_midi_in(self):
        name = self.midi_in_combo.currentText()
        if name and name != "— select port —":
            self.midi.open_input(name)
            self.midi_status_lbl.setText(f"MIDI in: {name}")

    def _open_midi_out(self):
        name = self.midi_out_combo.currentText()
        if name and name != "— select port —":
            self.midi.open_output(name)
            self.midi_status_lbl.setText(f"MIDI out: {name}")

    def _start_audio(self):
        idx = self.audio_combo.currentData()
        self.audio.start(idx)
        self.audio_status_lbl.setText("Audio started…")

    def _start_osc_server(self):
        ip   = self.osc_rx_ip.text()
        port = self.osc_rx_port.value()
        self.osc.start_server(ip, port)
        self.osc.receive_enabled = True

    def _open_osc_client(self):
        ip   = self.osc_tx_ip.text()
        port = self.osc_tx_port.value()
        self.osc.open_client(ip, port)
        self.osc.send_enabled = True

    def _browse_file(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Open Text File", "", "Text files (*.txt);;All files (*)"
        )
        if path:
            self.file_path_edit.setText(path)
            self.watcher.watch(path)

    # ── Cleanup ───────────────────────────────────────────────────────────────

    def closeEvent(self, event):
        self.preset_switcher.set_enabled(False)
        self.midi.shutdown()
        self.audio.shutdown()
        self.osc.shutdown()
        self.watcher.shutdown()
        self.display.close()
        event.accept()
