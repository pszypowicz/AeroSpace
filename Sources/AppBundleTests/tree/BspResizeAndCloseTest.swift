@testable import AppBundle
import Common
import XCTest

/// Exercises resize and close interactions on BSP trees built via `split-mru`.
///
/// These tests cover scenarios the user hit manually with the dev binary:
///  - resize with deltas comparable to or larger than the sibling's weight,
///  - closing windows in the middle of a BSP tree and letting flatten clean up,
///  - loops of resize/close/spawn that should not drift weights or produce
///    non-positive sibling weights.
///
/// Core invariant every test asserts after each mutation:
///
///   Every window (and every TilingContainer) whose parent is a `.tiles`
///   TilingContainer has `getWeight(parent.orientation) > 0`.
///
/// Negative or zero weights are the smoking gun for the "borders overlap /
/// borders too far apart" visual bug: the layout math distributes each child's
/// share as `weight / sum(siblingWeights) * parentSize`, so a negative weight
/// makes that child's rect invert, and a negative sum makes every child's
/// rect invert.
@MainActor
final class BspResizeAndCloseTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.tilingInsertionStrategy = .splitMru
    }

    // MARK: - Helpers

    /// Build a 4-window BSP tree via split-mru (the realistic daily-driver shape).
    /// Returns the workspace and the four windows in insertion order.
    @discardableResult
    private func buildFourWindowBsp() async throws -> (Workspace, [TestWindow]) {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        for id: UInt32 in 1 ... 4 {
            let w = TestWindow.new(id: id, parent: workspace.rootTilingContainer)
            try await w.relayoutWindow(on: workspace, forceTile: true)
            windows.append(w)
        }
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

    /// Walks the tree and returns every (node, parent, weight-along-parent-orientation)
    /// tuple for nodes whose parent is a `.tiles` TilingContainer.
    private func tilesWeightTriples(_ root: TilingContainer) -> [(node: TreeNode, parent: TilingContainer, weight: CGFloat)] {
        var result: [(TreeNode, TilingContainer, CGFloat)] = []
        func walk(_ node: TreeNode) {
            if let parent = node.parent as? TilingContainer, parent.layout == .tiles {
                result.append((node, parent, node.getWeight(parent.orientation)))
            }
            for c in node.children { walk(c) }
        }
        walk(root)
        return result
    }

    /// The load-bearing invariant. Violation = layout math produces inverted rects.
    private func assertAllTilesWeightsPositive(_ root: TilingContainer, file: StaticString = #filePath, line: UInt = #line) {
        for triple in tilesWeightTriples(root) {
            XCTAssertGreaterThan(
                triple.weight,
                0,
                "Non-positive weight \(triple.weight) for \(triple.node) under \(triple.parent)",
                file: file,
                line: line,
            )
        }
    }

    // MARK: - Baseline

    func testFourWindowBsp_baseline_allWeightsPositive() async throws {
        let (workspace, _) = try await buildFourWindowBsp()
        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        // Sanity: every tiles container's children have equal weight by default (1).
        for triple in tilesWeightTriples(workspace.rootTilingContainer) {
            XCTAssertEqual(triple.weight, 1.0, accuracy: 0.0001)
        }
    }

    // MARK: - Resize — small delta

    func testResize_smart_smallDelta_preservesPositiveWeights() async throws {
        let (workspace, windows) = try await buildFourWindowBsp()
        let w4 = windows[3]
        XCTAssertTrue(w4.focusWindow())

        try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .add(1))).run(.defaultEnv, .emptyStdin)

        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
    }

    // MARK: - Resize — the "borders overlap" smoking gun

    func testResize_smart_deltaLargerThanSibling_clampedToKeepWeightsPositive() async throws {
        // Regression for the "borders overlap / borders too far apart" visual bug:
        // before the ResizeCommand clamp landed, 'resize smart +50' on a weight-1
        // BSP window drove the sibling's weight to -49, and the layout renderer
        // produced inverted rects. After the fix, the delta is clamped so every
        // sibling stays >= MIN_TILING_WEIGHT.
        let (workspace, windows) = try await buildFourWindowBsp()
        let w4 = windows[3]
        XCTAssertTrue(w4.focusWindow())

        try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .add(50))).run(.defaultEnv, .emptyStdin)

        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
    }

    // MARK: - Resize — loop (left/right in a loop)

    func testResize_smart_plusMinusLoop_weightsStayPositiveAndBounded() async throws {
        // The "left and right in a loop" stress test the user asked for. The loop
        // is intentionally asymmetric at the boundary: the first `+1` on a weight-1
        // window gets clamped (sibling can't go below MIN_TILING_WEIGHT) while the
        // following `-1` applies fully, so weights drift within a small window —
        // but every intermediate state must keep every tiles child strictly positive
        // and no weight may explode. This mirrors what the user would feel
        // hammering alt-minus / alt-equal over and over without producing the
        // "borders overlap" visual bug.
        let (workspace, _) = try await buildFourWindowBsp()
        let focused = workspace.allLeafWindowsRecursive.last!
        XCTAssertTrue(focused.focusWindow())

        for _ in 0 ..< 20 {
            try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .add(1))).run(.defaultEnv, .emptyStdin)
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)
            try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .subtract(1))).run(.defaultEnv, .emptyStdin)
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        }

        // Bounded: every leaf weight within a sensible range even after many loops.
        for triple in tilesWeightTriples(workspace.rootTilingContainer) {
            XCTAssertGreaterThanOrEqual(triple.weight, MIN_TILING_WEIGHT)
            XCTAssertLessThan(triple.weight, 100.0, "Weight drifted far from its starting value (1.0)")
        }
    }

    // MARK: - Close

    func testClose_middleWindow_leavesValidBspShape() async throws {
        config.enableNormalizationFlattenContainers = true
        let (workspace, windows) = try await buildFourWindowBsp()
        let w3 = windows[2]

        // Closing w3 leaves h_tiles([w3, w4]) with only w4. Flatten must collapse.
        w3.unbindFromParent()
        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(4)]),
            ]),
        )
        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
    }

    func testClose_rootLevelWindow_leavesValidBspShape() async throws {
        config.enableNormalizationFlattenContainers = true
        let (workspace, windows) = try await buildFourWindowBsp()
        let w1 = windows[0]

        w1.unbindFromParent()
        workspace.normalizeContainers()

        // Initial shape: h([w1, v([w2, h([w3, w4])])]).
        // After removing w1, the root h_tiles has a single tiling-container child,
        // so unbindEmptyAndAutoFlatten collapses the root. The workspace's
        // rootTilingContainer is then the former v_tiles wrapper — its orientation
        // is 'v' rather than the workspace's default 'h'. This is the existing
        // flatten behavior for single-container-child roots (see the
        // `child is TilingContainer || !isRootContainer` guard in
        // normalizeContainers.swift).
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .v_tiles([
                .window(2),
                .h_tiles([.window(3), .window(4)]),
            ]),
        )
        assertAllTilesWeightsPositive(workspace.rootTilingContainer)
    }

    // MARK: - Loop: resize + close + spawn + resize

    func testResizeCloseSpawn_combinedLoop_weightsStayPositive() async throws {
        config.enableNormalizationFlattenContainers = true
        let (workspace, windows) = try await buildFourWindowBsp()

        for _ in 0 ..< 5 {
            // Focus and resize the last window we know about.
            let last = workspace.allLeafWindowsRecursive.last ?? windows[0]
            _ = last.focusWindow()
            try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .add(1))).run(.defaultEnv, .emptyStdin)
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)

            // Close the focused window.
            last.unbindFromParent()
            workspace.normalizeContainers()
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)

            // Spawn a fresh window via split-mru.
            let fresh = TestWindow.new(id: UInt32(100 + Int.random(in: 0 ... 1000)), parent: workspace.rootTilingContainer)
            try await fresh.relayoutWindow(on: workspace, forceTile: true)
            workspace.normalizeContainers()
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)

            // Resize the fresh window the other direction.
            _ = fresh.focusWindow()
            try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .subtract(1))).run(.defaultEnv, .emptyStdin)
            assertAllTilesWeightsPositive(workspace.rootTilingContainer)
        }
    }
}
