# DeepCrate — How It Works

DeepCrate is a macOS app for DJs that helps you analyze your local library, build sets from natural-language prompts, inspect weak transitions, discover missing tracks, and export playlists.

## The Big Picture

You have a folder full of music. DeepCrate scans each track, figures out its BPM, musical key, and energy level, and stores all of that in a local database. Then when you want to build a set, you describe what you want in plain English, like "60 minute liquid DnB set, start chill, peak around 40 minutes," and it asks either a local model server or Apple’s on-device model to choose and order tracks from your library. After that, DeepCrate scores every transition for harmonic compatibility, flags weak spots, can search Spotify for missing tracks, and exports the final result as an M3U or Rekordbox XML playlist.

## Primary App

The main product is the Swift macOS app:

```bash
cd DeepCrateMac
swift run
```

The app includes pages for:
- Library scan, stats, and search
- Set planning and preview
- Gap analysis
- Spotify discovery for gaps
- Playlist export

Use the in-app `Settings` screen to set:
- local model server endpoint / model
- Spotify client ID/secret
- Database path

The legacy CLI and Python GUI still exist for compatibility, but they are no longer the primary interface.

## Step by Step

### 1. Scanning Your Music

In the app, open `Library`, click `Scan`, and choose a music folder.

This walks through every audio file in the folder and runs each one through the current Swift analysis pipeline. For each track it figures out:

- **BPM** — Uses beat tracking to find the tempo
- **Musical key** — Builds a chromagram (a picture of which notes are present) and matches it against known key profiles (Krumhansl-Kessler profiles) to guess the key. Accuracy is roughly 70-80%. The key gets converted to Camelot notation (like "8A") which is what DJs use for harmonic mixing
- **Energy level** — Combines loudness (RMS) and brightness (spectral centroid) into a 0-1 score
- **Duration** — How long the track is in seconds

It also reads metadata tags and computes a hash of the file so it knows not to re-analyze tracks that have not changed. Everything gets saved to a SQLite database at `data/deepcrate.sqlite`.

Analysis takes roughly 5-10 seconds per track. But once a track is analyzed, it's cached — running scan again on the same folder skips tracks that haven't changed.

You can scan as many folders as you want. They all feed into the same database.

### 2. Browsing Your Library

The `Library` page queries the local database directly in Swift. You can filter by BPM range, key, energy range, review status, or text search on artist/title. Manual overrides let you correct BPM, key, and energy when the analyzer gets something wrong.

### 3. Planning a Set

Open `Build Set`, describe the vibe you want, choose a duration, and pick either `Local Model Server` or `Apple On-Device`.

This is what happens under the hood:

1. Pulls all your tracks from the database
2. If you have more than 200 tracks, it pre-filters based on keywords in your description (e.g., if you mention "DnB" it filters to 160-180 BPM) so the list fits in the LLM's context window
3. Formats your track library into a text list with IDs, artist, title, BPM, key, energy, and duration
4. Sends that list plus your description either to the local model server you configured or to the Apple on-device model, with a prompt that knows about harmonic mixing, energy flow, and DJ conventions
5. The LLM picks tracks by ID and orders them
6. DeepCrate scores every transition (key compatibility, BPM delta, energy flow) and saves the set to the database

The set is saved in SQLite so you can come back to it later.

### 4. Reviewing a Set

The `Sets` page shows the full tracklist with BPM, key, energy, and a color-coded transition score for each pair of adjacent tracks. Green means smooth, yellow means usable, red means rough.

### 5. Finding Weak Spots

The `Gaps` page looks at every transition and flags the ones below a 50% compatibility score. For each weak spot it tells you what is wrong, like a key clash, BPM jump, or energy jump, and suggests what kind of bridge track would fix it.

### 6. Discovering New Tracks

The `Discover` page takes a gap identified in the previous step and searches Spotify for tracks that match the suggested BPM, key, and energy. It auto-doubles BPM for DnB tracks when Spotify reports half-time values and returns track names, artists, BPM, energy, and Spotify links.

This requires Spotify API credentials in your `.env` file.

### 7. Exporting

From the `Export` page you can write:

- **M3U**: Standard playlist format. Works with most music players and DJ software.
- **Rekordbox XML**: Pioneer format. Import it into Rekordbox and the tracks load in order with BPM and key data.

Both formats reference your actual local files, so make sure the tracks are still in the same location.

## The Camelot Wheel

The Camelot wheel is a system DJs use to know which keys mix well together. Every musical key maps to a code like "8A" or "11B". The rules are simple:

- **Same code** = perfect match (8A → 8A)
- **One number up or down** = smooth transition (8A → 9A or 7A)
- **Same number, switch A/B** = relative major/minor (8A → 8B)
- **Everything else** = gets increasingly risky

DeepCrate uses these rules to score every transition in your set.

## Configuration

Bridge settings and service credentials can live in a `.env` file in the project root, and planner settings can also be edited in-app:

- `LOCAL_MODEL_ENDPOINT` — Optional if you use a local model server for set planning
- `LOCAL_MODEL_NAME` — The default model name to request from that server
- `LOCAL_MODEL_TOKEN` — Optional auth token for the local model server
- `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` — Only needed for the discover command
- `DATABASE_PATH` — Where the SQLite database lives. Default is `data/deepcrate.sqlite`

## Limitations

- Spotify discovery still depends on the Python bridge today.
- Key detection is still imperfect. If a track looks wrong, you can manually override BPM, key, and energy in the Library view.
- The LLM is only as good as the data you give it. If your metadata (artist/title) is messy, the AI has less to work with.
- Spotify's audio features API sometimes returns half-tempo BPMs for DnB. We auto-double when it looks wrong, but it's not perfect.
- Analysis is CPU-intensive. A library of 1000 tracks will take a while on the first scan.
