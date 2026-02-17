"""Audio analysis: BPM, key, energy, duration extraction using librosa."""

import hashlib
import re
from pathlib import Path

import librosa
import mutagen
import numpy as np

from deepcrate.analysis.camelot import CHROMA_MAJOR, CHROMA_MINOR, KEY_TO_CAMELOT, key_name_to_camelot, parse_camelot
from deepcrate.models import Track

ANALYSIS_VERSION = 3


def file_hash(path: Path) -> str:
    """Compute a fast hash of the first 1MB of a file for change detection."""
    h = hashlib.md5()
    with open(path, "rb") as f:
        h.update(f.read(1_048_576))
    return h.hexdigest()


def read_metadata(path: Path) -> dict[str, str]:
    """Read ID3/metadata tags from an audio file."""
    result: dict[str, str] = {"title": "", "artist": "", "bpm": "", "key": ""}

    try:
        easy_meta = mutagen.File(path, easy=True)
        if easy_meta is not None:
            result["title"] = _coerce_tag_value(easy_meta.get("title"))
            result["artist"] = _coerce_tag_value(easy_meta.get("artist"))
            result["bpm"] = _coerce_tag_value(easy_meta.get("bpm"))
            result["key"] = _coerce_tag_value(easy_meta.get("initialkey")) or _coerce_tag_value(
                easy_meta.get("key")
            )
    except Exception:
        pass

    try:
        raw_meta = mutagen.File(path, easy=False)
        raw_tags = getattr(raw_meta, "tags", None)
        if raw_tags is not None:
            if not result["bpm"]:
                result["bpm"] = (
                    _coerce_tag_value(raw_tags.get("TBPM"))
                    or _coerce_tag_value(raw_tags.get("tmpo"))
                    or _coerce_tag_value(raw_tags.get("bpm"))
                )
            if not result["key"]:
                result["key"] = (
                    _coerce_tag_value(raw_tags.get("TKEY"))
                    or _coerce_tag_value(raw_tags.get("INITIALKEY"))
                    or _coerce_tag_value(raw_tags.get("initialkey"))
                    or _coerce_tag_value(raw_tags.get("----:com.apple.iTunes:INITIALKEY"))
                )
            if not result["title"]:
                result["title"] = _coerce_tag_value(raw_tags.get("TIT2")) or _coerce_tag_value(
                    raw_tags.get("\xa9nam")
                )
            if not result["artist"]:
                result["artist"] = _coerce_tag_value(raw_tags.get("TPE1")) or _coerce_tag_value(
                    raw_tags.get("\xa9ART")
                )
    except Exception:
        pass

    return {k: v for k, v in result.items() if v}


def _coerce_tag_value(value: object) -> str:
    """Convert mutagen tag values into a usable string."""
    if value is None:
        return ""

    if isinstance(value, (list, tuple)):
        if not value:
            return ""
        value = value[0]

    text_attr = getattr(value, "text", None)
    if text_attr is not None:
        if isinstance(text_attr, (list, tuple)):
            value = text_attr[0] if text_attr else ""
        else:
            value = text_attr

    if isinstance(value, bytes):
        try:
            return value.decode("utf-8", errors="ignore").strip()
        except Exception:
            return ""

    return str(value).strip()


def parse_bpm_tag(value: str) -> float:
    """Parse BPM from metadata fields like '174', '174.0 BPM', etc."""
    if not value:
        return 0.0

    match = re.search(r"\d+(?:[\.,]\d+)?", value)
    if not match:
        return 0.0

    numeric = match.group(0).replace(",", ".")
    try:
        bpm = float(numeric)
    except ValueError:
        return 0.0

    if not np.isfinite(bpm) or bpm <= 0:
        return 0.0
    while bpm > 260.0:
        bpm /= 2.0
    if bpm < 40.0 or bpm > 260.0:
        return 0.0
    return round(bpm, 1)


