import Accelerate
import AVFoundation
import CryptoKit
import Foundation

let deepCrateAnalysisVersion = 3

struct AudioScanProgress: Sendable {
    let current: Int
    let total: Int
    let name: String
}

struct LibraryScanSummary: Sendable {
    let directory: String
    let total: Int
    let analyzed: Int
    let skipped: Int
    let errors: Int

    var statusText: String {
        "Found \(total) files | analyzed \(analyzed) | cached \(skipped) | errors \(errors)"
    }
}

struct TrackOverrideRecord: Sendable {
    let bpm: Double?
    let key: String?
    let energy: Double?
}

struct StoredTrackRecord: Sendable {
    let id: Int
    let filePath: String
    let fileHash: String
    let title: String
    let artist: String
    let bpm: Double
    let key: String
    let energy: Double
    let energyConfidence: Double
    let duration: Double
    let previewStart: Double
    let needsReview: Bool
    let reviewNotes: String
    let hasOverrides: Bool
    let analysisVersion: Int

    var asTrack: Track {
        Track(
            id: id,
            artist: artist,
            title: title,
            bpm: bpm,
            key: key,
            energy: energy,
            energyConfidence: energyConfidence,
            duration: duration,
            filePath: filePath,
            previewStart: previewStart,
            needsReview: needsReview,
            reviewNotes: reviewNotes,
            hasOverrides: hasOverrides
        )
    }
}

struct AnalyzedTrackRecord: Sendable {
    let existingID: Int?
    let filePath: String
    let fileHash: String
    let title: String
    let artist: String
    let bpm: Double
    let key: String
    let energy: Double
    let energyConfidence: Double
    let duration: Double
    let previewStart: Double
    let needsReview: Bool
    let reviewNotes: String
    let hasOverrides: Bool
    let analysisVersion: Int
}

enum LibraryAnalysisError: LocalizedError {
    case invalidDirectory(String)
    case trackNotFound(Int)
    case missingAudioFile(String)
    case unreadableAudio(String)

    var errorDescription: String? {
        switch self {
        case .invalidDirectory(let value):
            return "Not a directory: \(value)"
        case .trackNotFound(let trackID):
            return "Track not found: \(trackID)"
        case .missingAudioFile(let path):
            return "Track file is missing: \(path)"
        case .unreadableAudio(let path):
            return "Unable to read audio file: \(path)"
        }
    }
}

struct LibraryAnalysisService: Sendable {
    static let shared = LibraryAnalysisService()

    private let supportedExtensions: Set<String> = [
        "mp3", "flac", "wav", "aiff", "aif", "m4a", "ogg", "opus", "wma",
    ]

    func scan(
        directory: String,
        progress: (@Sendable (AudioScanProgress) async -> Void)? = nil
    ) async throws -> LibraryScanSummary {
        let expandedPath = (directory as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: expandedPath).standardizedFileURL
        guard isDirectory(root) else {
            throw LibraryAnalysisError.invalidDirectory(root.path)
        }

        let files = try audioFiles(in: root)
        var analyzed = 0
        var skipped = 0
        var errors = 0

        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            await progress?(AudioScanProgress(current: index + 1, total: files.count, name: url.lastPathComponent))

            do {
                let currentHash = try fileHash(for: url)
                let existing = try LocalDatabase.shared.storedTrackRecord(filePath: url.path)
                let hasTitle = !(existing?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if let existing,
                   existing.fileHash == currentHash,
                   hasTitle,
                   existing.analysisVersion >= deepCrateAnalysisVersion {
                    skipped += 1
                    continue
                }

                let override = try LocalDatabase.shared.trackOverride(filePath: url.path)
                let analyzedTrack = try await analyze(
                    url: url,
                    fileHash: currentHash,
                    existingID: existing?.id,
                    override: override
                )
                _ = try LocalDatabase.shared.upsertAnalyzedTrack(analyzedTrack)
                analyzed += 1
            } catch {
                errors += 1
            }
        }

        return LibraryScanSummary(
            directory: root.path,
            total: files.count,
            analyzed: analyzed,
            skipped: skipped,
            errors: errors
        )
    }

