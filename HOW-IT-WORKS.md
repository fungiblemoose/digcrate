# DeepCrate — How It Works

DeepCrate is a command-line tool that helps you plan DJ sets from your local music library using AI.

## The Big Picture

You have a folder full of music. DeepCrate listens to each track, figures out its BPM, musical key, and energy level, and stores all of that in a local database. Then when you want to build a set, you describe what you want in plain English — "60 minute liquid DnB set, start chill, peak around 40 minutes" — and it uses ChatGPT to pick tracks from your library and put them in an order that flows well. It checks every transition for harmonic compatibility using the Camelot wheel, flags any rough spots, and can even search Spotify for tracks you're missing. When you're happy with the set, export it as an M3U or Rekordbox XML and load it straight into your DJ software.

## Desktop GUI

If you prefer clicking over CLI commands, run the local desktop app:

```bash
deepcrate-gui
```

The GUI wraps the same core functions as the CLI with tabs for:
- Library scan, stats, and search
- Set planning and preview
- Gap analysis
- Spotify discovery for gaps
- Playlist export

Use `DeepCrate -> Preferences...` (or `Edit -> Preferences...`) to set:
- `OPENAI_API_KEY` / model
- Spotify client ID/secret
- Database path

## Step by Step

### 1. Scanning Your Music

```bash
deepcrate scan ~/Music/DnB
```

This walks through every audio file in the folder (mp3, flac, wav, aiff, m4a, ogg, opus, wma) and runs each one through librosa, an audio analysis library. For each track it figures out:

- **BPM** — Uses beat tracking to find the tempo
- **Musical key** — Builds a chromagram (a picture of which notes are present) and matches it against known key profiles (Krumhansl-Kessler profiles) to guess the key. Accuracy is roughly 70-80%. The key gets converted to Camelot notation (like "8A") which is what DJs use for harmonic mixing
- **Energy level** — Combines loudness (RMS) and brightness (spectral centroid) into a 0-1 score
- **Duration** — How long the track is in seconds

It also reads ID3 tags (artist, title) and computes a hash of the file so it knows not to re-analyze tracks that haven't changed. Everything gets saved to a SQLite database at `data/deepcrate.sqlite`.

Analysis takes roughly 5-10 seconds per track. But once a track is analyzed, it's cached — running scan again on the same folder skips tracks that haven't changed.

You can scan as many folders as you want. They all feed into the same database.

### 2. Browsing Your Library

```bash
deepcrate stats              # Overview: track count, BPM range, top keys
deepcrate search --bpm 170-175 --key 8A
deepcrate search -q "subfocus"
```

These just query the local database. Stats gives you the big picture. Search lets you filter by BPM range, key, energy range, or text search on artist/title.

### 3. Planning a Set

```bash
deepcrate plan "60 min liquid set, start mellow, peak at 40 min" \
    --name "Sunday Session" --duration 60
```

This is where the AI comes in. Here's what happens under the hood:

1. Pulls all your tracks from the database
2. If you have more than 200 tracks, it pre-filters based on keywords in your description (e.g., if you mention "DnB" it filters to 160-180 BPM) so the list fits in the LLM's context window
3. Formats your track library into a text list with IDs, artist, title, BPM, key, energy, and duration
4. Sends that list plus your description to OpenAI (gpt-4o-mini by default) with a system prompt that knows about harmonic mixing, energy flow, and DJ conventions
5. The LLM picks tracks by ID and orders them
6. DeepCrate scores every transition (key compatibility, BPM delta, energy flow) and saves the set to the database

The set is saved by name so you can come back to it later.

### 4. Reviewing a Set

```bash
deepcrate show "Sunday Session"
```

Shows the full tracklist with BPM, key, energy, and a color-coded transition score for each pair of adjacent tracks. Green = smooth, yellow = okay, red = rough.

### 5. Finding Weak Spots

```bash
deepcrate gaps "Sunday Session"
```

Looks at every transition and flags the ones below a 50% compatibility score. For each weak spot it tells you what's wrong (key clash, BPM jump, energy jump) and suggests what kind of bridge track would fix it — the ideal BPM, key, and energy level.

### 6. Discovering New Tracks

```bash
deepcrate discover --name "Sunday Session" --gap 1 --genre "drum and bass"
```

Takes a gap identified in the previous step and searches Spotify for tracks that match the suggested BPM, key, and energy. It auto-doubles BPM for DnB tracks (Spotify often lists 174 BPM as 87). Returns a table with track names, artists, BPM, energy, and Spotify links.

This requires Spotify API credentials in your `.env` file.

### 7. Exporting

```bash
deepcrate export "Sunday Session" --format m3u
deepcrate export "Sunday Session" --format rekordbox
```

- **M3U** — Standard playlist format. Works with most music players and DJ software.
- **Rekordbox XML** — Pioneer's format. Import it into Rekordbox and the tracks load in order with BPM and key data.

Both formats reference your actual local files, so make sure the tracks are still in the same location.

## The Camelot Wheel

The Camelot wheel is a system DJs use to know which keys mix well together. Every musical key maps to a code like "8A" or "11B". The rules are simple:

- **Same code** = perfect match (8A → 8A)
- **One number up or down** = smooth transition (8A → 9A or 7A)
- **Same number, switch A/B** = relative major/minor (8A → 8B)
- **Everything else** = gets increasingly risky

DeepCrate uses these rules to score every transition in your set.

## Configuration

All settings live in a `.env` file in the project root:

- `OPENAI_API_KEY` — Required for set planning
- `OPENAI_MODEL` — Default is `gpt-4o-mini` (cheap and fast). Change to `gpt-4o` if you want better results
- `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` — Only needed for the discover command
- `DATABASE_PATH` — Where the SQLite database lives. Default is `data/deepcrate.sqlite`

## Limitations

- Key detection is ~70-80% accurate. If a track's key looks wrong, the analysis can't be manually overridden yet (future feature).
- The LLM is only as good as the data you give it. If your metadata (artist/title) is messy, the AI has less to work with.
- Spotify's audio features API sometimes returns half-tempo BPMs for DnB. We auto-double when it looks wrong, but it's not perfect.
- Analysis is CPU-intensive. A library of 1000 tracks will take a while on the first scan.
