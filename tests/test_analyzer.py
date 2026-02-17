"""Tests for audio analyzer (unit tests that don't require audio files)."""

from pathlib import Path
from unittest.mock import patch

import numpy as np

from deepcrate.analysis.analyzer import (
    ANALYSIS_VERSION,
    _normalize_bpm,
    analyze_track,
    classify_review_flags,
    detect_energy,
    detect_energy_with_confidence,
    detect_key,
    detect_preview_start,
    file_hash,
    parse_bpm_tag,
    parse_filename_metadata,
    parse_key_tag_to_camelot,
)


def test_file_hash(tmp_path):
    """file_hash should produce consistent hashes."""
    test_file = tmp_path / "test.mp3"
    test_file.write_bytes(b"fake audio content for testing" * 100)

    hash1 = file_hash(test_file)
    hash2 = file_hash(test_file)
    assert hash1 == hash2
    assert len(hash1) == 32  # MD5 hex length


def test_file_hash_different_content(tmp_path):
    """Different content should produce different hashes."""
    file_a = tmp_path / "a.mp3"
    file_b = tmp_path / "b.mp3"
    file_a.write_bytes(b"content A" * 100)
    file_b.write_bytes(b"content B" * 100)

    assert file_hash(file_a) != file_hash(file_b)


def test_detect_key_returns_camelot():
    """detect_key should return a valid Camelot notation."""
    sr = 22050
    duration = 5.0
    # Generate a simple sine wave at A4 (440 Hz)
    t = np.linspace(0, duration, int(sr * duration), endpoint=False)
    y = np.sin(2 * np.pi * 440 * t).astype(np.float32)

    key = detect_key(y, sr)
    # Should be a valid Camelot key (number + letter)
    assert len(key) >= 2
    assert key[-1] in ("A", "B")
    assert key[:-1].isdigit()


def test_detect_energy_range():
    """detect_energy should return a value between 0.0 and 1.0."""
    sr = 22050
    # Quiet signal
    y_quiet = np.random.randn(sr * 3).astype(np.float32) * 0.001
    energy_quiet = detect_energy(y_quiet, sr)
    assert 0.0 <= energy_quiet <= 1.0

    # Loud signal
    y_loud = np.random.randn(sr * 3).astype(np.float32) * 0.5
    energy_loud = detect_energy(y_loud, sr)
    assert 0.0 <= energy_loud <= 1.0

    # Loud should have higher energy than quiet
    assert energy_loud > energy_quiet


def test_detect_energy_with_confidence_bounds():
    sr = 22050
    y = np.random.randn(sr * 4).astype(np.float32) * 0.2
    energy, confidence = detect_energy_with_confidence(y, sr)
    assert 0.0 <= energy <= 1.0
    assert 0.0 <= confidence <= 1.0


def test_detect_preview_start_range():
    sr = 22050
    # Two short transients to simulate strong moments.
    y = np.zeros(sr * 80, dtype=np.float32)
    y[sr * 25: sr * 25 + 4000] = 0.8
    y[sr * 55: sr * 55 + 4000] = 0.9

    start = detect_preview_start(y=y, sr=sr, duration=80.0, analysis_offset=0.0, preview_length=30.0)
    assert 0.0 <= start <= 50.0


def test_classify_review_flags_uses_energy_confidence():
    needs_review, notes = classify_review_flags(
        title="Track",
        artist="Artist",
        bpm=174.0,
        musical_key="8A",
        energy_level=0.6,
        energy_confidence=0.32,
        duration=240.0,
    )
    assert needs_review is True
    assert "Low energy confidence" in notes


def test_parse_filename_metadata_artist_dash_title():
    result = parse_filename_metadata(Path("/music/Calibre - Even If.mp3"))
    assert result["artist"] == "Calibre"
    assert result["title"] == "Even If"


def test_parse_filename_metadata_title_fallback():
    result = parse_filename_metadata(Path("/music/Untitled_Track_01.wav"))
    assert result["title"] == "Untitled_Track_01"
    assert "artist" not in result


