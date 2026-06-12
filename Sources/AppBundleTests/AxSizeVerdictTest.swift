@testable import AppBundle
import XCTest

final class AxSizeVerdictTest: XCTestCase {
    func testAppliedWithinTolerance() {
        XCTAssertEqual(
            axSizeVerdict(requested: CGSize(width: 1690, height: 1064), actual: CGSize(width: 1690, height: 1064), lastRefusedSize: nil),
            .applied,
        )
        // Terminal-style character grid snapping stays within tolerance
        XCTAssertEqual(
            axSizeVerdict(requested: CGSize(width: 800, height: 600), actual: CGSize(width: 793, height: 589), lastRefusedSize: nil),
            .applied,
        )
        // Deviation of exactly the tolerance still counts as applied
        XCTAssertEqual(
            axSizeVerdict(requested: CGSize(width: 820, height: 600), actual: CGSize(width: 800, height: 600), lastRefusedSize: nil),
            .applied,
        )
    }

    func testStuckWidthPerturbsHeight() {
        // The window keeps its width, the height is applied. Unstick by nudging the height while
        // keeping the refused width at its current value
        XCTAssertEqual(
            axSizeVerdict(requested: CGSize(width: 1690, height: 1064), actual: CGSize(width: 1278, height: 1068), lastRefusedSize: nil),
            .stuck(perturbation: CGSize(width: 1278, height: 1018)),
        )
    }

    func testStuckHeightPerturbsWidth() {
        XCTAssertEqual(
            axSizeVerdict(requested: CGSize(width: 1000, height: 500), actual: CGSize(width: 1004, height: 800), lastRefusedSize: nil),
            .stuck(perturbation: CGSize(width: 954, height: 800)),
        )
    }

    func testBothStuckPerturbsHeight() {
        XCTAssertEqual(
            axSizeVerdict(requested: CGSize(width: 1690, height: 1064), actual: CGSize(width: 1278, height: 1404), lastRefusedSize: nil),
            .stuck(perturbation: CGSize(width: 1278, height: 1354)),
        )
    }

    func testKnownRefusalIsNotRetried() {
        XCTAssertEqual(
            axSizeVerdict(
                requested: CGSize(width: 1690, height: 1064),
                actual: CGSize(width: 1278, height: 1074),
                lastRefusedSize: CGSize(width: 1278, height: 1074),
            ),
            .knownRefusal,
        )
        // Sub-pixel jitter of the refused size must not re-trigger the unstick attempt
        XCTAssertEqual(
            axSizeVerdict(
                requested: CGSize(width: 1690, height: 1064),
                actual: CGSize(width: 1277, height: 1073),
                lastRefusedSize: CGSize(width: 1278, height: 1074),
            ),
            .knownRefusal,
        )
    }

    func testKnownRefusalComparesOnlyStuckDimensions() {
        // Width is pinned at 1278; the height is accepted and tracks a new layout target.
        // The cached height (captured at a different target) must not invalidate the refusal
        XCTAssertEqual(
            axSizeVerdict(
                requested: CGSize(width: 1690, height: 900),
                actual: CGSize(width: 1278, height: 900),
                lastRefusedSize: CGSize(width: 1278, height: 1074),
            ),
            .knownRefusal,
        )
    }

    func testRefusalRetriedAfterStuckDimensionChanges() {
        XCTAssertEqual(
            axSizeVerdict(
                requested: CGSize(width: 1690, height: 1064),
                actual: CGSize(width: 1400, height: 1074),
                lastRefusedSize: CGSize(width: 1278, height: 1074),
            ),
            .stuck(perturbation: CGSize(width: 1400, height: 1024)),
        )
    }

    func testPerturbationGrowsWhenShrinkWouldDegenerate() {
        // Shrinking a 120pt-high window by the nudge would go below the floor; grow instead so the
        // perturbation never degenerates into a request for the current size
        XCTAssertEqual(
            axSizeVerdict(requested: CGSize(width: 500, height: 120), actual: CGSize(width: 200, height: 120), lastRefusedSize: nil),
            .stuck(perturbation: CGSize(width: 200, height: 170)),
        )
    }
}
