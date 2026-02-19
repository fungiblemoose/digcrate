"""DeepCrate CLI — AI-powered DJ set builder."""

from pathlib import Path
from typing import Optional

import typer
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, TaskProgressColumn
from rich.table import Table

app = typer.Typer(
    name="deepcrate",
    help="AI-powered DJ set builder. Analyze tracks, plan sets, export playlists.",
    no_args_is_help=True,
)
console = Console()


@app.command()
def scan(
    directory: str = typer.Argument(..., help="Directory to scan for audio files"),
):
    """Analyze all audio tracks in a directory."""
    from deepcrate.analysis.scanner import find_audio_files
    from deepcrate.analysis.analyzer import analyze_track, file_hash
    from deepcrate.db import get_track_by_path, upsert_track

    dir_path = Path(directory).expanduser().resolve()
    if not dir_path.is_dir():
        console.print(f"[red]Error:[/red] Not a directory: {dir_path}")
        raise typer.Exit(1)

    console.print(f"Scanning [bold]{dir_path}[/bold] for audio files...")
    files = find_audio_files(dir_path)

    if not files:
        console.print("[yellow]No audio files found.[/yellow]")
        raise typer.Exit(0)

    console.print(f"Found [bold]{len(files)}[/bold] audio files.")

    analyzed = 0
    skipped = 0
    errors = 0

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
        console=console,
    ) as progress:
        task = progress.add_task("Analyzing tracks", total=len(files))

        for audio_file in files:
            progress.update(task, description=f"[dim]{audio_file.name}[/dim]")

            # Skip if already analyzed with same hash
            existing = get_track_by_path(str(audio_file))
            current_hash = file_hash(audio_file)
            if existing and existing.file_hash == current_hash and (existing.title or "").strip():
                skipped += 1
                progress.advance(task)
                continue

            try:
                track = analyze_track(audio_file)
                upsert_track(track)
                analyzed += 1
            except Exception as e:
                console.print(f"\n[red]Error analyzing {audio_file.name}:[/red] {e}")
                errors += 1

            progress.advance(task)

    console.print()
    console.print(f"[green]Done![/green] Analyzed: {analyzed} | Cached: {skipped} | Errors: {errors}")


