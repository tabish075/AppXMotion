import AVFoundation
import Observation

/// Drives the live preview: an AVPlayer playing the composition through `SceneCompositor`.
@Observable @MainActor
final class PlaybackController {
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Playback loops inside this range (the trim).
    var loopRange: ClosedRange<Double>?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.reachedEnd(item) }
        }
    }

    var hasItem: Bool { player.currentItem != nil }

    func load(_ built: BuiltComposition?) {
        guard let built else {
            player.replaceCurrentItem(with: nil)
            duration = 0
            currentTime = 0
            isPlaying = false
            return
        }
        let item = AVPlayerItem(asset: built.asset)
        item.videoComposition = built.videoComposition
        item.audioTimePitchAlgorithm = .spectral
        let resume = currentTime
        player.replaceCurrentItem(with: item)
        duration = built.duration
        seek(to: min(resume, built.duration))
        if isPlaying { player.play() }
    }

    private func tick(_ t: Double) {
        guard t.isFinite, hasItem else { return }
        currentTime = t
        if isPlaying, let range = loopRange, t >= range.upperBound - 0.001 {
            seek(to: range.lowerBound)
        }
    }

    private func reachedEnd(_ item: AVPlayerItem?) {
        guard item === player.currentItem, isPlaying else { return }
        seek(to: loopRange?.lowerBound ?? 0)
        player.play()
    }

    func play() {
        guard hasItem else { return }
        if let range = loopRange, currentTime >= range.upperBound - 0.05 || currentTime < range.lowerBound {
            seek(to: range.lowerBound)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to time: Double) {
        let t = max(0, min(time, duration))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(by delta: Double) {
        pause()
        seek(to: currentTime + delta)
    }

    /// Re-renders the current frame after the style changed while paused.
    func refresh() {
        guard !isPlaying, let item = player.currentItem, let composition = item.videoComposition,
              let copy = composition.mutableCopy() as? AVVideoComposition else { return }
        item.videoComposition = copy
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
