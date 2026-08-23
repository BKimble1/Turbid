import CoreGraphics
import Foundation

/// Where a track is in its life.
enum TrackState: String, Equatable, Sendable, CaseIterable {
    /// Seen too few times to be believed yet.
    case tentative
    /// Seen enough times to be counted.
    case confirmed
    /// Missing for too long; kept briefly so a re-appearance can be joined.
    case lost
    /// Ruled out and never counted.
    case rejected

    var isCountable: Bool { self == .confirmed }
}

/// What a track appears to be.
///
/// Air bubbles and suspended particles overlap in appearance and no separation
/// is perfect, which is why `ambiguous` exists and carries its own count rather
/// than being folded into either side.
enum TrackClassification: String, Equatable, Sendable, CaseIterable {
    case unclassified
    /// Barely moves after compensation: a scratch, a stuck bubble, a fixed
    /// reflection the background model has not yet absorbed.
    case staticDefect
    /// Larger, faster, persistently along the up direction, and travelling in
    /// a near-straight line.
    case risingBubble
    /// Small, slow after compensation, persistent, and following a curved or
    /// locally coherent path rather than a ballistic one.
    case suspendedSpeck
    /// The evidence did not separate the classes. Counted separately and never
    /// silently folded into the speck count.
    case ambiguous
}

/// One sighting on a track.
struct TrackObservation: Equatable, Sendable {
    let timestampSeconds: Double
    /// Motion-compensated position, in region pixels.
    let position: CGPoint
    /// Position as measured, before compensation.
    let rawPosition: CGPoint
    let areaPixels: Int
    let normalizedDiameter: Double
    let peakResponse: Float
    let eccentricity: Double
}

/// A tracked bright event over time.
///
/// The observation history is a bounded ring: a track that survives a whole
/// nine-second window would otherwise accumulate hundreds of samples, and every
/// feature below is computed from the recent past anyway.
struct Track: Identifiable, Equatable, Sendable {
    let id: Int
    private(set) var state: TrackState
    private(set) var classification: TrackClassification
    private(set) var classificationConfidence: Double

    private(set) var observations: [TrackObservation]
    private let capacity: Int

    private(set) var filterX: ConstantVelocityAxisFilter
    private(set) var filterY: ConstantVelocityAxisFilter

    private(set) var missedFrames = 0
    /// Total sightings, which keeps counting after the ring starts discarding.
    private(set) var totalObservations = 1
    private(set) var firstTimestamp: Double
    private(set) var lastTimestamp: Double

    init(id: Int,
         observation: TrackObservation,
         capacity: Int,
         processNoise: Double,
         measurementNoise: Double) {
        self.id = id
        self.state = .tentative
        self.classification = .unclassified
        self.classificationConfidence = 0
        self.capacity = max(2, capacity)
        self.observations = [observation]
        self.observations.reserveCapacity(self.capacity)
        self.filterX = ConstantVelocityAxisFilter(position: Double(observation.position.x),
                                                  processNoise: processNoise,
                                                  measurementNoise: measurementNoise)
        self.filterY = ConstantVelocityAxisFilter(position: Double(observation.position.y),
                                                  processNoise: processNoise,
                                                  measurementNoise: measurementNoise)
        self.firstTimestamp = observation.timestampSeconds
        self.lastTimestamp = observation.timestampSeconds
    }

    /// Where the track is expected to be at `timestampSeconds`.
    func predictedPosition(at timestampSeconds: Double) -> CGPoint {
        let dt = max(0, timestampSeconds - lastTimestamp)
        return CGPoint(x: filterX.predictedPosition(after: dt),
                       y: filterY.predictedPosition(after: dt))
    }

