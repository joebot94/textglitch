"""audio_handler.py — Real-time beat detection via aubio + sounddevice."""

import threading
import numpy as np
from PyQt6.QtCore import QObject, pyqtSignal

try:
    import sounddevice as sd
    SOUNDDEVICE_AVAILABLE = True
except ImportError:
    SOUNDDEVICE_AVAILABLE = False

try:
    import aubio
    AUBIO_AVAILABLE = True
except ImportError:
    AUBIO_AVAILABLE = False


class AudioHandler(QObject):
    """
    Captures audio from a selected input device, runs aubio beat detection,
    and emits beat_tick when a beat is found.

    Signals:
        beat_tick      — fires on detected beat
        bpm_detected(float) — rolling estimated BPM
        level(float)   — RMS level 0.0–1.0 for VU meter
        error(str)     — human-readable error
    """

    beat_tick    = pyqtSignal()
    bpm_detected = pyqtSignal(float)
    level        = pyqtSignal(float)
    error        = pyqtSignal(str)

    # aubio parameters
    _SAMPLE_RATE = 44100
    _HOP_SIZE    = 512
    _BLOCK_SIZE  = 1024

    def __init__(self, engine, parent=None):
        super().__init__(parent)
        self.engine  = engine
        self.enabled = False
        self._stream = None
        self._tempo  = None
        self._lock   = threading.Lock()

        self.beat_tick.connect(self.engine.external_tick)

    # ── Device enumeration ────────────────────────────────────────────────────

    @staticmethod
    def available_devices() -> list[tuple[int, str]]:
        """Returns [(index, name), ...] for input-capable devices."""
        if not SOUNDDEVICE_AVAILABLE:
            return []
        devices = []
        try:
            for i, d in enumerate(sd.query_devices()):
                if d["max_input_channels"] > 0:
                    devices.append((i, d["name"]))
        except Exception:
            pass
        return devices

    # ── Start / stop ──────────────────────────────────────────────────────────

    def start(self, device_index: int | None = None):
        self.stop()
        if not SOUNDDEVICE_AVAILABLE:
            self.error.emit("sounddevice not installed — run: pip install sounddevice")
            return
        if not AUBIO_AVAILABLE:
            self.error.emit("aubio not installed — run: pip install aubio")
            return

        try:
            with self._lock:
                self._tempo = aubio.tempo(
                    "default",
                    self._BLOCK_SIZE,
                    self._HOP_SIZE,
                    self._SAMPLE_RATE,
                )

            kwargs = dict(
                samplerate=self._SAMPLE_RATE,
                channels=1,
                dtype="float32",
                blocksize=self._HOP_SIZE,
                callback=self._audio_callback,
            )
            if device_index is not None:
                kwargs["device"] = device_index

            self._stream = sd.InputStream(**kwargs)
            self._stream.start()

        except Exception as exc:
            self.error.emit(f"Audio start error: {exc}")

    def stop(self):
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass
            self._stream = None

    # ── Audio callback (runs in sounddevice background thread) ────────────────

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status):
        if not self.enabled:
            return

        samples = indata[:, 0].astype("float32")

        # VU level
        rms = float(np.sqrt(np.mean(samples ** 2)))
        self.level.emit(min(1.0, rms * 8.0))    # scale for visual display

        with self._lock:
            if self._tempo is None:
                return
            is_beat = self._tempo(samples)
            if is_beat[0] > 0:
                est_bpm = float(self._tempo.get_bpm())
                if 40.0 < est_bpm < 250.0:
                    self.bpm_detected.emit(round(est_bpm, 1))
                self.beat_tick.emit()            # queued → main thread

    # ── Cleanup ───────────────────────────────────────────────────────────────

    def shutdown(self):
        self.stop()
