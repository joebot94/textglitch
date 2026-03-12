# Text Grid Display System
### PyQt6 · MIDI · Audio Beat Detection · OSC · File Watch

A real-time text display tool for live events, VJ sets, and AV installs.
Displays words/letters/phrases across customizable grids (1×1 to 4×4), synced to music or external control systems.

---

## Setup

### 1. Install Python 3.11+
- Mac: `brew install python@3.11`
- Windows: https://python.org/downloads

### 2. Create virtual environment (recommended)
```bash
cd textgrid
python -m venv venv
source venv/bin/activate       # Mac/Linux
venv\Scripts\activate          # Windows
```

### 3. Install dependencies
```bash
pip install -r requirements.txt
```

> **aubio on Mac (Apple Silicon):**
> `pip install aubio` may need: `brew install libaubio` first.
>
> **rtmidi on Windows:**
> May need Visual C++ Build Tools: https://visualstudio.microsoft.com/visual-cpp-build-tools/

### 4. Run
```bash
python main.py
```

---

## Features

| Feature | Details |
|---|---|
| Grid layouts | Profiles: 1×1, 2×2, 3×3, 3×4, 4×4 + shape presets + custom click-to-toggle |
| Text modes | Letter / Word / Phrase (line) / Chunk (fixed chars per tile) |
| Auto choreography | Auto preset switching (sequential/random), interval control, selectable preset pool |
| Distribution | Sequential, All Same, Random |
| Fonts | System + Google Fonts (if installed) |
| Color modes | Global, Per-cell, Random, Cycle palette |
| MIDI | Clock in (sync) + Clock out (send), beat division |
| Audio | Real-time beat detection via aubio (mic/line in) |
| OSC | Server + Client — Extron, QLab, Resolume, custom |
| File watch | Hot-reload any .txt file on save |
| Screens | Target any display, fullscreen output |

---

## OSC Address Map

### Receive (default port 8000)
```
/textgrid/play
/textgrid/stop
/textgrid/tick
/textgrid/reset
/textgrid/bpm     <float>
/textgrid/preset  <string>    e.g. "Corners", "X", "All 4×4"
/textgrid/grid    <string>    e.g. "3x4", "4x4"
/textgrid/pointer <int>
/textgrid/speed   <int ms>
/textgrid/blank   <int|csv>   e.g. 1 or "1,3,8"
/textgrid/unblank <int|csv>
/textgrid/clear_blanks
```

### Send (configure target IP:port)
```
/textgrid/beat    <int pointer>
/textgrid/state   "playing" | "stopped"
```

### Extron GlobalScripter example
```python
# In your Extron script, send OSC to control the grid:
SendOscMessage("192.168.1.100", 8000, "/textgrid/play")
SendOscMessage("192.168.1.100", 8000, "/textgrid/bpm", 128.0)
```

---

## Keyboard Shortcuts

| Key | Action |
|---|---|
| Space | Play / Pause |
| → / ← | Step forward / back |
| R | Reset pointer |
| F | Fullscreen toggle (display window) |
| Ctrl+Enter | Show display window |
| A | Toggle Auto Preset Switch |
| ] / [ | Next / Previous preset |

---

## Auto Preset Switching

- Enable in **Layout → Auto Switch Presets**
- Modes:
  - **SEQ**: steps through enabled presets in order
  - **RND**: random choice with immediate-repeat prevention when possible
- Interval is in milliseconds (live-safe range: 80ms to 600000ms)
- Manual preset selection behavior:
  - manual selection applies immediately
  - if auto is enabled, timer restarts from that preset (new cycle anchor)
- Optional scene cycle support exists in code (`AutoPresetSwitcher.set_scene_cycle`)
  for later scripted performance workflows.

---

## Releases

### Update changelog
- Add new notes under `## [Unreleased]` in `CHANGELOG.md`
- On release, move those notes to a new version/date section

### Create and push a release tag
```bash
git add -A
git commit -m "release: v0.2.0"
git tag -a v0.2.0 -m "v0.2.0"
git push
git push origin v0.2.0
```

---

## Recommended Fonts (install separately)
- [Bebas Neue](https://fonts.google.com/specimen/Bebas+Neue)
- [Anton](https://fonts.google.com/specimen/Anton)
- [Oswald](https://fonts.google.com/specimen/Oswald)
- [Barlow Condensed](https://fonts.google.com/specimen/Barlow+Condensed)

Install system-wide and they'll appear in the font picker automatically.

---

## Roadmap
- [ ] Master clock WebSocket server (sync multiple instances)
- [ ] MIDI note/CC mapping for any parameter
- [ ] Per-cell font assignment
- [ ] Transition animations (fade, glitch, slide)
- [ ] Syphon/Spout output (video pipeline integration)
- [ ] Preset save/load (JSON)
- [ ] NDI output support
