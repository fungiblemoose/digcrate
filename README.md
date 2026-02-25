# DeepCrate

DeepCrate is a Swift-native macOS app for DJs. It scans your library, analyzes BPM/key/energy, builds sets from natural language prompts, explains transition quality, highlights weak gaps, and exports playlists.

## Status

- Primary product: **Swift app** in `DeepCrateMac/`
- Hybrid runtime:
  - Swift-native services for set planning orchestration, set persistence, and gap analysis
  - Python bridge (`deepcrate/mac_bridge.py`) still used for scan/import, audio analysis, discovery, and export
- Legacy Python GUI: kept for compatibility, no longer the primary UI

## What Works Today

- Native macOS SwiftUI interface with liquid-glass styling
- Library scan + analysis queue
- Track preview playback in Library and Sets pages
- Per-track and bulk reanalysis
- Manual metadata overrides and review queue
- AI set planning in Swift (cloud OpenAI or local Apple Foundation Model)
- DJ-jargon-aware planning (`dnb`, `ukg`, `rollers`, `hardbass`, `afrohouse`, `tropical house`, etc.)
- Gap analysis in Swift with severity and plain-language guidance
- Export to M3U/Rekordbox XML

## Usage Walkthrough

Here's what a typical session looks like once the app is running:

**1. Scan your library**  
Go to the Library tab → click Scan → point it at your music folder. DeepCrate analyzes each file for BPM, key (Camelot notation), and energy. Large collections take a few minutes; subsequent scans skip unchanged files.

**2. Review your tracks**  
The Library view shows all analyzed tracks with BPM, key, and energy. Flag anything that looks off for reanalysis, or manually override metadata from the track detail panel.

**3. Plan a set**  
Go to Sets → New Set → describe what you want in plain language:
- *"uplifting techno, 126–128 BPM, 60 minutes"*
- *"dnb rollers, energetic build, 45 min"*
- *"afrohouse into tropical, sunset vibe, 90 min"*

The AI reads your library and builds a tracklist with scored transitions. If your library doesn't have enough of a requested style, it warns you and falls back gracefully.

**4. Check transitions**  
Each transition gets a score (0–1) based on key compatibility, BPM match, and energy flow. Scores under 0.5 are flagged — the gap analysis view tells you exactly what kind of track would fix it and why.

**5. Export**  
When you're happy with the set, export to M3U (works with most players) or Rekordbox XML (for Pioneer gear). Done.

## Quick Start (Swift App)

### Requirements

- macOS 14+
- Xcode Command Line Tools
- Python 3.12 (for current backend bridge)

### Setup

```bash
git clone https://github.com/fungiblemoose/DeepCrate.git
cd DeepCrate
python3 -m venv .venv
.venv/bin/pip install -e .
cp .env.example .env
```

Set keys in `.env` as needed:

```env
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o-mini
SPOTIFY_CLIENT_ID=...
SPOTIFY_CLIENT_SECRET=...
DATABASE_PATH=data/deepcrate.sqlite
```

### Run

```bash
cd DeepCrateMac
swift run
```

### Build

```bash
cd DeepCrateMac
swift build
```

### Package macOS App (`.app` + `.dmg`)

```bash
./scripts/package-macos-app.sh
```

The generated `.dmg` can be attached to a GitHub Release and includes an `Applications` shortcut for drag-and-drop install.

## Planner Behavior

- The planner interprets broad + specific genre language and DJ shorthand.
- If a requested style is not in your library, it warns and falls back to the best available tracks.
- It does not hard-fail by default; it prioritizes usable output.

## Architecture (Current)

- `DeepCrateMac/`: SwiftUI app, planner + gap services, AVFoundation preview player, SQLite access for sets/tracks
- `deepcrate/mac_bridge.py`: command bridge still used by scan/import, analysis, discovery, and export flows
- `deepcrate/analysis/`: Python audio analysis (BPM/key/energy)
- `deepcrate/planning/`: Python planning, scoring, gaps
- `deepcrate/db.py`: SQLite persistence

## Swift-First Roadmap (Pure Swift End State)

1. Keep Swift UI as source of truth (done).
2. Move bridge commands into Swift services one area at a time:
   - scan/import
   - discovery
   - export
3. Replace Python analysis engine with native Swift DSP stack (Accelerate/AVFoundation/Core ML where appropriate), with regression tests against current outputs.
4. Keep SQLite but migrate data access to Swift-only layer.
5. Remove Python runtime dependency from app startup/build packaging.

## Developer Commands

### Swift

```bash
cd DeepCrateMac
swift build
swift run
```

### Python Tests

```bash
cd DeepCrate
.venv/bin/pytest -q
```

## Repo Layout

```text
DeepCrateMac/                 Swift app (primary UI)
deepcrate/analysis/           Python audio analysis
deepcrate/planning/           Python planning + scoring (legacy/bridge compatibility)
deepcrate/mac_bridge.py       Swift <-> Python bridge
deepcrate/db.py               SQLite layer
tests/                        Python tests
```

## Notes

- Set previews require local file paths to still exist (common external-drive workflows are supported as long as the drive is mounted).
- Half/double-tempo matching is handled in transition scoring and genre filtering.
- Keys are stored in Camelot notation (example: `8A`).
