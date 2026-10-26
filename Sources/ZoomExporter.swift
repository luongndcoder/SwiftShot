import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

/// A cursor recording captured alongside a screen recording (see
/// `ScreenRecorder`). Points are normalized to the capture area
/// (0…1 on both axes, top-left origin); times are seconds since the
/// recording started.
struct CursorTrack {
    struct Moment {
        let time: TimeInterval
        let point: CGPoint
    }
    var samples: [Moment] = []
    var clicks: [Moment] = []
}

enum ZoomExportError: Error {
    case noVideoTrack
    case tooShort
    case cannotRead
    case cannotWrite
}

/// Renders a Cursorful-style auto-zoom version of a recording.
///
/// The original file is never touched. The exporter replays it frame by
/// frame through a virtual camera whose state is computed from the cursor
/// track: a click opens a "zoom episode" (the camera eases in on the click
/// point and then follows the smoothed cursor), periods without clicks ease
/// back out to the full frame. Clicks landing close together merge into one
/// continuous episode so the camera never yo-yos.
final class ZoomExporter {
    /// Called on the main queue with a 0…1 fraction while rendering.
    var onProgress: ((Double) -> Void)?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Renders `input` into `output` (an MP4 written next to the original).
    /// The completion fires on the main queue.
    func export(input: URL, output: URL, track: CursorTrack, zoomLevel: Double,
                completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.render(input: input, output: output, track: track, zoomLevel: zoomLevel)
                DispatchQueue.main.async { completion(.success(output)) }
            } catch {
                try? FileManager.default.removeItem(at: output)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Render pipeline

    private func render(input: URL, output: URL, track: CursorTrack, zoomLevel: Double) throws {
        let asset = AVURLAsset(url: input)
        let loadSemaphore = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { loadSemaphore.signal() }
        loadSemaphore.wait()

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw ZoomExportError.noVideoTrack
        }
        let duration = asset.duration.seconds
        guard duration.isFinite, duration >= 1.2 else { throw ZoomExportError.tooShort }

        let transformed = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let width = Int(abs(transformed.width))
        let height = Int(abs(transformed.height))
        guard width > 0, height > 0 else { throw ZoomExportError.noVideoTrack }

        let camera = ZoomCamera(track: track, zoomLevel: zoomLevel)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: width * height * 3,
            AVVideoMaxKeyFrameIntervalKey: 120,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: 60
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw ZoomExportError.cannotWrite }
        guard reader.startReading() else { throw ZoomExportError.cannotRead }
        writer.startSession(atSourceTime: .zero)

        // SCStream timestamps are host-clock based; normalise every sample
        // (audio and video share that clock) so the output starts at zero.
        var timeOffset: CMTime?
        let offsetLock = NSLock()
        func normalize(_ pts: CMTime) -> CMTime {
            offsetLock.lock()
            if let timeOffset { offsetLock.unlock(); return pts - timeOffset }
            timeOffset = pts
            offsetLock.unlock()
            return .zero
        }

        let frameSize = CGSize(width: width, height: height)
        let estimatedFrames = max(1.0, duration * 60)
        var videoFrames = 0

        let finishSemaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var videoDone = false
        var audioDone = audioInput == nil
        func markDone(video: Bool) {
            stateLock.lock()
            if video { videoDone = true } else { audioDone = true }
            let all = videoDone && audioDone
            stateLock.unlock()
            if all { finishSemaphore.signal() }
        }