_NOTE_ALIAS_TO_CANONICAL: dict[str, str] = {
    "C": "C",
    "B#": "C",
    "C#": "C#",
    "DB": "Db",
    "D": "D",
    "D#": "Eb",
    "EB": "Eb",
    "E": "E",
    "FB": "E",
    "E#": "F",
    "F": "F",
    "F#": "F#",
    "GB": "Gb",
    "G": "G",
    "G#": "Ab",
    "AB": "Ab",
    "A": "A",
    "A#": "Bb",
    "BB": "Bb",
    "B": "B",
    "CB": "B",
}


def parse_key_tag_to_camelot(value: str) -> str:
    """Parse common key tag formats (e.g. 'Am', '8A', 'F# minor') into Camelot."""
    if not value:
        return ""

    cleaned = value.strip()
    parsed_camelot = parse_camelot(cleaned)
    if parsed_camelot is not None:
        number, letter = parsed_camelot
        return f"{number}{letter}"

    key_compact = re.sub(r"\s+", "", cleaned).upper()
    for key_name, camelot in KEY_TO_CAMELOT.items():
        if key_compact == re.sub(r"\s+", "", key_name).upper():
            return camelot

    match = re.match(
        r"^\s*([A-Ga-g])\s*([#b♭♯]?)\s*(maj(?:or)?|min(?:or)?|m)?\s*$",
        cleaned,
        re.IGNORECASE,
    )
    if not match:
        return ""

    letter = match.group(1).upper()
    accidental_raw = match.group(2) or ""
    accidental = "#" if accidental_raw in {"#", "♯"} else "B" if accidental_raw in {"b", "♭"} else ""
    mode_token = (match.group(3) or "").lower()
    is_minor = bool(mode_token) and mode_token.startswith("m") and not mode_token.startswith("maj")

    canonical_note = _NOTE_ALIAS_TO_CANONICAL.get(f"{letter}{accidental}")
    if not canonical_note:
        return ""

    key_name = f"{canonical_note} {'minor' if is_minor else 'major'}"
    return key_name_to_camelot(key_name)


def parse_filename_metadata(path: Path) -> dict[str, str]:
    """Infer title/artist from filename when tags are missing."""
    stem = re.sub(r"\s+", " ", path.stem).strip()
    if not stem:
        return {}

    match = re.match(r"^(?P<artist>.+?)\s*-\s*(?P<title>.+)$", stem)
    if match:
        artist = match.group("artist").strip()
        title = match.group("title").strip()
        if artist and title:
            return {"artist": artist, "title": title}

    return {"title": stem}


def read_duration(path: Path) -> float:
    """Read duration from container metadata, with librosa fallback."""
    try:
        meta = mutagen.File(path)
        if meta is not None and getattr(meta, "info", None) is not None:
            length = float(getattr(meta.info, "length", 0.0) or 0.0)
            if length > 0:
                return length
    except Exception:
        pass

    try:
        return float(librosa.get_duration(path=str(path)))
    except Exception:
        return 0.0


def _normalize_bpm(raw_bpm: float) -> float:
    """Normalize tempo to a practical DJ range while preserving feel."""
    bpm = float(raw_bpm)
    if bpm <= 0:
        return 0.0

    while bpm < 70.0:
        bpm *= 2.0
    while bpm > 190.0:
        bpm /= 2.0
    return bpm


def _dedupe_tempos(candidates: list[float], tolerance: float = 0.75) -> list[float]:
    unique: list[float] = []
    for candidate in candidates:
        if not np.isfinite(candidate) or candidate <= 0:
            continue
        if any(abs(candidate - existing) <= tolerance for existing in unique):
            continue
        unique.append(candidate)
    return unique


def _tempo_periodicity_score(ac: np.ndarray, tempo: float, sr: int, hop_length: int) -> float:
    if tempo <= 0:
        return 0.0

    lag = int(round((60.0 * sr) / (hop_length * tempo)))
    if lag <= 0 or lag >= len(ac):
        return 0.0

    score = float(ac[lag])
    if lag * 2 < len(ac):
        score += 0.5 * float(ac[lag * 2])
    if lag * 3 < len(ac):
        score += 0.25 * float(ac[lag * 3])
    return score


