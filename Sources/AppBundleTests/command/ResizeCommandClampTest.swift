@testable import AppBundle
import Common
import XCTest

/// Behavioural coverage for the 'resize' command's clamp invariant: every node
/// (focused and siblings) keeps `adaptiveWeight >= MIN_TILING_WEIGHT` after a
/// resize, no matter how large the requested delta. The clamp prevents the
/// "borders overlap" / "windows spill onto next monitor" visual bug that
/// surfaces when a sibling's weight is driven to zero or negative and macOS
/// then refuses to shrink the underlying window past its content minimum.
///
/// Tests build a flat 3-window tiling container (the simplest shape with
/// siblings to clamp against), seed weights to legal values, run
/// 'ResizeCommand', and assert that every weight in the tree is still
/// positive.
@MainActor
final class ResizeCommandClampTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // MARK: - Helpers

    /// Build a flat tiling tree of `count` windows under the workspace root.
    /// Returns the workspace and the windows in insertion order.
    private func buildFlatTree(_ count: Int) -> (Workspace, [TestWindow]) {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        for id: UInt32 in 1 ... UInt32(count) {
            windows.append(TestWindow.new(id: id, parent: workspace.rootTilingContainer))
        }
        return (workspace, windows)
    }

    /// Seed every node-with-tiles-parent's weight along its parent's orientation
    /// to `value`. Tests build a hand-synthesized starting state instead of
    /// relying on the production layout pass (which depends on a real monitor
    /// rect that doesn't exist under XCTest). MIN_TILING_WEIGHT is 100; seeding
    /// to a value well above that lets the clamp logic run on a realistic
    /// state without immediately tripping the unsatisfiable-bounds bail-out.
    private func seedWeights(_ root: TilingContainer, to value: CGFloat) {
        for child in root.children {
            child.setWeight(root.orientation, value)
        }
    }

    /// The load-bearing invariant: violation means the layout renderer would
    /// produce inverted or near-zero rects.
    private func assertAllTilesWeightsPositive(
        _ root: TilingContainer,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        for child in root.children {
            let w = child.getWeight(root.orientation)
            XCTAssertGreaterThan(
                w,
                0,
                "Non-positive weight \(w) on \(child) under \(root)",
                file: file,
                line: line,
            )
        }
    }

    /// Run a 'resize' command against the focused window with the given args.
    private func runResize(_ dimension: ResizeCmdArgs.Dimension, _ units: ResizeCmdArgs.Units) async throws {
        try await ResizeCommand(
            args: ResizeCmdArgs(rawArgs: [], dimension: dimension, units: units),
        ).run(.defaultEnv, .emptyStdin)
    }

    // MARK: - Baseline

    func testBaseline_threeWindowFlat_allWeightsPositive() {
        let (workspace, _) = buildFlatTree(3)
        seedWeights(workspace.rootTilingContainer, to: 500)
        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
    }

    // MARK: - Clamp - the "borders overlap" smoking gun

    func testClamp_deltaLargerThanSiblingSlack_keepsAllWeightsAboveMin() async throws {
        let (workspace, windows) = buildFlatTree(3)
        seedWeights(workspace.rootTilingContainer, to: 200)
        XCTAssertTrue(windows[2].focusWindow())

        // Siblings at weight 200 have only 100 slack above MIN. A delta of 1000
        // would drive a sibling to -800 without the clamp.
        try await runResize(.smart, .add(1000))

        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        for child in workspace.rootTilingContainer.children {
            XCTAssertGreaterThanOrEqual(
                child.getWeight(workspace.rootTilingContainer.orientation),
                MIN_TILING_WEIGHT,
                "Child weight below MIN_TILING_WEIGHT after clamped resize",
            )
        }
    }

    func testClamp_setAbsoluteBelowMin_clampsToMin() async throws {
        let (workspace, windows) = buildFlatTree(3)
        seedWeights(workspace.rootTilingContainer, to: 500)
        XCTAssertTrue(windows[2].focusWindow())

        // Asking to set the focused weight to 10 (well below MIN=100) must
        // clamp to MIN, not honour the literal request.
        try await runResize(.smart, .set(10))

        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        XCTAssertGreaterThanOrEqual(
            windows[2].getWeight(workspace.rootTilingContainer.orientation),
            MIN_TILING_WEIGHT,
        )
    }

    // MARK: - Idempotency

    func testIdempotency_unsatisfiableConstraints_isNoOp() async throws {
        // Sibling already below MIN. Any delta would push someone past MIN,
        // so the clamp logic must bail out cleanly rather than picking one
        // side and violating the other.
        let (workspace, windows) = buildFlatTree(3)
        seedWeights(workspace.rootTilingContainer, to: 50) // < MIN_TILING_WEIGHT
        XCTAssertTrue(windows[2].focusWindow())

        let beforeWeights = workspace.rootTilingContainer.children.map {
            ($0, $0.getWeight(workspace.rootTilingContainer.orientation))
        }

        try await runResize(.smart, .add(50))

        for (node, weight) in beforeWeights {
            XCTAssertEqual(
                node.getWeight(workspace.rootTilingContainer.orientation),
                weight,
                accuracy: 0.0001,
                "Resize should be a no-op when bounds are unsatisfiable",
            )
        }
    }

    // MARK: - Loop stability

    func testLoop_alternatingPlusMinus_weightsStayBounded() async throws {
        // The "alt-equal then alt-minus over and over" stress test: each tick
        // must keep every weight strictly positive, and no weight may drift
        // out of a reasonable range.
        let (workspace, windows) = buildFlatTree(3)
        seedWeights(workspace.rootTilingContainer, to: 500)
        XCTAssertTrue(windows[2].focusWindow())

        for _ in 0 ..< 50 {
            try await runResize(.smart, .add(10))
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)
            try await runResize(.smart, .subtract(10))
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        }

        for child in workspace.rootTilingContainer.children {
            let w = child.getWeight(workspace.rootTilingContainer.orientation)
            XCTAssertGreaterThanOrEqual(w, MIN_TILING_WEIGHT)
            XCTAssertLessThan(w, 5000, "Weight drifted far from its starting value (500)")
        }
    }

    // MARK: - Edge cases

    /// With two children, `n - 1 = 1`: the sibling absorbs the entire diff.
    /// Pinning down the trivial-but-edge division path.
    func testTwoChildren_singleSiblingAbsorbsEntireDiff() async throws {
        let (workspace, windows) = buildFlatTree(2)
        seedWeights(workspace.rootTilingContainer, to: 500)
        XCTAssertTrue(windows[1].focusWindow())

        try await runResize(.smart, .add(50))

        let root = workspace.rootTilingContainer
        XCTAssertEqual(windows[1].getWeight(root.orientation), 550, accuracy: 0.0001)
        XCTAssertEqual(windows[0].getWeight(root.orientation), 450, accuracy: 0.0001)
    }

    /// Resizing a window inside a nested wrapper must clamp against that
    /// wrapper's siblings, not the root's. A regression where the clamp
    /// walked the wrong parent would let the inner sibling go below MIN.
    func testNestedTree_resizeInsideWrapperClampsAgainstWrapperSiblings() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer // .h
        let outerWindow = TestWindow.new(id: 1, parent: root)
        outerWindow.setWeight(root.orientation, 500)
        let wrapper = TilingContainer.newVTiles(parent: root, adaptiveWeight: 500)
        let inner1 = TestWindow.new(id: 2, parent: wrapper)
        let inner2 = TestWindow.new(id: 3, parent: wrapper)
        inner1.setWeight(wrapper.orientation, 200)
        inner2.setWeight(wrapper.orientation, 200)
        XCTAssertTrue(inner2.focusWindow())

        // Smart-resize the focused inner window. Since its parent is the
        // V wrapper, the resize operates along V (height). Sibling at 200
        // has only 100 slack above MIN; a delta of 1000 must clamp.
        try await runResize(.smart, .add(1000))

        XCTAssertGreaterThanOrEqual(inner1.getWeight(wrapper.orientation), MIN_TILING_WEIGHT)
        XCTAssertGreaterThanOrEqual(inner2.getWeight(wrapper.orientation), MIN_TILING_WEIGHT)
        // The outer window is on a perpendicular axis - the smart-resize on V
        // must not have touched its H weight.
        XCTAssertEqual(outerWindow.getWeight(root.orientation), 500, accuracy: 0.0001)
    }
}
