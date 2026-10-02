import Foundation

/// How a clip's own time maps onto the output timeline: a list of pieces, each played at its own rate.
/// Used for the global speed setting and for speeding up pauses.
struct TimeMap: Equatable {
    struct Piece: Equatable {
        var start: Double   // clip time
        var end: Double     // clip time
        var rate: Double    // 2 = twice as fast

        var length: Double { end - start }
        var output: Double { length / rate }
    }

    var pieces: [Piece]

    /// Length of the clip it covers.
    var sourceLength: Double { pieces.last?.end ?? 0 }
    /// Length on the output timeline.
    var duration: Double { pieces.reduce(0) { $0 + $1.output } }
    var isIdentity: Bool { pieces.allSatisfy { abs($0.rate - 1) < 0.001 } }

    /// - Parameters:
    ///   - idle: clip-time ranges where nothing happens; played `idleBoost` times faster on top of `speed`.
    static func make(length: Double, speed: Double, idle: [ClosedRange<Double>] = [], idleBoost: Double = 4) -> TimeMap {
        let speed = max(0.1, speed)
        var pieces: [Piece] = []
        var cursor = 0.0
        for span in idle.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let a = max(cursor, span.lowerBound), b = min(length, span.upperBound)
            guard b - a > 0.3 else { continue }
            if a > cursor { pieces.append(Piece(start: cursor, end: a, rate: speed)) }
            pieces.append(Piece(start: a, end: b, rate: speed * idleBoost))
            cursor = b
        }
        if length > cursor { pieces.append(Piece(start: cursor, end: length, rate: speed)) }
        return TimeMap(pieces: pieces)
    }

    /// Output time for a moment in the clip.
    func output(at source: Double) -> Double {
        var out = 0.0
        for p in pieces {
            if source <= p.end { return out + max(0, source - p.start) / p.rate }
            out += p.output
        }
        return out
    }

    /// Clip time shown at an output moment.
    func source(at output: Double) -> Double {
        var acc = 0.0
        for p in pieces {
            if output <= acc + p.output { return p.start + max(0, output - acc) * p.rate }
            acc += p.output
        }
        return sourceLength
    }
}