def _candidate_strength(candidates: list[tuple[float, float]], tempo: float, tolerance: float = 1.5) -> float:
    """Get weighted support score for a tempo from nearby candidate bins."""
    if tempo <= 0 or not candidates:
        return 0.0

    best = 0.0
    for candidate_tempo, strength in candidates:
        diff = abs(candidate_tempo - tempo)
        if diff > tolerance:
            continue
        weight = 1.0 - (diff / max(tolerance, 1e-6))
        best = max(best, strength * max(weight, 0.0))
    return best


def load_analysis_window(path: Path, duration: float) -> tuple[np.ndarray, int, float]:
    """Load a representative slice to avoid intro/outro bias on long tracks."""
    if duration <= 0:
        y, sr = librosa.load(str(path), sr=22050, mono=True)
        return y, sr, 0.0

    if duration < 180.0:
        y, sr = librosa.load(str(path), sr=22050, mono=True)
        return y, sr, 0.0

    window = min(120.0, duration * 0.4)
    offset = min(max(30.0, duration * 0.25), max(duration - window, 0.0))
    y, sr = librosa.load(str(path), sr=22050, mono=True, offset=offset, duration=window)
    return y, sr, offset


def detect_bpm(y: np.ndarray, sr: int) -> float:
    """Detect BPM from audio signal with robust half/double-time disambiguation."""
    hop_length = 512
    try:
        _, y_percussive = librosa.effects.hpss(y)
        source = y_percussive if float(np.max(np.abs(y_percussive))) > 1e-6 else y
    except Exception:
        source = y

    onset_env = librosa.onset.onset_strength(y=source, sr=sr, hop_length=hop_length, aggregate=np.median)
    if onset_env.size < 8 or float(np.max(onset_env)) <= 1e-6:
        return 0.0
    onset_norm = onset_env / (float(np.max(onset_env)) + 1e-9)

    beat_tempo, _ = librosa.beat.beat_track(
        onset_envelope=onset_norm,
        sr=sr,
        hop_length=hop_length,
        start_bpm=128.0,
        tightness=100.0,
    )
    beat_value = float(np.atleast_1d(beat_tempo)[0])

    tempo_feature = librosa.feature.tempo(
        onset_envelope=onset_norm,
        sr=sr,
        hop_length=hop_length,
        aggregate=np.median,
    )
    feature_value = float(np.atleast_1d(tempo_feature)[0]) if np.size(tempo_feature) else 0.0

    dynamic_tempi = librosa.feature.tempo(
        onset_envelope=onset_norm,
        sr=sr,
        hop_length=hop_length,
        aggregate=None,
    )
    dynamic_candidates = dynamic_tempi[np.isfinite(dynamic_tempi)]
    dynamic_candidates = dynamic_candidates[(dynamic_candidates >= 55.0) & (dynamic_candidates <= 220.0)]
    dynamic_value = float(np.median(dynamic_candidates)) if dynamic_candidates.size else 0.0

    ac = librosa.autocorrelate(
        onset_norm,
        max_size=min(len(onset_env), int((sr / hop_length) * 8.0)),
    )
    if ac.size > 0:
        ac[0] = 0.0

    tempo_freqs_ac = librosa.tempo_frequencies(len(ac), sr=sr, hop_length=hop_length)
    autocorr_candidates: list[tuple[float, float]] = []
    if tempo_freqs_ac.size and ac.size == tempo_freqs_ac.size:
        idx = np.where(np.isfinite(tempo_freqs_ac) & (tempo_freqs_ac >= 55.0) & (tempo_freqs_ac <= 220.0))[0]
        if idx.size:
            ranked = idx[np.argsort(ac[idx])[::-1]]
            max_ac = float(np.max(ac[idx])) + 1e-9
            autocorr_candidates = [(float(tempo_freqs_ac[i]), float(ac[i] / max_ac)) for i in ranked[:8]]

    tempogram = librosa.feature.tempogram(onset_envelope=onset_norm, sr=sr, hop_length=hop_length)
    tempogram_candidates: list[tuple[float, float]] = []
    if tempogram.size > 0:
        tempo_freqs_tg = librosa.tempo_frequencies(tempogram.shape[0], sr=sr, hop_length=hop_length)
        strength = np.mean(tempogram, axis=1)
        idx = np.where(np.isfinite(tempo_freqs_tg) & (tempo_freqs_tg >= 55.0) & (tempo_freqs_tg <= 220.0))[0]
        if idx.size:
            ranked = idx[np.argsort(strength[idx])[::-1]]
            max_strength = float(np.max(strength[idx])) + 1e-9
            tempogram_candidates = [
                (float(tempo_freqs_tg[i]), float(strength[i] / max_strength)) for i in ranked[:10]
            ]

    base_candidates = (
        [beat_value, feature_value, dynamic_value]
        + [tempo for tempo, _ in autocorr_candidates]
        + [tempo for tempo, _ in tempogram_candidates]
    )
    expanded: list[float] = []
    for base in base_candidates:
        if base <= 0:
            continue
        for multiple in (0.5, 1.0, 2.0):
            candidate = base * multiple
            if 60.0 <= candidate <= 210.0:
                expanded.append(candidate)

    candidates = _dedupe_tempos(expanded)
    if not candidates:
        return round(_normalize_bpm(max(beat_value, feature_value, dynamic_value, 0.0)), 1)

    def score_candidate(tempo: float) -> float:
        score = _tempo_periodicity_score(ac, tempo, sr, hop_length)
        score += 1.15 * _candidate_strength(tempogram_candidates, tempo, tolerance=1.5)
        score += 0.8 * _candidate_strength(autocorr_candidates, tempo, tolerance=1.5)

        for reference, weight in ((beat_value, 0.30), (feature_value, 0.25), (dynamic_value, 0.20)):
            if reference <= 0:
                continue
            ratio = max(tempo, reference) / min(tempo, reference)
            if ratio <= 1.05:
                score += weight
            elif abs(ratio - 2.0) <= 0.08:
                score += weight * 0.45

        if 118.0 <= tempo <= 180.0:
            score *= 1.03
        return float(score)

    scored: list[tuple[float, float]] = []
    for tempo in candidates:
        scored.append((tempo, score_candidate(tempo)))

    best_tempo, best_score = max(scored, key=lambda item: item[1])

    # Refine with half/double variants around the best candidate.
    variants = [best_tempo]
    if best_tempo / 2.0 >= 60.0:
        variants.append(best_tempo / 2.0)
    if best_tempo * 2.0 <= 210.0:
        variants.append(best_tempo * 2.0)

    variant_scores = [(tempo, score_candidate(tempo)) for tempo in _dedupe_tempos(variants, tolerance=0.1)]
    best_tempo, best_score = max(variant_scores, key=lambda item: item[1])

    # DnB and similar styles are commonly tagged in double-time.
    if best_tempo < 100.0 and best_tempo * 2.0 <= 210.0:
        doubled = best_tempo * 2.0
        doubled_score = score_candidate(doubled)
        high_reference = max(beat_value, feature_value, dynamic_value)
        if high_reference >= 120.0 and doubled_score >= best_score * 0.90:
            best_tempo = doubled

    return round(_normalize_bpm(best_tempo), 1)


