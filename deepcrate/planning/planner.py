"""LLM-based set planning using OpenAI."""

import json
import re
from dataclasses import dataclass

from openai import OpenAI
from rich.console import Console

from deepcrate.config import get_settings
from deepcrate.db import (
    create_set,
    delete_set,
    get_all_tracks,
    set_set_tracks,
)
from deepcrate.models import SetPlan, SetTrack
from deepcrate.planning.prompts import SYSTEM_PROMPT, build_library_context, build_plan_prompt
from deepcrate.planning.scoring import transition_score

console = Console()


@dataclass(frozen=True)
class GenreProfile:
    family: str
    name: str
    aliases: tuple[str, ...]
    bpm_range: tuple[float, float]
    relaxed_bpm_range: tuple[float, float]


GENRE_PROFILES: tuple[GenreProfile, ...] = (
    GenreProfile(
        family="dnb",
        name="drum and bass",
        aliases=("dnb", "drum and bass", "drum & bass", "drum n bass", "drum'n'bass"),
        bpm_range=(170.0, 175.0),
        relaxed_bpm_range=(166.0, 178.0),
    ),
    GenreProfile(
        family="dnb",
        name="liquid drum and bass",
        aliases=("liquid dnb", "liquid drum and bass", "liquid", "rollers"),
        bpm_range=(172.0, 175.0),
        relaxed_bpm_range=(170.0, 177.0),
    ),
    GenreProfile(
        family="dnb",
        name="jungle",
        aliases=("jungle", "oldschool jungle", "amen"),
        bpm_range=(165.0, 174.0),
        relaxed_bpm_range=(160.0, 176.0),
    ),
    GenreProfile(
        family="dnb",
        name="neurofunk",
        aliases=("neurofunk", "neuro", "dark dnb"),
        bpm_range=(172.0, 178.0),
        relaxed_bpm_range=(170.0, 180.0),
    ),
    GenreProfile(
        family="house",
        name="house",
        aliases=("house", "club house", "classic house"),
        bpm_range=(120.0, 130.0),
        relaxed_bpm_range=(118.0, 132.0),
    ),
    GenreProfile(
        family="house",
        name="deep house",
        aliases=("deep house", "deep"),
        bpm_range=(118.0, 124.0),
        relaxed_bpm_range=(116.0, 126.0),
    ),
    GenreProfile(
        family="house",
        name="tech house",
        aliases=("tech house",),
        bpm_range=(124.0, 130.0),
        relaxed_bpm_range=(122.0, 132.0),
    ),
    GenreProfile(
        family="house",
        name="progressive house",
        aliases=("progressive house", "prog house"),
        bpm_range=(124.0, 132.0),
        relaxed_bpm_range=(122.0, 134.0),
    ),
    GenreProfile(
        family="house",
        name="bass house",
        aliases=("bass house", "uk bass house"),
        bpm_range=(126.0, 132.0),
        relaxed_bpm_range=(124.0, 134.0),
    ),
    GenreProfile(
        family="house",
        name="melodic house",
        aliases=("melodic house", "melodic house and techno", "melodic"),
        bpm_range=(118.0, 126.0),
        relaxed_bpm_range=(116.0, 130.0),
    ),
    GenreProfile(
        family="house",
        name="afro house",
        aliases=("afro house", "afrohouse"),
        bpm_range=(118.0, 124.0),
        relaxed_bpm_range=(116.0, 126.0),
    ),
    GenreProfile(
        family="house",
        name="organic house",
        aliases=("organic house", "downtempo house"),
        bpm_range=(112.0, 122.0),
        relaxed_bpm_range=(108.0, 124.0),
    ),
    GenreProfile(
        family="house",
        name="tropical house",
        aliases=("tropical house", "trop house"),
        bpm_range=(100.0, 115.0),
        relaxed_bpm_range=(96.0, 118.0),
    ),
    GenreProfile(
        family="techno",
        name="techno",
        aliases=("techno",),
        bpm_range=(128.0, 142.0),
        relaxed_bpm_range=(126.0, 145.0),
    ),
    GenreProfile(
        family="techno",
        name="melodic techno",
        aliases=("melodic techno",),
        bpm_range=(124.0, 132.0),
        relaxed_bpm_range=(122.0, 135.0),
    ),
    GenreProfile(
        family="techno",
        name="hard techno",
        aliases=("hard techno", "hardgroove", "hard groove"),
        bpm_range=(140.0, 155.0),
        relaxed_bpm_range=(136.0, 160.0),
    ),
    GenreProfile(
        family="trance",
        name="trance",
        aliases=("trance",),
        bpm_range=(132.0, 140.0),
        relaxed_bpm_range=(130.0, 145.0),
    ),
    GenreProfile(
        family="trance",
        name="psytrance",
        aliases=("psytrance", "psy trance"),
        bpm_range=(138.0, 145.0),
        relaxed_bpm_range=(136.0, 148.0),
    ),
    GenreProfile(
        family="garage",
        name="uk garage",
        aliases=("uk garage", "garage", "ukg", "2-step", "2 step"),
        bpm_range=(128.0, 136.0),
        relaxed_bpm_range=(126.0, 138.0),
    ),
    GenreProfile(
        family="bass",
        name="dubstep",
        aliases=("dubstep", "140", "deep dubstep"),
        bpm_range=(138.0, 145.0),
        relaxed_bpm_range=(136.0, 146.0),
    ),
    GenreProfile(
        family="bass",
        name="trap",
        aliases=("trap", "edm trap"),
        bpm_range=(130.0, 150.0),
        relaxed_bpm_range=(120.0, 155.0),
    ),
    GenreProfile(
        family="breaks",
        name="breakbeat",
        aliases=("breakbeat", "breaks", "nu skool breaks"),
        bpm_range=(125.0, 140.0),
        relaxed_bpm_range=(122.0, 145.0),
    ),
    GenreProfile(
        family="electro",
        name="electro",
        aliases=("electro", "electro house"),
        bpm_range=(125.0, 138.0),
        relaxed_bpm_range=(122.0, 142.0),
    ),
    GenreProfile(
        family="hard-dance",
        name="hardstyle",
        aliases=("hardstyle", "rawstyle", "hardbass", "hard bass"),
        bpm_range=(145.0, 155.0),
        relaxed_bpm_range=(140.0, 160.0),
    ),
    GenreProfile(
        family="hiphop",
        name="hip hop",
        aliases=("hip hop", "hip-hop", "rap"),
        bpm_range=(85.0, 102.0),
        relaxed_bpm_range=(78.0, 110.0),
    ),
    GenreProfile(
        family="disco",
        name="disco",
        aliases=("disco", "nu disco", "nudisco"),
        bpm_range=(110.0, 124.0),
        relaxed_bpm_range=(106.0, 128.0),
    ),
)

