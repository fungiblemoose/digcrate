"""Tests for planner helper logic that does not call external APIs."""

from deepcrate.models import Track
from deepcrate.planning.planner import (
    _bpm_matches_range,
    _infer_genre_profile,
    _infer_genre_profiles,
    _order_tracks_for_flow,
    _prefilter_tracks,
)


def make_track(track_id: int, bpm: float, key: str, energy: float, artist: str = "Artist") -> Track:
    return Track(
        id=track_id,
        file_path=f"/music/{track_id}.mp3",
        file_hash=f"hash-{track_id}",
        title=f"Track {track_id}",
        artist=artist,
        bpm=bpm,
        musical_key=key,
        energy_level=energy,
        duration=300.0,
    )


def test_infer_genre_profile_dnb_aliases():
    profile = _infer_genre_profile("need a liquid DnB warmup set")
    assert profile is not None
    assert profile.family == "dnb"
    assert profile.name in {"liquid drum and bass", "drum and bass"}


def test_infer_genre_profiles_understands_jargon_and_specificity():
    profiles = _infer_genre_profiles("need rollers and neuro for this dnb peak-time set")
    names = {profile.name for profile in profiles}

    assert "drum and bass" in names
    assert "liquid drum and bass" in names
    assert "neurofunk" in names


def test_infer_genre_profiles_handles_house_jargon():
    profiles = _infer_genre_profiles("prog house opener then tech house grooves")
    names = {profile.name for profile in profiles}
    assert "progressive house" in names
    assert "tech house" in names


def test_infer_genre_profiles_handles_hardbass_and_tropical_house():
    hard = {profile.name for profile in _infer_genre_profiles("hardbass peak-time set")}
    tropical = {profile.name for profile in _infer_genre_profiles("sunset tropical house warmup")}

    assert "hardstyle" in hard
    assert "tropical house" in tropical


def test_bpm_matches_range_supports_half_tempo():
    assert _bpm_matches_range(174.0, (170.0, 175.0)) is True
    assert _bpm_matches_range(87.0, (170.0, 175.0)) is True
    assert _bpm_matches_range(124.0, (170.0, 175.0)) is False


def test_prefilter_tracks_biases_to_genre_bpm():
    tracks = [
        make_track(1, 124.0, "8A", 0.45),
        make_track(2, 128.0, "9A", 0.55),
        make_track(3, 171.0, "10A", 0.35),
        make_track(4, 173.0, "11A", 0.50),
        make_track(5, 175.0, "12A", 0.65),
        make_track(6, 176.0, "1A", 0.72),
        make_track(7, 174.0, "2A", 0.58),
        make_track(8, 172.0, "3A", 0.62),
        make_track(9, 171.5, "4A", 0.41),
        make_track(10, 170.5, "5A", 0.48),
        make_track(11, 169.0, "6A", 0.53),
        make_track(12, 178.0, "7A", 0.66),
    ]

    filtered = _prefilter_tracks("build me a drum and bass set", tracks)
    assert len(filtered) >= 8
    assert all(166.0 <= t.bpm <= 178.0 for t in filtered)


def test_order_tracks_for_flow_preserves_unique_tracks():
    tracks = [
        make_track(1, 170.0, "8A", 0.30, artist="A"),
        make_track(2, 171.0, "9A", 0.42, artist="B"),
        make_track(3, 172.0, "10A", 0.56, artist="C"),
        make_track(4, 173.0, "11A", 0.68, artist="D"),
        make_track(5, 174.0, "12A", 0.78, artist="E"),
    ]

    ordered = _order_tracks_for_flow(tracks, "start mellow and build to a peak", _infer_genre_profiles("dnb"))
    assert len(ordered) == len(tracks)
    assert {t.id for t in ordered} == {t.id for t in tracks}
    assert ordered[0].energy_level <= ordered[-1].energy_level
