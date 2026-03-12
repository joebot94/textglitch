"""display_window.py — The output display: dynamic grid, fullscreen, multi-screen."""

from PyQt6.QtWidgets import QWidget, QGridLayout, QSizePolicy, QApplication
from PyQt6.QtCore    import Qt, QTimer, QRect
from PyQt6.QtGui     import QPainter, QColor, QFont, QPen, QFontMetrics

from engine import GridEngine


# ─── Cell Widget ──────────────────────────────────────────────────────────────

class CellWidget(QWidget):
    def __init__(self, index: int, engine: GridEngine):
        super().__init__()
        self.index   = index
        self.engine  = engine
        self._flash  = 0          # 0-100 alpha for flash overlay

        self._fade_timer = QTimer(self)
        self._fade_timer.setInterval(12)          # ~80fps fade
        self._fade_timer.timeout.connect(self._fade_step)

        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setMinimumSize(40, 40)

    # ── Flash ────────────────────────────────────────────────────────────────

    def trigger_flash(self):
        if self.engine.flash_enabled:
            self._flash = 95
            self._fade_timer.start()
        self.update()

    def _fade_step(self):
        self._flash = max(0, self._flash - 20)
        self.update()
        if self._flash == 0:
            self._fade_timer.stop()

    # ── Paint ─────────────────────────────────────────────────────────────────

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.TextAntialiasing)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        eng = self.engine
        w, h = self.width(), self.height()
        active = self.index in eng.active_indices
        visible = eng.is_cell_visible(self.index)
        color  = eng.get_cell_color(self.index)

        # ── Background ────────────────────────────────────────────────────────
        painter.fillRect(0, 0, w, h, QColor(eng.bg_color))

        # ── Scan-line texture on active cells ─────────────────────────────────
        if visible and eng.show_boxes:
            scan_c = QColor(color)
            scan_c.setAlpha(6)
            y = 0
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(scan_c)
            while y < h:
                painter.drawRect(0, y, w, 1)
                y += 4

        # ── Flash overlay ────────────────────────────────────────────────────
        if self._flash > 0 and visible:
            fc = QColor(color)
            fc.setAlpha(self._flash)
            painter.fillRect(0, 0, w, h, fc)

        # ── Border ────────────────────────────────────────────────────────────
        if eng.show_boxes:
            if visible:
                bc = QColor(color)
                bc.setAlpha(45)
            elif active:
                bc = QColor("#222222")
            else:
                bc = QColor("#181818")
            painter.setPen(QPen(bc, 1))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRect(0, 0, w - 1, h - 1)

        # ── Text ─────────────────────────────────────────────────────────────
        if visible:
            text = eng.get_cell_text(self.index)
            if text:
                self._draw_text(painter, text, color, w, h)

        # ── Custom-mode index badge ───────────────────────────────────────────
        if eng.preset_name == "Custom":
            small = QFont("Courier New", 7)
            painter.setFont(small)
            ic = QColor(color if active else "#2a2a2a")
            ic.setAlpha(160 if active else 255)
            painter.setPen(ic)
            painter.drawText(4, 13, str(self.index))

    def _draw_text(self, painter: QPainter, text: str, color_hex: str, w: int, h: int):
        eng = self.engine
        base = max(8, int(min(w, h) * eng.font_size_pct / 100.0))

        font = QFont(eng.font_family, base)
        font.setWeight(QFont.Weight.Black)

        # Scale down for long text
        fm = QFontMetrics(font)
        text_w = fm.horizontalAdvance(text)
        if text_w > w * 0.88:
            ratio  = (w * 0.88) / max(1, text_w)
            base   = max(6, int(base * ratio))
            font   = QFont(eng.font_family, base)
            font.setWeight(QFont.Weight.Black)

        painter.setFont(font)
        qc = QColor(color_hex)

        # Glow layers
        if eng.glow_enabled:
            for alpha, spread in [(22, 7), (12, 4)]:
                gc = QColor(qc)
                gc.setAlpha(alpha)
                painter.setPen(gc)
                for dx, dy in [(-spread, 0), (spread, 0), (0, -spread), (0, spread),
                                (-spread, -spread), (spread, spread)]:
                    painter.drawText(dx, dy, w, h, Qt.AlignmentFlag.AlignCenter, text)

        # Main text
        painter.setPen(qc)
        painter.drawText(0, 0, w, h, Qt.AlignmentFlag.AlignCenter, text)

    # ── Mouse ─────────────────────────────────────────────────────────────────

    def mousePressEvent(self, event):
        if self.engine.preset_name == "Custom":
            self.engine.toggle_custom_cell(self.index)
            self.update()


