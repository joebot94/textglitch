"""osc_handler.py — OSC send/receive for Extron, QLab, Resolume, and custom sync."""

import threading
from PyQt6.QtCore import QObject, pyqtSignal

try:
    from pythonosc import dispatcher as osc_dispatcher
    from pythonosc import osc_server
    from pythonosc import udp_client
    from pythonosc import osc_message_builder
    OSC_AVAILABLE = True
except ImportError:
    OSC_AVAILABLE = False


# ─── OSC address map ──────────────────────────────────────────────────────────
#
# Receive:
#   /textgrid/play          → play
#   /textgrid/stop          → stop
#   /textgrid/tick          → single step
#   /textgrid/reset         → reset pointer
#   /textgrid/bpm   <float> → set BPM
#   /textgrid/preset <str>  → set layout preset by name
#   /textgrid/grid   <str>  → set grid profile ("2x2", "3x4", etc.)
#   /textgrid/pointer <int> → jump to token index
#   /textgrid/speed  <int>  → set manual speed in ms
#   /textgrid/blank   <int|csv> → blank one or more cells
#   /textgrid/unblank <int|csv> → unblank one or more cells
#   /textgrid/clear_blanks      → clear all blanked cells
#
# Send:
#   /textgrid/beat  <int pointer>
#   /textgrid/bpm   <float>
#   /textgrid/state <str "playing"|"stopped">
#