        let videoQueue = DispatchQueue(label: "dev.luongcoder.SwiftShot.zoom.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
            guard let self else { return }
            while videoInput.isReadyForMoreMediaData {
                guard writer.status != .failed else {
                    videoInput.markAsFinished()
                    markDone(video: true)
                    return
                }
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    markDone(video: true)
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let normalized = normalize(pts)
                let t = normalized.seconds
                guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }

                let (center, zoom) = camera.advance(to: t)
                let appended: Bool
                if zoom < 1.005 {
                    // Full-frame moments pass through unmodified.
                    appended = adaptor.append(sourceBuffer, withPresentationTime: normalized)
                } else if let pool = adaptor.pixelBufferPool {
                    var outBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                    if let outBuffer {
                        self.renderZoomed(source: sourceBuffer, into: outBuffer,
                                          frameSize: frameSize, center: center, zoom: zoom)
                        appended = adaptor.append(outBuffer, withPresentationTime: normalized)
                    } else {
                        appended = false
                    }
                } else {
                    appended = false
                }
                if !appended {
                    // Writer trouble (or a dropped pool buffer): keep draining
                    // so the reader cannot stall, the final status check
                    // below reports the failure.
                    NSLog("[SwiftShot] zoom export: frame append failed at \(t)s")
                }
                videoFrames += 1
                if videoFrames % 30 == 0 {
                    let fraction = min(1, Double(videoFrames) / estimatedFrames)
                    DispatchQueue.main.async { self.onProgress?(fraction) }
                }
            }
        }

        if let audioInput, let audioOutput {
            let audioQueue = DispatchQueue(label: "dev.luongcoder.SwiftShot.zoom.audio")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard writer.status != .failed else {
                        audioInput.markAsFinished()
                        markDone(video: false)
                        return
                    }
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        markDone(video: false)
                        return
                    }
                    // Shift the sample onto the normalised timeline.
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let normalized = normalize(pts)
                    let delta = normalized - pts
                    var timing = [CMSampleTimingInfo(
                        duration: CMSampleBufferGetDuration(sample),
                        presentationTimeStamp: normalized,
                        decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample) == .invalid
                            ? .invalid : CMSampleBufferGetDecodeTimeStamp(sample) + delta
                    )]
                    var shifted: CMSampleBuffer?
                    CMSampleBufferCreateCopyWithNewTiming(
                        allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                        sampleTimingArray: &timing, sampleBufferOut: &shifted
                    )
                    if let shifted {
                        audioInput.append(shifted)
                    }
                }
            }
        }

        finishSemaphore.wait()
        if reader.status == .failed {
            writer.cancelWriting()
            throw ZoomExportError.cannotRead
        }
        let writerSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { writerSemaphore.signal() }
        writerSemaphore.wait()
        guard writer.status == .completed else {
            throw writer.error ?? ZoomExportError.cannotWrite
        }
        DispatchQueue.main.async { self.onProgress?(1) }
    }

    /// Crops the camera viewport out of a frame and scales it back to the
    /// full frame size. `center` is normalized with a top-left origin;
    /// CoreImage works bottom-left, so the crop rect is flipped.
    private func renderZoomed(source: CVPixelBuffer, into destination: CVPixelBuffer,
                              frameSize: CGSize, center: CGPoint, zoom: Double) {
        let W = frameSize.width
        let H = frameSize.height
        let vw = W / CGFloat(zoom)
        let vh = H / CGFloat(zoom)
        let vx = center.x * W - vw / 2
        let vyTop = center.y * H - vh / 2
        let crop = CGRect(x: vx, y: H - (vyTop + vh), width: vw, height: vh)

        let image = CIImage(cvPixelBuffer: source)
        let cropped = image.cropped(to: crop)
        let transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: W / vw, y: H / vh))
        let scaled = cropped.transformed(by: transform)
        ciContext.render(scaled, to: destination)
    }
}

// MARK: - Virtual camera

/// Computes the camera state (center + zoom) for each frame time from the
/// cursor track. Stateful: `advance(to:)` must be called with increasing
/// times, exactly as frames arrive.
private final class ZoomCamera {
    private struct Episode {
        let start: TimeInterval  // first click
        let end: TimeInterval    // last click + hold
    }

    private let samples: [CursorTrack.Moment]
    private let episodes: [Episode]
    private let level: Double

    private var center = CGPoint(x: 0.5, y: 0.5)
    private var zoom: Double = 1
    private var lastTime: TimeInterval = 0

    init(track: CursorTrack, zoomLevel: Double) {
        self.level = zoomLevel
        self.samples = Self.smoothed(track.samples, radius: 8)

        // Merge clicks into episodes: a click extends the current episode
        // when it lands while the camera is (or would still be) zoomed.
        let hold: TimeInterval = 1.8
        let mergeGap: TimeInterval = 1.6
        var episodes: [Episode] = []
        for click in track.clicks {
            if let last = episodes.last, click.time <= last.end + mergeGap {
                episodes[episodes.count - 1] = Episode(start: last.start, end: click.time + hold)
            } else {
                episodes.append(Episode(start: click.time, end: click.time + hold))
            }
        }
        self.episodes = episodes
    }

