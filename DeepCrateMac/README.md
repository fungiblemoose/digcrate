# DeepCrateMac

DeepCrateMac is the primary macOS app for DeepCrate.

It is a hybrid app today: the UI and most set-planning logic are Swift-native, while scan/import analysis, discovery, and export still run through the Python bridge.

## Current Status

- Native SwiftUI app with pages: Library, Plan Set, Sets, Gaps, Discover, Export
- Local audio preview in Library and Sets
- Manual metadata overrides + review workflow in Library
- Planning modes:
  - Local Apple Foundation Models planner
  - OpenAI planner via direct HTTP from Swift
- SQLite reads/writes for tracks, sets, set tracks, and gaps in Swift
- Gap analysis + severity labeling in Swift

## Architecture Split (What Runs Where)

Swift-native (`DeepCrateMac/Sources/DeepCrateMac/`):
- App shell/navigation/UI
- Planner orchestration and model routing
- OpenAI set planner client
- Local SQLite service (`LocalDatabase`)
- Transition scoring and gap analysis
- Audio preview playback

Python bridge (`deepcrate/mac_bridge.py`):
- Library scan + audio analysis
- Track search/reanalyze/override/delete commands used by Library tools
- Spotify discovery suggestions
- Export writers (`m3u`, Rekordbox XML)

## Requirements

- macOS 14+
- Xcode Command Line Tools
- Swift toolchain supporting this package (`swift-tools-version: 6.2`)
- Python 3.12

## Setup

From repo root:

```bash
cd ~/Projects/DeepCrate
python3 -m venv .venv
./.venv/bin/pip install -e .
cp .env.example .env
```

Notes:
- `.env` is used by Python bridge flows (for example Spotify discovery and legacy backend config).
- Planner/API credentials can also be set in-app via `Settings`.

## Run

Run from the `DeepCrateMac` directory so bridge paths resolve correctly:

```bash
cd ~/Projects/DeepCrate/DeepCrateMac
swift run
```

## Build

```bash
cd ~/Projects/DeepCrate/DeepCrateMac
swift build
```

## Packaging Notes

Distribution outside the App Store is possible with standard Developer ID signing + notarization, then shipping a `.dmg` on GitHub Releases.
