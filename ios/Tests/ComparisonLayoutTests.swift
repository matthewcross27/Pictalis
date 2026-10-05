import XCTest
@testable import Pictalis

final class ComparisonLayoutTests: XCTestCase {
    // Roughly an iPhone 17 Pro: the area left for the pair above the bottom bar.
    private let phone = CGSize(width: 374, height: 600)
    private let spacing: CGFloat = 8
    private let accuracy: CGFloat = 0.001

    private func aspect(of size: CGSize) -> CGFloat { size.width / size.height }

    private func assertFits(_ result: ComparisonLayout.Result, in area: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        switch result.arrangement {
        case .stacked:
            XCTAssertLessThanOrEqual(result.sizeA.height + result.sizeB.height + spacing, area.height + accuracy, file: file, line: line)
            XCTAssertLessThanOrEqual(max(result.sizeA.width, result.sizeB.width), area.width + accuracy, file: file, line: line)
        case .sideBySide:
            XCTAssertLessThanOrEqual(result.sizeA.width + result.sizeB.width + spacing, area.width + accuracy, file: file, line: line)
            XCTAssertLessThanOrEqual(max(result.sizeA.height, result.sizeB.height), area.height + accuracy, file: file, line: line)
        }
    }

    func testHorizontalPhotosAreShownUncroppedAtFullWidth() {
        // 3:2 is the regression case: the old fixed 4:3 frame cropped it.
        let result = ComparisonLayout.layout(aspectA: 3 / 2, aspectB: 3 / 2, in: phone, spacing: spacing)
        XCTAssertEqual(result.arrangement, .stacked)
        XCTAssertEqual(result.sizeA.width, phone.width, accuracy: accuracy)
        XCTAssertEqual(aspect(of: result.sizeA), 3 / 2, accuracy: accuracy)
        XCTAssertEqual(aspect(of: result.sizeB), 3 / 2, accuracy: accuracy)
        assertFits(result, in: phone)
    }

    func testCardAspectAlwaysMatchesPhotoAspect() {
        let aspects: [CGFloat] = [16 / 9, 3 / 2, 4 / 3, 1, 3 / 4, 2 / 3, 9 / 16]
        for a in aspects {
            for b in aspects {
                let result = ComparisonLayout.layout(aspectA: a, aspectB: b, in: phone, spacing: spacing)
                XCTAssertEqual(aspect(of: result.sizeA), a, accuracy: accuracy, "A \(a) vs \(b)")
                XCTAssertEqual(aspect(of: result.sizeB), b, accuracy: accuracy, "B \(a) vs \(b)")
                assertFits(result, in: phone)
            }
        }
    }

    func testMixedHorizontalAndVerticalKeepsHorizontalWideAndGivesVerticalTheRest() {
        let result = ComparisonLayout.layout(aspectA: 3 / 2, aspectB: 3 / 4, in: phone, spacing: spacing)
        XCTAssertEqual(result.arrangement, .stacked)
        // The horizontal photo keeps full width; the vertical one takes the remaining height.
        XCTAssertEqual(result.sizeA.width, phone.width, accuracy: accuracy)
        XCTAssertEqual(result.sizeB.height, phone.height - spacing - result.sizeA.height, accuracy: accuracy)
        assertFits(result, in: phone)
    }

    func testTwoVerticalPhotosShareHeightEqually() {
        let result = ComparisonLayout.layout(aspectA: 3 / 4, aspectB: 3 / 4, in: phone, spacing: spacing)
        XCTAssertEqual(result.arrangement, .stacked)
        XCTAssertEqual(result.sizeA.height, (phone.height - spacing) / 2, accuracy: accuracy)
        XCTAssertEqual(result.sizeA, result.sizeB)
    }

    func testSquarePhotosAreSquare() {
        let result = ComparisonLayout.layout(aspectA: 1, aspectB: 1, in: phone, spacing: spacing)
        XCTAssertEqual(result.sizeA.width, result.sizeA.height, accuracy: accuracy)
        XCTAssertEqual(result.sizeB.width, result.sizeB.height, accuracy: accuracy)
        assertFits(result, in: phone)
    }

    func testVeryTallPhotosOnShortScreenGoSideBySide() {
        let small = CGSize(width: 359, height: 480)
        let result = ComparisonLayout.layout(aspectA: 9 / 16, aspectB: 9 / 16, in: small, spacing: spacing)
        XCTAssertEqual(result.arrangement, .sideBySide)
        assertFits(result, in: small)
    }

    func testStackedIsKeptWhenSideBySideGainIsMarginal() {
        // Two 9:16 photos on a tall screen are within 25% of each other either way.
        let result = ComparisonLayout.layout(aspectA: 9 / 16, aspectB: 9 / 16, in: phone, spacing: spacing)
        XCTAssertEqual(result.arrangement, .stacked)
    }

    func testInvalidAspectFallsBackToPlaceholder() {
        for bad: CGFloat in [0, -1, .nan, .infinity] {
            let result = ComparisonLayout.layout(aspectA: bad, aspectB: bad, in: phone, spacing: spacing)
            XCTAssertEqual(aspect(of: result.sizeA), ComparisonLayout.placeholderAspect, accuracy: accuracy)
        }
    }

    func testZeroAvailableSpaceDoesNotProduceNegativeOrNaNSizes() {
        let result = ComparisonLayout.layout(aspectA: 3 / 2, aspectB: 3 / 4, in: .zero, spacing: spacing)
        for size in [result.sizeA, result.sizeB] {
            XCTAssertGreaterThanOrEqual(size.width, 0)
            XCTAssertGreaterThanOrEqual(size.height, 0)
            XCTAssertFalse(size.width.isNaN || size.height.isNaN)
        }
    }

    func testAspectOfSize() {
        XCTAssertEqual(ComparisonLayout.aspect(of: CGSize(width: 1920, height: 1280)), 1.5, accuracy: accuracy)
        XCTAssertEqual(ComparisonLayout.aspect(of: .zero), ComparisonLayout.placeholderAspect)
    }
}
