import Foundation

/// How well a fitted mapping predicts turbidity it was not fitted to.
struct CalibrationValidation: Equatable, Sendable, Codable {
    /// Mean signed error, in NTU. Positive means the mapping reads high.
    let biasNTU: Double
    let meanAbsoluteErrorNTU: Double
    let rootMeanSquareErrorNTU: Double
    /// Worst single held-out prediction.
    let maximumAbsoluteErrorNTU: Double
    /// Per-level residuals, kept so a calibration can be inspected rather than
    /// summarised away.
    let residualsNTU: [Double]
    /// Worst per-level relative standard deviation across replicates: how much
    /// the same standard varied when measured repeatedly.
    let worstRelativeRepeatability: Double
    /// Number of held-out concentrations the figures were computed from.
    let heldOutLevels: Int

    static let empty = CalibrationValidation(
        biasNTU: 0, meanAbsoluteErrorNTU: 0, rootMeanSquareErrorNTU: 0,
        maximumAbsoluteErrorNTU: 0, residualsNTU: [],
        worstRelativeRepeatability: 0, heldOutLevels: 0
    )
}

/// How an NTU estimate's uncertainty is built.
///
/// Two independent contributions, combined in quadrature:
///
/// * **Model error** — how far the fitted curve missed concentrations it had
///   never seen, taken from the cross-validation RMSE. This is the honest
///   answer to "how wrong is the shape of this curve".
/// * **Measurement error** — the spread of repeat readings at the nearest
///   calibrated level, converted to NTU through the curve's local slope.
///
/// The certificate tolerance of the standards themselves is added as a floor:
/// a calibration can never be more certain than the standards it was made from.
///
/// Reported with a coverage factor of two, which is the usual convention for an
/// interval intended to contain the true value about 95% of the time — under
/// the assumption that these two terms are the whole story, which for a
/// screening instrument they are not.
struct UncertaintyModel: Equatable, Sendable, Codable {
    let modelErrorNTU: Double
    /// Relative spread of replicate indices, worst level.
    let relativeMeasurementSpread: Double
    /// Worst certificate tolerance among the standards used.
    let standardToleranceNTU: Double
    let coverageFactor: Double
    let version: Int

    /// Expanded uncertainty at a given index, in NTU.
    func uncertainty(atIndex index: Double, mapping: MonotonicMapping) -> Double {
        let sensitivity = abs(mapping.sensitivity(atIndex: index))
        let measurement = sensitivity * relativeMeasurementSpread * abs(index)
        let combined = (modelErrorNTU * modelErrorNTU
                        + measurement * measurement
                        + standardToleranceNTU * standardToleranceNTU).squareRoot()
        return coverageFactor * combined
    }
}

/// The result of fitting one candidate mapping.
struct CalibrationCandidate: Equatable, Sendable {
    let mapping: MonotonicMapping
    let validation: CalibrationValidation
    /// Lower is better. The cross-validated RMSE, which is what actually
    /// matters: a curve is useful only for concentrations it has not seen.
    var score: Double { validation.rootMeanSquareErrorNTU }
}

/// Fits and selects a calibration curve.
///
/// Selection is by **leave-one-concentration-out** cross validation, not by fit
/// quality. Fit quality measures how well a curve reproduces the points it was
/// built from, which every candidate here does almost perfectly and which
/// predicts nothing. Holding out a whole concentration — every replicate of it
/// — and asking the remaining curve to predict it is the only question worth
/// asking of a calibration.
struct CalibrationFitter: Sendable {

    struct Requirements: Equatable, Sendable, Codable {
        var minimumNonZeroStandards: Int
        var minimumReplicatesPerLevel: Int
        /// Two levels are indistinguishable when their mean indices are closer
        /// than this many replicate standard deviations.
        var minimumLevelSeparationSigmas: Double
        var version: Int

        static let screening = Requirements(
            minimumNonZeroStandards: 4,
            minimumReplicatesPerLevel: 3,
            minimumLevelSeparationSigmas: 3.0,
            version: 1
        )
    }

    struct Outcome: Equatable, Sendable {
        let candidate: CalibrationCandidate?
        let rejectedCandidates: [String]
        let problems: [CalibrationDataProblem]
        let uncertainty: UncertaintyModel?
        /// The index range the standards actually covered. Nothing outside it
        /// has been validated, and nothing outside it will be reported.
        let validatedIndexRange: ClosedRange<Double>?
        let validatedNTURange: ClosedRange<Double>?
    }

    let requirements: Requirements

    init(requirements: Requirements = .screening) {
        self.requirements = requirements
    }

