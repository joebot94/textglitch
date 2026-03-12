"""preset_auto_switcher.py — Auto choreography scheduler for layout presets.

This module intentionally keeps timing/selection policy out of the UI so we can
reuse it later for beat-sync, MIDI/OSC triggers, and scene scripting.
"""

from __future__ import annotations

import random
import time
from PyQt6.QtCore import QObject, QTimer, pyqtSignal

from engine import PRESET_NAMES, GridEngine, normalize_preset_name


AUTO_SWITCHABLE_PRESETS = [p for p in PRESET_NAMES if p != "Custom"]


class AutoPresetSwitcher(QObject):
    """Schedules automatic preset changes using sequential or random policy."""

    auto_changed = pyqtSignal(bool)
    config_changed = pyqtSignal()
    switched = pyqtSignal(str, str)      # preset_name, source
    countdown_changed = pyqtSignal(int)  # milliseconds to next switch
    status_message = pyqtSignal(str)

    def __init__(self, engine: GridEngine, parent=None):
        super().__init__(parent)
        self.engine = engine

        self.enabled = False
        self.interval_ms = 3000
        self.mode = "sequential"         # sequential | random
        self.enabled_presets = list(AUTO_SWITCHABLE_PRESETS)
        self.scene_cycle: list[str] = []  # Optional explicit order override.

        self._rng = random.Random()
        self._seq_index = -1
        self._last_auto_preset = ""
        self._next_switch_at = 0.0
        self._switch_in_progress = False

        self._switch_timer = QTimer(self)
        self._switch_timer.setSingleShot(True)
        self._switch_timer.timeout.connect(self._on_switch_timeout)

        self._countdown_timer = QTimer(self)
        self._countdown_timer.setInterval(100)
        self._countdown_timer.timeout.connect(self._emit_countdown)

    # ── Public controls ──────────────────────────────────────────────────────

    def set_enabled(self, on: bool):
        on = bool(on)
        if on == self.enabled:
            return
        self.enabled = on
        if on:
            self._sync_seq_index_to_current()
            self._schedule_next_switch()
        else:
            self._stop_timers()
            self.countdown_changed.emit(0)
        self.auto_changed.emit(on)
        self.config_changed.emit()

    def toggle_enabled(self):
        self.set_enabled(not self.enabled)

    def set_interval_ms(self, interval_ms: int):
        self.interval_ms = max(80, min(600_000, int(interval_ms)))
        if self.enabled:
            self._schedule_next_switch()
        self.config_changed.emit()

    def set_mode(self, mode: str):
        mode = (mode or "").strip().lower()
        if mode not in {"sequential", "random"}:
            return
        if mode == self.mode:
            return
        self.mode = mode
        if self.enabled:
            self._schedule_next_switch()
        self.config_changed.emit()

    def set_enabled_presets(self, presets: list[str]):
        normalized = self._normalize_preset_list(presets)
        self.enabled_presets = normalized
        self._sync_seq_index_to_current()
        if self.enabled:
            self._schedule_next_switch()
        self.config_changed.emit()

    def set_scene_cycle(self, presets: list[str]):
        """Optional explicit order list for performance scenes."""
        self.scene_cycle = self._normalize_preset_list(presets)
        self._sync_seq_index_to_current()
        if self.enabled:
            self._schedule_next_switch()
        self.config_changed.emit()

    def apply_manual_preset(self, preset_name: str, source: str = "manual") -> bool:
        """
        Applies a manual preset immediately.

        Chosen behavior: if auto-switch is enabled, manual selection resets the
        cycle anchor and restarts the timer from now.
        """
        canonical = normalize_preset_name(preset_name)
        if canonical not in PRESET_NAMES:
            return False
        if not self.engine.set_preset(canonical, emit_display=True):
            return False

        self._sync_seq_index_to_current()
        if self.enabled:
            self._schedule_next_switch()
        self.switched.emit(canonical, source)
        return True

    def switch_next(self, source: str = "manual-next") -> bool:
        return self._step(direction=1, source=source, auto=False)

    def switch_previous(self, source: str = "manual-prev") -> bool:
        return self._step(direction=-1, source=source, auto=False)

    def next_switch_countdown_ms(self) -> int:
        if not self.enabled or not self._switch_timer.isActive():
            return 0
        return max(0, int(round((self._next_switch_at - time.monotonic()) * 1000)))

    # ── Timer internals ──────────────────────────────────────────────────────

    def _schedule_next_switch(self):
        cycle = self._current_cycle()
        if not self.enabled:
            return
        if not cycle:
            self._stop_timers()
            self.countdown_changed.emit(0)
            self.status_message.emit("Auto switch enabled but no presets are selected.")
            return

        self._next_switch_at = time.monotonic() + (self.interval_ms / 1000.0)
        self._switch_timer.start(self.interval_ms)
        if not self._countdown_timer.isActive():
            self._countdown_timer.start()
        self._emit_countdown()

    def _stop_timers(self):
        self._switch_timer.stop()
        self._countdown_timer.stop()
        self._next_switch_at = 0.0

    def _emit_countdown(self):
        remaining = self.next_switch_countdown_ms()
        self.countdown_changed.emit(remaining)
        if not self.enabled and self._countdown_timer.isActive():
            self._countdown_timer.stop()
        if self.enabled and remaining <= 0 and not self._switch_timer.isActive():
            self._countdown_timer.stop()

    def _on_switch_timeout(self):
        if self._switch_in_progress or not self.enabled:
            return
        self._switch_in_progress = True
        try:
            changed = self._step(direction=1, source="auto", auto=True)
            if not changed:
                self.status_message.emit("Auto switch skipped: no valid target preset.")
            if self.enabled:
                self._schedule_next_switch()
        finally:
            self._switch_in_progress = False

    # ── Selection policy ─────────────────────────────────────────────────────

    def _current_cycle(self) -> list[str]:
        base = self.scene_cycle if self.scene_cycle else self.enabled_presets
        return self._normalize_preset_list(base)

    def _normalize_preset_list(self, presets: list[str]) -> list[str]:
        out: list[str] = []
        seen: set[str] = set()
        for name in presets:
            canonical = normalize_preset_name(name)
            if canonical not in PRESET_NAMES:
                continue
            if canonical == "Custom":
                continue
            if canonical in seen:
                continue
            seen.add(canonical)
            out.append(canonical)
        return out

    def _sync_seq_index_to_current(self):
        cycle = self._current_cycle()
        if not cycle:
            self._seq_index = -1
            return
        current = normalize_preset_name(self.engine.preset_name)
        self._seq_index = cycle.index(current) if current in cycle else -1

    def _step(self, direction: int, source: str, auto: bool) -> bool:
        cycle = self._current_cycle()
        if not cycle:
            return False

        current = normalize_preset_name(self.engine.preset_name)
        target = ""

        if direction < 0:
            idx = cycle.index(current) if current in cycle else 0
            target = cycle[(idx - 1) % len(cycle)]
        elif auto and self.mode == "random":
            target = self._random_target(cycle, current)
        else:
            idx = cycle.index(current) if current in cycle else self._seq_index
            if idx < 0:
                idx = -1
            target = cycle[(idx + 1) % len(cycle)]

        if not target:
            return False
        if not self.engine.set_preset(target, emit_display=True):
            return False

        if auto:
            self._last_auto_preset = target
        self._sync_seq_index_to_current()
        self.switched.emit(target, source)
        return True

    def _random_target(self, cycle: list[str], current: str) -> str:
        if len(cycle) == 1:
            return cycle[0]

        # Avoid immediate repeats for stronger rhythmic variation.
        choices = [p for p in cycle if p != current]
        if len(choices) > 1 and self._last_auto_preset in choices:
            alt = [p for p in choices if p != self._last_auto_preset]
            if alt:
                choices = alt
        return self._rng.choice(choices) if choices else cycle[0]