    mutating func accept(_ observation: TrackObservation, confirmAfter: Int) {
        let dt = observation.timestampSeconds - lastTimestamp
        if dt > 0 {
            filterX.predict(seconds: dt)
            filterY.predict(seconds: dt)
        }
        filterX.update(measurement: Double(observation.position.x))
        filterY.update(measurement: Double(observation.position.y))

        if observations.count == capacity {
            observations.removeFirst()
        }
        observations.append(observation)
        totalObservations += 1
        lastTimestamp = observation.timestampSeconds
        missedFrames = 0

        if state == .tentative && totalObservations >= confirmAfter {
            state = .confirmed
        } else if state == .lost {
            state = .confirmed
        }
    }

    mutating func miss(at timestampSeconds: Double, dropAfter: Int) {
        missedFrames += 1
        if missedFrames >= dropAfter {
            state = state == .tentative ? .rejected : .lost
        }
    }

    mutating func classify(as classification: TrackClassification, confidence: Double) {
        self.classification = classification
        self.classificationConfidence = confidence
    }

    // MARK: - Features

    /// Velocity from the filter, in region pixels per second.
    var velocity: CGVector {
        CGVector(dx: filterX.velocity, dy: filterY.velocity)
    }

    var speedPixelsPerSecond: Double {
        (filterX.velocity * filterX.velocity + filterY.velocity * filterY.velocity).squareRoot()
    }

    /// Median of the step speeds over the retained history.
    ///
    /// Preferred to the filter's velocity for classification because it is
    /// robust: one bad association cannot drag it, and it needs no assumption
    /// about how well the filter has converged.
    var medianStepSpeed: Double {
        guard observations.count >= 2 else { return 0 }
        var speeds: [Double] = []
        speeds.reserveCapacity(observations.count - 1)
        for index in 1..<observations.count {
            let dt = observations[index].timestampSeconds - observations[index - 1].timestampSeconds
            guard dt > 0 else { continue }
            let dx = Double(observations[index].position.x - observations[index - 1].position.x)
            let dy = Double(observations[index].position.y - observations[index - 1].position.y)
            speeds.append((dx * dx + dy * dy).squareRoot() / dt)
        }
        guard !speeds.isEmpty else { return 0 }
        speeds.sort()
        return speeds[speeds.count / 2]
    }

    /// Net displacement divided by distance travelled, `0...1`.
    ///
    /// `1` is a straight line, which is what a rising bubble draws. A speck
    /// carried by convection curves and doubles back, so it scores lower. This
    /// is the feature that separates the two when their speeds overlap.
    var straightness: Double {
        guard observations.count >= 3 else { return 0 }
        var pathLength: Double = 0
        for index in 1..<observations.count {
            let dx = Double(observations[index].position.x - observations[index - 1].position.x)
            let dy = Double(observations[index].position.y - observations[index - 1].position.y)
            pathLength += (dx * dx + dy * dy).squareRoot()
        }
        guard pathLength > 0, let first = observations.first, let last = observations.last else { return 0 }
        let netX = Double(last.position.x - first.position.x)
        let netY = Double(last.position.y - first.position.y)
        return min(1, (netX * netX + netY * netY).squareRoot() / pathLength)
    }

    /// How consistently the motion runs along `up`, from `-1` to `1`.
    func upwardConsistency(up: CGVector) -> Double {
        guard observations.count >= 2 else { return 0 }
        var alongUp: Double = 0
        var total: Double = 0
        for index in 1..<observations.count {
            let dx = Double(observations[index].position.x - observations[index - 1].position.x)
            let dy = Double(observations[index].position.y - observations[index - 1].position.y)
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { continue }
            alongUp += dx * Double(up.dx) + dy * Double(up.dy)
            total += length
        }
        guard total > 0 else { return 0 }
        return max(-1, min(1, alongUp / total))
    }

    var medianDiameter: Double { median(observations.map(\.normalizedDiameter)) }
    var medianEccentricity: Double { median(observations.map(\.eccentricity)) }
    var medianPeakResponse: Double { median(observations.map { Double($0.peakResponse) }) }

    var durationSeconds: Double { max(0, lastTimestamp - firstTimestamp) }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