    func reanalyze(trackID: Int) async throws -> Track {
        guard let existing = try LocalDatabase.shared.storedTrackRecord(trackID: trackID) else {
            throw LibraryAnalysisError.trackNotFound(trackID)
        }

        let url = URL(fileURLWithPath: existing.filePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryAnalysisError.missingAudioFile(url.path)
        }

        let override = try LocalDatabase.shared.trackOverride(filePath: url.path)
        let analyzedTrack = try await analyze(
            url: url,
            fileHash: try fileHash(for: url),
            existingID: existing.id,
            override: override
        )
        return try LocalDatabase.shared.upsertAnalyzedTrack(analyzedTrack)
    }

    private func analyze(
        url: URL,
        fileHash: String,
        existingID: Int?,
        override: TrackOverrideRecord?
    ) async throws -> AnalyzedTrackRecord {
        let metadata = await readMetadata(url: url)
        let filenameMetadata = parseFilenameMetadata(url: url)
        let duration = await readDuration(url: url)
        let analysisWindow = try loadAnalysisWindow(url: url, duration: duration)

        guard !analysisWindow.samples.isEmpty else {
            throw LibraryAnalysisError.unreadableAudio(url.path)
        }

        let metrics = computeShortTimeMetrics(
            samples: analysisWindow.samples,
            sampleRate: analysisWindow.sampleRate
        )
        let metadataBPM = parseBPMTag(metadata["bpm"] ?? "")
        let metadataKey = parseKeyTagToCamelot(metadata["key"] ?? "")

        let analyzedBPM = metadataBPM > 0 ? metadataBPM : detectBPM(metrics: metrics)
        let analyzedKey = metadataKey.isEmpty ? detectKey(samples: analysisWindow.samples, sampleRate: analysisWindow.sampleRate) : metadataKey
        let (energy, energyConfidence) = detectEnergyWithConfidence(metrics: metrics)
        let previewStart = detectPreviewStart(
            metrics: metrics,
            duration: duration,
            analysisOffset: analysisWindow.offset,
            previewLength: 30.0
        )

        let title = normalizedTitle(
            metadataTitle: metadata["title"],
            filenameTitle: filenameMetadata["title"],
            url: url
        )
        let artist = normalizedArtist(
            metadataArtist: metadata["artist"],
            filenameArtist: filenameMetadata["artist"]
        )

        let (needsReview, reviewNotes) = classifyReviewFlags(
            title: title,
            artist: artist,
            bpm: analyzedBPM,
            musicalKey: analyzedKey,
            energyLevel: energy,
            energyConfidence: energyConfidence,
            duration: duration
        )

        let baseRecord = AnalyzedTrackRecord(
            existingID: existingID,
            filePath: url.path,
            fileHash: fileHash,
            title: title,
            artist: artist,
            bpm: analyzedBPM,
            key: analyzedKey,
            energy: energy,
            energyConfidence: energyConfidence,
            duration: duration,
            previewStart: previewStart,
            needsReview: needsReview,
            reviewNotes: reviewNotes,
            hasOverrides: false,
            analysisVersion: deepCrateAnalysisVersion
        )
        return applyOverride(override, to: baseRecord)
    }

    private func applyOverride(_ override: TrackOverrideRecord?, to analyzed: AnalyzedTrackRecord) -> AnalyzedTrackRecord {
        guard let override else {
            return analyzed
        }

        return AnalyzedTrackRecord(
            existingID: analyzed.existingID,
            filePath: analyzed.filePath,
            fileHash: analyzed.fileHash,
            title: analyzed.title,
            artist: analyzed.artist,
            bpm: override.bpm ?? analyzed.bpm,
            key: override.key ?? analyzed.key,
            energy: override.energy ?? analyzed.energy,
            energyConfidence: analyzed.energyConfidence,
            duration: analyzed.duration,
            previewStart: analyzed.previewStart,
            needsReview: analyzed.needsReview,
            reviewNotes: analyzed.reviewNotes,
            hasOverrides: override.bpm != nil || override.key != nil || override.energy != nil,
            analysisVersion: analyzed.analysisVersion
        )
    }

    private func audioFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw LibraryAnalysisError.invalidDirectory(root.path)
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if supportedExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url.standardizedFileURL)
            }
        }
        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private struct AnalysisWindow {
    let samples: [Float]
    let sampleRate: Double
    let offset: Double
}

private struct ShortTimeMetrics {
    let onsetEnvelope: [Double]
    let rms: [Double]
    let spectralCentroid: [Double]
    let hopSize: Int
    let sampleRate: Double
}

