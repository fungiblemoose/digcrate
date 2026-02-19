"""PySide6 desktop GUI for DeepCrate."""

from __future__ import annotations

import platform
import sys
from functools import partial
from pathlib import Path
from typing import Callable

from PySide6.QtCore import Qt, QThreadPool, QTimer, QUrl
from PySide6.QtGui import QAction, QDesktopServices, QKeySequence
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFrame,
    QFormLayout,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QProgressBar,
    QListWidget,
    QListWidgetItem,
    QSpinBox,
    QSplitter,
    QStackedWidget,
    QStyleFactory,
    QTableWidget,
    QTableWidgetItem,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from deepcrate.gui import services
from deepcrate.gui.worker import Worker


class LibraryTab(QWidget):
    def __init__(self, thread_pool: QThreadPool) -> None:
        super().__init__()
        self.thread_pool = thread_pool
        self.search_results = []
        self.preview_seconds = 30

        root = QVBoxLayout(self)

        scan_box = QGroupBox("Library Scan")
        scan_layout = QGridLayout(scan_box)
        self.directory_input = QLineEdit()
        self.scan_btn = QPushButton("Scan")
        browse_btn = QPushButton("Browse")
        self.scan_status = QLabel("Pick a folder, then scan.")
        self.scan_progress = QProgressBar()
        self.scan_progress.setMinimum(0)
        self.scan_progress.setValue(0)

        browse_btn.clicked.connect(self._pick_directory)
        self.scan_btn.clicked.connect(self._start_scan)

        scan_layout.addWidget(QLabel("Folder"), 0, 0)
        scan_layout.addWidget(self.directory_input, 0, 1)
        scan_layout.addWidget(browse_btn, 0, 2)
        scan_layout.addWidget(self.scan_btn, 0, 3)
        scan_layout.addWidget(self.scan_progress, 1, 0, 1, 4)
        scan_layout.addWidget(self.scan_status, 2, 0, 1, 4)

        stats_box = QGroupBox("Library Stats")
        stats_layout = QVBoxLayout(stats_box)
        self.stats_label = QLabel()
        refresh_stats_btn = QPushButton("Refresh Stats")
        refresh_stats_btn.clicked.connect(self._refresh_stats)
        stats_layout.addWidget(self.stats_label)
        stats_layout.addWidget(refresh_stats_btn)

        search_box = QGroupBox("Track Search")
        search_layout = QVBoxLayout(search_box)

        filters = QHBoxLayout()
        self.bpm_input = QLineEdit()
        self.bpm_input.setPlaceholderText("BPM (e.g. 170-175)")
        self.key_input = QLineEdit()
        self.key_input.setPlaceholderText("Key (e.g. 8A)")
        self.energy_input = QLineEdit()
        self.energy_input.setPlaceholderText("Energy (e.g. 0.6-0.8)")
        self.query_input = QLineEdit()
        self.query_input.setPlaceholderText("Artist/title query")
        search_btn = QPushButton("Search")
        search_btn.clicked.connect(self._search)

        filters.addWidget(self.bpm_input)
        filters.addWidget(self.key_input)
        filters.addWidget(self.energy_input)
        filters.addWidget(self.query_input)
        filters.addWidget(search_btn)

        self.search_table = QTableWidget(0, 8)
        self.search_table.setHorizontalHeaderLabels(["Artist", "Title", "BPM", "Key", "Energy", "Status", "Dupes", "Path"])
        self.search_table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.search_table.setSelectionMode(QAbstractItemView.SingleSelection)
        header = self.search_table.horizontalHeader()
        for column in range(7):
            header.setSectionResizeMode(column, QHeaderView.ResizeToContents)
        header.setSectionResizeMode(7, QHeaderView.Stretch)

        self.audio_output = QAudioOutput(self)
        self.audio_output.setVolume(1.0)
        self.media_player = QMediaPlayer(self)
        self.media_player.setAudioOutput(self.audio_output)
        self.media_player.errorOccurred.connect(self._on_preview_error)

        self.preview_timer = QTimer(self)
        self.preview_timer.setSingleShot(True)
        self.preview_timer.timeout.connect(self._stop_preview)

        preview_controls = QHBoxLayout()
        self.play_preview_btn = QPushButton("Play Preview")
        self.stop_preview_btn = QPushButton("Stop")
        self.stop_preview_btn.setEnabled(False)
        self.preview_status = QLabel("Select a track, then click Play Preview.")

        self.play_preview_btn.clicked.connect(self._play_preview)
        self.stop_preview_btn.clicked.connect(self._stop_preview)

        preview_controls.addWidget(self.play_preview_btn)
        preview_controls.addWidget(self.stop_preview_btn)
        preview_controls.addWidget(self.preview_status)

        search_layout.addLayout(filters)
        search_layout.addWidget(self.search_table)
        search_layout.addLayout(preview_controls)

        root.addWidget(scan_box)
        root.addWidget(stats_box)
        root.addWidget(search_box)

        self._refresh_stats()
        self._search()

    def _pick_directory(self) -> None:
        directory = QFileDialog.getExistingDirectory(self, "Select music folder")
        if directory:
            self.directory_input.setText(directory)

    def set_scan_directory(self, directory: str) -> None:
        self.directory_input.setText(directory)

    def run_scan(self) -> None:
        self._start_scan()

    def _start_scan(self) -> None:
        directory = self.directory_input.text().strip()
        if not directory:
            self._error("Please choose a folder to scan.")
            return

        self.scan_btn.setEnabled(False)
        self.scan_progress.setValue(0)
        self.scan_status.setText("Scanning...")

        worker = Worker(services.scan_directory, directory)
        worker.signals.progress.connect(self._on_scan_progress)
        worker.signals.finished.connect(self._on_scan_done)
        worker.signals.error.connect(self._on_error)
        self.thread_pool.start(worker)

    def _on_scan_progress(self, data: dict) -> None:
        current = int(data.get("current", 0))
        total = int(data.get("total", 0))
        name = str(data.get("name", ""))
        if total > 0:
            self.scan_progress.setMaximum(total)
            self.scan_progress.setValue(current)
        self.scan_status.setText(f"Analyzing {name} ({current}/{total})")

    def _on_scan_done(self, result: dict) -> None:
        self.scan_btn.setEnabled(True)
        max_value = self.scan_progress.maximum() if self.scan_progress.maximum() > 0 else 1
        self.scan_progress.setRange(0, max_value)
        self.scan_progress.setValue(max_value)
        self.scan_status.setText(
            f"Done. Found {result['total']} files | Analyzed {result['analyzed']} | "
            f"Cached {result['skipped']} | Errors {result['errors']}"
        )
        self._refresh_stats()
        self._search()

    def _search(self) -> None:
        try:
            tracks = services.search_library(
                self.bpm_input.text(),
                self.key_input.text(),
                self.energy_input.text(),
                self.query_input.text(),
            )
        except Exception as exc:
            self._error(str(exc))
            return

        self.search_results = tracks
        hash_counts = services.duplicate_hash_counts()

        self.search_table.setRowCount(len(tracks))
        for row, track in enumerate(tracks):
            self.search_table.setItem(row, 0, QTableWidgetItem(track.artist))
            self.search_table.setItem(row, 1, QTableWidgetItem(track.title))
            self.search_table.setItem(row, 2, QTableWidgetItem(f"{track.bpm:.0f}"))
            self.search_table.setItem(row, 3, QTableWidgetItem(track.musical_key))
            self.search_table.setItem(row, 4, QTableWidgetItem(f"{track.energy_level:.2f}"))
            status = "Online" if Path(track.file_path).exists() else "Missing"
            self.search_table.setItem(row, 5, QTableWidgetItem(status))
            duplicates = hash_counts.get(track.file_hash, 0)
            dupe_text = f"x{duplicates}" if duplicates > 1 else ""
            self.search_table.setItem(row, 6, QTableWidgetItem(dupe_text))
            self.search_table.setItem(row, 7, QTableWidgetItem(track.file_path))

        if tracks:
            self.preview_status.setText(f"{len(tracks)} tracks loaded.")
        else:
            self.preview_status.setText("No tracks match this filter.")
            self._stop_preview(update_status=False)

    def _refresh_stats(self) -> None:
        stats = services.compute_library_stats()
        if stats["total"] == 0:
            self.stats_label.setText("No tracks in library yet.")
            return

        key_text = ", ".join(k for k, _ in stats["top_keys"][:3]) or "-"
        self.stats_label.setText(
            f"{stats['total']} tracks  |  BPM {stats['bpm_min']:.0f}-{stats['bpm_max']:.0f}  |  "
            f"Energy {stats['energy_avg']:.2f} avg  |  Duration {stats['duration_minutes']} min  |  "
            f"Top keys {key_text}"
        )

    def _on_error(self, trace: str) -> None:
        self.scan_btn.setEnabled(True)
        self.scan_progress.setRange(0, 1)
        self.scan_progress.setValue(0)
        self.scan_status.setText("Scan failed")
        self._error(trace)

    def _selected_track(self):
        row = self.search_table.currentRow()
        if row < 0 or row >= len(self.search_results):
            return None
        return self.search_results[row]

    def _play_preview(self) -> None:
        track = self._selected_track()
        if track is None:
            self.preview_status.setText("Select a track row first.")
            return

        file_path = Path(track.file_path)
        if not file_path.exists():
            self.preview_status.setText(f"Missing file: {file_path.name}")
            return

        self._stop_preview(update_status=False)

        self.media_player.setSource(QUrl.fromLocalFile(str(file_path)))
        self.media_player.setPosition(int(max(track.preview_start, 0) * 1000))
        self.media_player.play()

        self.preview_timer.start(self.preview_seconds * 1000)
        self.play_preview_btn.setEnabled(False)
        self.stop_preview_btn.setEnabled(True)
        self.preview_status.setText(f"Previewing: {track.artist} - {track.title}")

    def _stop_preview(self, update_status: bool = True) -> None:
        if self.preview_timer.isActive():
            self.preview_timer.stop()
        self.media_player.stop()
        self.play_preview_btn.setEnabled(True)
        self.stop_preview_btn.setEnabled(False)
        if update_status:
            self.preview_status.setText("Preview stopped.")

    def _on_preview_error(self, _error) -> None:
        self._stop_preview(update_status=False)
        detail = self.media_player.errorString().strip() or "Unknown media playback error."
        self.preview_status.setText(f"Preview error: {detail}")

    def _error(self, message: str) -> None:
        QMessageBox.critical(self, "DeepCrate", message)