def test_normalize_bpm_handles_half_and_double_time():
    assert _normalize_bpm(62.0) == 124.0
    assert _normalize_bpm(256.0) == 128.0


def test_parse_bpm_tag_handles_common_formats():
    assert parse_bpm_tag("174") == 174.0
    assert parse_bpm_tag("174,5 BPM") == 174.5
    assert parse_bpm_tag("600") == 150.0
    assert parse_bpm_tag("unknown") == 0.0


def test_parse_key_tag_to_camelot_formats():
    assert parse_key_tag_to_camelot("8A") == "8A"
    assert parse_key_tag_to_camelot("Am") == "8A"
    assert parse_key_tag_to_camelot("F# minor") == "11A"
    assert parse_key_tag_to_camelot("Bb major") == "6B"
    assert parse_key_tag_to_camelot("not-a-key") == ""


def test_analyze_track_prefers_metadata_bpm_and_key():
    fake_audio = np.zeros(22050 * 4, dtype=np.float32)
    with (
        patch("deepcrate.analysis.analyzer.file_hash", return_value="abc123"),
        patch(
            "deepcrate.analysis.analyzer.read_metadata",
            return_value={"title": "Tagged Title", "artist": "Tagged Artist", "bpm": "174", "key": "Am"},
        ),
        patch("deepcrate.analysis.analyzer.parse_filename_metadata", return_value={"title": "Filename Title"}),
        patch("deepcrate.analysis.analyzer.read_duration", return_value=240.0),
        patch("deepcrate.analysis.analyzer.load_analysis_window", return_value=(fake_audio, 22050, 0.0)),
        patch("deepcrate.analysis.analyzer.detect_bpm", return_value=128.0) as mock_detect_bpm,
        patch("deepcrate.analysis.analyzer.detect_key", return_value="9A") as mock_detect_key,
        patch("deepcrate.analysis.analyzer.detect_energy_with_confidence", return_value=(0.72, 0.88)),
        patch("deepcrate.analysis.analyzer.detect_preview_start", return_value=12.0),
    ):
        track = analyze_track(Path("/music/test.mp3"))

    assert track.bpm == 174.0
    assert track.musical_key == "8A"
    assert track.analysis_version == ANALYSIS_VERSION
    mock_detect_bpm.assert_not_called()
    mock_detect_key.assert_not_called()


def test_analyze_track_falls_back_to_signal_when_tags_invalid():
    fake_audio = np.zeros(22050 * 4, dtype=np.float32)
    with (
        patch("deepcrate.analysis.analyzer.file_hash", return_value="abc123"),
        patch(
            "deepcrate.analysis.analyzer.read_metadata",
            return_value={"title": "", "artist": "", "bpm": "??", "key": "??"},
        ),
        patch(
            "deepcrate.analysis.analyzer.parse_filename_metadata",
            return_value={"title": "Filename Title", "artist": "Filename Artist"},
        ),
        patch("deepcrate.analysis.analyzer.read_duration", return_value=200.0),
        patch("deepcrate.analysis.analyzer.load_analysis_window", return_value=(fake_audio, 22050, 0.0)),
        patch("deepcrate.analysis.analyzer.detect_bpm", return_value=171.2) as mock_detect_bpm,
        patch("deepcrate.analysis.analyzer.detect_key", return_value="10A") as mock_detect_key,
        patch("deepcrate.analysis.analyzer.detect_energy_with_confidence", return_value=(0.65, 0.93)),
        patch("deepcrate.analysis.analyzer.detect_preview_start", return_value=15.0),
    ):
        track = analyze_track(Path("/music/test.mp3"))

    assert track.bpm == 171.2
    assert track.musical_key == "10A"
    assert track.title == "Filename Title"
    assert track.artist == "Filename Artist"
    mock_detect_bpm.assert_called_once()
    mock_detect_key.assert_called_once()
