import AVFoundation
import Foundation

@MainActor
final class AudioPreviewPlayer: ObservableObject {
    @Published private(set) var activeTrackID: Int?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var previewDuration: TimeInterval = 0
    @Published var lastError: String?

    private var player: AVAudioPlayer?
    private var previewEndTime: TimeInterval = 0
    private var previewStartTime: TimeInterval = 0
    private var timer: Timer?

    func togglePreview(for track: Track, clipLength: TimeInterval = 30) {
        if activeTrackID == track.id, isPlaying {
            stopPreview(clearSelection: false)
            return
        }
        startPreview(for: track, clipLength: clipLength)
    }

    func startPreview(for track: Track, clipLength: TimeInterval = 30) {
        stopPreview(clearSelection: true)
        lastError = nil

        let path = track.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            lastError = "Track has no local file path. Re-scan to refresh metadata."
            return
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Track file is missing on disk: \(url.lastPathComponent)"
            return
        }

        do {
            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            nextPlayer.prepareToPlay()

            player = nextPlayer
            activeTrackID = track.id
            previewStartTime = min(
                max(track.previewStart, 0),
                max(nextPlayer.duration - max(5, clipLength), 0)
            )
            previewEndTime = min(nextPlayer.duration, previewStartTime + max(5, clipLength))
            previewDuration = max(previewEndTime - previewStartTime, 0)
            nextPlayer.currentTime = previewStartTime
            currentTime = 0

            guard nextPlayer.play() else {
                lastError = "Unable to start preview playback."
                return
            }

            isPlaying = true
            startTimer()
        } catch {
            lastError = "Preview failed: \(error.localizedDescription)"
            stopPreview(clearSelection: true)
        }
    }

    func stopPreview(clearSelection: Bool = false) {
        timer?.invalidate()
        timer = nil

        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0

        if clearSelection {
            activeTrackID = nil
            previewDuration = 0
            previewStartTime = 0
            previewEndTime = 0
        }
    }

    var progress: Double {
        guard previewDuration > 0 else { return 0 }
        return min(max(currentTime / previewDuration, 0), 1)
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let clamped = min(max(fraction, 0), 1)
        let target = previewStartTime + clamped * previewDuration
        player.currentTime = min(target, previewEndTime)
        currentTime = max(player.currentTime - previewStartTime, 0)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPlaybackState()
            }
        }
    }

    private func refreshPlaybackState() {
        guard let player else {
            stopPreview(clearSelection: true)
            return
        }

        currentTime = min(max(player.currentTime - previewStartTime, 0), previewDuration)

        if player.currentTime >= previewEndTime || !player.isPlaying {
            stopPreview(clearSelection: false)
            currentTime = previewDuration
        }
    }
}

func formatTimecode(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite && seconds >= 0 else { return "0:00" }
    let whole = Int(seconds.rounded(.down))
    let minutes = whole / 60
    let secs = whole % 60
    return String(format: "%d:%02d", minutes, secs)
}