class PlanTab(QWidget):
    def __init__(self, thread_pool: QThreadPool, on_set_changed: Callable[[], None]) -> None:
        super().__init__()
        self.thread_pool = thread_pool
        self.on_set_changed = on_set_changed

        root = QVBoxLayout(self)

        form_box = QGroupBox("Plan Set")
        form = QFormLayout(form_box)

        self.name_input = QLineEdit()
        self.duration_input = QSpinBox()
        self.duration_input.setRange(10, 600)
        self.duration_input.setValue(60)
        self.description_input = QTextEdit()
        self.description_input.setPlaceholderText("Example: 60 min liquid DnB set, start mellow, peak at 40 min")

        self.plan_btn = QPushButton("Generate Set")
        self.plan_btn.clicked.connect(self._plan_set)
        self.status_label = QLabel("")

        form.addRow("Set Name", self.name_input)
        form.addRow("Duration (min)", self.duration_input)
        form.addRow("Description", self.description_input)
        form.addRow(self.plan_btn)
        form.addRow(self.status_label)

        self.preview_table = QTableWidget(0, 7)
        self.preview_table.setHorizontalHeaderLabels(["#", "Artist", "Title", "BPM", "Key", "Energy", "Transition"])
        self.preview_table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)

        root.addWidget(form_box)
        root.addWidget(self.preview_table)

    def _plan_set(self) -> None:
        name = self.name_input.text().strip()
        description = self.description_input.toPlainText().strip()
        duration = self.duration_input.value()

        if not name or not description:
            QMessageBox.warning(self, "DeepCrate", "Name and description are required.")
            return

        self.plan_btn.setEnabled(False)
        self.status_label.setText("Planning with OpenAI...")

        worker = Worker(services.create_set_plan, description, name, duration)
        worker.signals.finished.connect(partial(self._on_plan_done, name))
        worker.signals.error.connect(self._on_plan_error)
        self.thread_pool.start(worker)

    def _on_plan_done(self, name: str, _result: object) -> None:
        self.plan_btn.setEnabled(True)
        self.status_label.setText(f"Set '{name}' created.")
        self._load_preview(name)
        self.on_set_changed()

    def _on_plan_error(self, trace: str) -> None:
        self.plan_btn.setEnabled(True)
        self.status_label.setText("Failed to plan set.")
        QMessageBox.critical(self, "DeepCrate", trace)

    def _load_preview(self, name: str) -> None:
        rows = services.get_set_tracks_detailed(name)
        self.preview_table.setRowCount(len(rows))

        for row, (set_track, track, transition) in enumerate(rows):
            self.preview_table.setItem(row, 0, QTableWidgetItem(str(set_track.position)))
            self.preview_table.setItem(row, 1, QTableWidgetItem(track.artist))
            self.preview_table.setItem(row, 2, QTableWidgetItem(track.title))
            self.preview_table.setItem(row, 3, QTableWidgetItem(f"{track.bpm:.0f}"))
            self.preview_table.setItem(row, 4, QTableWidgetItem(track.musical_key))
            self.preview_table.setItem(row, 5, QTableWidgetItem(f"{track.energy_level:.2f}"))
            self.preview_table.setItem(row, 6, QTableWidgetItem(transition))