def detect_key(y: np.ndarray, sr: int) -> str:
    """Detect musical key and return Camelot notation."""
    if y.size == 0:
        return ""

    try:
        y_harmonic, _ = librosa.effects.hpss(y)
        source = y_harmonic if float(np.max(np.abs(y_harmonic))) > 1e-6 else y
    except Exception:
        source = y

    try:
        tuning = float(librosa.estimate_tuning(y=source, sr=sr))
    except Exception:
        tuning = 0.0

    chroma_cqt = librosa.feature.chroma_cqt(y=source, sr=sr, tuning=tuning)
    chroma_stft = librosa.feature.chroma_stft(y=source, sr=sr, tuning=tuning)
    chroma = 0.7 * chroma_cqt + 0.3 * chroma_stft
    chroma = librosa.util.normalize(chroma + 1e-9, axis=0)

    rms = librosa.feature.rms(y=source)[0]
    if rms.size == chroma.shape[1]:
        threshold = float(np.percentile(rms, 30))
        mask = rms >= threshold
        chroma_avg = np.mean(chroma[:, mask], axis=1) if np.any(mask) else np.mean(chroma, axis=1)
    else:
        chroma_avg = np.mean(chroma, axis=1)

    chroma_avg = chroma_avg / (np.sum(chroma_avg) + 1e-9)

    # Krumhansl-Kessler key profiles
    major_profile = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
    minor_profile = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])

    best_corr = -1.0
    best_key = ""

    for i in range(12):
        # Rotate chroma to test each root
        rotated = np.roll(chroma_avg, -i)
        major_corr = _safe_corr(rotated, major_profile)
        minor_corr = _safe_corr(rotated, minor_profile)

        if major_corr > best_corr:
            best_corr = major_corr
            best_key = CHROMA_MAJOR[i]
        if minor_corr > best_corr:
            best_corr = minor_corr
            best_key = CHROMA_MINOR[i]

    return key_name_to_camelot(best_key)


