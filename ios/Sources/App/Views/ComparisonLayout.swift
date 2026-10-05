import CoreGraphics

/// Sizes the two comparison cards so each photo is shown whole (never cropped).
/// Cards are sized to their photo's aspect ratio rather than a fixed frame, and
/// the pair is arranged to give the photos as much room as the screen allows.
enum ComparisonLayout {
    enum Arrangement: Equatable {
        case stacked
        case sideBySide
    }

    struct Result: Equatable {
        var arrangement: Arrangement
        var sizeA: CGSize
        var sizeB: CGSize
    }

    /// Used until a photo's real dimensions are known (matches most phone cameras).
    static let placeholderAspect: CGFloat = 4 / 3

    /// Side by side has to beat stacked by this factor (on the smaller photo's
    /// area) to be chosen, so the pair doesn't flip arrangement for marginal gains.
    static let sideBySideAdvantage: CGFloat = 1.25

    /// - Parameters:
    ///   - aspectA/aspectB: width / height of each photo.
    ///   - available: the area the pair may occupy.
    static func layout(
        aspectA: CGFloat,
        aspectB: CGFloat,
        in available: CGSize,
        spacing: CGFloat
    ) -> Result {
        let a = sanitized(aspectA)
        let b = sanitized(aspectB)
        let width = max(0, available.width)
        let height = max(0, available.height)

        let stacked = stackedSizes(a, b, width: width, height: height, spacing: spacing)
        let sideBySide = sideBySideSizes(a, b, width: width, height: height, spacing: spacing)

        if smallerArea(sideBySide) >= smallerArea(stacked) * sideBySideAdvantage {
            return Result(arrangement: .sideBySide, sizeA: sideBySide.0, sizeB: sideBySide.1)
        }
        return Result(arrangement: .stacked, sizeA: stacked.0, sizeB: stacked.1)
    }

    static func aspect(of size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return placeholderAspect }
        return size.width / size.height
    }

    // MARK: - Private

    private static func sanitized(_ aspect: CGFloat) -> CGFloat {
        aspect.isFinite && aspect > 0 ? aspect : placeholderAspect
    }

    private static func smallerArea(_ sizes: (CGSize, CGSize)) -> CGFloat {
        min(sizes.0.width * sizes.0.height, sizes.1.width * sizes.1.height)
    }

    /// Both photos at full width if they fit; otherwise the height budget is
    /// shared by water-filling so a short (wide) photo keeps its natural height
    /// and a taller one takes the rest, or both get an equal height.
    private static func stackedSizes(
        _ a: CGFloat, _ b: CGFloat, width: CGFloat, height: CGFloat, spacing: CGFloat
    ) -> (CGSize, CGSize) {
        let budget = max(0, height - spacing)
        let naturalA = width / a
        let naturalB = width / b

        var heightA = naturalA
        var heightB = naturalB
        if naturalA + naturalB > budget {
            let shorter = min(naturalA, naturalB)
            if shorter * 2 <= budget {
                // The shorter photo stays at natural height; the other takes the remainder.
                if naturalA <= naturalB {
                    heightB = budget - naturalA
                } else {
                    heightA = budget - naturalB
                }
            } else {
                heightA = budget / 2
                heightB = budget / 2
            }
        }
        return (
            CGSize(width: min(width, heightA * a), height: heightA),
            CGSize(width: min(width, heightB * b), height: heightB)
        )
    }

    private static func sideBySideSizes(
        _ a: CGFloat, _ b: CGFloat, width: CGFloat, height: CGFloat, spacing: CGFloat
    ) -> (CGSize, CGSize) {
        let column = max(0, (width - spacing) / 2)
        return (fit(aspect: a, width: column, height: height), fit(aspect: b, width: column, height: height))
    }

    private static func fit(aspect: CGFloat, width: CGFloat, height: CGFloat) -> CGSize {
        let fittedHeight = min(height, width / aspect)
        return CGSize(width: fittedHeight * aspect, height: fittedHeight)
    }
}
