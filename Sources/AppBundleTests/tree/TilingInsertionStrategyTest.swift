@testable import AppBundle
import Common
import XCTest

@MainActor
final class TilingInsertionStrategyTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    // MARK: - General case

    func testSplitMru_emptyWorkspace_appendsToRoot() async throws {
        config.tilingInsertionStrategy = .splitMru
        let workspace = Workspace.get(byName: name)

        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await w1.relayoutWindow(on: workspace, forceTile: true)

        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    func testSplitMru_oneWindowRoot_appendsAsSiblingWithoutFlip() async throws {
        // Single-window root: there is no alternation invariant to maintain yet,
        // so the second window lands as a plain sibling without flipping the root.
        config.tilingInsertionStrategy = .splitMru
        let workspace = Workspace.get(byName: name)
        let initialRootOrientation = workspace.rootTilingContainer.orientation

        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await w2.relayoutWindow(on: workspace, forceTile: true)

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
        assertEquals(workspace.rootTilingContainer.orientation, initialRootOrientation)
    }

    func testSplitMru_threeWindows_wrapsMruInOppositeOrientation() async throws {
        config.tilingInsertionStrategy = .splitMru
        let workspace = Workspace.get(byName: name)

        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await w2.relayoutWindow(on: workspace, forceTile: true)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        try await w3.relayoutWindow(on: workspace, forceTile: true)

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testSplitMru_fourWindows_producesFibonacciBspShape() async throws {
        config.tilingInsertionStrategy = .splitMru
        let workspace = Workspace.get(byName: name)

        for id: UInt32 in 1 ... 4 {
            let window = TestWindow.new(id: id, parent: workspace.rootTilingContainer)
            try await window.relayoutWindow(on: workspace, forceTile: true)
        }

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
    }

    func testSplitMru_mruIsNotLastSibling_wrapsCorrectSibling() async throws {
        config.tilingInsertionStrategy = .splitMru
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        // Make the middle window the MRU.
        let w2 = (root.children[1] as! Window)
        w2.markAsMostRecentChild()

        let w4 = TestWindow.new(id: 4, parent: root)
        try await w4.relayoutWindow(on: workspace, forceTile: true)

        // w2 (the middle sibling) is wrapped, not w3 (the last sibling).
        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(4)]),
                .window(3),
            ]),
        )
    }

    // MARK: - Fallback edge cases

    func testSplitMru_mruInAccordionContainer_fallsBackToSibling() async throws {
        config.tilingInsertionStrategy = .splitMru
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer(parent: $0, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        // MRU is w3, parent is the accordion container.
        let w3 = (root.children[1].children[1] as! Window)
        w3.markAsMostRecentChild()

        let w4 = TestWindow.new(id: 4, parent: root)
        try await w4.relayoutWindow(on: workspace, forceTile: true)

        // The accordion subtree is treated as an escape island: w4 lands as a
        // plain sibling of w3 inside the accordion, not wrapped in a new container.
        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .window(1),
                .h_accordion([.window(2), .window(3), .window(4)]),
            ]),
        )
    }

    func testSplitMru_mruInSingleChildNonRootContainer_flipsInPlace() async throws {
        // Regression for the flatten-collapses-our-wrap edge case: when MRU's parent
        // has only the MRU as its child, wrapping would be undone by
        // unbindEmptyAndAutoFlatten on the next refresh. The strategy must instead
        // flip the parent's orientation in place and append as a sibling.
        config.tilingInsertionStrategy = .splitMru
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TilingContainer(parent: $0, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST).apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }
        let inner = (root.children[0] as! TilingContainer)
        XCTAssertEqual(inner.orientation, .h)
        XCTAssertEqual(inner.children.count, 1)

        let w2 = TestWindow.new(id: 2, parent: root)
        try await w2.relayoutWindow(on: workspace, forceTile: true)

        // inner flipped from .h to .v; w2 landed inside it as a sibling of w1.
        assertEquals(
            root.layoutDescription,
            .h_tiles([
                .v_tiles([.window(1), .window(2)]),
            ]),
        )
        XCTAssertEqual(inner.orientation, .v)
    }

    // MARK: - Weight & normalization interactions

    func testSplitMru_weightInheritance_wrapperInheritsMruWeight() async throws {
        config.tilingInsertionStrategy = .splitMru
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 5)
        }

        let w3 = TestWindow.new(id: 3, parent: root)
        try await w3.relayoutWindow(on: workspace, forceTile: true)

        // The new wrapper occupies w2's slot, so it must carry w2's horizontal weight (5).
        let wrapper = root.children[1] as! TilingContainer
        XCTAssertEqual(wrapper.getWeight(.h), 5)
    }

    func testSplitMru_withFlattenNormalizationEnabled_doesNotCollapseFreshWrap() async throws {
        // Inserting via split-mru produces a 1-child wrapper momentarily during the
        // dispatch, but by the time normalizeContainers() runs the wrapper holds
        // exactly two children. Flatten must therefore leave it alone.
        config.tilingInsertionStrategy = .splitMru
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)

        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await w2.relayoutWindow(on: workspace, forceTile: true)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        try await w3.relayoutWindow(on: workspace, forceTile: true)
        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testSplitMru_withOppositeOrientationNormalizationDisabled_stillProducesBsp() async throws {
        // The opposite-orientation normalizer is the safety net for non-BSP shapes.
        // Even with it off, the strategy itself must pick the opposite orientation
        // at wrap time — verified by the resulting tree shape.
        config.tilingInsertionStrategy = .splitMru
        config.enableNormalizationOppositeOrientationForNestedContainers = false
        let workspace = Workspace.get(byName: name)

        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await w2.relayoutWindow(on: workspace, forceTile: true)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        try await w3.relayoutWindow(on: workspace, forceTile: true)

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([
                .window(1),
                .v_tiles([.window(2), .window(3)]),
            ]),
        )
    }

    func testSplitMru_closeWindow_flattenCollapsesStaleWrapper() async throws {
        // After building a 3-window BSP shape, closing the window inside the
        // wrapper leaves a 1-child wrapper that flatten must collapse.
        config.tilingInsertionStrategy = .splitMru
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)

        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await w2.relayoutWindow(on: workspace, forceTile: true)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        try await w3.relayoutWindow(on: workspace, forceTile: true)

        // Sanity: the BSP shape is in place.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]),
        )

        // Closing w2 leaves wrapper holding only w3.
        w2.unbindFromParent()
        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(3)]),
        )
    }

    // MARK: - Default behavior regression

    func testSiblingOfMru_isDefault_unchangedBehavior() async throws {
        // Default config must continue to insert as a sibling of the MRU at the
        // root (no wrapping, no flipping). This guards against any accidental
        // behavior change from the refactor or the new branch.
        XCTAssertEqual(config.tilingInsertionStrategy, .siblingOfMru)
        let workspace = Workspace.get(byName: name)

        for id: UInt32 in 1 ... 4 {
            let window = TestWindow.new(id: id, parent: workspace.rootTilingContainer)
            try await window.relayoutWindow(on: workspace, forceTile: true)
        }

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .window(3), .window(4)]),
        )
    }
}
