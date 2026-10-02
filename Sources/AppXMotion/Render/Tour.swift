import CoreGraphics

/// Timing for a tour: overview of all screens → fly to each screen (with a close-up on screenshots) → back out.
struct TourPlan: Equatable {
    var intro: Double
    var transition: Double
    /// When the camera arrives at each screen.
    var arrivals: [Double]
    var holds: [Double]
    var isVideo: [Bool]
    var outro: Double
    var total: Double

    /// Composition time at which each slot's video starts playing (just before the camera lands on it).
    var videoStarts: [Double] { arrivals.map { max(0, $0 - 0.25) } }

    static func make(items: [MediaItem?], offsets: [Double], timeMaps: [TimeMap?] = []) -> TourPlan {
        let intro = 1.8, transition = 1.0, outro = 2.2
        var arrivals: [Double] = [], holds: [Double] = [], isVideo: [Bool] = []
        var t = intro
        for (i, item) in items.enumerated() {
            let video = item?.isVideo == true
            var available = (item?.duration ?? 0) - (i < offsets.count ? offsets[i] : 0)
            if i < timeMaps.count, let map = timeMaps[i] { available = map.duration }
            let hold = video ? min(max(2.5, available), 10) : 3.2
            arrivals.append(t + transition)
            holds.append(hold)
            isVideo.append(video)
            t += transition + hold
        }
        return TourPlan(intro: intro, transition: transition, arrivals: arrivals, holds: holds, isVideo: isVideo,
                        outro: outro, total: t + outro)
    }
}

/// A camera position: zoom level and the canvas point (top-left origin) at the centre of the view.
struct CameraKey {
    var time: Double
    var scale: CGFloat
    var center: CGPoint
}

enum TourCamera {
    static func keys(plan: TourPlan, layout: SceneLayout) -> [CameraKey] {
        let C = CGPoint(x: layout.canvas.width / 2, y: layout.canvas.height / 2)
        var keys = [CameraKey(time: 0, scale: 1, center: C), CameraKey(time: plan.intro, scale: 1.06, center: C)]
        for (i, device) in layout.devices.enumerated() where i < plan.arrivals.count {
            let body = device.body
            let fit = min(layout.canvas.height * 0.88 / body.height, layout.canvas.width * 0.88 / body.width)
            let center = CGPoint(x: body.midX, y: body.midY)
            let arrive = plan.arrivals[i], leave = arrive + plan.holds[i]
            keys.append(CameraKey(time: arrive, scale: fit, center: center))
            if plan.isVideo[i] {
                keys.append(CameraKey(time: leave, scale: fit * 1.04, center: center))
            } else {
                // Screenshot: settle, then push in on the top half (headline / hero content), then hold.
                let detail = CGPoint(x: device.screen.midX, y: device.screen.minY + device.screen.height * 0.33)
                keys.append(CameraKey(time: arrive + plan.holds[i] * 0.3, scale: fit * 1.02, center: center))
                keys.append(CameraKey(time: arrive + plan.holds[i] * 0.75, scale: fit * 1.75, center: detail))
                keys.append(CameraKey(time: leave, scale: fit * 1.8, center: detail))
            }
        }
        keys.append(CameraKey(time: plan.total - plan.outro + plan.transition, scale: 1, center: C))
        keys.append(CameraKey(time: plan.total, scale: 1, center: C))
        return keys
    }

    /// Eased interpolation between keys. Zoom is interpolated in log space so it feels even.
    static func sample(_ keys: [CameraKey], at t: Double) -> (scale: CGFloat, center: CGPoint) {
        guard let first = keys.first else { return (1, .zero) }
        guard t > first.time else { return (first.scale, first.center) }
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.time {
            let span = max(0.0001, b.time - a.time)
            let p = CGFloat(SceneRenderer.ease((t - a.time) / span))
            let scale = exp(log(a.scale) + (log(b.scale) - log(a.scale)) * p)
            let center = CGPoint(x: a.center.x + (b.center.x - a.center.x) * p, y: a.center.y + (b.center.y - a.center.y) * p)
            return (scale, center)
        }
        let last = keys[keys.count - 1]
        return (last.scale, last.center)
    }
}