@app.command()
def stats():
    """Show library overview statistics."""
    from deepcrate.db import get_all_tracks

    tracks = get_all_tracks()
    if not tracks:
        console.print("[yellow]No tracks in library. Run 'deepcrate scan' first.[/yellow]")
        raise typer.Exit(0)

    bpms = [t.bpm for t in tracks if t.bpm > 0]
    energies = [t.energy_level for t in tracks if t.energy_level > 0]
    keys = {}
    for t in tracks:
        if t.musical_key:
            keys[t.musical_key] = keys.get(t.musical_key, 0) + 1

    table = Table(title="Library Stats")
    table.add_column("Metric", style="bold")
    table.add_column("Value")

    table.add_row("Total tracks", str(len(tracks)))
    if bpms:
        table.add_row("BPM range", f"{min(bpms):.0f} - {max(bpms):.0f}")
        table.add_row("Average BPM", f"{sum(bpms)/len(bpms):.1f}")
    if energies:
        table.add_row("Energy range", f"{min(energies):.2f} - {max(energies):.2f}")
        table.add_row("Average energy", f"{sum(energies)/len(energies):.2f}")

    total_duration = sum(t.duration for t in tracks)
    hours = int(total_duration // 3600)
    minutes = int((total_duration % 3600) // 60)
    table.add_row("Total duration", f"{hours}h {minutes}m")

    console.print(table)

    if keys:
        console.print()
        sorted_keys = sorted(keys.items(), key=lambda x: -x[1])[:10]
        key_table = Table(title="Top Keys")
        key_table.add_column("Key")
        key_table.add_column("Count")
        for k, count in sorted_keys:
            key_table.add_row(k, str(count))
        console.print(key_table)


@app.command()
def search(
    bpm: Optional[str] = typer.Option(None, help="BPM range, e.g. '170-175'"),
    key: Optional[str] = typer.Option(None, help="Camelot key, e.g. '8A'"),
    energy: Optional[str] = typer.Option(None, help="Energy range, e.g. '0.5-0.8'"),
    query: Optional[str] = typer.Option(None, "-q", help="Search artist/title"),
):
    """Search your track library."""
    from deepcrate.db import search_tracks as db_search

    bpm_min, bpm_max = None, None
    if bpm:
        parts = bpm.split("-")
        bpm_min = float(parts[0])
        bpm_max = float(parts[1]) if len(parts) > 1 else bpm_min + 5

    energy_min, energy_max = None, None
    if energy:
        parts = energy.split("-")
        energy_min = float(parts[0])
        energy_max = float(parts[1]) if len(parts) > 1 else energy_min + 0.1

    tracks = db_search(
        bpm_min=bpm_min, bpm_max=bpm_max,
        key=key, energy_min=energy_min, energy_max=energy_max,
        query=query,
    )

    if not tracks:
        console.print("[yellow]No tracks found matching criteria.[/yellow]")
        raise typer.Exit(0)

    table = Table(title=f"Search Results ({len(tracks)} tracks)")
    table.add_column("#", style="dim")
    table.add_column("Artist")
    table.add_column("Title")
    table.add_column("BPM", justify="right")
    table.add_column("Key")
    table.add_column("Energy", justify="right")

    for i, t in enumerate(tracks, 1):
        table.add_row(
            str(i), t.artist, t.title,
            f"{t.bpm:.0f}", t.musical_key, f"{t.energy_level:.2f}",
        )

    console.print(table)


@app.command()
def plan(
    description: str = typer.Argument(..., help="Describe your set in plain English"),
    name: str = typer.Option(..., "--name", "-n", help="Name for this set"),
    duration: int = typer.Option(60, "--duration", "-d", help="Target duration in minutes"),
):
    """Plan a DJ set using AI."""
    from deepcrate.planning.planner import plan_set

    console.print(f"Planning set [bold]{name}[/bold]: {description}")
    result = plan_set(description, name, duration)

    if result:
        console.print(f"\n[green]Set '{name}' created![/green] Use 'deepcrate show \"{name}\"' to view it.")
    else:
        console.print("[red]Failed to create set.[/red]")
        raise typer.Exit(1)


@app.command()
def show(
    name: str = typer.Argument(..., help="Name of the set to display"),
):
    """View a planned set with transition scores."""
    from deepcrate.db import get_set_by_name, get_set_tracks, get_track_by_id
    from deepcrate.planning.scoring import describe_transition

    set_plan = get_set_by_name(name)
    if not set_plan or set_plan.id is None:
        console.print(f"[red]Error:[/red] Set '{name}' not found.")
        raise typer.Exit(1)

    set_tracks = get_set_tracks(set_plan.id)
    if not set_tracks:
        console.print(f"[yellow]Set '{name}' has no tracks.[/yellow]")
        raise typer.Exit(0)

    console.print(f"\n[bold]{set_plan.name}[/bold]")
    if set_plan.description:
        console.print(f"[italic]{set_plan.description}[/italic]")
    console.print(f"Target: {set_plan.target_duration} min\n")

    table = Table()
    table.add_column("#", style="dim", width=3)
    table.add_column("Artist")
    table.add_column("Title")
    table.add_column("BPM", justify="right")
    table.add_column("Key")
    table.add_column("Energy", justify="right")
    table.add_column("Transition", justify="center")

    total_duration = 0.0
    for st in set_tracks:
        track = get_track_by_id(st.track_id)
        if not track:
            continue

        total_duration += track.duration

        trans = ""
        if st.position > 1:
            label = describe_transition(st.transition_score)
            color = "green" if st.transition_score >= 0.7 else "yellow" if st.transition_score >= 0.5 else "red"
            trans = f"[{color}]{label} ({st.transition_score:.0%})[/{color}]"

        table.add_row(
            str(st.position), track.artist, track.title,
            f"{track.bpm:.0f}", track.musical_key, f"{track.energy_level:.2f}",
            trans,
        )

    console.print(table)

    mins = int(total_duration // 60)
    console.print(f"\nEstimated duration: {mins} min")


@app.command()
def gaps(
    name: str = typer.Argument(..., help="Name of the set to analyze"),
):
    """Show weak transitions and suggest what's missing."""
    from deepcrate.db import get_set_by_name
    from deepcrate.planning.gaps import analyze_gaps

    set_plan = get_set_by_name(name)
    if not set_plan or set_plan.id is None:
        console.print(f"[red]Error:[/red] Set '{name}' not found.")
        raise typer.Exit(1)

    weak = analyze_gaps(set_plan.id)

    if not weak:
        console.print(f"[green]No weak transitions in '{name}'![/green]")
        return

    console.print(f"\n[bold]Weak Transitions in '{name}'[/bold]\n")

    for i, trans in enumerate(weak, 1):
        console.print(f"[red]Gap {i}:[/red] {trans.from_track.display_name} → {trans.to_track.display_name}")
        console.print(f"  Score: {trans.score:.0%}")
        for issue in trans.issues:
            console.print(f"  - {issue}")

        avg_bpm = (trans.from_track.bpm + trans.to_track.bpm) / 2
        console.print(f"  [dim]Needs: ~{avg_bpm:.0f} BPM bridge track[/dim]")
        console.print()


@app.command()
def discover(
    gap: int = typer.Option(..., "--gap", "-g", help="Gap number to fill (from 'deepcrate gaps')"),
    name: str = typer.Option(..., "--name", "-n", help="Set name to search gaps from"),
    genre: Optional[str] = typer.Option(None, help="Genre filter for Spotify search"),
    limit: int = typer.Option(10, help="Max results"),
):
    """Find tracks on Spotify to fill a gap in your set."""
    from deepcrate.db import get_gaps, get_set_by_name
    from deepcrate.discovery.spotify import search_tracks as spotify_search

    set_plan = get_set_by_name(name)
    if not set_plan or set_plan.id is None:
        console.print(f"[red]Error:[/red] Set '{name}' not found.")
        raise typer.Exit(1)

    gap_list = get_gaps(set_plan.id)
    if not gap_list:
        console.print("[yellow]No gaps found. Run 'deepcrate gaps' first.[/yellow]")
        raise typer.Exit(0)

    if gap < 1 or gap > len(gap_list):
        console.print(f"[red]Error:[/red] Gap number must be between 1 and {len(gap_list)}")
        raise typer.Exit(1)

    target = gap_list[gap - 1]
    console.print(f"Searching Spotify for: ~{target.suggested_bpm:.0f} BPM, key {target.suggested_key}, energy {target.suggested_energy:.2f}")

    results = spotify_search(
        bpm=target.suggested_bpm,
        energy=target.suggested_energy,
        genre=genre,
        limit=limit,
    )

    if not results:
        console.print("[yellow]No matching tracks found on Spotify.[/yellow]")
        return

    table = Table(title="Spotify Suggestions")
    table.add_column("#", style="dim")
    table.add_column("Artist")
    table.add_column("Track")
    table.add_column("BPM", justify="right")
    table.add_column("Energy", justify="right")
    table.add_column("Link")

    for i, r in enumerate(results, 1):
        table.add_row(
            str(i), r["artist"], r["name"],
            f"{r['bpm']:.0f}", f"{r['energy']:.2f}",
            f"[link={r['spotify_url']}]Open[/link]" if r["spotify_url"] else "",
        )

    console.print(table)


@app.command()
def export(
    name: str = typer.Argument(..., help="Name of the set to export"),
    format: str = typer.Option("m3u", "--format", "-f", help="Export format: m3u or rekordbox"),
    output: Optional[str] = typer.Option(None, "--output", "-o", help="Output file path"),
):
    """Export a set as a playlist file."""
    fmt = format.lower()

    if fmt == "m3u":
        from deepcrate.export.m3u import export_m3u
        path = export_m3u(name, output)
    elif fmt in ("rekordbox", "xml"):
        from deepcrate.export.rekordbox import export_rekordbox
        path = export_rekordbox(name, output)
    else:
        console.print(f"[red]Error:[/red] Unknown format '{format}'. Use 'm3u' or 'rekordbox'.")
        raise typer.Exit(1)

    if path:
        console.print(f"[green]Exported:[/green] {path}")
    else:
        console.print(f"[red]Error:[/red] Set '{name}' not found or has no tracks.")
        raise typer.Exit(1)


if __name__ == "__main__":
    app()