private final class RealFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    init?(size: Int) {
        guard size > 1, size.nonzeroBitCount == 1 else { return nil }
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.setup = setup
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.window = window
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func powerSpectrum(_ frame: ArraySlice<Float>) -> [Float] {
        var samples = [Float](frame)
        if samples.count < size {
            samples.append(contentsOf: repeatElement(0, count: size - samples.count))
        } else if samples.count > size {
            samples = Array(samples.prefix(size))
        }

        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        var real = [Float](repeating: 0, count: size / 2)
        var imag = [Float](repeating: 0, count: size / 2)
        return real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var splitComplex = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { bufferPointer in
                    bufferPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(size / 2))
                    }
                }

                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                var magnitudes = [Float](repeating: 0, count: size / 2)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(size / 2))
                return magnitudes
            }
        }
    }
}

private let camelotKeyMap: [String: String] = [
    "C major": "8B", "G major": "9B", "D major": "10B", "A major": "11B", "E major": "12B", "B major": "1B",
    "F# major": "2B", "Gb major": "2B", "Db major": "3B", "C# major": "3B", "Ab major": "4B", "Eb major": "5B",
    "Bb major": "6B", "F major": "7B",
    "C minor": "5A", "G minor": "6A", "D minor": "7A", "A minor": "8A", "E minor": "9A", "B minor": "10A",
    "F# minor": "11A", "Gb minor": "11A", "Db minor": "12A", "C# minor": "12A", "Ab minor": "1A",
    "Eb minor": "2A", "Bb minor": "3A", "F minor": "4A",
]

private let chromaMajor = [
    "C major", "C# major", "D major", "Eb major", "E major", "F major",
    "F# major", "G major", "Ab major", "A major", "Bb major", "B major",
]

private let chromaMinor = [
    "C minor", "C# minor", "D minor", "Eb minor", "E minor", "F minor",
    "F# minor", "G minor", "Ab minor", "A minor", "Bb minor", "B minor",
]

private let noteAliases: [String: String] = [
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
]

private func fileHash(for url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 1_048_576) ?? Data()
    let digest = Insecure.MD5.hash(data: data)
    return digest.map { String(format: "%02hhx", $0) }.joined()
}

private func readMetadata(url: URL) async -> [String: String] {
    let asset = AVURLAsset(url: url)
    var result: [String: String] = [
        "title": "",
        "artist": "",
        "bpm": "",
        "key": "",
    ]

    if let commonMetadata = try? await asset.load(.commonMetadata) {
        for item in commonMetadata {
            await captureMetadata(item, into: &result)
        }
    }

    if let formats = try? await asset.load(.availableMetadataFormats) {
        for format in formats {
            if let items = try? await asset.loadMetadata(for: format) {
                for item in items {
                    await captureMetadata(item, into: &result)
                }
            }
        }
    }

    return result.filter { !$0.value.isEmpty }
}

private func captureMetadata(_ item: AVMetadataItem, into result: inout [String: String]) async {
    guard let value = await metadataString(item), !value.isEmpty else { return }

    let commonKey = item.commonKey?.rawValue.lowercased() ?? ""
    let identifier = item.identifier?.rawValue.lowercased() ?? ""
    let key = metadataKey(item).lowercased()

    if result["title"]?.isEmpty != false, commonKey == "title" || identifier.contains("title") || key == "tit2" || key == "nam" {
        result["title"] = value
    }
    if result["artist"]?.isEmpty != false, commonKey == "artist" || identifier.contains("artist") || key == "tpe1" || key == "art" {
        result["artist"] = value
    }
    if result["bpm"]?.isEmpty != false, identifier.contains("bpm") || key == "tbpm" || key == "tmpo" || key == "bpm" {
        result["bpm"] = value
    }
    if result["key"]?.isEmpty != false, identifier.contains("initialkey") || identifier.hasSuffix("/key") || key == "tkey" || key == "initialkey" || key == "key" {
        result["key"] = value
    }
}

private func metadataKey(_ item: AVMetadataItem) -> String {
    if let key = item.key as? String {
        return key
    }
    if let key = item.key as? NSNumber {
        return key.stringValue
    }
    if let key = item.key as? NSString {
        return key as String
    }
    return ""
}

