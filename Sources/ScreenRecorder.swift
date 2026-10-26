import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Records a display (or a region of it) to an MP4 file using ScreenCaptureKit.
///
/// Pipeline: `SCStream` delivers BGRA frames (and optionally system audio) on a
/// serial queue, an `AVAssetWriter` encodes them as H.264 + AAC. The app's own
/// windows are excluded from the capture, so toasts and menus of SwiftShot
/// itself never end up in the recording.
///
/// The Screen Recording permission the app already holds for screenshots
/// covers video capture as well — no extra TCC grant is needed. Microphone
/// capture is intentionally not included: putting the mic into an SCStream is
/// a macOS 15 API while the app targets macOS 14.
final class ScreenRecorder: NSObject {
    /// True between a successful `start` and the end of `stop`.
    private(set) var isRecording = false
    /// When the current recording started (drives the menu bar timer).
    private(set) var startedAt: Date?

    /// Called on the main queue whenever `isRecording` flips.
    var onRecordingChanged: ((Bool) -> Void)?
    /// Called on the main queue with the finished file.
    var onFinished: ((URL) -> Void)?
    /// Called on the main queue when the stream dies unexpectedly.
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var includeAudio = false
    private var sessionStarted = false
    private var isStopping = false

    // MARK: - Cursor tracking (for the auto-zoom pass)

    /// The cursor track of the most recent recording, consumed by
    /// `ZoomExporter`. Positions are normalized to the capture area.
    private(set) var lastCursorTrack: CursorTrack?
    private var cursorTimer: DispatchSourceTimer?
    private let cursorQueue = DispatchQueue(label: "dev.luongcoder.SwiftShot.recorder.cursor")
    private var cursorSamples: [CursorTrack.Moment] = []
    private var cursorClicks: [CursorTrack.Moment] = []

    /// Serial queue for the stream outputs — keeps every writer access in order.
    private let sampleQueue = DispatchQueue(label: "dev.luongcoder.SwiftShot.recorder.samples")

    // MARK: - Start

    /// Starts recording.
    ///
    /// - Parameters:
    ///   - display: the `SCDisplay` to record.
    ///   - displayPointSize: the display's size in points.
    ///   - scale: the display's backing scale factor (output is native pixels).
    ///   - region: an optional region in display-local points with a
    ///     **bottom-left** origin (the AppKit convention); `nil` records the
    ///     whole display.
    ///   - includeAudio: also record system audio as an AAC track.
    ///   - outputURL: where the MP4 is written.
    func start(
        display: SCDisplay,
        displayPointSize: CGSize,
        scale: CGFloat,
        region: CGRect?,
        includeAudio: Bool,
        outputURL: URL
    ) async throws {
        guard !isRecording else { return }
        self.includeAudio = includeAudio
        self.outputURL = outputURL
        sessionStarted = false
        isStopping = false

        // Capture everything except this app's own windows.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        // Output size in native pixels. H.264 needs even dimensions.
        let captureSize = region?.size ?? displayPointSize
        let pixelWidth = Self.even(Int(captureSize.width * scale))
        let pixelHeight = Self.even(Int(captureSize.height * scale))

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = false
        config.showsCursor = true
        if let region {
            // `sourceRect` is expressed in points with a top-left origin,
            // AppKit selection rects use a bottom-left origin — flip the Y.
            config.sourceRect = CGRect(
                x: region.minX,
                y: displayPointSize.height - region.maxY,
                width: region.width,
                height: region.height
            )
        }
        if includeAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        try setupWriter(outputURL: outputURL, width: pixelWidth, height: pixelHeight, includeAudio: includeAudio)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if includeAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream

        try await stream.startCapture()
        startedAt = Date()
        setRecording(true)
        startCursorTracking(display: display, displayPointSize: displayPointSize, region: region)
    }

    // MARK: - Cursor tracking

