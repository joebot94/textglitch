"""midi_handler.py — MIDI clock in/out using mido + python-rtmidi."""

import threading
import time
from PyQt6.QtCore import QObject, pyqtSignal

try:
    import mido
    MIDO_AVAILABLE = True
except ImportError:
    MIDO_AVAILABLE = False


# MIDI spec: 24 timing clock pulses per quarter note
_PPQN = 24


class MidiHandler(QObject):
    """
    Listens for incoming MIDI clock and converts it to engine ticks.
    Also sends MIDI clock output so downstream devices can sync to us.

    Signals emitted (safe to connect to main-thread slots):
        beat_tick  — fires when enough MIDI clock pulses received
        bpm_detected(float) — estimated BPM from incoming clock
        port_error(str)     — human-readable error string
    """

    beat_tick     = pyqtSignal()
    bpm_detected  = pyqtSignal(float)
    port_error    = pyqtSignal(str)

    def __init__(self, engine, parent=None):
        super().__init__(parent)
        self.engine = engine

        self._in_port_name  = ""
        self._out_port_name = ""
        self._in_port       = None
        self._out_port      = None
        self._in_thread: threading.Thread | None = None
        self._out_thread: threading.Thread | None = None

        self._running = False
        self._pulse_count    = 0
        self._pulses_per_tick = _PPQN          # default: fire on every quarter note
        self._last_clock_time: float | None = None
        self._bpm_samples: list[float] = []

        self.enabled = False
        self.send_enabled = False

        # Connect beat_tick to the engine (cross-thread, queued automatically)
        self.beat_tick.connect(self.engine.external_tick)

    # ── Available ports ──────────────────────────────────────────────────────

    @staticmethod
    def available_inputs() -> list[str]:
        if not MIDO_AVAILABLE:
            return []
        try:
            return mido.get_input_names()
        except Exception:
            return []

    @staticmethod
    def available_outputs() -> list[str]:
        if not MIDO_AVAILABLE:
            return []
        try:
            return mido.get_output_names()
        except Exception:
            return []

    # ── Beat division ─────────────────────────────────────────────────────────

    def set_beat_division(self, division: float):
        """division: 2.0=half, 1.0=quarter, 0.5=eighth, 0.25=sixteenth"""
        self._pulses_per_tick = max(1, int(_PPQN * division))

    # ── Input (receive clock) ─────────────────────────────────────────────────

    def open_input(self, port_name: str):
        self.close_input()
        if not MIDO_AVAILABLE:
            self.port_error.emit("mido not installed — run: pip install mido python-rtmidi")
            return
        if not port_name:
            return
        try:
            self._in_port      = mido.open_input(port_name)
            self._in_port_name = port_name
            self._running      = True
            self._in_thread    = threading.Thread(
                target=self._read_loop, daemon=True, name="midi-in"
            )
            self._in_thread.start()
        except Exception as exc:
            self.port_error.emit(f"MIDI input error: {exc}")

    def close_input(self):
        self._running = False
        if self._in_port:
            try:
                self._in_port.close()
            except Exception:
                pass
        self._in_port = None

    def _read_loop(self):
        while self._running and self._in_port:
            try:
                for msg in self._in_port.iter_pending():
                    self._handle_message(msg)
            except Exception:
                break
            time.sleep(0.001)          # 1 ms poll — tight enough for MIDI clock

    def _handle_message(self, msg):
        if msg.type == "clock":
            now = time.perf_counter()
            if self._last_clock_time is not None:
                interval = now - self._last_clock_time
                if interval > 0:
                    pulse_bpm = 60.0 / (interval * _PPQN)
                    self._bpm_samples.append(pulse_bpm)
                    if len(self._bpm_samples) > 24:
                        self._bpm_samples.pop(0)
                    avg_bpm = sum(self._bpm_samples) / len(self._bpm_samples)
                    self.bpm_detected.emit(round(avg_bpm, 1))
            self._last_clock_time = now

            if self.enabled:
                self._pulse_count += 1
                if self._pulse_count >= self._pulses_per_tick:
                    self._pulse_count = 0
                    self.beat_tick.emit()          # queued → main thread

        elif msg.type == "start" or msg.type == "continue":
            self._pulse_count = 0
            self._bpm_samples.clear()
            self._last_clock_time = None

        elif msg.type == "stop":
            pass  # keep engine playing; just stop counting pulses if desired

    # ── Output (send clock) ───────────────────────────────────────────────────

    def open_output(self, port_name: str):
        self.close_output()
        if not MIDO_AVAILABLE:
            return
        if not port_name:
            return
        try:
            self._out_port      = mido.open_output(port_name)
            self._out_port_name = port_name
        except Exception as exc:
            self.port_error.emit(f"MIDI output error: {exc}")

    def close_output(self):
        if self._out_port:
            try:
                self._out_port.close()
            except Exception:
                pass
        self._out_port = None

    def send_clock_pulse(self):
        """Call 24× per beat to generate MIDI clock output."""
        if self._out_port and self.send_enabled and MIDO_AVAILABLE:
            try:
                self._out_port.send(mido.Message("clock"))
            except Exception:
                pass

    def send_start(self):
        if self._out_port and MIDO_AVAILABLE:
            try:
                self._out_port.send(mido.Message("start"))
            except Exception:
                pass

    def send_stop(self):
        if self._out_port and MIDO_AVAILABLE:
            try:
                self._out_port.send(mido.Message("stop"))
            except Exception:
                pass

    # ── Cleanup ───────────────────────────────────────────────────────────────

    def shutdown(self):
        self._running = False
        self.close_input()
        self.close_output()