private func metadataString(_ item: AVMetadataItem) async -> String? {
    if let string = (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
        return string
    }
    if let number = try? await item.load(.numberValue) {
        return number.stringValue
    }
    if let data = try? await item.load(.dataValue) {
        if let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            return string
        }
        if let string = String(data: data, encoding: .utf16)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            return string
        }
    }
    return nil
}

private func parseFilenameMetadata(url: URL) -> [String: String] {
    let stem = url.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !stem.isEmpty else { return [:] }
    let parts = stem.split(separator: "-", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
        return ["artist": parts[0], "title": parts[1]]
    }
    return ["title": stem]
}

private func readDuration(url: URL) async -> Double {
    if let file = try? AVAudioFile(forReading: url) {
        let sampleRate = file.processingFormat.sampleRate
        if sampleRate > 0 {
            return Double(file.length) / sampleRate
        }
    }

    let asset = AVURLAsset(url: url)
    if let duration = try? await asset.load(.duration) {
        let seconds = duration.seconds
        if seconds.isFinite, seconds > 0 {
            return seconds
        }
    }
    return 0.0
}

private func loadAnalysisWindow(url: URL, duration: Double) throws -> AnalysisWindow {
    let audioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let sampleRate = audioFile.processingFormat.sampleRate
    guard sampleRate > 0 else {
        throw LibraryAnalysisError.unreadableAudio(url.path)
    }

    let totalFrames = AVAudioFramePosition(audioFile.length)
    guard totalFrames > 0 else {
        throw LibraryAnalysisError.unreadableAudio(url.path)
    }

    let resolvedDuration = duration > 0 ? duration : Double(totalFrames) / sampleRate
    let windowDuration: Double
    let offset: Double
    if resolvedDuration >= 180.0 {
        windowDuration = min(120.0, resolvedDuration * 0.4)
        offset = min(max(30.0, resolvedDuration * 0.25), max(resolvedDuration - windowDuration, 0.0))
    } else {
        windowDuration = resolvedDuration
        offset = 0.0
    }

    let offsetFrames = max(0, min(totalFrames, AVAudioFramePosition(offset * sampleRate)))
    audioFile.framePosition = offsetFrames
    let targetFrames = min(
        totalFrames - offsetFrames,
        max(1, AVAudioFramePosition(windowDuration * sampleRate))
    )

    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: audioFile.processingFormat,
        frameCapacity: AVAudioFrameCount(targetFrames)
    ) else {
        throw LibraryAnalysisError.unreadableAudio(url.path)
    }
    try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(targetFrames))

    let monoSamples = monoSamples(from: buffer)
    if monoSamples.isEmpty {
        throw LibraryAnalysisError.unreadableAudio(url.path)
    }

    if sampleRate > 24_000 {
        let targetRate = 22_050.0
        return AnalysisWindow(
            samples: resample(samples: monoSamples, from: sampleRate, to: targetRate),
            sampleRate: targetRate,
            offset: offset
        )
    }

    return AnalysisWindow(samples: monoSamples, sampleRate: sampleRate, offset: offset)
}

private func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channelData = buffer.floatChannelData else { return [] }
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return [] }
    let channelCount = Int(buffer.format.channelCount)

    if channelCount == 1 {
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }

    var mono = [Float](repeating: 0, count: frameLength)
    for channelIndex in 0..<channelCount {
        let samples = UnsafeBufferPointer(start: channelData[channelIndex], count: frameLength)
        for frameIndex in 0..<frameLength {
            mono[frameIndex] += samples[frameIndex]
        }
    }

    let scale = 1.0 / Float(channelCount)
    for index in mono.indices {
        mono[index] *= scale
    }
    return mono
}

private func resample(samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
    guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return samples }
    if abs(sourceRate - targetRate) < 1 {
        return samples
    }

    let outputCount = max(1, Int((Double(samples.count) * targetRate / sourceRate).rounded()))
    var output = [Float](repeating: 0, count: outputCount)
    let step = sourceRate / targetRate

    for index in 0..<outputCount {
        let sourcePosition = Double(index) * step
        let lowerIndex = min(Int(sourcePosition), samples.count - 1)
        let upperIndex = min(lowerIndex + 1, samples.count - 1)
        let fraction = Float(sourcePosition - Double(lowerIndex))
        output[index] = samples[lowerIndex] + ((samples[upperIndex] - samples[lowerIndex]) * fraction)
    }
    return output
}

