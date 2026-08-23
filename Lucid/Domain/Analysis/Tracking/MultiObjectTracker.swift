import CoreGraphics
import Foundation

/// Associates detections with tracks, frame by frame.
///
/// One bounded custom tracker rather than a Vision object-tracking request per
/// speck: a frame can hold dozens of candidates, and a per-object Vision
/// request each would cost orders of magnitude more than the entire rest of the
/// pipeline while adding nothing — these are two-pixel dots, not objects with
/// appearance worth modelling.
final class MultiObjectTracker {

    struct Configuration: Equatable, Sendable, Codable {
        var maximumTracks: Int
        var observationCapacity: Int
        /// Sightings before a track is believed. Above one, so a single noise
        /// detection can never be counted.
        var confirmAfterObservations: Int
        /// Consecutive misses before a track is dropped. Above one, so a speck
        /// that dims for a frame or passes behind a bubble is not restarted as
        /// a new track and counted twice.
        var dropAfterMissedFrames: Int
        /// Association gate, as a fraction of the region diagonal per second.
        /// Expressed as a rate so the gate widens correctly when a frame is
        /// dropped and the time step doubles.
        var gateSpeedFraction: Double
        /// Floor on the gate, in region pixels, so a very short time step still
        /// admits the measurement noise.
        var minimumGatePixels: Double
        /// Weights for the association cost. Position dominates; size and
        /// brightness break ties when two tracks cross.
        var sizeCostWeight: Double
        var brightnessCostWeight: Double
        var processNoise: Double
        var measurementNoise: Double
        var version: Int

        static let screening = Configuration(
            maximumTracks: 256,
            observationCapacity: 32,
            confirmAfterObservations: 4,
            dropAfterMissedFrames: 4,
            gateSpeedFraction: 0.30,
            minimumGatePixels: 3.0,
            sizeCostWeight: 0.35,
            brightnessCostWeight: 0.20,
            processNoise: 400,
            measurementNoise: 1.0,
            version: 1
        )
    }

    let configuration: Configuration
    private(set) var tracks: [Track] = []
    private var nextIdentifier = 1
    private var lastTimestamp: Double?
    private var regionDiagonal: Double = 1
    /// Counted rather than silently forgotten: a run that hit the cap is a run
    /// whose counts are a lower bound.
    private(set) var droppedForCapacity = 0

    init(configuration: Configuration = .screening) {
        self.configuration = configuration
    }

    func prepare(regionWidth: Int, regionHeight: Int) {
        regionDiagonal = max(1, Double(regionWidth * regionWidth
                                       + regionHeight * regionHeight).squareRoot())
    }

    func reset() {
        tracks.removeAll(keepingCapacity: true)
        nextIdentifier = 1
        lastTimestamp = nil
        droppedForCapacity = 0
    }

    /// Folds one frame of candidates into the track set.
    ///
    /// - Parameter motion: accumulated scene displacement. Subtracting it puts
    ///   every detection into a stabilised frame in which a stationary object
    ///   stays still, so a track's residual motion is the object's own. An
    ///   untrustworthy estimate is not subtracted at all — compensating with a
    ///   wrong vector is worse than not compensating.
    @discardableResult
    func update(candidates: [SpeckCandidate],
                timestampSeconds: Double,
                motion: GlobalMotion) -> [Track] {
        let offset = motion.isTrustworthy ? motion.cumulativeOffset : .zero
        let dt = lastTimestamp.map { max(0, timestampSeconds - $0) } ?? 0
        lastTimestamp = timestampSeconds

        let observations = candidates.map { candidate in
            TrackObservation(
                timestampSeconds: timestampSeconds,
                position: CGPoint(x: candidate.centroidX - Double(offset.dx),
                                  y: candidate.centroidY - Double(offset.dy)),
                rawPosition: CGPoint(x: candidate.centroidX, y: candidate.centroidY),
                areaPixels: candidate.areaPixels,
                normalizedDiameter: candidate.normalizedDiameter,
                peakResponse: candidate.peakResponse,
                eccentricity: candidate.eccentricity
            )
        }

        let gate = max(configuration.minimumGatePixels,
                       configuration.gateSpeedFraction * regionDiagonal * max(dt, 1.0 / 60.0))

        var assignedObservations = Set<Int>()
        var assignedTracks = Set<Int>()

        // Every legal (track, detection) pair, cheapest first. Taking them in
        // that order and marking both sides used is what stops one detection
        // from updating two tracks, and is why two crossing specks keep their
        // own identities: at the crossing the cheaper pairing is the one whose
        // predicted position and size agree.
        var pairs: [(cost: Double, track: Int, observation: Int)] = []
        pairs.reserveCapacity(tracks.count * max(1, observations.count))

        for (trackIndex, track) in tracks.enumerated() where track.state != .rejected {
            let predicted = track.predictedPosition(at: timestampSeconds)
            for (observationIndex, observation) in observations.enumerated() {
                let dx = Double(observation.position.x - predicted.x)
                let dy = Double(observation.position.y - predicted.y)
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance <= gate else { continue }

                pairs.append((
                    cost: cost(distance: distance, gate: gate, track: track, observation: observation),
                    track: trackIndex,
                    observation: observationIndex
                ))
            }
        }
        pairs.sort { $0.cost < $1.cost }

        for pair in pairs {
            guard !assignedTracks.contains(pair.track),
                  !assignedObservations.contains(pair.observation) else { continue }
            assignedTracks.insert(pair.track)
            assignedObservations.insert(pair.observation)
            tracks[pair.track].accept(observations[pair.observation],
                                      confirmAfter: configuration.confirmAfterObservations)
        }

        for index in tracks.indices where !assignedTracks.contains(index) {
            guard tracks[index].state != .rejected else { continue }
            tracks[index].miss(at: timestampSeconds,
                               dropAfter: configuration.dropAfterMissedFrames)
        }

        for (index, observation) in observations.enumerated() where !assignedObservations.contains(index) {
            guard tracks.count < configuration.maximumTracks else {
                droppedForCapacity += 1
                continue
            }
            tracks.append(Track(id: nextIdentifier,
                                observation: observation,
                                capacity: configuration.observationCapacity,
                                processNoise: configuration.processNoise,
                                measurementNoise: configuration.measurementNoise))
            nextIdentifier += 1
        }

        // A rejected track is one that never earned confirmation; a lost one is
        // kept, because it is the record of something that was counted.
        tracks.removeAll { $0.state == .rejected }
        return tracks
    }

    /// Position dominates; size and brightness only separate candidates the
    /// predicted position cannot.
    private func cost(distance: Double,
                      gate: Double,
                      track: Track,
                      observation: TrackObservation) -> Double {
        var total = distance / gate

        let trackDiameter = track.medianDiameter
        if trackDiameter > 0, observation.normalizedDiameter > 0 {
            let ratio = observation.normalizedDiameter / trackDiameter
            total += configuration.sizeCostWeight * abs(log(ratio))
        }

        let trackBrightness = track.medianPeakResponse
        if trackBrightness > 0 {
            let difference = abs(Double(observation.peakResponse) - trackBrightness) / trackBrightness
            total += configuration.brightnessCostWeight * min(difference, 4)
        }

        return total
    }

    /// Applies a classifier to every confirmed track.
    func classifyAll(using classifier: TrackClassifier, gravity: GravityReference) {
        for index in tracks.indices {
            guard tracks[index].state.isCountable else { continue }
            let verdict = classifier.classify(tracks[index],
                                              regionDiagonal: regionDiagonal,
                                              gravity: gravity)
            tracks[index].classify(as: verdict.classification, confidence: verdict.confidence)
        }
    }
}