class SetsTab(QWidget):
    def __init__(self) -> None:
        super().__init__()

        root = QVBoxLayout(self)
        top = QHBoxLayout()
        self.set_picker = QComboBox()
        refresh_btn = QPushButton("Refresh")
        load_btn = QPushButton("Load")

        refresh_btn.clicked.connect(self.refresh_sets)
        load_btn.clicked.connect(self._load)

        top.addWidget(QLabel("Set"))
        top.addWidget(self.set_picker)
        top.addWidget(load_btn)
        top.addWidget(refresh_btn)

        self.table = QTableWidget(0, 7)
        self.table.setHorizontalHeaderLabels(["#", "Artist", "Title", "BPM", "Key", "Energy", "Transition"])
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)

        root.addLayout(top)
        root.addWidget(self.table)

    def refresh_sets(self) -> None:
        current = self.set_picker.currentText()
        self.set_picker.clear()
        for set_plan in services.list_sets():
            self.set_picker.addItem(set_plan.name)
        if current:
            index = self.set_picker.findText(current)
            if index >= 0:
                self.set_picker.setCurrentIndex(index)

    def _load(self) -> None:
        name = self.set_picker.currentText().strip()
        rows = services.get_set_tracks_detailed(name)
        self.table.setRowCount(len(rows))

        for row, (set_track, track, transition) in enumerate(rows):
            self.table.setItem(row, 0, QTableWidgetItem(str(set_track.position)))
            self.table.setItem(row, 1, QTableWidgetItem(track.artist))
            self.table.setItem(row, 2, QTableWidgetItem(track.title))
            self.table.setItem(row, 3, QTableWidgetItem(f"{track.bpm:.0f}"))
            self.table.setItem(row, 4, QTableWidgetItem(track.musical_key))
            self.table.setItem(row, 5, QTableWidgetItem(f"{track.energy_level:.2f}"))
            self.table.setItem(row, 6, QTableWidgetItem(transition))