private func computeShortTimeMetrics(samples: [Float], sampleRate: Double) -> ShortTimeMetrics {
    guard samples.count >= 1024 else {
        return ShortTimeMetrics(onsetEnvelope: [], rms: [], spectralCentroid: [], hopSize: 512, sampleRate: sampleRate)
    }

    let maxWindow = min(2048, highestPowerOfTwo(atMost: samples.count))
    guard maxWindow >= 512, let fft = RealFFT(size: maxWindow) else {
        return ShortTimeMetrics(onsetEnvelope: [], rms: [], spectralCentroid: [], hopSize: 512, sampleRate: sampleRate)
    }

    let hopSize = maxWindow / 4
    let frequencies = (0..<(maxWindow / 2)).map { Double($0) * sampleRate / Double(maxWindow) }
    var onsetEnvelope: [Double] = []
    var rmsSeries: [Double] = []
    var centroidSeries: [Double] = []
    var previousSpectrum: [Float] = []

    for start in stride(from: 0, through: samples.count - maxWindow, by: hopSize) {
        let frame = samples[start..<(start + maxWindow)]
        let spectrum = fft.powerSpectrum(frame)
        let rmsValue = rms(frame)
        rmsSeries.append(rmsValue)

        let powerSum = spectrum.reduce(0.0) { $0 + Double($1) }
        if powerSum > 1e-9 {
            let weighted = zip(frequencies, spectrum).reduce(0.0) { partial, pair in
                partial + (pair.0 * Double(pair.1))
            }
            centroidSeries.append(weighted / powerSum)
        } else {
            centroidSeries.append(0.0)
        }

        if previousSpectrum.isEmpty {
            onsetEnvelope.append(0.0)
        } else {
            var flux = 0.0
            for index in 1..<spectrum.count {
                let delta = Double(spectrum[index] - previousSpectrum[index])
                if delta > 0 {
                    flux += delta
                }
            }
            onsetEnvelope.append(flux)
        }
        previousSpectrum = spectrum
    }

    return ShortTimeMetrics(
        onsetEnvelope: onsetEnvelope,
        rms: rmsSeries,
        spectralCentroid: centroidSeries,
        hopSize: hopSize,
        sampleRate: sampleRate
    )
}

private func detectBPM(metrics: ShortTimeMetrics) -> Double {
    let onset = normalized(metrics.onsetEnvelope)
    guard onset.count >= 16 else { return 0.0 }

    let framesPerSecond = metrics.sampleRate / Double(metrics.hopSize)
    let minBPM = 60.0
    let maxBPM = 210.0
    let minLag = max(1, Int(framesPerSecond * 60.0 / maxBPM))
    let maxLag = min(onset.count - 1, Int(framesPerSecond * 60.0 / minBPM))
    guard minLag <= maxLag else { return 0.0 }

    var bestLag = 0
    var bestScore = -Double.infinity

    for lag in minLag...maxLag {
        let score = autocorrelationScore(values: onset, lag: lag)
        if score > bestScore {
            bestScore = score
            bestLag = lag
        }
    }

    guard bestLag > 0 else { return 0.0 }
    var bpm = normalizeBPM(60.0 * framesPerSecond / Double(bestLag))

    if bpm < 100.0 {
        let doubleLag = max(1, Int(round(Double(bestLag) / 2.0)))
        if doubleLag < onset.count {
            let doubleScore = autocorrelationScore(values: onset, lag: doubleLag)
            let doubledBPM = normalizeBPM(60.0 * framesPerSecond / Double(doubleLag))
            if doubledBPM <= 190.0, doubleScore >= bestScore * 0.92 {
                bpm = doubledBPM
            }
        }
    }

    return round(bpm * 10.0) / 10.0
}

