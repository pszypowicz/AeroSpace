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
/// All tests build a 4-window BSP via 'normalizeContainers()' (the same path
/// the daemon uses), seed weights to legal values >= MIN_TILING_WEIGHT, run
/// 'ResizeCommand', and assert that every weight in the tree is still
/// positive. Mouse-drag resize ('resizeWithMouse') uses the same clamp logic
/// but is gated behind real macOS AX events; it's covered by the integration
/// path rather than these unit tests.
@MainActor
final class ResizeCommandClampTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() async throws {
        config.enableNormalizationBspShape = false
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
    }

    // MARK: - Helpers

    /// Build the canonical 4-window BSP shape used by every test in this file.
    /// Returns the workspace and the four windows in insertion order.
    @discardableResult
    private func buildFourWindowBsp() -> (Workspace, [TestWindow]) {
        config.enableNormalizationBspShape = true
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        for id: UInt32 in 1 ... 4 {
            windows.append(TestWindow.new(id: id, parent: workspace.rootTilingContainer))
        }
        workspace.normalizeContainers()
        // Sanity: exact Fibonacci shape.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([
                    .window(2),
                    .h_tiles([.window(3), .window(4)]),
                ]),
            ]),
        )
        return (workspace, windows)
    }

    /// Seed every node-with-tiles-parent's weight along its parent's orientation
    /// to `value`. Tests build a hand-synthesized starting state instead of
    /// relying on the production layout pass (which depends on a real monitor
    /// rect that doesn't exist under XCTest). MIN_TILING_WEIGHT is 100; seeding
    /// to a value well above that lets the clamp logic run on a realistic
    /// state without immediately tripping the unsatisfiable-bounds bail-out.
    private func seedWeights(_ root: TilingContainer, to value: CGFloat) {
        func walk(_ node: TreeNode) {
            if let parent = node.parent as? TilingContainer, parent.layout == .tiles {
                node.setWeight(parent.orientation, value)
            }
            for c in node.children { walk(c) }
        }
        walk(root)
    }

    /// The load-bearing invariant: violation means the layout renderer would
    /// produce inverted or near-zero rects. Returns the offending triple for a
    /// useful diagnostic when the assertion fails.
    private func assertAllTilesWeightsPositive(
        _ root: TilingContainer,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        func walk(_ node: TreeNode) {
            if let parent = node.parent as? TilingContainer, parent.layout == .tiles {
                let w = node.getWeight(parent.orientation)
                XCTAssertGreaterThan(
                    w,
                    0,
                    "Non-positive weight \(w) on \(node) under \(parent)",
                    file: file,
                    line: line,
                )
            }
            for c in node.children { walk(c) }
        }
        walk(root)
    }

    /// Run a 'resize' command against the focused window with the given args.
    private func runResize(_ dimension: ResizeCmdArgs.Dimension, _ units: ResizeCmdArgs.Units) async throws {
        try await ResizeCommand(
            args: ResizeCmdArgs(rawArgs: [], dimension: dimension, units: units),
        ).run(.defaultEnv, .emptyStdin)
    }

    // MARK: - Baseline

    func testBaseline_fourWindowBsp_allWeightsPositive() {
        let (workspace, _) = buildFourWindowBsp()
        seedWeights(workspace.rootTilingContainer, to: 500)
        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
    }

    // MARK: - Clamp - the "borders overlap" smoking gun

    func testClamp_deltaLargerThanSiblingSlack_keepsAllWeightsAboveMin() async throws {
        let (workspace, windows) = buildFourWindowBsp()
        seedWeights(workspace.rootTilingContainer, to: 200)
        XCTAssertTrue(windows[3].focusWindow())

        // Sibling at weight 200 has only 100 slack above MIN. A delta of 1000
        // would drive the sibling to -800 without the clamp.
        try await runResize(.smart, .add(1000))

        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        // Every node along the resized orientation must still respect the floor.
        let parent = windows[3].parent as! TilingContainer
        for child in parent.children {
            XCTAssertGreaterThanOrEqual(
                child.getWeight(parent.orientation),
                MIN_TILING_WEIGHT,
                "Child weight \(child.getWeight(parent.orientation)) below MIN_TILING_WEIGHT after clamped resize",
            )
        }
    }

    func testClamp_setAbsoluteBelowMin_clampsToMin() async throws {
        let (workspace, windows) = buildFourWindowBsp()
        seedWeights(workspace.rootTilingContainer, to: 500)
        XCTAssertTrue(windows[3].focusWindow())

        // Asking to set the focused weight to 10 (well below MIN=100) must
        // clamp to MIN, not honour the literal request.
        try await runResize(.smart, .set(10))

        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        let parent = windows[3].parent as! TilingContainer
        XCTAssertGreaterThanOrEqual(
            windows[3].getWeight(parent.orientation),
            MIN_TILING_WEIGHT,
        )
    }

    // MARK: - Idempotency

    func testIdempotency_unsatisfiableConstraints_isNoOp() async throws {
        // Sibling already below MIN. Any delta would push someone past MIN,
        // so the clamp logic must bail out cleanly rather than picking one
        // side and violating the other.
        let (workspace, windows) = buildFourWindowBsp()
        seedWeights(workspace.rootTilingContainer, to: 50) // < MIN_TILING_WEIGHT
        XCTAssertTrue(windows[3].focusWindow())

        let beforeWeights = workspace.rootTilingContainer.children.map { ($0, $0.getWeight(.h)) }

        try await runResize(.smart, .add(50))

        // No-op: weights unchanged when constraints are unsatisfiable.
        for (node, weight) in beforeWeights {
            XCTAssertEqual(
                node.getWeight(.h),
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
        let (workspace, windows) = buildFourWindowBsp()
        seedWeights(workspace.rootTilingContainer, to: 500)
        XCTAssertTrue(windows[3].focusWindow())

        for _ in 0 ..< 50 {
            try await runResize(.smart, .add(10))
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)
            try await runResize(.smart, .subtract(10))
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        }

        // Bounded: weights haven't run away. Starting from 500, asymmetric
        // clamping at the boundary can drift each weight, but never far.
        func walk(_ node: TreeNode) {
            if let parent = node.parent as? TilingContainer, parent.layout == .tiles {
                let w = node.getWeight(parent.orientation)
                XCTAssertGreaterThanOrEqual(w, MIN_TILING_WEIGHT)
                XCTAssertLessThan(w, 5000, "Weight drifted far from its starting value (500)")
            }
            for c in node.children { walk(c) }
        }
        walk(workspace.rootTilingContainer)
    }
}