    func advance(to t: TimeInterval) -> (center: CGPoint, zoom: Double) {
        let dt = min(max(t - lastTime, 0), 0.1)
        lastTime = t
        guard dt > 0 || t == 0 else { return (clampedCenter(), zoom) }

        var desiredZoom = 1.0
        var desiredCenter = CGPoint(x: 0.5, y: 0.5)
        if let episode = episodes.first(where: { t >= $0.start - 0.35 && t <= $0.end + 0.5 }) {
            let rampIn = Self.smoothstep((t - (episode.start - 0.35)) / 0.5)
            let rampOut = Self.smoothstep((t - episode.end) / 0.5)
            let factor = min(rampIn, 1 - rampOut)
            if factor > 0 {
                desiredZoom = 1 + (level - 1) * factor
                let cursor = cursorPosition(at: t)
                desiredCenter = CGPoint(
                    x: 0.5 + (cursor.x - 0.5) * CGFloat(factor),
                    y: 0.5 + (cursor.y - 0.5) * CGFloat(factor)
                )
            }
        }

        // Critically-damped style approach: fast enough to follow, too soft
        // to jump. Zoom-outs run a little slower than zoom-ins.
        let zoomTau = desiredZoom > zoom ? 0.10 : 0.16
        zoom += (desiredZoom - zoom) * (1 - exp(-dt / zoomTau))

        let centerAlpha = 1 - exp(-dt / 0.085)
        var next = CGPoint(
            x: center.x + (desiredCenter.x - center.x) * CGFloat(centerAlpha),
            y: center.y + (desiredCenter.y - center.y) * CGFloat(centerAlpha)
        )
        // Cap the pan speed so a far-away click produces a glide, not a cut.
        let maxStep = CGFloat(1.4 * dt)
        let dx = next.x - center.x
        let dy = next.y - center.y
        let distance = hypot(dx, dy)
        if distance > maxStep, distance > 0 {
            next = CGPoint(x: center.x + dx / distance * maxStep,
                           y: center.y + dy / distance * maxStep)
        }
        center = next
        return (clampedCenter(), zoom)
    }

    /// Keeps the viewport inside the frame at the current zoom.
    private func clampedCenter() -> CGPoint {
        guard zoom > 1.001 else { return CGPoint(x: 0.5, y: 0.5) }
        let half = CGFloat(0.5 / zoom)
        return CGPoint(
            x: min(1 - half, max(half, center.x)),
            y: min(1 - half, max(half, center.y))
        )
    }

    private func cursorPosition(at t: TimeInterval) -> CGPoint {
        guard let first = samples.first else { return CGPoint(x: 0.5, y: 0.5) }
        if t <= first.time { return first.point }
        guard let last = samples.last else { return first.point }
        if t >= last.time { return last.point }
        var lo = 0
        var hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].time <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo]
        let b = samples[hi]
        let span = b.time - a.time
        let f = span > 0 ? CGFloat((t - a.time) / span) : 0
        return CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                       y: a.point.y + (b.point.y - a.point.y) * f)
    }

    private static func smoothstep(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    /// Moving-average smoothing of the raw path (radius in samples; the
    /// recorder samples at ~125 Hz, so 8 ≈ a 130 ms window).
    private static func smoothed(_ input: [CursorTrack.Moment], radius: Int) -> [CursorTrack.Moment] {
        guard input.count > radius * 2 else { return input }
        return input.indices.map { i in
            let lo = max(0, i - radius)
            let hi = min(input.count - 1, i + radius)
            var x = 0.0
            var y = 0.0
            for j in lo...hi {
                x += Double(input[j].point.x)
                y += Double(input[j].point.y)
            }
            let n = Double(hi - lo + 1)
            return CursorTrack.Moment(
                time: input[i].time,
                point: CGPoint(x: x / n, y: y / n)
            )
        }
    }
}