class GapsTab(QWidget):
    def __init__(self) -> None:
        super().__init__()

        root = QVBoxLayout(self)
        top = QHBoxLayout()
        self.set_picker = QComboBox()
        self.analyze_btn = QPushButton("Analyze Gaps")
        self.analyze_btn.clicked.connect(self._analyze)

        top.addWidget(QLabel("Set"))
        top.addWidget(self.set_picker)
        top.addWidget(self.analyze_btn)

        self.table = QTableWidget(0, 7)
        self.table.setHorizontalHeaderLabels(["Gap", "From", "To", "Score", "Issues", "Need BPM", "Need Key"])
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)

        root.addLayout(top)
        root.addWidget(self.table)

    def refresh_sets(self) -> None:
        current = self.set_picker.currentText()
        self.set_picker.clear()
        for set_plan in services.list_sets():
            self.set_picker.addItem(set_plan.name)
        if current:
            index = self.set_picker.findText(current)
            if index >= 0:
                self.set_picker.setCurrentIndex(index)

    def _analyze(self) -> None:
        name = self.set_picker.currentText().strip()
        if not name:
            QMessageBox.warning(self, "DeepCrate", "Choose a set first.")
            return

        try:
            weak, gaps = services.analyze_set_gaps(name)
        except Exception as exc:
            QMessageBox.critical(self, "DeepCrate", str(exc))
            return

        self.table.setRowCount(len(weak))
        for row, transition in enumerate(weak):
            gap_meta = gaps[row] if row < len(gaps) else None
            self.table.setItem(row, 0, QTableWidgetItem(str(row + 1)))
            self.table.setItem(row, 1, QTableWidgetItem(transition.from_track.display_name))
            self.table.setItem(row, 2, QTableWidgetItem(transition.to_track.display_name))
            self.table.setItem(row, 3, QTableWidgetItem(f"{transition.score:.0%}"))
            self.table.setItem(row, 4, QTableWidgetItem("; ".join(transition.issues)))
            self.table.setItem(row, 5, QTableWidgetItem(f"{gap_meta.suggested_bpm:.0f}" if gap_meta else ""))
            self.table.setItem(row, 6, QTableWidgetItem(gap_meta.suggested_key if gap_meta else ""))