private func detectKey(samples: [Float], sampleRate: Double) -> String {
    guard samples.count >= 2048 else { return "" }

    let windowSize = min(4096, highestPowerOfTwo(atMost: samples.count))
    guard windowSize >= 1024, let fft = RealFFT(size: windowSize) else { return "" }

    let hopSize = windowSize / 2
    let frequencies = (0..<(windowSize / 2)).map { Double($0) * sampleRate / Double(windowSize) }
    var perFrameProfiles: [[Double]] = []
    var frameEnergy: [Double] = []

    for start in stride(from: 0, through: samples.count - windowSize, by: hopSize) {
        let frame = samples[start..<(start + windowSize)]
        let spectrum = fft.powerSpectrum(frame)
        let energy = rms(frame)
        frameEnergy.append(energy)

        var pitchClassProfile = [Double](repeating: 0, count: 12)
        for (binIndex, magnitude) in spectrum.enumerated() {
            let frequency = frequencies[binIndex]
            guard frequency >= 60.0, frequency <= 5_000.0 else { continue }
            let midi = 69.0 + (12.0 * log2(frequency / 440.0))
            let pitchClass = positiveModulo(Int(midi.rounded()), 12)
            pitchClassProfile[pitchClass] += sqrt(Double(magnitude))
        }
        perFrameProfiles.append(pitchClassProfile)
    }

    guard !perFrameProfiles.isEmpty else { return "" }

    let energyThreshold = percentile(frameEnergy, 0.30)
    var combined = [Double](repeating: 0, count: 12)
    var totalWeight = 0.0

    for (index, profile) in perFrameProfiles.enumerated() {
        if frameEnergy[index] < energyThreshold {
            continue
        }
        let weight = profile.reduce(0, +)
        totalWeight += weight
        for pitchClass in 0..<12 {
            combined[pitchClass] += profile[pitchClass]
        }
    }

    if totalWeight <= 1e-9 {
        for profile in perFrameProfiles {
            for pitchClass in 0..<12 {
                combined[pitchClass] += profile[pitchClass]
            }
        }
    }

    let sum = combined.reduce(0, +)
    guard sum > 1e-9 else { return "" }
    combined = combined.map { $0 / sum }

    let majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    let minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    var bestKey = ""
    var bestScore = -Double.infinity

    for index in 0..<12 {
        let rotated = rotateLeft(combined, by: index)
        let majorScore = safeCorrelation(rotated, majorProfile)
        if majorScore > bestScore {
            bestScore = majorScore
            bestKey = chromaMajor[index]
        }

        let minorScore = safeCorrelation(rotated, minorProfile)
        if minorScore > bestScore {
            bestScore = minorScore
            bestKey = chromaMinor[index]
        }
    }

    return camelotKeyMap[bestKey] ?? ""
}

private func detectEnergyWithConfidence(metrics: ShortTimeMetrics) -> (Double, Double) {
    guard !metrics.rms.isEmpty else { return (0.0, 0.0) }

    let rmsMean = metrics.rms.reduce(0, +) / Double(metrics.rms.count)
    let rmsScore = min(rmsMean / 0.15, 1.0)

    let centroidMean = metrics.spectralCentroid.isEmpty ? 0.0 : metrics.spectralCentroid.reduce(0, +) / Double(metrics.spectralCentroid.count)
    let centroidScore = min(centroidMean / 5_000.0, 1.0)

    let energy = round(min(max((0.6 * rmsScore) + (0.4 * centroidScore), 0.0), 1.0) * 100.0) / 100.0

    let dynamicRange = percentile(metrics.rms, 0.95) - percentile(metrics.rms, 0.05)
    let rmsStd = standardDeviation(metrics.rms, mean: rmsMean)
    let varianceRatio = rmsMean > 1e-9 ? rmsStd / rmsMean : 0.0

    let centroidStd = standardDeviation(metrics.spectralCentroid, mean: centroidMean)
    let centroidRatio = centroidMean > 1e-9 ? centroidStd / centroidMean : 0.0
    let silenceThreshold = max(rmsMean * 0.35, 1e-6)
    let silenceRatio = metrics.rms.isEmpty ? 1.0 : Double(metrics.rms.filter { $0 < silenceThreshold }.count) / Double(metrics.rms.count)

    let dynamicScore = min(dynamicRange / 0.12, 1.0)
    let varianceScore = min(varianceRatio / 0.8, 1.0)
    let centroidVarianceScore = min(centroidRatio / 0.8, 1.0)

    let confidence = round(
        min(
            max(
                0.25
                    + (0.35 * dynamicScore)
                    + (0.20 * varianceScore)
                    + (0.20 * centroidVarianceScore)
                    - (0.20 * silenceRatio),
                0.0
            ),
            1.0
        ) * 100.0
    ) / 100.0

    return (energy, confidence)
}

