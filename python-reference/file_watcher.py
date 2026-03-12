"""file_watcher.py — Hot-reload a text file into the engine whenever it changes on disk."""

import os
import threading
from PyQt6.QtCore import QObject, pyqtSignal

try:
    from watchdog.observers import Observer
    from watchdog.events    import FileSystemEventHandler, FileModifiedEvent
    WATCHDOG_AVAILABLE = True
except ImportError:
    WATCHDOG_AVAILABLE = False


class _ChangeHandler(FileSystemEventHandler if WATCHDOG_AVAILABLE else object):
    """Watchdog event handler — notifies parent on file modification."""

    def __init__(self, target_path: str, callback):
        if WATCHDOG_AVAILABLE:
            super().__init__()
        self._target = os.path.abspath(target_path)
        self._callback = callback
        self._last_size = -1

    def on_modified(self, event):
        if hasattr(event, "src_path") and os.path.abspath(event.src_path) == self._target:
            # Debounce: skip if file size didn't change
            try:
                size = os.path.getsize(self._target)
                if size == self._last_size:
                    return
                self._last_size = size
            except OSError:
                pass
            self._callback()


class FileWatcher(QObject):
    """
    Watches a single text file and signals the engine to reload it.

    Signals:
        file_loaded(str)  — emitted with new text content after load
        file_error(str)   — emitted on read errors
        status(str)       — human-readable status message
    """

    file_loaded = pyqtSignal(str)
    file_error  = pyqtSignal(str)
    status      = pyqtSignal(str)

    def __init__(self, engine, parent=None):
        super().__init__(parent)
        self.engine     = engine
        self._observer: "Observer | None" = None
        self._handler   = None
        self._path      = ""
        self._lock      = threading.Lock()
        self.enabled    = True

        self.file_loaded.connect(engine.set_text)

    # ── Watch management ──────────────────────────────────────────────────────

    def watch(self, path: str):
        """Start watching a file. Loads it immediately, then monitors for changes."""
        self.stop()
        if not path or not os.path.isfile(path):
            self.file_error.emit(f"File not found: {path}")
            return
        if not WATCHDOG_AVAILABLE:
            self.file_error.emit("watchdog not installed — run: pip install watchdog")
            self._load(path)   # still load the file, just no hot-reload
            return

        self._path = path
        self._load(path)      # immediate first load

        directory = os.path.dirname(os.path.abspath(path))
        self._handler = _ChangeHandler(path, lambda: self._load(path))

        self._observer = Observer()
        self._observer.schedule(self._handler, directory, recursive=False)
        self._observer.start()
        self.status.emit(f"Watching: {os.path.basename(path)}")

    def stop(self):
        if self._observer:
            try:
                self._observer.stop()
                self._observer.join(timeout=2)
            except Exception:
                pass
            self._observer = None
        self._handler = None
        self._path    = ""

    def reload(self):
        """Manually re-read the current file."""
        if self._path:
            self._load(self._path)

    # ── File I/O ──────────────────────────────────────────────────────────────

    def _load(self, path: str):
        with self._lock:
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
                self.file_loaded.emit(text)          # queued → main thread
                self.status.emit(f"Loaded: {os.path.basename(path)}"
                                 f"  ({len(text.splitlines())} lines)")
            except Exception as exc:
                self.file_error.emit(f"Read error: {exc}")

    # ── Cleanup ───────────────────────────────────────────────────────────────

    def shutdown(self):
        self.stop()
