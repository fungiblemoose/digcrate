"""Pydantic models for DeepCrate domain objects."""

from pathlib import Path

from pydantic import BaseModel


class Track(BaseModel):
    id: int | None = None
    file_path: str
    file_hash: str
    title: str = ""
    artist: str = ""
    bpm: float = 0.0
    musical_key: str = ""  # Camelot notation e.g. "8A"
    energy_level: float = 0.0  # 0.0 - 1.0
    energy_confidence: float = 1.0  # quality confidence for energy estimate
    duration: float = 0.0  # seconds
    preview_start: float = 0.0  # seconds
    needs_review: bool = False
    review_notes: str = ""
    has_overrides: bool = False
    analysis_version: int = 3

    @property
    def display_name(self) -> str:
        if self.artist and self.title:
            return f"{self.artist} - {self.title}"
        if self.title:
            return self.title
        return Path(self.file_path).stem if self.file_path else "Unknown"

    @property
    def review_reasons(self) -> list[str]:
        if not self.review_notes:
            return []
        return [part.strip() for part in self.review_notes.split("|") if part.strip()]


class SetPlan(BaseModel):
    id: int | None = None
    name: str
    description: str = ""
    target_duration: int = 60  # minutes


class SetTrack(BaseModel):
    set_id: int
    track_id: int
    position: int
    transition_score: float = 0.0  # 0.0 - 1.0


class Gap(BaseModel):
    id: int | None = None
    set_id: int
    position: int  # position in set where gap exists
    suggested_bpm: float = 0.0
    suggested_key: str = ""
    suggested_energy: float = 0.0
    suggested_vibe: str = ""


class TransitionInfo(BaseModel):
    """Info about a transition between two tracks in a set."""
    from_track: Track
    to_track: Track
    score: float
    issues: list[str] = []