private func detectPreviewStart(
    metrics: ShortTimeMetrics,
    duration: Double,
    analysisOffset: Double,
    previewLength: Double
) -> Double {
    guard duration > previewLength + 5.0, !metrics.onsetEnvelope.isEmpty, !metrics.rms.isEmpty else {
        return 0.0
    }

    let score = zip(normalized(metrics.onsetEnvelope), normalized(metrics.rms)).map { (0.65 * $0.0) + (0.35 * $0.1) }
    let localMaxStart = max((Double(score.count * metrics.hopSize) / metrics.sampleRate) - previewLength, 0.0)
    guard localMaxStart > 0 else {
        return round(min(max(analysisOffset, 0.0), max(duration - previewLength, 0.0)) * 10.0) / 10.0
    }

    let minimumLocal = min(8.0, localMaxStart)
    var bestIndex = 0
    var bestScore = -Double.infinity

    for index in score.indices {
        let time = Double(index * metrics.hopSize) / metrics.sampleRate
        guard time >= minimumLocal, time <= localMaxStart else { continue }
        if score[index] > bestScore {
            bestScore = score[index]
            bestIndex = index
        }
    }

    let localStart = max((Double(bestIndex * metrics.hopSize) / metrics.sampleRate) - 4.0, 0.0)
    let absolute = min(max(analysisOffset + localStart, 0.0), max(duration - previewLength, 0.0))
    return round(absolute * 10.0) / 10.0
}

private func classifyReviewFlags(
    title: String,
    artist: String,
    bpm: Double,
    musicalKey: String,
    energyLevel: Double,
    energyConfidence: Double,
    duration: Double
) -> (Bool, String) {
    var reasons: [String] = []

    if energyConfidence < 0.55 {
        reasons.append("Low energy confidence")
    }
    if energyLevel <= 0.03 || energyLevel >= 0.97 {
        reasons.append("Energy at boundary")
    }
    if duration > 0, duration < 45.0 {
        reasons.append("Very short duration")
    }
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reasons.append("Missing title")
    }
    if artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reasons.append("Missing artist")
    }
    if bpm <= 0 {
        reasons.append("Missing BPM")
    }
    if musicalKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reasons.append("Missing key")
    }

    return (!reasons.isEmpty, reasons.joined(separator: " | "))
}