def _safe_corr(a: np.ndarray, b: np.ndarray) -> float:
    if a.size == 0 or b.size == 0:
        return 0.0
    if float(np.std(a)) < 1e-9 or float(np.std(b)) < 1e-9:
        return 0.0
    value = float(np.corrcoef(a, b)[0, 1])
    if not np.isfinite(value):
        return 0.0
    return value


def detect_energy(y: np.ndarray, sr: int) -> float:
    energy, _ = detect_energy_with_confidence(y, sr)
    return energy


def _normalize_series(values: np.ndarray) -> np.ndarray:
    if values.size == 0:
        return values
    low = float(np.min(values))
    high = float(np.max(values))
    span = high - low
    if span <= 1e-9:
        return np.zeros_like(values)
    return (values - low) / span


def detect_energy_with_confidence(y: np.ndarray, sr: int) -> tuple[float, float]:
    """Estimate energy level (0.0-1.0) from RMS and spectral features."""
    rms = librosa.feature.rms(y=y)[0]
    spectral_centroid = librosa.feature.spectral_centroid(y=y, sr=sr)[0]

    # Normalize RMS (typical range for music)
    rms_mean = float(np.mean(rms))
    rms_score = min(rms_mean / 0.15, 1.0)

    # Normalize spectral centroid (higher = brighter = more energy)
    centroid_mean = float(np.mean(spectral_centroid))
    centroid_score = min(centroid_mean / 5000.0, 1.0)

    # Weighted combination
    energy = 0.6 * rms_score + 0.4 * centroid_score
    energy = round(min(max(energy, 0.0), 1.0), 2)

    # Confidence focuses on the quality of the energy estimate only.
    dynamic_range = float(np.percentile(rms, 95) - np.percentile(rms, 5)) if rms.size > 0 else 0.0
    rms_std = float(np.std(rms)) if rms.size > 0 else 0.0
    variance_ratio = rms_std / (rms_mean + 1e-6)
    centroid_std = float(np.std(spectral_centroid)) if spectral_centroid.size > 0 else 0.0
    centroid_ratio = centroid_std / (centroid_mean + 1e-6)
    silence_ratio = float(np.mean(rms < max(rms_mean * 0.35, 1e-6))) if rms.size > 0 else 1.0

    dynamic_score = min(dynamic_range / 0.12, 1.0)
    variance_score = min(variance_ratio / 0.8, 1.0)
    centroid_var_score = min(centroid_ratio / 0.8, 1.0)

    confidence = (
        0.25
        + 0.35 * dynamic_score
        + 0.20 * variance_score
        + 0.20 * centroid_var_score
        - 0.20 * silence_ratio
    )
    confidence = round(min(max(confidence, 0.0), 1.0), 2)
    return energy, confidence