    /// Builds the mapping from global mouse locations (AppKit points,
    /// bottom-left origin across all displays) into the capture area's
    /// normalized space (0…1, top-left origin), or `nil` when the display
    /// cannot be matched to an `NSScreen`.
    private func makeTrackMapping(
        display: SCDisplay, displayPointSize: CGSize, region: CGRect?
    ) -> ((CGPoint) -> CGPoint?)? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }) else { return nil }
        let displayFrame = screen.frame
        // Display-local capture rect, bottom-left origin (the recorder's
        // own convention for `region`).
        let capture = region ?? CGRect(origin: .zero, size: displayPointSize)
        return { global in
            let nx = (global.x - displayFrame.minX - capture.minX) / capture.width
            let ny = 1 - (global.y - displayFrame.minY - capture.minY) / capture.height
            // A little slack: a cursor just outside the area still belongs to
            // the recording's story, clamped to the edge.
            guard nx >= -0.05, nx <= 1.05, ny >= -0.05, ny <= 1.05 else { return nil }
            return CGPoint(x: min(1, max(0, nx)), y: min(1, max(0, ny)))
        }
    }

    /// Samples the cursor at ~125 Hz and detects clicks by polling the mouse
    /// button state — no event taps, no extra permissions.
    private func startCursorTracking(display: SCDisplay, displayPointSize: CGSize, region: CGRect?) {
        lastCursorTrack = nil
        guard let mapping = makeTrackMapping(display: display, displayPointSize: displayPointSize, region: region)
        else { return }
        cursorQueue.sync {
            cursorSamples = []
            cursorClicks = []
        }
        var wasPressed = false
        let timer = DispatchSource.makeTimerSource(queue: cursorQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let startedAt = self.startedAt else { return }
            guard let point = mapping(NSEvent.mouseLocation) else { return }
            // Safety cap (~65 minutes at 125 Hz) so a forgotten recording
            // cannot grow the track without bound.
            guard self.cursorSamples.count < 500_000 else { return }
            let t = Date().timeIntervalSince(startedAt)
            self.cursorSamples.append(CursorTrack.Moment(time: t, point: point))
            let pressed = NSEvent.pressedMouseButtons & 1 != 0
            if pressed && !wasPressed {
                self.cursorClicks.append(CursorTrack.Moment(time: t, point: point))
            }
            wasPressed = pressed
        }
        timer.resume()
        cursorTimer = timer
    }

    private func stopCursorTracking() {
        cursorTimer?.cancel()
        cursorTimer = nil
        let snapshot: (samples: [CursorTrack.Moment], clicks: [CursorTrack.Moment]) =
            cursorQueue.sync { (cursorSamples, cursorClicks) }
        if !snapshot.samples.isEmpty {
            lastCursorTrack = CursorTrack(samples: snapshot.samples, clicks: snapshot.clicks)
        }
    }

    private func setupWriter(outputURL: URL, width: Int, height: Int, includeAudio: Bool) throws {
        // A same-named leftover would make the writer fail — start clean.
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

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
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
        self.videoInput = videoInput

        if includeAudio {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            audioInput.expectsMediaDataInRealTime = true
            writer.add(audioInput)
            self.audioInput = audioInput
        } else {
            self.audioInput = nil
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "SwiftShot.Recorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not start writing the recording"]
            )
        }
        self.writer = writer
    }

    // MARK: - Stop

    /// Stops the stream and finalises the MP4. `onFinished` fires with the file.
    func stop() async {
        guard isRecording, let stream else { return }
        isStopping = true
        setRecording(false)
        stopCursorTracking()

        try? await stream.stopCapture()
        self.stream = nil

        // Finish on the sample queue so no frame is appended after this point.
        let finishedURL: URL? = await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                guard let self, let writer = self.writer else {
                    continuation.resume(returning: nil)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                let url = self.outputURL
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }

        writer = nil
        videoInput = nil
        audioInput = nil
        startedAt = nil

        if let finishedURL {
            DispatchQueue.main.async { [weak self] in
                self?.onFinished?(finishedURL)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onError?("The recording could not be saved")
            }
        }
    }

    private func setRecording(_ value: Bool) {
        isRecording = value
        DispatchQueue.main.async { [weak self] in
            self?.onRecordingChanged?(value)
        }
    }

    private static func even(_ value: Int) -> Int {
        max(2, value - value % 2)
    }
}

// MARK: - Stream outputs

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status != .failed else { return }

        switch type {
        case .screen:
            // Frames without a pixel buffer (idle/blank) carry nothing to encode.
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            if !sessionStarted {
                sessionStarted = true
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            // Audio that predates the writer session has nowhere valid to go.
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        default:
            break
        }
    }
}

// MARK: - Stream delegate

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // A stop the user asked for also lands here in some paths — only an
        // unexpected stop is an error worth surfacing.
        guard !isStopping, isRecording else { return }
        NSLog("[SwiftShot] recording stream stopped with error: \(error.localizedDescription)")
        // Finalise whatever was captured; `stop()` reports the outcome through
        // `onFinished`/`onError`, so the user is not notified twice.
        Task { [weak self] in
            await self?.stop()
        }
    }
}