# ─── Display Window ───────────────────────────────────────────────────────────

class DisplayWindow(QWidget):
    """The output window: a dynamic grid that can float, fullscreen, or target a screen."""

    def __init__(self, engine: GridEngine):
        super().__init__()
        self.engine = engine
        self.cells: list[CellWidget] = []

        self.setWindowTitle("TEXT GRID — Display")
        self.setMinimumSize(400, 400)
        self.setStyleSheet(f"background-color: {engine.bg_color};")
        self.setAttribute(Qt.WidgetAttribute.WA_OpaquePaintEvent)

        self.grid_layout = QGridLayout(self)
        self.grid_layout.setSpacing(1)
        self.grid_layout.setContentsMargins(1, 1, 1, 1)
        self._rebuild_cells()

        # Signals
        engine.ticked.connect(self._on_tick)
        engine.display_changed.connect(self.refresh_all)

    # ── Slots ─────────────────────────────────────────────────────────────────

    def _rebuild_cells(self):
        while self.grid_layout.count():
            item = self.grid_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()

        self.cells.clear()
        cols = max(1, self.engine.grid_cols)
        for i in range(self.engine.cell_count):
            cell = CellWidget(i, self.engine)
            self.cells.append(cell)
            self.grid_layout.addWidget(cell, i // cols, i % cols)

    def _on_tick(self, _pointer: int):
        active = set(self.engine.visible_indices)
        for i, cell in enumerate(self.cells):
            if i in active:
                cell.trigger_flash()
            else:
                cell.update()

    def refresh_all(self):
        self.setStyleSheet(f"background-color: {self.engine.bg_color};")
        if len(self.cells) != self.engine.cell_count:
            self._rebuild_cells()

        layout = self.grid_layout
        sp = 1 if self.engine.show_boxes else 0
        layout.setSpacing(sp)
        layout.setContentsMargins(sp, sp, sp, sp)
        for cell in self.cells:
            cell.update()

    # ── Screen management ─────────────────────────────────────────────────────

    def toggle_fullscreen(self):
        if self.isFullScreen():
            self.showNormal()
        else:
            self.showFullScreen()

    def move_to_screen(self, screen_index: int, fullscreen: bool = True):
        screens = QApplication.screens()
        if 0 <= screen_index < len(screens):
            geom: QRect = screens[screen_index].geometry()
            self.setGeometry(geom)
            if fullscreen:
                self.showFullScreen()
            else:
                self.showNormal()

    # ── Key shortcuts (when display window is focused) ────────────────────────

    def keyPressEvent(self, event):
        key = event.key()
        if key == Qt.Key.Key_Escape:
            if self.isFullScreen():
                self.showNormal()
        elif key == Qt.Key.Key_F:
            self.toggle_fullscreen()
        elif key == Qt.Key.Key_Space:
            self.engine.toggle_play()
        elif key == Qt.Key.Key_Right:
            self.engine.step(1)
        elif key == Qt.Key.Key_Left:
            self.engine.step(-1)
        elif key == Qt.Key.Key_R:
            self.engine.reset()
        else:
            super().keyPressEvent(event)