class OscHandler(QObject):
    """Bidirectional OSC handler."""

    received_play    = pyqtSignal()
    received_stop    = pyqtSignal()
    received_tick    = pyqtSignal()
    received_reset   = pyqtSignal()
    received_bpm     = pyqtSignal(float)
    received_preset  = pyqtSignal(str)
    received_grid    = pyqtSignal(str)
    received_pointer = pyqtSignal(int)
    received_speed   = pyqtSignal(int)
    received_blank   = pyqtSignal(str)
    received_unblank = pyqtSignal(str)
    received_clear_blanks = pyqtSignal()
    status_changed   = pyqtSignal(str)   # human-readable status

    def __init__(self, engine, parent=None):
        super().__init__(parent)
        self.engine  = engine
        self.preset_switcher = None
        self._server: osc_server.ThreadingOSCUDPServer | None = None
        self._client: "udp_client.SimpleUDPClient | None"     = None
        self._thread: threading.Thread | None                 = None

        self.receive_ip   = "0.0.0.0"
        self.receive_port = 8000
        self.send_ip      = "192.168.1.1"   # default: typical Extron device IP
        self.send_port    = 8001

        self.receive_enabled = False
        self.send_enabled    = False

        # Wire received signals to engine
        self.received_play.connect(engine.play)
        self.received_stop.connect(engine.stop)
        self.received_tick.connect(engine.external_tick)
        self.received_reset.connect(engine.reset)
        self.received_bpm.connect(self._apply_bpm)
        self.received_preset.connect(self._apply_preset)
        self.received_grid.connect(self._apply_grid)
        self.received_pointer.connect(self._apply_pointer)
        self.received_speed.connect(self._apply_speed)
        self.received_blank.connect(self._apply_blank)
        self.received_unblank.connect(self._apply_unblank)
        self.received_clear_blanks.connect(self.engine.clear_blanks)

        # Send beat on every engine tick
        engine.ticked.connect(self._send_beat)
        engine.playing_changed.connect(self._send_state)

    def set_preset_switcher(self, switcher):
        self.preset_switcher = switcher

    # ── Server ────────────────────────────────────────────────────────────────

    def start_server(self, ip: str = "0.0.0.0", port: int = 8000):
        self.stop_server()
        if not OSC_AVAILABLE:
            self.status_changed.emit("python-osc not installed — run: pip install python-osc")
            return

        try:
            disp = osc_dispatcher.Dispatcher()
            disp.map("/textgrid/play",    lambda *_: self.received_play.emit())
            disp.map("/textgrid/stop",    lambda *_: self.received_stop.emit())
            disp.map("/textgrid/tick",    lambda *_: self.received_tick.emit())
            disp.map("/textgrid/reset",   lambda *_: self.received_reset.emit())
            disp.map("/textgrid/bpm",     lambda _, v: self.received_bpm.emit(float(v)))
            disp.map("/textgrid/preset",  lambda _, v: self.received_preset.emit(str(v)))
            disp.map("/textgrid/grid",    lambda _, *v: self.received_grid.emit(self._join_args(v)))
            disp.map("/textgrid/pointer", lambda _, v: self.received_pointer.emit(int(v)))
            disp.map("/textgrid/speed",   lambda _, v: self.received_speed.emit(int(v)))
            disp.map("/textgrid/blank",   lambda _, *v: self.received_blank.emit(self._join_args(v)))
            disp.map("/textgrid/unblank", lambda _, *v: self.received_unblank.emit(self._join_args(v)))
            disp.map("/textgrid/clear_blanks", lambda *_: self.received_clear_blanks.emit())

            self._server = osc_server.ThreadingOSCUDPServer((ip, port), disp)
            self._thread = threading.Thread(
                target=self._server.serve_forever, daemon=True, name="osc-server"
            )
            self._thread.start()
            self.receive_ip   = ip
            self.receive_port = port
            self.status_changed.emit(f"OSC server listening on {ip}:{port}")
        except Exception as exc:
            self.status_changed.emit(f"OSC server error: {exc}")

    def stop_server(self):
        if self._server:
            try:
                self._server.shutdown()
            except Exception:
                pass
            self._server = None
        self.status_changed.emit("OSC server stopped")

    # ── Client ────────────────────────────────────────────────────────────────

    def open_client(self, ip: str, port: int):
        if not OSC_AVAILABLE:
            return
        try:
            self._client   = udp_client.SimpleUDPClient(ip, port)
            self.send_ip   = ip
            self.send_port = port
            self.status_changed.emit(f"OSC client → {ip}:{port}")
        except Exception as exc:
            self.status_changed.emit(f"OSC client error: {exc}")

    def close_client(self):
        self._client = None

    def send(self, address: str, *args):
        if self._client and self.send_enabled and OSC_AVAILABLE:
            try:
                self._client.send_message(address, list(args) if args else [])
            except Exception:
                pass

    # ── Auto-send slots ───────────────────────────────────────────────────────

    def _send_beat(self, pointer: int):
        if self.send_enabled:
            self.send("/textgrid/beat", pointer)

    def _send_state(self, playing: bool):
        if self.send_enabled:
            self.send("/textgrid/state", "playing" if playing else "stopped")

    # ── Apply-to-engine helpers (run on main thread via signal) ───────────────

    def _apply_bpm(self, bpm: float):
        self.engine.bpm = max(40.0, min(300.0, bpm))
        self.engine.bpm_sync = True
        self.engine.update_speed()

    def _apply_preset(self, name: str):
        from engine import PRESET_NAMES, normalize_preset_name
        canonical = normalize_preset_name(name)
        if canonical in PRESET_NAMES:
            if self.preset_switcher:
                self.preset_switcher.apply_manual_preset(canonical, source="osc")
            else:
                self.engine.set_preset(canonical, emit_display=True)

    def _apply_grid(self, profile: str):
        raw = (profile or "").strip()
        if self.engine.set_grid_profile(raw):
            return
        bits = [b for b in raw.replace(",", " ").split() if b]
        if len(bits) == 2 and bits[0].isdigit() and bits[1].isdigit():
            self.engine.set_grid_profile(f"{bits[0]}x{bits[1]}")

    def _apply_pointer(self, ptr: int):
        toks = max(1, len(self.engine._tokens))
        self.engine.pointer = ptr % toks
        self.engine.ticked.emit(self.engine.pointer)

    def _apply_speed(self, ms: int):
        self.engine.speed_ms = max(16, ms)
        self.engine.bpm_sync = False
        self.engine.update_speed()

    def _join_args(self, values) -> str:
        if not values:
            return ""
        return ",".join(str(v).strip() for v in values if str(v).strip())

    def _parse_cell_indices(self, payload: str) -> list[int]:
        raw = (payload or "").replace(";", ",").replace(" ", ",")
        values: list[int] = []
        for part in raw.split(","):
            part = part.strip()
            if not part:
                continue
            try:
                values.append(int(part))
            except ValueError:
                continue

        if not values:
            return []

        if 0 not in values and min(values) >= 1 and max(values) <= self.engine.cell_count:
            values = [v - 1 for v in values]  # support 1-based control systems

        out = []
        seen = set()
        for v in values:
            if 0 <= v < self.engine.cell_count and v not in seen:
                seen.add(v)
                out.append(v)
        return out

    def _apply_blank(self, payload: str):
        indices = self._parse_cell_indices(payload)
        if indices:
            self.engine.set_cells_blank(indices, True)

    def _apply_unblank(self, payload: str):
        indices = self._parse_cell_indices(payload)
        if indices:
            self.engine.set_cells_blank(indices, False)

    # ── Cleanup ───────────────────────────────────────────────────────────────

    def shutdown(self):
        self.stop_server()
        self.close_client()
