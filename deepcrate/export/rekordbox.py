"""Rekordbox XML playlist export."""

import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

from deepcrate.db import get_set_by_name, get_set_tracks, get_track_by_id
from deepcrate.models import Track

# Camelot to Rekordbox key ID mapping
CAMELOT_TO_REKORDBOX_KEY = {
    "1A": 0, "1B": 1, "2A": 2, "2B": 3, "3A": 4, "3B": 5,
    "4A": 6, "4B": 7, "5A": 8, "5B": 9, "6A": 10, "6B": 11,
    "7A": 12, "7B": 13, "8A": 14, "8B": 15, "9A": 16, "9B": 17,
    "10A": 18, "10B": 19, "11A": 20, "11B": 21, "12A": 22, "12B": 23,
}


def export_rekordbox(set_name: str, output_path: str | None = None) -> str | None:
    """Export a set as a Rekordbox-compatible XML file.

    Returns the output file path on success, None on failure.
    """
    set_plan = get_set_by_name(set_name)
    if not set_plan or set_plan.id is None:
        return None

    set_tracks = get_set_tracks(set_plan.id)
    if not set_tracks:
        return None

    tracks: list[Track] = []
    for st in set_tracks:
        track = get_track_by_id(st.track_id)
        if track:
            tracks.append(track)

    if not output_path:
        safe_name = set_name.replace(" ", "_").replace("/", "-")
        output_path = f"{safe_name}.xml"
    output_file = Path(output_path).expanduser()
    output_file.parent.mkdir(parents=True, exist_ok=True)

    # Build Rekordbox XML
    root = ET.Element("DJ_PLAYLISTS", Version="1.0.0")
    product = ET.SubElement(root, "PRODUCT", Name="DeepCrate", Version="0.1.0")
    collection = ET.SubElement(root, "COLLECTION", Entries=str(len(tracks)))

    for i, track in enumerate(tracks):
        file_path = Path(track.file_path)
        location = "file://localhost" + quote(str(file_path.resolve()))
        key_id = CAMELOT_TO_REKORDBOX_KEY.get(track.musical_key.upper(), 0)

        ET.SubElement(collection, "TRACK", {
            "TrackID": str(i + 1),
            "Name": track.title or file_path.stem,
            "Artist": track.artist,
            "TotalTime": str(int(track.duration)),
            "AverageBpm": f"{track.bpm:.2f}",
            "Tonality": track.musical_key,
            "Location": location,
        })

    # Playlist node
    playlists = ET.SubElement(root, "PLAYLISTS")
    playlist_root = ET.SubElement(playlists, "NODE", Type="0", Name="ROOT", Count="1")
    playlist_node = ET.SubElement(playlist_root, "NODE", {
        "Type": "1",
        "Name": set_name,
        "KeyType": "0",
        "Entries": str(len(tracks)),
    })

    for i in range(len(tracks)):
        ET.SubElement(playlist_node, "TRACK", Key=str(i + 1))

    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    tree.write(str(output_file), encoding="utf-8", xml_declaration=True)
    return str(output_file)