class DiscoverTab(QWidget):
    def __init__(self, thread_pool: QThreadPool) -> None:
        super().__init__()
        self.thread_pool = thread_pool

        root = QVBoxLayout(self)

        controls = QGridLayout()
        self.set_picker = QComboBox()
        self.gap_picker = QComboBox()
        self.genre_input = QLineEdit()
        self.genre_input.setPlaceholderText("Optional genre")
        self.limit_input = QSpinBox()
        self.limit_input.setRange(1, 50)
        self.limit_input.setValue(10)
        refresh_gaps_btn = QPushButton("Refresh Gaps")
        self.discover_btn = QPushButton("Discover")
        self.status_label = QLabel("")

        refresh_gaps_btn.clicked.connect(self._load_gaps)
        self.discover_btn.clicked.connect(self._discover)

        controls.addWidget(QLabel("Set"), 0, 0)
        controls.addWidget(self.set_picker, 0, 1)
        controls.addWidget(refresh_gaps_btn, 0, 2)
        controls.addWidget(QLabel("Gap"), 1, 0)
        controls.addWidget(self.gap_picker, 1, 1)
        controls.addWidget(QLabel("Genre"), 2, 0)
        controls.addWidget(self.genre_input, 2, 1)
        controls.addWidget(QLabel("Limit"), 2, 2)
        controls.addWidget(self.limit_input, 2, 3)
        controls.addWidget(self.discover_btn, 3, 0, 1, 4)
        controls.addWidget(self.status_label, 4, 0, 1, 4)

        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(["Artist", "Track", "BPM", "Energy", "Spotify"])
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        self.table.cellDoubleClicked.connect(self._open_link)

        root.addLayout(controls)
        root.addWidget(self.table)

    def refresh_sets(self) -> None:
        current = self.set_picker.currentText()
        self.set_picker.clear()
        for set_plan in services.list_sets():
            self.set_picker.addItem(set_plan.name)
        if current:
            index = self.set_picker.findText(current)
            if index >= 0:
                self.set_picker.setCurrentIndex(index)
        self._load_gaps()

    def _load_gaps(self) -> None:
        name = self.set_picker.currentText().strip()
        self.gap_picker.clear()
        if not name:
            return

        try:
            _, gaps = services.analyze_set_gaps(name)
        except Exception:
            return

        for gap in gaps:
            self.gap_picker.addItem(
                f"{gap.position}: ~{gap.suggested_bpm:.0f} BPM {gap.suggested_key} {gap.suggested_energy:.2f}",
                gap.position,
            )

    def _discover(self) -> None:
        set_name = self.set_picker.currentText().strip()
        gap_number = self.gap_picker.currentData()
        genre = self.genre_input.text().strip()
        limit = self.limit_input.value()

        if not set_name or gap_number is None:
            QMessageBox.warning(self, "DeepCrate", "Choose a set and gap first.")
            return

        self.discover_btn.setEnabled(False)
        self.status_label.setText("Searching Spotify...")

        worker = Worker(services.discover_for_gap, set_name, int(gap_number), genre, limit)
        worker.signals.finished.connect(self._on_discover_done)
        worker.signals.error.connect(self._on_discover_error)
        self.thread_pool.start(worker)

    def _on_discover_done(self, results: list[dict]) -> None:
        self.discover_btn.setEnabled(True)
        self.status_label.setText(f"Found {len(results)} suggestions")
        self.table.setRowCount(len(results))

        for row, result in enumerate(results):
            self.table.setItem(row, 0, QTableWidgetItem(result.get("artist", "")))
            self.table.setItem(row, 1, QTableWidgetItem(result.get("name", "")))
            self.table.setItem(row, 2, QTableWidgetItem(f"{result.get('bpm', 0):.0f}"))
            self.table.setItem(row, 3, QTableWidgetItem(f"{result.get('energy', 0):.2f}"))
            self.table.setItem(row, 4, QTableWidgetItem(result.get("spotify_url", "")))

    def _on_discover_error(self, trace: str) -> None:
        self.discover_btn.setEnabled(True)
        self.status_label.setText("Discover failed")
        QMessageBox.critical(self, "DeepCrate", trace)

    def _open_link(self, row: int, column: int) -> None:
        if column != 4:
            return
        item = self.table.item(row, column)
        if not item:
            return
        url = item.text().strip()
        if url:
            QDesktopServices.openUrl(QUrl(url))


