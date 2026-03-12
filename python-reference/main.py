"""main.py — Text Grid Display System — entry point."""

import sys
from PyQt6.QtWidgets import QApplication
from PyQt6.QtCore    import Qt
from PyQt6.QtGui     import QFont

from engine          import GridEngine
from display_window  import DisplayWindow
from midi_handler    import MidiHandler
from audio_handler   import AudioHandler
from osc_handler     import OscHandler
from file_watcher    import FileWatcher
from control_window  import ControlWindow
from preset_auto_switcher import AutoPresetSwitcher


def main():
    # HiDPI + font rendering
    QApplication.setHighDpiScaleFactorRoundingPolicy(
        Qt.HighDpiScaleFactorRoundingPolicy.PassThrough
    )

    app = QApplication(sys.argv)
    app.setApplicationName("Text Grid Display")
    app.setOrganizationName("TextGrid")
    app.setStyle("Fusion")

    # Set default app font
    app.setFont(QFont("Courier New", 10))

    # ── Wire up the system ────────────────────────────────────────────────────
    engine  = GridEngine()
    display = DisplayWindow(engine)
    auto    = AutoPresetSwitcher(engine)
    midi    = MidiHandler(engine)
    audio   = AudioHandler(engine)
    osc     = OscHandler(engine)
    watcher = FileWatcher(engine)

    osc.set_preset_switcher(auto)
    control = ControlWindow(engine, display, auto, midi, audio, osc, watcher)

    # Show both windows
    control.show()
    display.resize(600, 600)
    display.show()

    # Position display to right of control panel (single-screen default)
    ctrl_geo  = control.geometry()
    display.move(ctrl_geo.right() + 16, ctrl_geo.top())

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