JARGON_EXPANSIONS: dict[str, str] = {
    "dnb": "drum and bass",
    "drum n bass": "drum and bass",
    "ukg": "uk garage",
    "prog house": "progressive house",
    "afro": "afro house",
    "afrohouse": "afro house",
    "rollers": "liquid drum and bass",
    "neuro": "neurofunk",
    "hardbass": "hardstyle",
    "hard bass": "hardstyle",
    "hardgroove": "hard techno",
    "trop house": "tropical house",
    "2-step": "uk garage",
    "2 step": "uk garage",
}

START_LOW_HINTS = ("start mellow", "start chill", "warm", "warmup", "opening", "open with")
PEAK_HINTS = ("peak", "build", "climax", "lift", "drive")
COOLDOWN_HINTS = ("cool down", "cooldown", "wind down", "close mellow", "comedown")


def _target_track_count(duration_minutes: int) -> int:
    return max(6, min(24, duration_minutes // 5))


def _normalize_text(text: str) -> str:
    normalized = text.lower().replace("&", " and ")
    normalized = re.sub(r"[^a-z0-9]+", " ", normalized)
    return re.sub(r"\s+", " ", normalized).strip()


def _contains_phrase(normalized_text: str, normalized_phrase: str) -> bool:
    if not normalized_text or not normalized_phrase:
        return False
    return f" {normalized_phrase} " in f" {normalized_text} "


def _matched_jargon_expansions(description: str) -> list[tuple[str, str]]:
    normalized = _normalize_text(description)
    matches: list[tuple[str, str]] = []
    for term, expansion in JARGON_EXPANSIONS.items():
        if _contains_phrase(normalized, _normalize_text(term)):
            matches.append((term, expansion))
    return matches


def _expanded_description(description: str) -> str:
    normalized = _normalize_text(description)
    matches = _matched_jargon_expansions(description)
    if not matches:
        return normalized

    expansions = " ".join(_normalize_text(expansion) for _, expansion in matches)
    return f"{normalized} {expansions}".strip()


def _profile_alias_tokens(profile: GenreProfile) -> tuple[str, ...]:
    tokens = {_normalize_text(profile.name)}
    tokens.update(_normalize_text(alias) for alias in profile.aliases if alias)
    return tuple(token for token in tokens if token)


def _profile_match_score(description: str, profile: GenreProfile) -> float:
    score = 0.0
    for alias in _profile_alias_tokens(profile):
        if not _contains_phrase(description, alias):
            continue
        words = max(1, len(alias.split()))
        score += 1.0 + min(0.6, 0.1 * words)
        if alias == _normalize_text(profile.name):
            score += 0.2
    return score


def _infer_genre_profiles(description: str) -> list[GenreProfile]:
    expanded = _expanded_description(description)
    scored: list[tuple[float, int, GenreProfile]] = []
    for profile in GENRE_PROFILES:
        score = _profile_match_score(expanded, profile)
        if score <= 0:
            continue
        specificity = max((len(alias.split()) for alias in _profile_alias_tokens(profile)), default=1)
        scored.append((score, specificity, profile))

    if not scored:
        return []

    scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
    strongest = scored[0][0]
    threshold = max(1.0, strongest * 0.45)

    picked: list[GenreProfile] = []
    seen_names: set[str] = set()
    for score, _, profile in scored:
        if score < threshold:
            continue
        if profile.name in seen_names:
            continue
        seen_names.add(profile.name)
        picked.append(profile)
        if len(picked) >= 6:
            break
    return picked


def _infer_genre_profile(description: str) -> GenreProfile | None:
    profiles = _infer_genre_profiles(description)
    return profiles[0] if profiles else None


def _profiles_bpm_ranges(profiles: list[GenreProfile], relaxed: bool = False) -> list[tuple[float, float]]:
    if not profiles:
        return []

    ranges: list[tuple[float, float]] = []
    seen: set[tuple[float, float]] = set()
    for profile in profiles:
        bpm_range = profile.relaxed_bpm_range if relaxed else profile.bpm_range
        if bpm_range in seen:
            continue
        seen.add(bpm_range)
        ranges.append(bpm_range)
    return ranges


def _bpm_matches_range(bpm: float, bpm_range: tuple[float, float]) -> bool:
    low, high = bpm_range
    if bpm <= 0:
        return False

    checks = [bpm, bpm * 2.0, bpm / 2.0]
    return any(low <= candidate <= high for candidate in checks if candidate > 0)


def _genre_prefilter_tracks(all_tracks: list, profiles: list[GenreProfile]) -> list:
    if not profiles:
        return all_tracks

    strict_ranges = _profiles_bpm_ranges(profiles)
    strict = [
        track for track in all_tracks
        if any(_bpm_matches_range(track.bpm, bpm_range) for bpm_range in strict_ranges)
    ]
    if len(strict) >= 10:
        return strict

    relaxed_ranges = _profiles_bpm_ranges(profiles, relaxed=True)
    relaxed = [
        track for track in all_tracks
        if any(_bpm_matches_range(track.bpm, bpm_range) for bpm_range in relaxed_ranges)
    ]
    if len(relaxed) >= 10:
        return relaxed

    return strict or relaxed or all_tracks


def _context_relevance_score(track, profiles: list[GenreProfile]) -> float:
    score = 0.0

    if track.bpm > 0:
        score += 0.2
    if track.musical_key:
        score += 0.2
    if track.duration > 90:
        score += 0.1

    if profiles and track.bpm > 0:
        profile_scores: list[float] = []
        for profile in profiles:
            center = (profile.bpm_range[0] + profile.bpm_range[1]) / 2.0
            distance = min(
                abs(track.bpm - center),
                abs(track.bpm * 2.0 - center),
                abs((track.bpm / 2.0) - center),
            )
            profile_scores.append(max(0.0, 1.0 - (distance / 25.0)))
        score += max(profile_scores, default=0.0)

    score += max(0.0, 1.0 - abs(track.energy_level - 0.62))
    return score


def _prefilter_tracks(description: str, all_tracks: list, profiles: list[GenreProfile] | None = None) -> list:
    """Pre-filter tracks to fit in LLM context while preserving genre intent."""
    genre_profiles = profiles if profiles is not None else _infer_genre_profiles(description)
    candidates = _genre_prefilter_tracks(all_tracks, genre_profiles)

    # Keep enough context for the LLM while biasing toward musically useful metadata.
    max_context_tracks = 260
    if len(candidates) > max_context_tracks:
        candidates = sorted(
            candidates,
            key=lambda track: _context_relevance_score(track, genre_profiles),
            reverse=True,
        )[:max_context_tracks]
    return candidates


def _description_prefers_low_start(description: str) -> bool:
    desc = _normalize_text(description)
    return any(hint in desc for hint in START_LOW_HINTS)


def _description_has_peak_arc(description: str) -> bool:
    desc = _normalize_text(description)
    return any(hint in desc for hint in PEAK_HINTS)


def _description_has_cooldown(description: str) -> bool:
    desc = _normalize_text(description)
    return any(hint in desc for hint in COOLDOWN_HINTS)


def _expected_energy_direction(position: int, total: int, description: str) -> str:
    if total <= 2:
        return "any"

    pct = position / float(max(total - 1, 1))
    has_peak = _description_has_peak_arc(description)
    has_cooldown = _description_has_cooldown(description)

    if has_peak and has_cooldown:
        if pct < 0.65:
            return "up"
        return "down"
    if has_peak:
        return "up" if pct < 0.75 else "any"
    if has_cooldown:
        return "down" if pct > 0.5 else "any"
    return "any"


def _seed_track_for_ordering(tracks: list, description: str, profiles: list[GenreProfile]):
    if not tracks:
        return None

    sorted_by_match = sorted(
        tracks,
        key=lambda track: _context_relevance_score(track, profiles),
        reverse=True,
    )
    shortlist = sorted_by_match[: max(8, min(40, len(sorted_by_match)))]

    if _description_prefers_low_start(description):
        return min(shortlist, key=lambda track: track.energy_level)

    return min(shortlist, key=lambda track: abs(track.energy_level - 0.45))


def _order_tracks_for_flow(tracks: list, description: str, profiles: list[GenreProfile]) -> list:
    if len(tracks) <= 2:
        return tracks

    seed = _seed_track_for_ordering(tracks, description, profiles)
    if seed is None:
        return tracks

    ordered = [seed]
    remaining = [track for track in tracks if track.id != seed.id]

    while remaining:
        previous = ordered[-1]
        position = len(ordered)
        direction = _expected_energy_direction(position, len(tracks), description)

        def candidate_score(candidate) -> float:
            score = transition_score(previous, candidate, expected_direction=direction)
            if any(_bpm_matches_range(candidate.bpm, profile.bpm_range) for profile in profiles):
                score += 0.12
            if candidate.artist and previous.artist and candidate.artist != previous.artist:
                score += 0.03
            return score

        next_track = max(remaining, key=candidate_score)
        ordered.append(next_track)
        remaining = [track for track in remaining if track.id != next_track.id]

    return ordered


def _fallback_ids(tracks: list, target_count: int, description: str, profiles: list[GenreProfile]) -> list[int]:
    if not tracks:
        return []
    ranked = sorted(
        tracks,
        key=lambda track: _context_relevance_score(track, profiles),
        reverse=True,
    )[: max(target_count * 2, target_count)]
    ordered = _order_tracks_for_flow(ranked, description, profiles)
    return [track.id for track in ordered[:target_count]]


def plan_set(description: str, name: str, duration: int = 60) -> SetPlan | None:
    """Use the LLM to plan a DJ set from the library."""
    settings = get_settings()
    if not settings.openai_api_key:
        console.print("[red]Error:[/red] OPENAI_API_KEY not set in .env")
        return None

    all_tracks = get_all_tracks()
    if not all_tracks:
        console.print("[red]Error:[/red] No tracks in library. Run 'deepcrate scan' first.")
        return None

    genre_profiles = _infer_genre_profiles(description)
    tracks = _prefilter_tracks(description, all_tracks, profiles=genre_profiles)
    track_lookup = {track.id: track for track in all_tracks if track.id is not None}

    target_count = _target_track_count(duration)
    fallback_ids = _fallback_ids(tracks, target_count=target_count, description=description, profiles=genre_profiles)

    request_description = description
    if genre_profiles:
        names: list[str] = []
        for profile in genre_profiles:
            if profile.name not in names:
                names.append(profile.name)
        low_bpm = min(profile.bpm_range[0] for profile in genre_profiles)
        high_bpm = max(profile.bpm_range[1] for profile in genre_profiles)
        jargon_pairs = _matched_jargon_expansions(description)
        jargon_line = ""
        if jargon_pairs:
            rendered = ", ".join(f"{source}->{target}" for source, target in jargon_pairs)
            jargon_line = f"\nResolved DJ shorthand: {rendered}."
        request_description += (
            f"\n\nGenre guidance: this request maps to {', '.join(names[:4])}. "
            f"Target BPM should usually sit around {low_bpm:.0f}-{high_bpm:.0f}."
            "\nInterpret jargon and subgenre shorthand as intentional user language, not noise."
            f"{jargon_line}"
        )

    library_data = [
        {
            "id": t.id, "artist": t.artist, "title": t.title,
            "bpm": t.bpm, "musical_key": t.musical_key,
            "energy_level": t.energy_level, "duration": t.duration,
        }
        for t in tracks
    ]

    library_context = build_library_context(library_data)
    user_prompt = build_plan_prompt(request_description, duration, library_context)

    console.print(f"[dim]Sending {len(tracks)} tracks to {settings.openai_model}...[/dim]")

    client = OpenAI(api_key=settings.openai_api_key)
    result: dict = {}
    summary = ""
    try:
        response = client.chat.completions.create(
            model=settings.openai_model,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.7,
            max_tokens=2000,
        )
        raw = response.choices[0].message.content
        if raw:
            cleaned = raw.strip()
            if cleaned.startswith("```"):
                cleaned = cleaned.split("\n", 1)[1]
                if cleaned.endswith("```"):
                    cleaned = cleaned[:-3]
            result = json.loads(cleaned)
            summary = str(result.get("summary", "")).strip()
    except Exception as exc:
        console.print(f"[yellow]Planner warning:[/yellow] {exc}. Falling back to deterministic flow ordering.")

    # Delete existing set with same name
    delete_set(name)

    # Create set
    set_plan = create_set(SetPlan(name=name, description=description, target_duration=duration))
    if set_plan.id is None:
        console.print("[red]Error:[/red] Failed to create set in database")
        return None

    raw_entries = result.get("tracks", []) if isinstance(result, dict) else []
    selected_ids: list[int] = []
    if isinstance(raw_entries, list):
        for entry in raw_entries:
            if not isinstance(entry, dict):
                continue
            track_id = entry.get("track_id")
            if not isinstance(track_id, int):
                continue
            if track_id in track_lookup and track_id not in selected_ids:
                selected_ids.append(track_id)

    if not selected_ids:
        selected_ids = fallback_ids

    if len(selected_ids) < target_count:
        for track_id in fallback_ids:
            if track_id not in selected_ids:
                selected_ids.append(track_id)
            if len(selected_ids) >= target_count:
                break

    ordered_candidates = [track_lookup[track_id] for track_id in selected_ids if track_id in track_lookup]
    ordered_candidates = _order_tracks_for_flow(ordered_candidates, description, genre_profiles)

    # Build set tracks with transition scores
    set_tracks = []
    prev_track = None
    for track in ordered_candidates[:target_count]:
        if track.id is None:
            continue

        score = 0.0
        if prev_track is not None:
            score = transition_score(prev_track, track)

        set_tracks.append(SetTrack(
            set_id=set_plan.id,
            track_id=track.id,
            position=len(set_tracks) + 1,
            transition_score=score,
        ))
        prev_track = track

    set_set_tracks(set_plan.id, set_tracks)

    if summary:
        console.print(f"\n[italic]{summary}[/italic]")

    return set_plan