class ExportTab(QWidget):
    def __init__(self) -> None:
        super().__init__()

        root = QVBoxLayout(self)

        form = QFormLayout()
        self.set_picker = QComboBox()
        self.format_picker = QComboBox()
        self.format_picker.addItems(["m3u", "rekordbox"])

        output_row = QHBoxLayout()
        self.output_input = QLineEdit()
        browse_btn = QPushButton("Browse")
        browse_btn.clicked.connect(self._pick_output)
        output_row.addWidget(self.output_input)
        output_row.addWidget(browse_btn)

        export_btn = QPushButton("Export")
        export_btn.clicked.connect(self._export)

        self.status_label = QLabel("")

        form.addRow("Set", self.set_picker)
        form.addRow("Format", self.format_picker)
        form.addRow("Output", output_row)
        form.addRow(export_btn)
        form.addRow(self.status_label)

        root.addLayout(form)

    def refresh_sets(self) -> None:
        current = self.set_picker.currentText()
        self.set_picker.clear()
        for set_plan in services.list_sets():
            self.set_picker.addItem(set_plan.name)
        if current:
            index = self.set_picker.findText(current)
            if index >= 0:
                self.set_picker.setCurrentIndex(index)

    def _pick_output(self) -> None:
        fmt = self.format_picker.currentText()
        suffix = "m3u" if fmt == "m3u" else "xml"
        selected, _ = QFileDialog.getSaveFileName(
            self,
            "Save export",
            filter=f"*.{suffix}",
        )
        if selected:
            self.output_input.setText(selected)

    def _export(self) -> None:
        name = self.set_picker.currentText().strip()
        fmt = self.format_picker.currentText()
        output_path = self.output_input.text().strip() or None

        if not name:
            QMessageBox.warning(self, "DeepCrate", "Choose a set first.")
            return

        try:
            path = services.export_set(name, fmt, output_path)
        except Exception as exc:
            QMessageBox.critical(self, "DeepCrate", str(exc))
            return

        self.status_label.setText(f"Exported: {path}")


