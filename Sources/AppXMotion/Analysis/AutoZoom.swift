import AVFoundation
import CoreVideo

/// Finds the moments worth zooming into, without any manual editing.
///
/// The recording is decoded at low resolution and consecutive frames are compared. When only a small
/// region changes (a tap dot, a toggle, a button reacting, text being typed) that region becomes a zoom.
/// Big changes (scrolling, page transitions) are left un-zoomed so the viewer keeps context.
enum AutoZoom {
    struct Event {
        let time: Double
        let u: Double   // 0…1 across the screen
        let v: Double   // 0…1 down the screen
        let area: Double
        let weight: Double
        /// A big change (scroll, page transition): zooms end here so the viewer keeps context.
        var isGlobal = false
    }

    static func analyze(url: URL, level: AutoZoomLevel, slot: Int = 0, offset: Double = 0, ramp: Double, duration: Double = .infinity) async throws -> [ZoomSegment] {
        guard level != .off else { return [] }
        let events = try await detectEvents(url: url, offset: offset)
        return segments(from: events, level: level, slot: slot, ramp: ramp, duration: duration)
    }

    // MARK: Motion detection

    /// Grid the frames are reduced to before comparing (long side 156 cells).
    private struct Grid { let w: Int; let h: Int; let ignoreTop: Double; let ignoreBottom: Double }

    /// - Parameter phone: ignore Android's status bar and gesture bar (not present on web recordings).
    static func detectEvents(url: URL, offset: Double, phone: Bool = true) async throws -> [Event] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let (range, transform, natural) = try await track.load(.timeRange, .preferredTransform, .naturalSize)
        let orientation = MediaItem.orientation(for: transform)
        let upright = natural.applying(transform)
        let landscape = abs(upright.width) > abs(upright.height)
        let grid = Grid(w: landscape ? 156 : 72, h: landscape ? 72 : 156, ignoreTop: phone ? 0.05 : 0, ignoreBottom: phone ? 0.025 : 0)