    func fit(levels: [CalibrationLevel], asOf date: Date) -> Outcome {
        let problems = validate(levels: levels, asOf: date)
        guard problems.isEmpty else {
            return Outcome(candidate: nil, rejectedCandidates: [], problems: problems,
                           uncertainty: nil, validatedIndexRange: nil, validatedNTURange: nil)
        }

        let sorted = levels.sorted { $0.standard.nominalNTU < $1.standard.nominalNTU }
        let points = sorted.map {
            MonotonicMapping.Knot(x: $0.meanIndex, y: $0.standard.nominalNTU)
        }

        var candidates: [CalibrationCandidate] = []
        var rejected: [String] = []

        for builder in Self.builders {
            guard let mapping = builder.build(points) else {
                rejected.append("\(builder.name): could not be fitted to these points")
                continue
            }
            let range = (points.first?.x ?? 0)...(points.last?.x ?? 1)
            guard mapping.isMonotoneIncreasing(over: range) else {
                rejected.append("\(builder.name): fitted curve was not monotone")
                continue
            }
            let validation = crossValidate(builder: builder, levels: sorted)
            guard validation.heldOutLevels > 0 else {
                rejected.append("\(builder.name): could not be cross validated")
                continue
            }
            candidates.append(CalibrationCandidate(mapping: mapping, validation: validation))
        }

        // Ties broken by name so the same data always yields the same choice.
        let best = candidates.min {
            $0.score == $1.score ? $0.mapping.name < $1.mapping.name : $0.score < $1.score
        }
        guard let best else {
            return Outcome(candidate: nil, rejectedCandidates: rejected,
                           problems: [.notMonotonic], uncertainty: nil,
                           validatedIndexRange: nil, validatedNTURange: nil)
        }

        for candidate in candidates where candidate.mapping.name != best.mapping.name {
            rejected.append(String(format: "%@: cross-validated RMSE %.3f NTU",
                                   candidate.mapping.name, candidate.score))
        }

        let uncertainty = UncertaintyModel(
            modelErrorNTU: best.validation.rootMeanSquareErrorNTU,
            relativeMeasurementSpread: best.validation.worstRelativeRepeatability,
            standardToleranceNTU: sorted.map(\.standard.toleranceNTU).max() ?? 0,
            coverageFactor: 2,
            version: 1
        )

        let indexRange = (points.first?.x ?? 0)...(points.last?.x ?? 0)
        let ntuRange = (sorted.first?.standard.nominalNTU ?? 0)...(sorted.last?.standard.nominalNTU ?? 0)

        return Outcome(candidate: best, rejectedCandidates: rejected, problems: [],
                       uncertainty: uncertainty,
                       validatedIndexRange: indexRange, validatedNTURange: ntuRange)
    }

    // MARK: - Validation of the data itself

    func validate(levels: [CalibrationLevel], asOf date: Date) -> [CalibrationDataProblem] {
        var problems: [CalibrationDataProblem] = []

        let usable = levels.filter { $0.usableReplicates.count >= requirements.minimumReplicatesPerLevel }
        if !levels.contains(where: { $0.standard.isBlank }) {
            problems.append(.noBlank)
        }
        if usable.filter({ !$0.standard.isBlank }).count < requirements.minimumNonZeroStandards {
            problems.append(.tooFewNonZeroStandards)
        }
        if usable.count < levels.count {
            problems.append(.tooFewReplicates)
        }
        if levels.contains(where: { $0.standard.isExpired(asOf: date) }) {
            problems.append(.expiredStandard)
        }

        let sorted = levels.sorted { $0.standard.nominalNTU < $1.standard.nominalNTU }
        for index in 1..<max(1, sorted.count) where sorted[index].meanIndex <= sorted[index - 1].meanIndex {
            problems.append(.notMonotonic)
            break
        }

        for index in 1..<max(1, sorted.count) {
            let gap = sorted[index].meanIndex - sorted[index - 1].meanIndex
            let noise = max(sorted[index].indexStandardDeviation,
                            sorted[index - 1].indexStandardDeviation)
            if noise > 0, gap < noise * requirements.minimumLevelSeparationSigmas {
                problems.append(.indistinguishableLevels)
                break
            }
        }

        return problems
    }

    // MARK: - Cross validation

    /// Leave one concentration out: fit on the others, predict the one held
    /// back, repeat.
    private func crossValidate(builder: Builder, levels: [CalibrationLevel]) -> CalibrationValidation {
        var residuals: [Double] = []

        for heldOut in levels.indices {
            let remaining = levels.enumerated()
                .filter { $0.offset != heldOut }
                .map { MonotonicMapping.Knot(x: $0.element.meanIndex,
                                             y: $0.element.standard.nominalNTU) }
            guard let mapping = builder.build(remaining) else { continue }

            let level = levels[heldOut]
            // Only interpolation is a fair test. Predicting an end point from a
            // curve that never saw it is extrapolation, which the mapping
            // clamps, and scoring a clamped value would flatter every
            // candidate equally and mean nothing.
            guard let lowest = remaining.first?.x, let highest = remaining.last?.x,
                  level.meanIndex > lowest, level.meanIndex < highest else { continue }

            residuals.append(mapping.ntu(forIndex: level.meanIndex) - level.standard.nominalNTU)
        }

        guard !residuals.isEmpty else { return .empty }

        let n = Double(residuals.count)
        let bias = residuals.reduce(0, +) / n
        let absolute = residuals.map(abs)
        let squared = residuals.reduce(0) { $0 + $1 * $1 } / n

        return CalibrationValidation(
            biasNTU: bias,
            meanAbsoluteErrorNTU: absolute.reduce(0, +) / n,
            rootMeanSquareErrorNTU: squared.squareRoot(),
            maximumAbsoluteErrorNTU: absolute.max() ?? 0,
            residualsNTU: residuals,
            worstRelativeRepeatability: levels.map(\.relativeStandardDeviation).max() ?? 0,
            heldOutLevels: residuals.count
        )
    }

    // MARK: - Candidates

    struct Builder {
        let name: String
        let build: ([MonotonicMapping.Knot]) -> MonotonicMapping?
    }

    /// The candidate set, in a fixed order so fitting is deterministic.
    ///
    /// Piecewise linear rarely wins, and that is expected rather than a
    /// problem: a monotone cubic through collinear points *is* the straight
    /// line, so it reproduces the linear fit exactly and takes the tie. It is
    /// kept as the simplest candidate and as a guard for a point set too small
    /// for a cubic.
    static let builders: [Builder] = [
        Builder(name: "piecewise linear", build: MonotonicMapping.piecewiseLinear(through:)),
        Builder(name: "monotone cubic", build: MonotonicMapping.monotoneCubic(through:)),
        Builder(name: "power law", build: MonotonicMapping.powerLaw(through:))
    ]
}
