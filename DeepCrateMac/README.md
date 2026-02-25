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

## Packaging (GitHub Download + Drag to Applications)

From repo root:

```bash
./scripts/package-macos-app.sh
```

This builds:

- `dist/DeepCrate-<version>-macOS-<arch>.zip`
- `dist/DeepCrate-<version>-macOS-<arch>.dmg` (includes an `Applications` shortcut for drag-install)

Optional signing/notarization environment variables:

- `DEEPCRATE_CODESIGN_IDENTITY`
- `DEEPCRATE_NOTARY_APPLE_ID`
- `DEEPCRATE_NOTARY_APP_PASSWORD`
- `DEEPCRATE_NOTARY_TEAM_ID`

GitHub Actions workflow:

- `.github/workflows/release-macos.yml` builds the macOS bundle on tag pushes (`v*`) and uploads the DMG/ZIP to the release.
