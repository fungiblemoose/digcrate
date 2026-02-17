"""JSON bridge for DeepCrateMac Swift app."""

from __future__ import annotations

import argparse
import io
import json
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


def _ok(payload: dict) -> None:
    print(json.dumps(payload))


def _err(message: str, exit_code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(exit_code)


def _track_payload(track) -> dict:
    artist = (track.artist or "").strip() or "Unknown Artist"
    title = (track.title or "").strip()
    if not title:
        title = Path(track.file_path).stem if track.file_path else "Unknown Track"

    return {
        "id": track.id,
        "artist": artist,
        "title": title,
        "bpm": track.bpm,
        "musical_key": track.musical_key,
        "energy_level": track.energy_level,
        "energy_confidence": track.energy_confidence,
        "duration": track.duration,
        "file_path": track.file_path,
        "preview_start": track.preview_start,
        "needs_review": track.needs_review,
        "review_notes": track.review_notes,
        "has_overrides": track.has_overrides,
    }


def cmd_scan(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import scan_directory

    result = scan_directory(args.directory)
    _ok(result)


def cmd_reanalyze(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import reanalyze_track

    track = reanalyze_track(args.track_id)
    _ok({"track": _track_payload(track)})


def cmd_override_track(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import clear_track_override, save_track_override

    if args.clear:
        track = clear_track_override(args.track_id)
        _ok({"track": _track_payload(track)})
        return

    track = save_track_override(
        track_id=args.track_id,
        bpm=args.bpm,
        musical_key=args.key,
        energy_level=args.energy,
    )
    _ok({"track": _track_payload(track)})


def cmd_tracks(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import search_library

    tracks = search_library(args.bpm, args.key, args.energy, args.query, needs_review=args.needs_review)

    _ok(
        {
            "tracks": [_track_payload(t) for t in tracks]
        }
    )


def cmd_delete_tracks(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import delete_tracks

    try:
        raw_ids = json.loads(args.track_ids)
    except Exception as exc:
        _err(f"Invalid --track-ids payload: {exc}")

    if not isinstance(raw_ids, list):
        _err("Invalid --track-ids payload: expected a JSON array.")

    normalized_ids: list[int] = []
    try:
        for item in raw_ids:
            normalized_ids.append(int(item))
    except Exception as exc:
        _err(f"Invalid --track-ids payload: {exc}")

    result = delete_tracks(normalized_ids)
    _ok(result)


def cmd_plan(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import create_set_plan

    captured_out = io.StringIO()
    captured_err = io.StringIO()
    try:
        with redirect_stdout(captured_out), redirect_stderr(captured_err):
            create_set_plan(args.description, args.name, args.duration)
    except Exception as exc:
        details = captured_out.getvalue() + "\n" + captured_err.getvalue()
        _err(f"Plan failed: {exc}\n{details}")

    _ok({"ok": True})


def cmd_sets(_args: argparse.Namespace) -> None:
    from deepcrate.gui.services import list_sets

    sets = list_sets()
    _ok(
        {
            "sets": [
                {
                    "id": s.id,
                    "name": s.name,
                    "description": s.description,
                    "target_duration": s.target_duration,
                }
                for s in sets
                if s.id is not None
            ]
        }
    )


def cmd_set_tracks(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import get_set_tracks_detailed

    rows = get_set_tracks_detailed(args.name)

    def artist_for(track) -> str:
        artist = (track.artist or "").strip()
        return artist if artist else "Unknown Artist"

    def title_for(track) -> str:
        title = (track.title or "").strip()
        if title:
            return title
        return Path(track.file_path).stem if track.file_path else "Unknown Track"

    _ok(
        {
            "rows": [
                {
                    "position": st.position,
                    "artist": artist_for(t),
                    "title": title_for(t),
                    "bpm": t.bpm,
                    "musical_key": t.musical_key,
                    "energy_level": t.energy_level,
                    "transition": transition,
                }
                for st, t, transition in rows
            ]
        }
    )


def cmd_gaps(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import analyze_set_gaps

    weak, gaps = analyze_set_gaps(args.name)
    payload = []
    for i, w in enumerate(weak):
        gap = gaps[i] if i < len(gaps) else None
        payload.append(
            {
                "from": w.from_track.display_name,
                "to": w.to_track.display_name,
                "score": w.score,
                "issues": w.issues,
                "suggested_bpm": gap.suggested_bpm if gap else 0.0,
                "suggested_key": gap.suggested_key if gap else "",
            }
        )

    _ok({"gaps": payload})


def cmd_discover(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import discover_for_gap

    try:
        rows = discover_for_gap(args.name, args.gap, args.genre, args.limit)
    except Exception as exc:
        _err(str(exc))

    _ok({"results": rows})


def cmd_export(args: argparse.Namespace) -> None:
    from deepcrate.gui.services import export_set

    path = export_set(args.name, args.format, args.output)
    _ok({"path": path})


def cmd_save_set(args: argparse.Namespace) -> None:
    from deepcrate.db import create_set, delete_set, get_track_by_id, set_set_tracks
    from deepcrate.models import SetPlan, SetTrack
    from deepcrate.planning.scoring import transition_score

    try:
        track_ids = [int(x) for x in json.loads(args.track_ids)]
    except Exception as exc:
        _err(f"Invalid --track-ids payload: {exc}")

    delete_set(args.name)
    set_plan = create_set(
        SetPlan(name=args.name, description=args.description, target_duration=args.duration)
    )
    if set_plan.id is None:
        _err("Failed to create set")

    rows = []
    previous = None
    for idx, track_id in enumerate(track_ids, start=1):
        track = get_track_by_id(track_id)
        if track is None:
            continue

        score = 0.0
        if previous is not None:
            score = transition_score(previous, track)

        rows.append(
            SetTrack(
                set_id=set_plan.id,
                track_id=track_id,
                position=idx,
                transition_score=score,
            )
        )
        previous = track

    set_set_tracks(set_plan.id, rows)
    _ok({"ok": True, "count": len(rows)})


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="DeepCrateMac bridge")
    sub = p.add_subparsers(dest="cmd", required=True)

    scan = sub.add_parser("scan")
    scan.add_argument("--directory", required=True)
    scan.set_defaults(func=cmd_scan)

    reanalyze = sub.add_parser("reanalyze")
    reanalyze.add_argument("--track-id", required=True, type=int)
    reanalyze.set_defaults(func=cmd_reanalyze)

    override = sub.add_parser("override-track")
    override.add_argument("--track-id", required=True, type=int)
    override.add_argument("--bpm", type=float, default=None)
    override.add_argument("--key", default=None)
    override.add_argument("--energy", type=float, default=None)
    override.add_argument("--clear", action="store_true")
    override.set_defaults(func=cmd_override_track)

    tracks = sub.add_parser("tracks")
    tracks.add_argument("--query", default=None)
    tracks.add_argument("--bpm", default=None)
    tracks.add_argument("--key", default=None)
    tracks.add_argument("--energy", default=None)
    tracks.add_argument("--needs-review", action="store_true")
    tracks.set_defaults(func=cmd_tracks)

    delete_tracks_cmd = sub.add_parser("delete-tracks")
    delete_tracks_cmd.add_argument("--track-ids", required=True)
    delete_tracks_cmd.set_defaults(func=cmd_delete_tracks)

    plan = sub.add_parser("plan")
    plan.add_argument("--description", required=True)
    plan.add_argument("--name", required=True)
    plan.add_argument("--duration", type=int, required=True)
    plan.set_defaults(func=cmd_plan)

    sets = sub.add_parser("sets")
    sets.set_defaults(func=cmd_sets)

    set_tracks = sub.add_parser("set-tracks")
    set_tracks.add_argument("--name", required=True)
    set_tracks.set_defaults(func=cmd_set_tracks)

    gaps = sub.add_parser("gaps")
    gaps.add_argument("--name", required=True)
    gaps.set_defaults(func=cmd_gaps)

    discover = sub.add_parser("discover")
    discover.add_argument("--name", required=True)
    discover.add_argument("--gap", type=int, required=True)
    discover.add_argument("--genre", default=None)
    discover.add_argument("--limit", type=int, default=10)
    discover.set_defaults(func=cmd_discover)

    export = sub.add_parser("export")
    export.add_argument("--name", required=True)
    export.add_argument("--format", required=True)
    export.add_argument("--output", default=None)
    export.set_defaults(func=cmd_export)

    save_set = sub.add_parser("save-set")
    save_set.add_argument("--name", required=True)
    save_set.add_argument("--description", required=True)
    save_set.add_argument("--duration", required=True, type=int)
    save_set.add_argument("--track-ids", required=True)
    save_set.set_defaults(func=cmd_save_set)

    return p


def main() -> None:
    args = parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
