# DigCrate

DigCrate is a command-line tool for AI-powered DJ set planning. It analyzes
your local music library (BPM, musical key, energy), plans sets from natural
language descriptions, scores every transition using harmonic mixing rules,
finds the weak spots, and exports playlists you can actually play out.

> **Looking for the Mac app?** DigCrate for macOS is now available —
> [Download on the Mac App Store](https://apps.apple.com/us/app/digcrate/id6779803539?mt=12).
> Learn more at [digcrate.backspinlabs.com](https://digcrate.backspinlabs.com).

## What it does

- **Analyze** — scans a folder of audio files and extracts BPM (beat
  tracking), musical key (chromagram + Krumhansl-Kessler profiles, reported
  in standard harmonic notation like `8A`), and energy (RMS + spectral centroid).
  All analysis is local via `librosa`; nothing is uploaded.
- **Plan** — describe the set you want ("60 minute liquid dnb journey,
  start mellow, peak around minute 40") and DigCrate selects and orders
  tracks from your library using an LLM, then validates everything against
  your actual files. Note: planning sends track metadata (artist, title,
  BPM, key, energy) to OpenAI — audio never leaves your machine, but the
  catalog text does.
- **Score** — every transition is rated on key compatibility (40%), BPM
  match (35%), and energy flow (25%), with half-tempo detection so 87 BPM
  and 174 BPM DnB mix correctly.
- **Find gaps** — weak transitions get flagged with a suggested bridge-track
  profile (target BPM, key, energy), and `discover` searches Spotify for
  candidates that fit.
- **Export** — M3U for any player, or Rekordbox XML for Pioneer gear.

## Install

```bash
git clone https://github.com/fungiblemoose/digcrate.git
cd digcrate
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
cp .env.example .env   # add your OpenAI key (and Spotify keys for discover)
```

Requires Python 3.12+.

## Commands

| Command | What it does |
|---------|-------------|
| `digcrate scan <dir>` | Analyze audio files and store results. Unchanged files are skipped on rescan. |
| `digcrate stats` | Library overview: track count, BPM range, top keys, total duration. |
| `digcrate search` | Filter by `--bpm`, `--key`, `--energy`, or `-q` text. |
| `digcrate plan "<description>" --name <name> --duration <min>` | AI set planning. |
| `digcrate show <name>` | Tracklist with per-transition scores. |
| `digcrate gaps <name>` | Flag weak transitions and suggest bridge profiles. |
| `digcrate discover --name <name> --gap <n>` | Spotify candidates for a gap. |
| `digcrate export <name> --format m3u\|rekordbox` | Write a playlist file. |

## Configuration

Set in `.env` at the project root:

| Variable | Required for | Default |
|----------|--------------|---------|
| `OPENAI_API_KEY` | `plan` | — |
| `OPENAI_MODEL` | optional | `gpt-4o-mini` |
| `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` | `discover` | — |
| `DATABASE_PATH` | optional | `data/digcrate.sqlite` |

## Tests

```bash
python -m pytest tests/ -v
```

The suite covers harmonic-wheel math, transition scoring (including
half-tempo and energy-direction handling), and analyzer output validation —
no audio files or API keys needed.

## License

MIT — see [LICENSE](LICENSE).