def detect_preview_start(
    y: np.ndarray,
    sr: int,
    duration: float,
    analysis_offset: float = 0.0,
    preview_length: float = 30.0,
) -> float:
    """Choose a musically dense cue point for preview playback."""
    if duration <= preview_length + 5:
        return 0.0

    hop_length = 512
    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)
    rms = librosa.feature.rms(y=y, hop_length=hop_length)[0]

    if onset_env.size == 0 or rms.size == 0:
        return round(min(max(analysis_offset, 0.0), max(duration - preview_length, 0.0)), 1)

    score = 0.65 * _normalize_series(onset_env) + 0.35 * _normalize_series(rms)
    times = librosa.times_like(score, sr=sr, hop_length=hop_length)
    local_max_start = max((len(y) / float(sr)) - preview_length, 0.0)

    if local_max_start <= 0:
        return round(min(max(analysis_offset, 0.0), max(duration - preview_length, 0.0)), 1)

    min_local = min(8.0, local_max_start)
    mask = (times >= min_local) & (times <= local_max_start)
    if not np.any(mask):
        local_start = min_local
    else:
        masked_scores = np.where(mask, score, -np.inf)
        local_start = float(times[int(np.argmax(masked_scores))])

    local_start = max(local_start - 4.0, 0.0)
    absolute = analysis_offset + local_start
    absolute = min(max(absolute, 0.0), max(duration - preview_length, 0.0))
    return round(absolute, 1)


def classify_review_flags(
    title: str,
    artist: str,
    bpm: float,
    musical_key: str,
    energy_level: float,
    energy_confidence: float,
    duration: float,
) -> tuple[bool, str]:
    reasons: list[str] = []

    if energy_confidence < 0.55:
        reasons.append("Low energy confidence")
    if energy_level <= 0.03 or energy_level >= 0.97:
        reasons.append("Energy at boundary")
    if duration > 0 and duration < 45:
        reasons.append("Very short duration")
    if not title.strip():
        reasons.append("Missing title")
    if not artist.strip():
        reasons.append("Missing artist")
    if bpm <= 0:
        reasons.append("Missing BPM")
    if not musical_key.strip():
        reasons.append("Missing key")

    return (len(reasons) > 0, " | ".join(reasons))


def analyze_track(path: Path) -> Track:
    """Full analysis of a single audio track. Returns a Track model."""
    fhash = file_hash(path)
    metadata = read_metadata(path)
    filename_meta = parse_filename_metadata(path)
    duration = read_duration(path)

    # Analyze a representative segment for more stable DJ attributes.
    y, sr, analysis_offset = load_analysis_window(path, duration)
    if duration <= 0:
        duration = float(librosa.get_duration(y=y, sr=sr))

    metadata_bpm = parse_bpm_tag(metadata.get("bpm", ""))
    metadata_key = parse_key_tag_to_camelot(metadata.get("key", ""))

    bpm = metadata_bpm if metadata_bpm > 0 else detect_bpm(y, sr)
    musical_key = metadata_key or detect_key(y, sr)
    energy, energy_confidence = detect_energy_with_confidence(y, sr)
    preview_start = detect_preview_start(
        y=y,
        sr=sr,
        duration=duration,
        analysis_offset=analysis_offset,
        preview_length=30.0,
    )

    title = metadata.get("title", "").strip() or filename_meta.get("title", "").strip()
    artist = metadata.get("artist", "").strip() or filename_meta.get("artist", "").strip()

    # Fall back to filename when embedded tags are missing.
    if not title:
        title = path.stem

    needs_review, review_notes = classify_review_flags(
        title=title,
        artist=artist,
        bpm=bpm,
        musical_key=musical_key,
        energy_level=energy,
        energy_confidence=energy_confidence,
        duration=duration,
    )

    return Track(
        file_path=str(path),
        file_hash=fhash,
        title=title,
        artist=artist,
        bpm=bpm,
        musical_key=musical_key,
        energy_level=energy,
        energy_confidence=energy_confidence,
        duration=duration,
        preview_start=preview_start,
        needs_review=needs_review,
        review_notes=review_notes,
        analysis_version=ANALYSIS_VERSION,
    )
