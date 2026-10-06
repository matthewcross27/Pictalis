import XCTest
@testable import Pictalis

final class RankingStageTests: XCTestCase {

    func testServerStageStringsMapToTheirLabels() {
        // These raw values are what next-pair / results return in `stage`.
        XCTAssertEqual(RankingStage(rawValue: "cull")?.label, "Cull")
        XCTAssertEqual(RankingStage(rawValue: "ranking")?.label, "Ranking")
        XCTAssertEqual(RankingStage(rawValue: "complete")?.label, "Complete")
    }

    func testUnknownServerStageHasNoBadge() {
        XCTAssertNil(RankingStage(rawValue: "stage1"))
        XCTAssertNil(RankingStage(rawValue: ""))
    }
}