        let reader = try AVAssetReader(asset: asset)
        let start = range.start + CMTime(seconds: offset, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: start, end: range.end)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return [] }

        var events: [Event] = []
        var previous: [UInt8]?
        var lastSampled = -1.0
        let sampleInterval = 1.0 / 15.0

        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start.seconds
            guard time - lastSampled >= sampleInterval * 0.98, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            lastSampled = time
            guard let cells = lumaGrid(buffer, orientation: orientation, grid: grid) else { continue }
            defer { previous = cells }
            guard let previous else { continue }
            if let event = compare(previous, cells, time: time, grid: grid) { events.append(event) }
        }
        return events
    }

    /// Block-averaged luma, rotated upright if the video carries rotation metadata.
    private static func lumaGrid(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, grid: Grid) -> [UInt8]? {
        let gridW = grid.w, gridH = grid.h
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let rotated = orientation == .left || orientation == .right
        let gw = rotated ? gridH : gridW, gh = rotated ? gridW : gridH
        var raw = [UInt8](repeating: 0, count: gw * gh)
        let cellW = max(1, width / gw), cellH = max(1, height / gh)
        let step = max(1, min(cellW, cellH) / 3)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var sum = 0, count = 0
                var y = gy * cellH
                while y < min(height, (gy + 1) * cellH) {
                    let row = pixels + y * stride
                    var x = gx * cellW
                    while x < min(width, (gx + 1) * cellW) {
                        sum += Int(row[x]); count += 1
                        x += step
                    }
                    y += step
                }
                raw[gy * gw + gx] = UInt8(sum / max(1, count))
            }
        }
        guard orientation != .up else { return raw }
        // Rotate into an upright gridW × gridH grid.
        var out = [UInt8](repeating: 0, count: gridW * gridH)
        for y in 0..<gridH {
            for x in 0..<gridW {
                let (sx, sy): (Int, Int)
                switch orientation {
                case .right: (sx, sy) = (y, gh - 1 - x)
                case .left: (sx, sy) = (gw - 1 - y, x)
                case .down: (sx, sy) = (gw - 1 - x, gh - 1 - y)
                default: (sx, sy) = (x, y)
                }
                out[y * gridW + x] = raw[sy * gw + sx]
            }
        }
        return out
    }

    private static func compare(_ a: [UInt8], _ b: [UInt8], time: Double, grid: Grid) -> Event? {
        let gridW = grid.w, gridH = grid.h
        // Ignore the status bar (clock, notification icons) and the gesture bar on phones.
        let top = Int(Double(gridH) * grid.ignoreTop), bottom = Int(Double(gridH) * (1 - grid.ignoreBottom))
        var changed = 0
        var sumX = 0.0, sumY = 0.0, totalWeight = 0.0
        var minX = gridW, maxX = 0, minY = gridH, maxY = 0
        for y in top..<bottom {
            for x in 0..<gridW {
                let i = y * gridW + x
                let d = abs(Int(a[i]) - Int(b[i]))
                guard d > 10 else { continue }
                changed += 1
                let w = Double(d)
                sumX += Double(x) * w; sumY += Double(y) * w; totalWeight += w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let cells = Double(gridW * (bottom - top))
        let fraction = Double(changed) / cells
        guard changed >= 3 else { return nil }
        let boxArea = Double((maxX - minX + 1) * (maxY - minY + 1)) / cells
        // Large or scattered change = scrolling or a page transition.
        if fraction >= 0.22 || boxArea >= 0.30 {
            return Event(time: time, u: 0.5, v: 0.5, area: boxArea, weight: 0, isGlobal: true)
        }
        return Event(time: time,
                     u: (sumX / totalWeight + 0.5) / Double(gridW),
                     v: (sumY / totalWeight + 0.5) / Double(gridH),
                     area: boxArea, weight: totalWeight)
    }

    // MARK: Events → zooms

    static func segments(from allEvents: [Event], level: AutoZoomLevel, slot: Int, ramp: Double, duration: Double = .infinity) -> [ZoomSegment] {
        let globals = allEvents.filter(\.isGlobal).map(\.time).sorted()
        // Ignore the last few frames of a scroll or transition settling down.
        let events = allEvents.filter { e in !e.isGlobal && !globals.contains { e.time > $0 && e.time - $0 < 0.35 } }
        guard !events.isEmpty else { return [] }

        // Group events that happen close together in time and place.
        var clusters: [[Event]] = []
        for event in events.sorted(by: { $0.time < $1.time }) {
            if var last = clusters.last, let tail = last.last,
               event.time - tail.time < 1.1,
               hypot(event.u - centroid(last).u, (event.v - centroid(last).v) * 2.2) < 0.32 {
                last.append(event)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([event])
            }
        }

        // Keep clusters with real activity; drop single-frame flickers.
        let meaningful = clusters.filter { cluster in
            let span = (cluster.last?.time ?? 0) - (cluster.first?.time ?? 0)
            return cluster.count >= 2 || span > 0.2 || (cluster.first?.area ?? 0) > 0.004
        }

        var zooms: [ZoomSegment] = []
        for cluster in meaningful {
            guard let first = cluster.first, let last = cluster.last else { continue }
            let c = centroid(cluster)
            let lead = ramp + 0.15
            var start = max(0, first.time - lead)
            var end = last.time + 1.3 + ramp
            if end - start < 2.2 { end = start + 2.2 }
            // Zoom back out as soon as the screen scrolls or changes page.
            if let cut = globals.first(where: { $0 > last.time + 0.1 }), cut + 0.25 < end {
                end = max(cut + 0.25, start + 1.4)
            }
            // Don't stack zooms: extend the previous one if this starts right after it at a similar spot.
            if let previous = zooms.last, start < previous.end + 0.6 {
                let distance = hypot(previous.anchorU - c.u, (previous.anchorV - c.v) * 2.2)
                if distance < 0.35 {
                    zooms[zooms.count - 1].end = max(previous.end, end)
                    continue
                }
                // Different spot soon after: hand over directly so the camera pans across in time.
                let handover = max(previous.start + 1.0, min(previous.end, start))
                zooms[zooms.count - 1].end = handover
                start = handover
                if end - start < 1.2 { continue }
            }
            end = min(end, duration)
            if end - start < 1.2 { continue }
            // Busy, spread-out activity gets a gentler zoom.
            let spread = cluster.map(\.area).max() ?? 0
            let scale = spread > 0.12 ? 1 + (level.scale - 1) * 0.6 : level.scale
            zooms.append(ZoomSegment(start: start, end: end, scale: scale, anchorSlot: slot,
                                     anchorU: min(0.9, max(0.1, c.u)), anchorV: min(0.92, max(0.08, c.v)), isAuto: true))
        }
        return zooms
    }

    /// Stretches where nothing changes on screen, keeping a little breathing room around each action.
    static func idleSpans(from events: [Event], length: Double) -> [ClosedRange<Double>] {
        let times = events.map(\.time).filter { $0 >= 0 && $0 <= length }.sorted()
        let points = [0.0] + times + [length]
        var spans: [ClosedRange<Double>] = []
        for (a, b) in zip(points, points.dropFirst()) where b - a > 1.8 {
            let start = a + (a == 0 ? 0.5 : 1.1)     // let the result of an action sink in
            let end = b - (b == length ? 0.6 : 0.5)  // and slow down just before the next one
            if end - start > 0.5 { spans.append(start...end) }
        }
        return spans
    }

    private static func centroid(_ events: [Event]) -> (u: Double, v: Double) {
        let total = events.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return (0.5, 0.5) }
        return (events.reduce(0) { $0 + $1.u * $1.weight } / total, events.reduce(0) { $0 + $1.v * $1.weight } / total)
    }
}