private func normalizedTitle(metadataTitle: String?, filenameTitle: String?, url: URL) -> String {
    let title = (metadataTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty {
        return title
    }

    let filename = (filenameTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !filename.isEmpty {
        return filename
    }
    return url.deletingPathExtension().lastPathComponent
}

private func normalizedArtist(metadataArtist: String?, filenameArtist: String?) -> String {
    let artist = (metadataArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !artist.isEmpty {
        return artist
    }
    return (filenameArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseBPMTag(_ value: String) -> Double {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = trimmed.range(of: #"\d+(?:[\.,]\d+)?"#, options: .regularExpression) else {
        return 0.0
    }

    let numeric = trimmed[match].replacingOccurrences(of: ",", with: ".")
    guard var bpm = Double(numeric), bpm.isFinite, bpm > 0 else {
        return 0.0
    }

    while bpm > 260.0 {
        bpm /= 2.0
    }
    guard bpm >= 40.0, bpm <= 260.0 else {
        return 0.0
    }
    return round(bpm * 10.0) / 10.0
}

private func parseKeyTagToCamelot(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let camelot = parseCamelot(trimmed) {
        return camelot
    }

    if let existing = camelotKeyMap.first(where: { $0.key.caseInsensitiveCompare(trimmed) == .orderedSame }) {
        return existing.value
    }

    let pattern = #"^\s*([A-Ga-g])\s*([#bB♭♯]?)\s*(maj(?:or)?|min(?:or)?|m)?\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return ""
    }

    let range = NSRange(location: 0, length: trimmed.utf16.count)
    guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else {
        return ""
    }

    func component(_ index: Int) -> String {
        let nsRange = match.range(at: index)
        guard let swiftRange = Range(nsRange, in: trimmed) else { return "" }
        return String(trimmed[swiftRange])
    }

    let letter = component(1).uppercased()
    let accidentalRaw = component(2)
    let accidental: String
    switch accidentalRaw {
    case "#", "♯":
        accidental = "#"
    case "b", "B", "♭":
        accidental = "B"
    default:
        accidental = ""
    }

    let modeToken = component(3).lowercased()
    let isMinor = !modeToken.isEmpty && modeToken.hasPrefix("m") && !modeToken.hasPrefix("maj")

    guard let canonicalNote = noteAliases["\(letter)\(accidental)"] else {
        return ""
    }

    let keyName = "\(canonicalNote) \(isMinor ? "minor" : "major")"
    return camelotKeyMap[keyName] ?? ""
}

private func parseCamelot(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard trimmed.count >= 2, let letter = trimmed.last, letter == "A" || letter == "B" else {
        return nil
    }
    guard let number = Int(trimmed.dropLast()), (1...12).contains(number) else {
        return nil
    }
    return "\(number)\(letter)"
}

private func normalizeBPM(_ rawBPM: Double) -> Double {
    var bpm = rawBPM
    guard bpm > 0 else { return 0.0 }
    while bpm < 70.0 {
        bpm *= 2.0
    }
    while bpm > 190.0 {
        bpm /= 2.0
    }
    return bpm
}

private func autocorrelationScore(values: [Double], lag: Int) -> Double {
    guard lag > 0, lag < values.count else { return 0.0 }
    var score = 0.0
    for index in 0..<(values.count - lag) {
        score += values[index] * values[index + lag]
    }
    return score
}

private func normalized(_ values: [Double]) -> [Double] {
    guard let minValue = values.min(), let maxValue = values.max(), maxValue - minValue > 1e-9 else {
        return values.map { _ in 0.0 }
    }
    let span = maxValue - minValue
    return values.map { ($0 - minValue) / span }
}

private func percentile(_ values: [Double], _ quantile: Double) -> Double {
    guard !values.isEmpty else { return 0.0 }
    let sorted = values.sorted()
    if sorted.count == 1 { return sorted[0] }

    let clamped = min(max(quantile, 0.0), 1.0)
    let position = clamped * Double(sorted.count - 1)
    let lowerIndex = Int(position.rounded(.down))
    let upperIndex = Int(position.rounded(.up))
    if lowerIndex == upperIndex {
        return sorted[lowerIndex]
    }
    let fraction = position - Double(lowerIndex)
    return sorted[lowerIndex] + ((sorted[upperIndex] - sorted[lowerIndex]) * fraction)
}

private func standardDeviation(_ values: [Double], mean: Double) -> Double {
    guard !values.isEmpty else { return 0.0 }
    let variance = values.reduce(0.0) { partial, value in
        let delta = value - mean
        return partial + (delta * delta)
    } / Double(values.count)
    return sqrt(variance)
}

private func rms(_ frame: ArraySlice<Float>) -> Double {
    guard !frame.isEmpty else { return 0.0 }
    let sumSquares = frame.reduce(0.0) { partial, sample in
        partial + Double(sample * sample)
    }
    return sqrt(sumSquares / Double(frame.count))
}

private func highestPowerOfTwo(atMost value: Int) -> Int {
    guard value > 0 else { return 0 }
    var power = 1
    while power * 2 <= value {
        power *= 2
    }
    return power
}

private func rotateLeft(_ values: [Double], by amount: Int) -> [Double] {
    guard !values.isEmpty else { return [] }
    let shift = positiveModulo(amount, values.count)
    guard shift != 0 else { return values }
    return Array(values[shift...] + values[..<shift])
}

private func safeCorrelation(_ lhs: [Double], _ rhs: [Double]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return 0.0 }
    let lhsMean = lhs.reduce(0, +) / Double(lhs.count)
    let rhsMean = rhs.reduce(0, +) / Double(rhs.count)

    var numerator = 0.0
    var lhsVariance = 0.0
    var rhsVariance = 0.0

    for index in lhs.indices {
        let lhsDelta = lhs[index] - lhsMean
        let rhsDelta = rhs[index] - rhsMean
        numerator += lhsDelta * rhsDelta
        lhsVariance += lhsDelta * lhsDelta
        rhsVariance += rhsDelta * rhsDelta
    }

    guard lhsVariance > 1e-9, rhsVariance > 1e-9 else { return 0.0 }
    let value = numerator / sqrt(lhsVariance * rhsVariance)
    return value.isFinite ? value : 0.0
}

private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
    guard modulus > 0 else { return 0 }
    let remainder = value % modulus
    return remainder >= 0 ? remainder : remainder + modulus
}