class PreferencesDialog(QDialog):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Preferences")
        self.setModal(True)
        self.resize(560, 260)

        root = QVBoxLayout(self)
        form = QFormLayout()

        current = services.load_preferences()

        self.openai_key = QLineEdit(current.get("OPENAI_API_KEY", ""))
        self.openai_key.setEchoMode(QLineEdit.Password)
        self.openai_key.setPlaceholderText("sk-...")

        self.openai_model = QLineEdit(current.get("OPENAI_MODEL", "gpt-4o-mini"))

        self.spotify_client_id = QLineEdit(current.get("SPOTIFY_CLIENT_ID", ""))
        self.spotify_client_secret = QLineEdit(current.get("SPOTIFY_CLIENT_SECRET", ""))
        self.spotify_client_secret.setEchoMode(QLineEdit.Password)

        self.database_path = QLineEdit(current.get("DATABASE_PATH", "data/deepcrate.sqlite"))

        form.addRow("OpenAI API Key", self.openai_key)
        form.addRow("OpenAI Model", self.openai_model)
        form.addRow("Spotify Client ID", self.spotify_client_id)
        form.addRow("Spotify Client Secret", self.spotify_client_secret)
        form.addRow("Database Path", self.database_path)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)

        root.addLayout(form)
        root.addWidget(buttons)

    def _save(self) -> None:
        updates = {
            "OPENAI_API_KEY": self.openai_key.text(),
            "OPENAI_MODEL": self.openai_model.text() or "gpt-4o-mini",
            "SPOTIFY_CLIENT_ID": self.spotify_client_id.text(),
            "SPOTIFY_CLIENT_SECRET": self.spotify_client_secret.text(),
            "DATABASE_PATH": self.database_path.text() or "data/deepcrate.sqlite",
        }
        path = services.save_preferences(updates)
        QMessageBox.information(self, "DeepCrate", f"Saved preferences to {path}")
        self.accept()


def _apply_platform_look(app: QApplication) -> None:
    if platform.system() == "Darwin":
        available_styles = {name.lower(): name for name in QStyleFactory.keys()}
        if "macintosh" in available_styles:
            app.setStyle(available_styles["macintosh"])

    app.setStyleSheet(
        """
        QWidget {
            font-size: 13px;
        }
        QGroupBox {
            font-weight: 600;
            border: 1px solid palette(midlight);
            border-radius: 10px;
            margin-top: 10px;
            padding: 8px 10px 10px 10px;
        }
        QGroupBox::title {
            subcontrol-origin: margin;
            left: 10px;
            padding: 0 4px;
        }
        QPushButton {
            padding: 6px 10px;
            border-radius: 7px;
        }
        QLineEdit, QTextEdit, QComboBox, QSpinBox, QTableWidget {
            border-radius: 7px;
            padding: 4px;
        }
        QListWidget#sidebar {
            border: none;
            background: palette(window);
            padding-top: 10px;
            padding-left: 8px;
            padding-right: 8px;
        }
        QListWidget#sidebar::item {
            padding: 8px 10px;
            margin: 2px 0px;
            border-radius: 7px;
        }
        QListWidget#sidebar::item:selected {
            background: palette(highlight);
            color: palette(highlighted-text);
        }
        """
    )


class DeepCrateWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("DeepCrate")
        self.resize(1320, 860)

        self.thread_pool = QThreadPool.globalInstance()

        self.library_tab = LibraryTab(self.thread_pool)
        self.plan_tab = PlanTab(self.thread_pool, self.refresh_set_tabs)
        self.sets_tab = SetsTab()
        self.gaps_tab = GapsTab()
        self.discover_tab = DiscoverTab(self.thread_pool)
        self.export_tab = ExportTab()

        container = QSplitter()
        container.setChildrenCollapsible(False)

        self.sidebar = QListWidget()
        self.sidebar.setObjectName("sidebar")
        self.sidebar.setSelectionMode(QAbstractItemView.SingleSelection)
        self.sidebar.setFrameShape(QFrame.NoFrame)
        self.sidebar.setFocusPolicy(Qt.FocusPolicy.NoFocus)

        self.stack = QStackedWidget()
        pages = [
            ("Library", self.library_tab),
            ("Plan Set", self.plan_tab),
            ("Set Browser", self.sets_tab),
            ("Gap Analysis", self.gaps_tab),
            ("Discover", self.discover_tab),
            ("Export", self.export_tab),
        ]

        for title, widget in pages:
            self.sidebar.addItem(QListWidgetItem(title))
            self.stack.addWidget(widget)

        self.sidebar.currentRowChanged.connect(self.stack.setCurrentIndex)
        self.sidebar.setCurrentRow(0)

        container.addWidget(self.sidebar)
        container.addWidget(self.stack)
        container.setSizes([220, 1100])

        self.setCentralWidget(container)
        self._build_menu_bar()

        self.refresh_set_tabs()

    def refresh_set_tabs(self) -> None:
        self.sets_tab.refresh_sets()
        self.gaps_tab.refresh_sets()
        self.discover_tab.refresh_sets()
        self.export_tab.refresh_sets()

    def _build_menu_bar(self) -> None:
        menu = self.menuBar()

        file_menu = menu.addMenu("&File")
        open_folder_action = QAction("Open Music Folder…", self)
        open_folder_action.setShortcut(QKeySequence.Open)
        open_folder_action.triggered.connect(self._open_music_folder)
        file_menu.addAction(open_folder_action)

        scan_action = QAction("Scan Current Folder", self)
        scan_action.setShortcut(QKeySequence.Refresh)
        scan_action.triggered.connect(self._scan_current_folder)
        file_menu.addAction(scan_action)

        file_menu.addSeparator()
        quit_action = QAction("Quit", self)
        quit_action.setShortcut(QKeySequence.Quit)
        quit_action.setMenuRole(QAction.QuitRole)
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)

        edit_menu = menu.addMenu("&Edit")
        prefs_action = QAction("Preferences…", self)
        prefs_action.setShortcut(QKeySequence.Preferences)
        prefs_action.setMenuRole(QAction.PreferencesRole)
        prefs_action.triggered.connect(self._open_preferences)
        edit_menu.addAction(prefs_action)

        help_menu = menu.addMenu("&Help")
        about_action = QAction("About DeepCrate", self)
        about_action.setMenuRole(QAction.AboutRole)
        about_action.triggered.connect(self._about_dialog)
        help_menu.addAction(about_action)

    def _open_music_folder(self) -> None:
        directory = QFileDialog.getExistingDirectory(self, "Select music folder")
        if not directory:
            return
        self.sidebar.setCurrentRow(0)
        self.library_tab.set_scan_directory(directory)

    def _scan_current_folder(self) -> None:
        self.sidebar.setCurrentRow(0)
        self.library_tab.run_scan()

    def _open_preferences(self) -> None:
        dialog = PreferencesDialog(self)
        dialog.exec()

    def _about_dialog(self) -> None:
        QMessageBox.about(
            self,
            "About DeepCrate",
            "DeepCrate\nAI-powered DJ set builder\n\nLocal desktop GUI using PySide6.",
        )


def run() -> None:
    app = QApplication(sys.argv)
    app.setApplicationName("DeepCrate")
    _apply_platform_look(app)

    window = DeepCrateWindow()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    run()
